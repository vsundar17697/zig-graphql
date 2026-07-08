# Roadmap to v1.0 — "Hasura-core parity, general-purpose"

Target: pg-gql is usable for a real project the way Hasura graphql-engine is — point it at
any reasonable Postgres database and get an authenticated, permission-filtered, observable
GraphQL API — in two consumption modes:

1. **Server mode**: a single static binary + a browser console (GraphiQL + schema explorer),
   deployable against managed Postgres (RDS/Cloud SQL/Neon), safe to expose to untrusted
   clients.
2. **Library mode**: an embeddable Zig package and a stable, versioned C ABI, so a host
   application can run the whole pipeline in-process — including permission-enforced
   execution, not just raw queries.

## Scope honesty: what "Hasura-level" means here

v1.0 targets **Hasura's core single-Postgres experience**: queries, mutations,
subscriptions, role-based row/column permissions with session variables, a metadata/config
system, and a console. It explicitly does **not** target Hasura's platform features —
actions, remote schemas, event triggers, scheduled triggers, multi-database federation,
query caching, Relay endpoints, or migrations tooling. Pagination is offset-based, matching
Hasura's core (non-Relay) surface; cursor/Relay-style pagination is an explicit v2 decision,
not an omission — nothing in the IR forecloses it. Those are all v2 candidates; nothing in
the v1 plan should foreclose them, but none gate v1.

## Where we start (verified 2026-07-07)

Milestones 1–4.5 delivered: the full read path (filters, order/limit/offset, object+array
relationships, exists, aggregates, NDC variable batching), auto-derived insert/update/delete
procedures with transactions (ADRs 0010/0011) — including multi-root-field mutation documents
collapsing to one transactional MutationRequest (ADR 0014) — permanent relationship naming
(ADR 0012), a cached GraphQL type system with SDL generation (ADR 0013), and a spec-shaped
`POST /graphql` endpoint with document variables, `operationName`, fragments,
`@skip`/`@include`, and executable `__schema`/`__type` introspection (ADR 0014). A connection
pool exists (`pg_wire/pool.zig`). ~200 unit tests plus Postgres-backed integration tests pass.

Known-good foundations a design review confirmed (so later milestones can lean on them):
identifier quoting doubles embedded quotes and values are only ever `$N` parameters (the
injection boundary holds); mutation transaction semantics are already correct.

What the current state adds up to: **the engine works; it is not yet safe, broad, or
operable.** No TLS, no auth(n/z), narrow scalar *and operator* coverage, mutations limited to
single-object insert and by-PK update/delete, live-introspection-only startup, a
thread-per-connection server on a debug allocator, no limits, no observability, no version
control. The milestones below close exactly those gaps, ordered by dependency.

---

## Milestone 5 — Repo, CI, and fuzzing baseline

The cheapest milestone and the one everything else compounds on. Currently the project has
**zero git commits**.

- `git init` + initial commit of pg-gql (the sibling `graphql-engine`/`ndc-postgres` clones
  stay untracked reference material or move out of the repo).
- CI (GitHub Actions): `zig build test` on every push; `zig build test-integration` against a
  Postgres service container; build matrix for macOS/Linux, x86_64/aarch64.
- Fuzzing harness for the two untrusted-input surfaces: the GraphQL lexer/parser and the NDC
  request JSON decoder. Plan A is Zig's built-in `zig build --fuzz`; it is still immature in
  0.16, so the named fallback is libFuzzer/AFL++ driving the parser through a small C-ABI
  harness (which already exists). Wire into CI as a short smoke-fuzz; keep a longer local
  target.
- Catch up `roadmap.md` with milestone 3/4/4.5 entries and write the missing ADR 0015
  (connection pool) that `pool.zig` already references.

Exit criteria: green CI badge on a real remote; fuzzers (real coverage-guided ones, not a
random-input loop) run clean for a sustained local run.

## Milestone 6 — Postgres driver: adopt libpq, harden connection lifecycle

Decision (ADR 0016, accepted 2026-07-07, supersedes ADR 0001): replace the hand-rolled
wire-protocol internals with **libpq**, linked through Zig's native C interop, while keeping
`pg_wire`'s public interface ("run this parameterized SQL, hand back rows" + the pool) so
`sql_gen`, `executor`, and both server/library consumers are untouched — exactly the seam
the architecture deliberately preserved.

