# Roadmap

## Milestone 1 (complete)

Goal: a demonstrable end-to-end vertical slice proving the whole pipeline works — GraphQL
text *or* a direct query-builder call, through the shared IR, through SQL generation, against
a real Postgres, back out as JSON — including at least one relationship hop. Feature breadth
is deliberately narrow; pipeline correctness is not.

Delivered: `ndc_ir`, `schema` (with live introspection), `pg_wire` (native wire protocol,
real SCRAM-SHA-256), `sql_gen` (JSON-shaping SQL generation), `executor`, `graphql_parser`,
`query_builder` (with runtime schema validation), a C ABI (`c_abi`) verified against a real
C program, and an HTTP server (`http_server`) exposing `GET /capabilities`, `GET /schema`,
and `POST /query` (accepting literal NDC QueryRequest JSON — a third IR producer alongside
GraphQL text and the query builder). 82 unit tests and 5 Postgres-backed integration tests
pass, including a flagship test proving the GraphQL and query-builder producer paths return
byte-identical JSON when executed against real Postgres.

### In scope

- Single collection queries plus one level of relationship (object/to-one relationships are
  required; array/to-many relationships are attempted if time allows once
  [JSON-shaping SQL](decisions/0003-json-shaping-sql-in-generator.md) is in place, since it
  makes them a small incremental change rather than a rewrite).
- Comparison operators: `_eq`, `_neq`, `_gt`, `_gte`, `_lt`, `_lte`, `_in`, `is_null`, plus
  logical combinators `_and`, `_or`, `_not`.
- `order_by`, `limit`, `offset` on the top-level collection.
- Scalar types: `int2`/`int4`/`int8`, `text`/`varchar`, `bool`, `float4`/`float8`,
  `timestamp`/`timestamptz` (passed through as opaque text, no date arithmetic).
- Schema introspection via `information_schema`: single `public` schema, tables and views
  only, foreign-key-derived object relationships only.
- GraphQL surface: one query root field per collection.
- Query-builder surface: mirrors the same feature set via comptime table descriptors.
- HTTP surface: `GET /schema`, `POST /query`, static `GET /capabilities`. A `/graphql` text
  endpoint is a stretch goal, not required for the milestone to be complete — the GraphQL-to-IR
  and IR-to-SQL halves are each proven by unit tests plus one joint integration test.

### Explicitly deferred (and why the module boundaries already accommodate it)

| Deferred feature | Lands later without re-architecting because... |
|---|---|
| Aggregates | `Query` reserves a slot for it; `sql_gen` adds a new node kind alongside the existing `Select`, doesn't replace it. |
| Mutations | Separate `ndc_ir.Mutation` IR type and separate `sql_gen` entry point; doesn't touch `Query`/`Expression`. |
| Array (to-many) relationships, if not pulled into M1 | `Relationship.relationship_type` already has an `array` variant; `sql_gen`'s relationship lowering gets a second case (subquery + `json_agg` instead of a single joined row) without changing `ndc_ir.Field.relationship`'s shape. |
| `exists` / nested-in-array expressions | New `Expression` variant; existing `and_`/`or_`/`binary_op` variants and all code handling them are untouched. |
| Query variables (batching) | `ComparisonValue.variable` case is already reserved in the union. |
| SCRAM connection pooling, prepared-statement caching | Isolated to `pg_wire`; no other module is aware of connection lifecycle details. |
| Multiple schemas, materialized/partitioned/foreign tables, composite/array/domain types | Isolated to `schema/introspect.zig`'s query and type-mapping branches; `SchemaModel`'s shape doesn't change, just what populates it. |

## Milestone 1.5 (complete)

Fixed a spec-compliance bug found while scoping milestone 2: `POST /query` returned a bare
`{"rows": [...]}` object instead of NDC's actual `QueryResponse` shape, a JSON *array* of
RowSets. See [ADR 0005](decisions/0005-query-response-array-of-rowsets.md).

## Milestone 2 (complete)

Goal: "any read-only NDC QueryRequest works" — array relationships, `exists` expressions,
aggregates, and query variables/batching, on top of milestone 1's object-relationship-only
read path.

Delivered:

- **Array (to-many) relationships**: `schema/introspect.zig` now derives both the forward
  (object) and reverse (array) direction from each foreign key, with an inverted column
  mapping for the reverse direction. The rest of the pipeline (`sql_gen`, all three producers)
  was already relationship-cardinality-agnostic from milestone 1. Same-target FK collisions
  (two FKs from one table to the same target) are a detected introspection error rather than
  a silent overwrite — see [ADR 0006](decisions/0006-relationship-naming-stopgap.md), a
  deliberate stopgap pending a permanent naming scheme before milestone 4 ships SDL generation.
