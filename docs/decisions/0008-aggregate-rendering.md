# 0008 — Aggregates render via a `RowSetQuery` sibling node, single-pass

## Status

Accepted.

## Context

Milestone 1's `sql_gen` implicitly treated "the thing rendered as one NDC RowSet JSON object"
as inseparable from `ast.Select` — `render.zig`'s `renderRowSet`/`appendRowSet` wrapped a
`Select` directly in `json_build_object('rows', ...)`. Adding aggregates means a query can now
produce a `'aggregates': {...}` key alongside (or instead of) `'rows'`, and per NDC semantics
aggregates are computed **post-limit** — over the same predicate/limit/offset-restricted row
set as `rows`, not the raw table.

Two designs were considered: extend `Select` with an `aggregates` field directly, or introduce
a new sibling AST node representing the RowSet-shaping layer explicitly. A design review (see
the milestones 2-4 planning) confirmed the wrapping layer already existed *implicitly* in
`appendRowSet` — reifying it as `ast.RowSetQuery` doesn't add a new concept, it names one that
was already there.

A second problem surfaced during implementation: an aggregate can reference a column that
isn't otherwise a requested display field (e.g. `{albums_aggregate { aggregate { max { AlbumId
} } } }` with no `nodes { AlbumId }` alongside it). That column still needs to be selected by
the underlying SQL for the aggregate function to reference it, but must **not** leak into the
`'rows'` JSON output, which `row_to_json("t")` would otherwise include automatically since it
serializes every column of "t".

## Decision

`ast.RowSetQuery = struct { select: *const Select, row_field_aliases: ?[]const []const u8,
aggregates: []const AggregateItem }` is the unit `sql_gen` renders as one RowSet JSON object.
`RelationshipItem.subquery` is `*const RowSetQuery` (not `*const Select`), so relationship
fields carry their own aggregates the same way the top-level query does — no special-casing
needed for "aggregates on a relationship".

Both `'rows'` and `'aggregates'` are computed from **one** underlying subquery scan (aliased
`"t"` by `render.zig`), not two independent re-executions of the predicate/join/limit logic —
this was an explicit requirement from the design review, since duplicating the scan would
double the cost of any query with a non-trivial `WHERE`/join.

For the "aggregate references a non-displayed column" case: `ir_to_sql.zig` adds the column to
`Select.items` under its own name if not already present (reusing an existing display field's
alias if one already selects the same column), and sets `RowSetQuery.row_field_aliases` to the
*original* (pre-addition) list of display aliases. `render.zig` uses this to re-project "t"
down to just the display aliases before `json_agg`-ing, so the extra column is available to
the aggregate functions (which read directly from "t") without appearing in row output. When
`row_field_aliases` is `null` (the common case — no such extra columns), rendering skips the
re-projection entirely and uses the original direct `row_to_json("t")` path unchanged, so this
costs nothing for the vast majority of queries that don't need it.

`'rows'` and `'aggregates'` keys are each omitted from the JSON when not applicable (no display
fields requested → no `'rows'`; no aggregates requested → no `'aggregates'`), matching NDC's
RowSet optionality.

## Consequences

- Every existing milestone-1 query (no aggregates) renders byte-identically to before this
  change — verified by the full existing test suite passing unmodified after this refactor.
- Adding aggregates required zero changes to `Expression`, `FieldSelection`, or any producer's
  column/relationship-field handling — exactly the "reserved slot" milestone 1's roadmap
  promised.
- The re-projection path (`row_field_aliases` non-null) is untested by ordinary queries and
  only exercised by aggregate-with-hidden-column cases — this is a real, if narrow, seam to
  watch if aggregate scope grows (e.g. order-by-aggregate in a later milestone might need the
  same "extra column, don't leak it" treatment and should reuse this mechanism rather than
  inventing another).
