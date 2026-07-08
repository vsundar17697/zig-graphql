# Architecture

`pg-gql` is a Postgres-backed GraphQL engine written in Zig, structured the way Hasura's NDC
(Native Data Connector) spec structures things: a translation layer that turns a query
(GraphQL text, or a direct Zig API call) into a database-agnostic IR, and a connector core
that executes that IR against Postgres. The two halves are deliberately independent enough
that the connector core could serve a different frontend later, and the frontend could target
a different connector later, without a rewrite.

## Module graph

```
                     ┌─────────────┐
                     │   ndc_ir    │  (pure data: Query, Expression, OrderBy, Field, Relationship)
                     └──────┬──────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
        ┌─────▼────┐  ┌─────▼──────┐ ┌────▼─────┐
        │  schema  │  │graphql_    │ │  query_  │
        │          │  │parser      │ │ builder  │
        └─────┬────┘  └─────┬──────┘ └────┬─────┘
              │             └──────┬───────┘
              │                    │ both produce ndc_ir.Query
              │             ┌──────▼──────┐
              └────────────►│   sql_gen   │  (IR + schema -> SQL text + params)
                             └──────┬──────┘
                                    │
                             ┌──────▼──────┐
                             │  pg_wire    │  (native Postgres wire protocol)
                             └──────┬──────┘
                                    │
                             ┌──────▼──────┐
                             │  executor   │  (ties sql_gen + pg_wire + schema together)
                             └──────┬──────┘
                        ┌───────────┼───────────┐
                  ┌─────▼─────┐ ┌───▼────┐
                  │  c_abi    │ │ http_  │
                  │           │ │ server │
                  └───────────┘ └────────┘
```

## Why this boundary

- **`ndc_ir` is a dependency-free hub.** It has zero I/O and zero awareness of how a `Query`
  value was produced. That's what makes "GraphQL or a direct Zig API call, same IR" true
  rather than aspirational: both `graphql_parser` and `query_builder` depend on `ndc_ir` and
  `schema` but not on each other, and both must produce structurally identical `ndc_ir.Query`
  values for equivalent queries. See [0004](decisions/0004-schema-reconciliation-runtime-validation.md)
  for how the two stay in sync with the schema.
- **`sql_gen` is a pure function** of `(Query, SchemaModel) -> (sql text, params)`. No
  Postgres connection, no I/O. This is what makes SQL generation unit-testable without Docker,
  and it's also the injection-safety boundary: values are never string-interpolated into SQL
  text, only ever passed as `$N` parameters.
- **`pg_wire` is IR-agnostic.** It only knows "run this parameterized SQL, hand back rows." It
  doesn't know what an NDC query looks like. This keeps the door open to changing how queries
  reach Postgres (pooling, prepared-statement caching) without touching `sql_gen`, and in
  principle to supporting another wire-compatible backend later without touching `sql_gen`
  either.
- **`executor` is the only module allowed to depend on both `sql_gen` and `pg_wire`.** It's
  the integration point, and correspondingly the module the Postgres integration tests exercise
  most directly. Because `sql_gen` shapes results as JSON in SQL itself (see
  [0003](decisions/0003-json-shaping-sql-in-generator.md)), `executor` stays close to a
  pass-through rather than doing row-to-tree reconstruction in Zig.
- **`c_abi` and `http_server` are consumers, not participants.** Neither adds behavior; they
  adapt the same core to an embeddable C interface and to an HTTP+JSON interface,
  respectively.

## Non-obvious decisions

Recorded as ADRs under [`docs/decisions/`](decisions/):

- [0001 — Native Postgres wire protocol instead of libpq](decisions/0001-native-postgres-wire-protocol.md)
- [0002 — SCRAM-SHA-256 auth, not MD5](decisions/0002-scram-auth-not-md5.md)
- [0003 — JSON-shaping SQL in the generator](decisions/0003-json-shaping-sql-in-generator.md)
- [0004 — Schema reconciliation via runtime validation](decisions/0004-schema-reconciliation-runtime-validation.md)
- [0005 — `executor.run` returns an array of RowSets, not a bare RowSet](decisions/0005-query-response-array-of-rowsets.md)
- [0006 — Relationship naming: stopgap for milestone 2, hard gate for milestone 4](decisions/0006-relationship-naming-stopgap.md)
- [0007 — `sql_gen` resolves relationships from `query.relationships` first](decisions/0007-sql-gen-honors-query-relationships.md)
- [0008 — Aggregates render via a `RowSetQuery` sibling node, single-pass](decisions/0008-aggregate-rendering.md)
- [0009 — Query variables: reuse existing parameterization, N sequential executions](decisions/0009-query-variables.md)

See [roadmap.md](roadmap.md) for what's in vs. deferred for each milestone.