- **`exists` expressions**: a new `ndc_ir.Expression.exists` variant (`related`/`unrelated`),
  lowering to a SQL `EXISTS (SELECT 1 FROM ... WHERE ...)` subquery that reuses the same
  column-mapping-to-join-conjuncts logic as relationship fields. `sql_gen` now honors
  `query.relationships` (previously dead) ahead of schema-derived lookups — see
  [ADR 0007](decisions/0007-sql-gen-honors-query-relationships.md).
- **Aggregates**: `star_count` / `column_count` / `single_column` (`min`/`max`/`sum`/`avg`),
  computed in the same pass as `rows` over one wrapped subquery so they respect the query's
  own predicate/limit/offset. Rendered via a new `RowSetQuery` AST node that fully replaced the
  old implicit RowSet wrapper — see [ADR 0008](decisions/0008-aggregate-rendering.md). Exposed
  on a flat, NDC-faithful `<collection>_aggregate` GraphQL root field rather than Hasura's
  nested shape, to avoid building response-reshaping infrastructure ahead of milestone 4.
- **Query variables/batching**: `ast.Value.variable_ref` slots into the existing `$N`
  parameterization milestone 1 already had; `executor.runWithVariables` renders SQL once and
  executes it once per variable set on one connection. `_in` with a variable is explicitly
  unsupported (would need array-parameter binding). See
  [ADR 0009](decisions/0009-query-variables.md).

113 unit tests and 10 Postgres-backed integration tests pass, including the flagship
GraphQL-path/query-builder-path byte-identical-JSON proof extended to cover exists+aggregates
together, and a live 3-variable-set batching test.

### Explicitly deferred from milestone 2

| Deferred feature | Why |
|---|---|
| `_in` with a query variable | Needs array-parameter binding (`= ANY($1::text[])`), which `pg_wire`'s text-only parameter encoding doesn't support yet. |
| Relationship-nested aggregates (`artist { albums_aggregate { count } }`) | Parser-only gap — `sql_gen`/IR already support it; deferred to keep milestone 2's GraphQL surface change minimal. |
| Permanent relationship naming scheme | Deliberately deferred to milestone 4 (hard gate, before SDL generation ships) — see ADR 0006. |
| GraphQL-document-level `$variable` syntax | A different, request-level concept from NDC's variable-set batching implemented here; planned for milestone 4 alongside `operationName`. |

## Milestone 3 (complete)

Goal: the write path. NDC procedures auto-derived from the schema — `insert_<table>`
(single object), `update_<table>_by_pk` (`_set` only), `delete_<table>_by_pk` — with names,
argument shapes, and the insertability policy fixed permanently by
[ADR 0010](decisions/0010-mutation-procedure-naming.md). Every multi-operation
MutationRequest executes inside one all-or-nothing transaction
([ADR 0011](decisions/0011-mutation-transactions.md)), exposed over `POST /mutation` and
GraphQL mutation documents, with a `MutationBuilder` for the query-builder producer — the
flagship two-producer equivalence proof extends to the write path. A connection pool landed
alongside ([ADR 0015](decisions/0015-connection-pool.md)).

## Milestone 4 (complete)

Goal: a real GraphQL type system. Permanent relationship naming
([ADR 0012](decisions/0012-permanent-relationship-naming.md), closing ADR 0006's hard gate),
then the type system as a cached derived artifact with SDL generation and the
argument-dependent aggregate surface redesign
([ADR 0013](decisions/0013-graphql-type-system.md)).

## Milestone 4.5 (complete)

Goal: real GraphQL clients can connect. `POST /graphql` accepting the standard
`{query, operationName, variables}` body and answering with the standard `{data, errors}`
envelope — document variables, fragments, `@skip`/`@include`, `__typename`, and executable
`__schema`/`__type` introspection — as a post-processing envelope over the unchanged NDC
pipeline ([ADR 0014](decisions/0014-graphql-post-endpoint.md)).

## Milestones 5+ — the road to v1.0

Everything from here on is planned in detail in [roadmap-v1.md](roadmap-v1.md) (milestones
5–14: repo/CI/fuzzing, libpq adoption and connection lifecycle, type/operator breadth,
mutation breadth, metadata, authorization, production hardening, subscriptions, console,
release). Status so far: the repo is on GitHub with CI green on macOS and Linux
(milestone 5, fuzzing still pending); milestone 6 has libpq
([ADR 0016](decisions/0016-adopt-libpq.md)) and array parameter binding (`_in` with
variables, lifting ADR 0009's deferral) done, with connection-lifecycle work remaining.