What this buys immediately: TLS 1.2 **and** 1.3 with `sslmode=verify-full` and
client-certificate auth (the single biggest risk in the previous plan — a TLS 1.2 story for
RDS/Azure — disappears), every auth method maintained upstream, query cancellation
(`PQcancel`), and two decades of protocol edge-case handling. The native wire client and
SCRAM implementation are retired (git history keeps them; ADR 0002 becomes historical).

The honest cost — distribution: pg-gql now links libpq (and its OpenSSL), so "single static
binary" and Zig's trivially-cross-compiling build get harder, and C-ABI consumers link libpq
too. ADR 0016 documents the per-platform packaging strategy (static libpq+OpenSSL for
release artifacts, dynamic for library mode).

- **The migration itself**: `pg_wire` internals → libpq (`PQconnectdb`/`PQexecParams`); the
  pool manages `PGconn` handles; the existing integration suite must pass unchanged.
- **Array parameter binding** (arrays as Postgres array literals through `PQexecParams`):
  unblocks `_in` with variables (deferred since M2) and is a prerequisite for array scalar
  types and array operators in M7.
- **Connection lifecycle**: connect/statement timeouts; cancellation on client disconnect;
  pool health checks (validate-on-acquire after idle), max-lifetime recycling, and
  reconnect-on-failure instead of failing the request.
- **Prepared-statement caching** per pooled connection (`PQprepare`, keyed by SQL text),
  now that SQL text is stable per query shape.
- Scope note: the **outbound HTTPS client** (JWKS fetch, webhook authn) is no longer covered
  by this milestone's TLS decision; it moves to ADR 0021 (Zig `std.http.Client`'s TLS
  1.3-only support is acceptable for identity providers, unlike for managed Postgres).

Exit criteria: full integration suite green on libpq against (a) a TLS-required managed
Postgres (e.g. free-tier Neon) in CI **and** (b) a local Postgres pinned to
`ssl_max_protocol_version = TLSv1.2`; a kill-the-database-mid-query test recovers cleanly; a
release artifact linking libpq statically runs on a clean machine.

## Milestone 7 — Type-system and query-capability breadth

The current scalar set (ints, text, bool, float, timestamps-as-text) and operator set
(`eq/neq/gt/gte/lt/lte/in` + `is_null`) cover demos, not general schemas. This milestone is
"point it at a database you didn't design, ask the questions a real app asks, and nothing is
missing or silently wrong."

Types:

- New scalars: `uuid`, `date`/`time`/`timetz`/`interval`, `json`/`jsonb` (passed through as
  structured JSON, not text), `bytea` (base64), `numeric` **as string by default** —
  representing money-safe decimals as IEEE floats is the classic silent-corruption bug;
  an explicit per-type representation policy (ADR 0017) decides string vs float vs int per
  scalar, Hasura/ndc-postgres-style.
- Postgres **enums** → GraphQL enums; **array columns** → GraphQL lists (depends on M6 array
  binding); **domains** resolve to their base type.
- Introspection moves from `information_schema` to `pg_catalog` (correctness for exotic
  relkinds and speed on large schemas), gains multi-schema support with a configurable schema
  allowlist and a naming policy for cross-schema collisions, and picks up materialized views,
  partitioned tables, and foreign tables.
- Unknown/unsupported column types degrade gracefully (column exposed as opaque text or
  skipped with a startup warning — never a crash, never a silent wrong value).

Query capabilities (day-one Hasura features that change IR shapes, so they land **before**
the metadata and permission formats freeze):

- Text operators `_like`/`_ilike`/`_similar`/regex; `jsonb` containment (`_contains`,
  `_contained_in`, `_has_key`); array operators. Note: the permission predicates of M10
  inherit exactly whatever operator set exists at this point.
- `order_by` gains `nulls_first`/`nulls_last`, ordering by related columns and by
  relationship aggregates (requires `OrderByTarget` to grow a relationship path — an IR
  change), and `distinct_on`.
- A **GraphQL validation phase**: document variables type-checked against declared variable
  types (today they substitute unchecked), field-merge validation, fragment-spread type
  validity, and correct null-propagation semantics for non-null fields in the response
  envelope. Apollo/Relay-class clients trip on exactly these edges.

