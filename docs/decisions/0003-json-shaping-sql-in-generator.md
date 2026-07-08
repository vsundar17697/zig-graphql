# 0003 — JSON-shaping SQL in the generator

## Status

Accepted (milestone 1).

## Context

The NDC `QueryResponse` shape is a nested `RowSet` (`{"rows": [...]}`, with relationship
fields nesting as further `{"rows": [...]}` or single objects). An earlier draft of the
`executor` module planned to run a flat SQL `SELECT`, get back flat rows (with joined
relationship columns), and reconstruct the nested JSON shape in Zig.

This has two problems. First, it doesn't generalize: flat rows from a join against a to-many
(array) relationship explode combinatorially, requiring de-duplication/grouping logic in Zig
that would later be thrown away once array relationships are supported. Second, `ndc-postgres`
itself — the reference implementation this project's protocol shapes are drawn from —
deliberately does not do this; it shapes results as JSON *inside* the generated SQL (see
`ndc-postgres/crates/query-engine/sql/src/sql/helpers.rs` and
`translation/src/translation/query/fields.rs`) using `json_agg`/`jsonb_build_object`, so
Postgres itself returns one JSON document per row set.

## Decision

`sql_gen` generates SQL that shapes its own output as JSON (via `json_agg`/`jsonb_build_object`
or equivalent), rather than `executor` reconstructing nested JSON from flat rows in Zig.

## Consequences

- `executor` becomes a near-pass-through: decode one JSON/text column per row rather than
  performing row-to-tree reconstruction. This is both simpler and better aligned with the
  "efficient hot path" goal (fewer allocations, less intermediate structure in Zig).
- Object (to-one) relationships in milestone 1 and array (to-many) relationships in a later
  milestone become different cases of the same SQL-generation strategy (a joined single-row
  object vs. a `json_agg` over a lateral-joined subquery) rather than requiring two different
  row-mapping strategies in `executor`. This directly reduces the risk noted in
  [roadmap.md](../roadmap.md) around array relationships needing a rewrite rather than an
  incremental change.
- Reduces the need for a broad per-scalar-type OID decoder matrix in `pg_wire`/`executor`,
  since results already arrive pre-shaped as JSON text for the majority of the response;
  `pg_wire` still needs to decode the small set of scalar types used in top-level `WHERE`
  parameter binding and non-nested column values.
- Puts more responsibility on `sql_gen`'s correctness for JSON shaping (aliasing, nesting
  depth, null handling for absent relationships) — mitigated by concentrating detailed
  behavioral test coverage in the Postgres integration tests (which exercise real JSON output),
  while keeping unit tests focused on structural correctness (WHERE clause construction,
  parameter ordering) that doesn't need to be re-asserted against exact SQL text on every
  refactor.
