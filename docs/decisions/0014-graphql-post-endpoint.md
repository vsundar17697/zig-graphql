# 0014 — `/graphql` as a post-processing envelope over the existing NDC pipeline

## Status

Accepted.

## Context

`/query` and `/mutation` speak NDC's own wire JSON — correct for the connector protocol, but
not what a real GraphQL client (Apollo Client, urql, graphql-request, GraphiQL) sends or
expects. `POST /graphql` needs to accept the standard `{query, operationName, variables}`
request body and respond with the standard `{data, errors}` envelope, including `__typename`
support and correct reshaping of NDC's RowSet JSON into GraphQL's array/object/aggregate
shapes — without disturbing `/query`/`/mutation`'s byte-exact NDC-native behavior.

## Decision

**Reshaping lives in `graphql_schema/envelope.zig`, a pure function, not in `http_server`.**
`buildQueryEnvelope(allocator, schema_model, resolved_fields, outcomes) -> {data, errors}`
takes each root field's already-resolved `ast.Field` (fragment-expanded, directive-evaluated,
variable-substituted — see [request.zig](../../src/graphql_parser/request.zig)) paired with its
execution outcome (`FieldOutcome{ok: RowSet JSON} | {err: message}`), and:

- Unwraps a collection field's RowSet `rows` array into a plain GraphQL array; an *object*
  relationship's RowSet (still shaped `{"rows": [<=1 item]}` at the NDC level — object vs.
  array relationships share one wrapper, see [0003](0003-json-shaping-sql-in-generator.md))
  unwraps to the single row object or `null`, never an array — this requires walking
  `schema_model.relationships` at every nesting level to know each field's cardinality, exactly
  the same walk `to_ir.zig`'s lowering already does.
- Re-nests an `_aggregate` field's flat `aggregates` map (keyed `"<function>.<column>"`, see
  [0013](0013-graphql-type-system.md)'s Gate 2) back into `{count, max: {...}, min: {...}, ...}`.
- Injects `__typename` (the collection name, since object type names equal collection names in
  this engine's type system) into every row that asked for it, during the same recursive walk.
- A per-field error nulls that field's `data` entry and adds one `errors[]` entry with
  `path: [responseKey]` — never fails the whole response.

**`__typename` requires one narrow change in `graphql_parser/to_ir.zig`**: `lowerField`/
`lowerMutationReturning` now skip a `__typename` sub-field instead of lowering it as a real
column (which would produce `SELECT "t"."__typename"` and fail at the database — no such
column exists). This is the one place `__typename` touches anything outside `graphql_schema` —
`ndc_ir` and `sql_gen` remain completely unaware of it, matching the design principle that
GraphQL-specific concerns don't leak into the NDC path.

**Execution errors are HTTP 200; only malformed requests are 400.** Per graphql-over-http
convention (and because Apollo-class clients treat any non-2xx response as a transport failure
and discard the body entirely), a field that fails to lower or execute becomes a per-field
`errors[]` entry with the response still `200 OK`. `400` is reserved for cases execution never
even started: invalid JSON body, or a missing/non-string `query` field. GraphQL syntax errors
and operation-resolution failures (unknown operation name, ambiguous operation, fragment cycle)
also get `200` with a request-level error envelope (`{"errors": [...]}`, no `data` key) — the
document was well-formed HTTP, it just couldn't be executed.

**Mutation root fields collapse into one `MutationRequest`.** A `mutation { op1 op2 }` document
becomes one NDC `MutationRequest` with `operations: [op1, op2]`, running as the existing
all-or-nothing transaction ([0011](0011-mutation-transactions.md)) — no new transaction
semantics for GraphQL specifically. `http_server/graphql_route.zig` builds this directly from
the already-resolved root fields (via `graphql_parser.lowerMutationField`, exported for this
purpose) rather than re-parsing, and maps each `operation_results[]` entry back to its field's
response key for the envelope.

**Multiple query root fields execute independently** (`{ albums {...} artists {...} }`) — each
lowers and executes as its own `ndc_ir.Query` via `graphql_parser.lowerRootField` (also newly
exported), unlike mutations. `to_ir.lower`/`parseToIr` (the NDC-native producers' entry points)
keep their existing single-root-field contract unchanged; `lowerAll`/`lowerRootField` are the
new entry points multi-root callers use.

**CORS is unconditional and generic**, not `/graphql`-specific: `OPTIONS` on any path returns
`204` with `Access-Control-Allow-*` headers, and every JSON response (including `/query`/
`/mutation`/`/schema`/`/capabilities`) gets `Access-Control-Allow-Origin: *`. Browser-based
tools (GraphiQL, Apollo Sandbox) fail their very first request without this; there's no reason
to restrict it to one route.

**`http_server`'s three loose parameters become `ServerContext{connection, schema_model,
type_system}`**, threaded through `routes.zig` and `graphql_route.zig` alike. `connection`
becomes a `*pg_wire.Pool` lease source once [0015](0015-connection-pool.md) lands — nothing in
either route file assumes it's a single bare connection specifically.

## Consequences

- `/query` and `/mutation` are provably unaffected: `envelope.zig`/`graphql_route.zig` are new
  code paths, and `to_ir.zig`'s only change (skipping `__typename`) is a no-op for every
  existing NDC-JSON/query-builder caller, none of which ever produces a field named
  `__typename`.
- Request-level `$variables` (GraphQL-document-level, resolved by `request.zig` at lowering
  time) and NDC's `variables` array (IR-level batching, [0009](0009-query-variables.md),
  resolved at execution time) remain two independent mechanisms with no shared code path —
  `/graphql` never uses NDC variable-set batching; each root field executes exactly once.
- Every `executor.run`/`executor.runMutation` call's returned `Parsed` value owns its own arena
  (existing convention) and must stay alive until the envelope is fully serialized to text --
  `graphql_route.zig` collects them in a function-scoped list with one `defer`-of-all at the end,
  not a per-call `defer` inside the dispatch loop (which would free each result's backing memory
  at the end of that loop iteration, before the envelope could read it — a real bug caught
  during implementation, not shipped).