Exit criteria: introspect + query a "nasty schema" fixture (every supported type, arrays,
enums, domains, three schemas, a partitioned table, a matview) with round-trip value
fidelity tests per type, in CI; operator matrix tests; a validation-error conformance test
set (bad variables, conflicting field merges) returning spec-shaped errors.

## Milestone 8 — Mutation breadth

Verified current state: single-object insert, update/delete **by primary key only**, `_set`
only, and relationship fields in `returning` explicitly rejected. A real team hits
`update_<t>(where: ...)`, upsert, and multi-row insert in week one. This has ordering teeth:
mutation names and argument shapes are permanent public API (ADR 0010's own rule), they get
snapshotted into metadata (M9), analyzed by the permission model (M10), and frozen into the
C ABI (M14) — retrofitting them later means redoing that work. So this lands **before**
metadata and permissions.

- **Bulk insert**: `insert_<t>(objects: [...])`, one statement, transactional.
- **Where-based update/delete**: `update_<t>(where: ..., _set: ...)` / `delete_<t>(where:
  ...)` reusing the full M7 expression surface; `affected_rows` + `returning` in the
  response.
- **Upsert**: `on_conflict: {constraint, update_columns}` on inserts, Hasura-shaped.
- **Update operators** beyond `_set`: `_inc` for numerics; `_append`/`_prepend`/
  `_delete_key` etc. for `jsonb`.
- **Relationship fields in `returning`** (lifting ADR 0010's `UnsupportedReturningField`
  restriction by reusing the read path's JSON-shaping machinery over the mutation's row set).
- ADR 0018 fixes the new names and argument shapes permanently, superseding the relevant
  parts of ADR 0010.

Exit criteria: Hasura-parity mutation matrix (bulk, where-update, upsert,
`_inc`/jsonb operators, nested returning) passing against real Postgres; by-PK forms remain
byte-compatible.

## Milestone 9 — Metadata: introspect once, serve from config

Live-introspection-at-startup means schema drift silently changes the API and startup
requires DB access. Hasura's real spine is its metadata; this is ours.

- A versioned **metadata file** (JSON; one document): the introspected schema snapshot plus
  everything layered on it — naming overrides, included/excluded tables and columns, manual
  relationships (beyond FK-derived), and (M10) permissions. `pg-gql introspect` writes it;
  the production server *serves from it* and never introspects implicitly. Schema drift
  becomes an explicit, diffable re-introspect. A loud, explicitly-non-production **`--dev`
  mode** auto-introspects (and refreshes the metadata file) on boot — this is what makes the
  five-minute console onboarding (M13) possible without breaking the production rule.
- **The permission-predicate serialization is part of this format.** ADR 0019 (metadata
  format/versioning) and the serialized-predicate half of ADR 0020 are **drafted together**,
  even though enforcement code lands in M10 — otherwise metadata goes to v2 one milestone
  after v1, plus migration machinery nobody budgeted.
- **Native queries**: named parameterized SQL statements declared in metadata, exposed as
  read-only collections through the existing pipeline (ndc-postgres "native operations",
  Hasura "logical models"). This is the escape hatch that makes "general purpose" honest —
  anything the IR can't express yet remains reachable.
- Startup validation: metadata-vs-database reconciliation with clear errors (the ADR 0004
  runtime-validation machinery generalizes here), plus a `pg-gql validate` subcommand.
- The library mode consumes the same metadata: pass a metadata document instead of a live
  introspection call.

Exit criteria: production server boots with no DB introspection round-trip; metadata diff
test (introspect → mutate DB → re-introspect) produces a clean, reviewable diff; a native
query appears in SDL and executes; `--dev` mode round-trip works.

## Milestone 10 — Authorization: roles, session variables, permission predicates

The single feature that makes Hasura *Hasura*, and the hard gate for exposing pg-gql to
untrusted clients. Enforcement lives in a **new top-level `authz` module** — a distinct
layer with the signature `(NDC IR, role, session variables, metadata) → validated and
rewritten IR` — sitting between all three producers and `sql_gen` in the module graph.
Row filters compile to `ndc_ir.Expression` conjuncts injected there — enforcement at the IR
boundary all three producers share. But that "for free"
claim holds **only for row filters**; column-level rules need their own IR-level enforcement
(below), because the raw-NDC producer never consults the GraphQL type system.

- **Session resolution (server)**: three authn modes, Hasura-compatible in spirit — static
  admin secret; **JWT** (HS256 via std.crypto HMAC; RS256 via `std.crypto.Certificate.rsa`
  — a semi-internal, verify-only API, so ADR 0021 includes a spike assembling JWKS `n`/`e`
  into std's key type, with ES256 via std ECDSA as the well-supported path; JWKS URL fetch
  with caching, on M6's HTTPS client); and **webhook** mode. Output of all three: a role
  plus a map of session variables.
- **Library-mode authorization is a first-class API**: the core enforcement entry point
  takes `(role, session-variable map)` directly; HTTP session resolution is a thin producer
  of that pair. This is what keeps authn server-only and authz in the core — and what the
  C ABI freezes in M14, so it's designed here, not discovered during the ABI audit.
- **Permission model in metadata, per role per collection**: select/insert/update/delete
  permissions; **row filters** as NDC-expression-shaped predicates referencing session
  variables (`{"user_id": {"_eq": "X-Session-User-Id"}}`); **insert/update `check`
  predicates enforced post-write within the transaction** — a filter constrains which rows
  you may *target*, not what the row may look like *after* the write; without `check`, an
  update can set `owner_id` to someone else and pass; **column allowlists**; per-role
  **select row limits** (the cheap parity feature that prevents unbounded dumps); insert
  **column presets** from session variables; aggregate-permission flag.
- **Enforcement point honesty**: column allowlists and the aggregate flag are enforced by
  **IR validation** — every column/aggregate reference in an incoming IR is checked against
  the role's permissions — *and* reflected in the per-role schema. Schema shaping alone
  would leave raw `POST /query` as a column-permission bypass.
- **NDC endpoints get an explicit auth mode**: `/query`/`/mutation`/`/schema` are
  admin-secret-gated by default, with an opt-in role-resolved mode. Today they are
  unauthenticated; that ends here.
- **Role-specific type systems**: the M4 cached-TypeSystem artifact becomes per-role — SDL
  and `__schema` for a role show only what that role can touch. Anything else leaks schema.
- Depth of enforcement: filters apply to relationship hops, exists subqueries, and aggregate
  inputs, not just top-level collections. The adversarial suite ("can role X ever see a row
  or column it shouldn't, via any path") includes **raw-NDC probes** for masked columns and
  aggregates, not just GraphQL-path probes.

Exit criteria: the adversarial permission suite (GraphQL and raw-NDC probes, including
check-predicate violation attempts) passes; an example two-role app (anon + user with row
ownership) runs end-to-end with JWTs in an integration test; a library-mode consumer
enforces the same permissions with no HTTP layer present.

## Milestone 11 — Production server: concurrency, limits, observability

- **Server concurrency and memory model (ADR 0022)** — the current model is one detached OS
  thread per accepted connection, each with its own `std.Io.Threaded` pool, one request per
  connection (no keep-alive), all on `std.heap.DebugAllocator`. That substrate fails a soak
  test regardless of what else this milestone ships, and cannot carry M12's long-lived
  subscription connections. Deliverables: bounded-worker or evented connection handling,
  HTTP keep-alive, a production allocator decision (arena-per-request over a
  general-purpose backing allocator), and the connection-scheduling foundation M12's poll
  scheduler will sit on.
- **Request protection**: GraphQL depth and node-count limits, request body size cap,
  per-request timeout wired through to statement timeout + cancellation (M6), pool-acquire
  timeout with 503 backpressure. Sane defaults, all configurable.
- **Configuration**: one coherent story for flags/env vars (port, pool size, limits, auth
  mode, metadata path, TLS...), with `pg-gql --help` as the reference.
- **Observability**: structured JSON logs with per-request IDs; Prometheus `/metrics`
  (request counts/latencies by endpoint and outcome, pool utilization, per-query-shape
  timing); OpenTelemetry traces (HTTP span → SQL span) exported over OTLP — ADR 0024
  decides between hand-emitting OTLP/HTTP (small, dependency-free) and binding
  opentelemetry-cpp through its C wrapper via Zig's C interop (there is no official pure-C
  OTel SDK; the C++ one is linkable but heavyweight); `/healthz` (liveness) and `/readyz`
  (DB-reachable readiness).
- **Lifecycle**: graceful shutdown (drain in-flight, close pool); metadata hot-reload on
  SIGHUP as an **atomic pointer swap** of the `SchemaModel` + per-role TypeSystems, with the
  old generation retired only after in-flight requests drain — these artifacts are shared
  across connection threads as bare pointers, and freeing under a live reader is a
  use-after-free.
- Error envelope audit: every failure path produces a spec-shaped GraphQL error or NDC
  error, never a raw 500 with internals, never a leaked SQL string to a non-admin.

Exit criteria: a 24h soak test under mixed keep-alive load with a chaos step (DB restart
mid-run) shows no leaks (stable RSS), bounded thread count, no stuck connections, and clean
metrics/traces throughout.

## Milestone 12 — Subscriptions (live queries)

Heaviest new machinery, so it comes after the platform is safe and observable — after M10
because subscriptions must enforce permissions identically to queries, and after M11 because
they sit on its connection-scheduling model.

- **Transport**: WebSocket upgrade on `/graphql` implementing the `graphql-transport-ws`
  protocol (what Apollo/urql/graphql-ws speak). RFC 6455 framing is hand-rolled and
  contained; the connection-lifetime problem is M11's scheduler, not per-socket threads.
- **Semantics**: Hasura-style **polling live queries** — a **single shared poll scheduler**
  re-runs compiled SQL on an interval (default 1s, configurable), diffs a result hash,
  pushes on change. No triggers, no logical decoding in v1 (ADR 0023).
- **Multiplexing** (the actual hard part at scale): subscriptions sharing a query shape
  batch into one SQL execution over a variable set — which the M2 NDC variable-batching
  machinery already knows how to run. Ship single-flight polling first, multiplex second —
  but multiplexing is in-milestone, not deferred, because the exit criteria measure it.
- Connection-level auth (JWT at WS init, expiry closes the socket), per-connection
  subscription cap, and pool isolation so pollers can't starve request traffic.

Exit criteria: 1k concurrent idle same-shape subscriptions on one modest instance with flat
memory, **bounded thread count, and O(1) SQL executions per poll tick** (a DB-query-rate
ceiling, not just RSS — 1k unmultiplexed 1s pollers is 1k queries/sec and would still "pass"
a memory-only check); a change-propagation latency test; permission-revocation test (role's
rows stop flowing).

## Milestone 13 — Console UI

"Usable as a UI" — a browser workspace served by the binary itself at `/console`, no
separate deploy.

- **GraphiQL** (vendored static assets, no CDN dependency) preconfigured against `/graphql`
  with header/JWT management — introspection already works, so this is mostly packaging.
- **Schema explorer**: rendered SDL, collections/relationships browser, per-role schema
  preview (pick a role, see its schema) — all driven by existing introspection JSON.
- **Ops panel**: health, pool stats, config summary — read-only views over `/metrics` and
  `/healthz`.
- Console is admin-secret-gated and can be compiled out / disabled by flag.
- Explicit non-goal: Hasura console's data browser and metadata *editor* (metadata stays a
  file you edit and validate; the console visualizes it). Editing UI is v2.

Exit criteria: a newcomer with the binary and a connection string reaches "browsing their
own data in GraphiQL" in under five minutes via `--dev` mode (M9), no docs beyond `--help`.

## Milestone 14 — Library packaging, docs, and v1.0 release

- **Zig package**: consumable via `build.zig.zon` fetch; the `pg_gql` module builds against
  a pinned Zig release; examples for embedded use (run permission-enforced queries
  in-process via the M10 `(role, session variables)` entry point, no HTTP).
- **C ABI v1**: audit + freeze the `c_abi` surface (versioned `pg_gql_v1_*` symbols, error
  codes, memory ownership rules documented per function), including the authorization entry
  point; shared + static artifacts per platform in CI releases; a non-C consumer example
  (Python ctypes) as proof.
- **Docs**: a real getting-started (server mode and library mode), metadata reference,
  permissions guide, deployment guide (TLS, limits, metrics), and a Hasura-migration note
  (what maps, what doesn't).
- **Conformance + benchmarks**: the NDC spec's `ndc-test` tool against `/query`+`/schema`,
  **and the `graphql-http` conformance audit suite against `/graphql`** — the GraphQL
  endpoint is the actual product surface and needs its own conformance gate, in CI.
  Benchmark suite vs Hasura+ndc-postgres on the same schema/queries — not to win, to catch
  regressions and know where we stand.
- Versioning policy (semver; what's covered: HTTP API, metadata format, C ABI, Zig API
  tiers), CHANGELOG, tagged v1.0.0 with release artifacts.

Exit criteria: `zig fetch` + ten lines of Zig runs a permission-enforced query in-process;
ndc-test and graphql-http both pass in CI; v1.0.0 tag with binaries for macOS/Linux.

---

## Sequencing and dependency logic

```
M5 (repo/CI/fuzz) ───────────────────────────────────────────────────────┐
M6 (libpq, arrays, lifecycle) ─► M7 (types+operators+validation) ─► M8 (mutations)
                                                                     │
                                            M9 (metadata; predicate  ▼
                                            format co-drafted) ─► M10 (authz)
                                                                     │
                     M11 (concurrency/limits/observability) ◄────────┤ (overlaps M9–M10)
                                                                     ▼
                                          M12 (subscriptions) ─► M13 (console)
                                                               ─► M14 (release)
```

- M5 first because every later milestone's exit criteria assume CI exists.
- M6 before M7 (array types/operators need array binding); M7 before M8 (where-based
  mutations reuse the full expression surface); M8 before M9 (mutation shapes are snapshotted
  into metadata and are permanent API); M9 before M10 (permissions live in metadata, and the
  predicate serialization is co-drafted with the metadata format); M10 before M12/M13
  (subscriptions and console must be permission-aware from day one); M11 before M12
  (subscriptions sit on the new concurrency model).
- M11 can start any time after M6 and should land before M12 begins.
- Relative size, in "milestone-2 units": M5 ≈ 0.5, M6 ≈ 1–1.5 (libpq migration +
  packaging; the TLS risk is gone), M7 ≈ 1.5, M8 ≈ 1, M9 ≈ 1, M10 ≈ 2 (largest and most
  safety-critical), M11 ≈ 1.5, M12 ≈ 1.5, M13 ≈ 1, M14 ≈ 1.

## Decisions needing ADRs before their milestone starts

| ADR | Decision | Gate for |
|---|---|---|
| 0015 | Connection pool design (retroactive — code exists) | M5 |
| 0016 | Adopt libpq for Postgres communication (supersedes 0001; accepted 2026-07-07); packaging strategy per platform | M6 |
| 0017 | Scalar representation policy (`numeric`-as-string, date/time formats, bytea) | M7 |
| 0018 | Mutation surface v2: bulk/where/upsert names + argument shapes (permanent API; supersedes parts of 0010) | M8 |
| 0019 | Metadata format, versioning, reconciliation — drafted together with 0020's predicate serialization | M9 |
| 0020 | Permission model: predicate compilation into IR, `check` predicates, row limits, IR-level column enforcement, adversarial test plan | M9 (format half) / M10 (enforcement) |
| 0021 | Session/authn: JWT claims mapping (incl. RS256-via-std spike), webhook contract, outbound HTTPS client, library `(role, session vars)` entry point | M10 |
| 0022 | Server concurrency + allocator model (bounded workers/evented, keep-alive, arena strategy) | M11 |
| 0023 | Subscription semantics: shared poll scheduler, multiplexing, delivery guarantees | M12 |
| 0024 | Telemetry export: direct OTLP/HTTP emission vs opentelemetry-cpp C-wrapper binding | M11 |

## v1.0 definition of done

A single checklist, restating the exit criteria that matter most: CI green with real
coverage-guided fuzzing; TLS-required managed Postgres **and** a TLS 1.2-pinned Postgres in
CI; nasty-schema fixture round-trips; Hasura-parity mutation matrix passes; boots from
metadata without DB introspection; adversarial permission suite (GraphQL + raw-NDC probes,
check predicates) passes; library-mode permission-enforced execution works; 24h chaos soak
clean on the production concurrency model; 1k idle subscriptions flat with O(1) queries per
poll tick; five-minute `--dev` console onboarding; ndc-test **and** graphql-http conformance
pass; tagged release with binaries, C ABI docs, and a Zig package example.
