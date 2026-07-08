# 0009 — Query variables: reuse existing parameterization, N sequential executions

## Status

Accepted. The one deliberate cut — `_in` with a variable
(`Error.VariablesNotSupportedForIn`) — was lifted in milestone 6 after
[0016](0016-adopt-libpq.md) (libpq) made array-parameter binding practical:
`_in` with a variable now lowers to `= ANY($N)` with the whole array bound as
one Postgres array-literal text parameter (`ast.AnyExpr`,
`executor/pg_array.zig`). Everything else here stands unchanged.

## Context

NDC's `QueryRequest.variables` lets a caller supply N sets of variable bindings for one query,
getting back N RowSets (one per set) in a single request — a batching mechanism, not a
GraphQL-language `$variable`. `ndc_ir.ComparisonValue.variable` was reserved for this since
milestone 1 but unimplemented.

A design review raised a concern that variables might require adding SQL parameterization
infrastructure that didn't already exist. That concern doesn't apply here: milestone 1's
`sql_gen`/`pg_wire` already fully parameterize every value — `render.zig` emits a `$N`
placeholder for every `Value`, and `pg_wire.Connection.query` already runs the extended
protocol (Parse/Bind/Execute/Sync) with real bound parameters, never string-interpolating
values into SQL text. Variables are therefore a much smaller feature than initially worried:
name a variable reference in the IR, slot it into the existing `$N` mechanism, and resolve it
to a concrete value at execution time instead of at render time.

## Decision

`sql_gen.ast.Value` gains a `variable_ref: []const u8` case, handled by `render.zig` exactly
like every other `Value` variant (no special-casing needed there — it already treats `Value`
opaquely). `ir_to_sql.zig` translates `ComparisonValue.variable` into `ast.Value.variable_ref`
for ordinary binary comparisons; `_in` with a variable is rejected for now
(`Error.VariablesNotSupportedForIn`) since it would need array-parameter binding (e.g. `= ANY($1::text[])`),
which pg_wire's current text-only parameter encoding doesn't support — a narrow, explicit cut,
not a design gap.

`executor` renders SQL **once** via `sql_gen.generate` and gains `runWithVariables`, which
loops over `[]const ndc_ir.VariableSet`, resolving each `variable_ref` to a concrete
`pg_wire.QueryParam` from that set's JSON values and executing the same rendered SQL text once
per set, all on the same connection (no reconnect or re-authentication between sets). The
existing `run` entry point (no variables) rejects any unresolved `variable_ref` it encounters
via `Error.UnboundVariable`, rather than silently sending `NULL` or similar.

## Consequences

- Zero changes were needed to `render.zig` — the entire feature fit into the existing `Value`
  union and placeholder mechanism, confirming the "reuse, don't rebuild" framing above.
- N sequential round trips per variables request is accepted as sufficient for milestone 2.
  This is deliberately structured to upgrade cleanly later: the same SQL text is reused
  unchanged across every set, which is exactly the shape milestone 4's prepared-statement
  cache (Parse once, Bind N times) is designed to speed up — nothing here needs to be torn out
  when that lands.
- `_in` with a variable is unsupported until array-parameter binding exists in `pg_wire`;
  ordinary scalar comparisons (`_eq`, `_gt`, etc.) with variables work today.
- The GraphQL text producer does not gain `$variable` syntax in this milestone — that's a
  different, GraphQL-document-level concept (see milestone 4's plan for request-level
  `variables`/`operationName`), distinct from NDC's variable-set batching implemented here.
  Variables are exercised by the query-builder and NDC-JSON producers only.
