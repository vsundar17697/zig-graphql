# 0005 — `executor.run` returns an array of RowSets, not a bare RowSet

## Status

Accepted.

## Context

Milestone 1's `executor.run` returned `std.json.Parsed(std.json.Value)` whose `.value` was a
single RowSet object (`{"rows": [...]}`), decoded directly from the one JSON column
`sql_gen`'s generated SQL produces (see
[0003](0003-json-shaping-sql-in-generator.md)). The real NDC `QueryResponse` is a JSON
**array** of RowSets — one per requested variable set (see
[milestone 2's query-variables work](../roadmap.md)), with a single-element array being the
normal case when no variables are requested. `POST /query`, `pg_gql_query_graphql`'s C ABI
result, and every consumer expecting NDC-shaped output were non-compliant with this from
milestone 1 onward. This wasn't caught in milestone 1 because there were no external callers
relying on the exact wire shape yet, but planning milestone 2's variables feature (where the
array becomes load-bearing — N variable sets genuinely produce N RowSets) surfaced it as a
pre-existing bug worth fixing immediately rather than layering variables logic on top of a
non-compliant shape.

## Decision

`executor.run` wraps its decoded RowSet value in a one-element JSON array before returning.
This is fixed now, as its own small change, rather than bundled into milestone 2 — it's a
spec-compliance bug independent of the variables feature, and every week it ships in the
wrong shape more callers and tests bake in the incorrect assumption.

## Consequences

- `POST /query`'s response body, and the C ABI's `pg_gql_result_json` output, both change
  shape: from a bare object to a single-element array. This is a breaking change to any
  external caller already depending on the milestone-1 shape (none exist outside this
  project's own tests as of this decision).
- All existing tests asserting the old bare-object shape needed updating to index into the
  array's first element.
- Milestone 2's variables work can build directly on this shape (return N elements instead of
  1) without a second shape migration.
