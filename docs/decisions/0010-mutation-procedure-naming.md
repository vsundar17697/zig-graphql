# 0010 — Mutation procedure naming, argument surface, and insertability policy

## Status

Accepted.

## Context

Milestone 3 auto-derives NDC procedures from the schema rather than requiring hand-written
mutation definitions. Two things need to be fixed permanently, since they become public API
the moment a client relies on them: the procedure *names* themselves, and the shape of the
JSON arguments each one takes.

## Decision

**Procedure names**, one per collection:

- `insert_<collection>` — always derived, regardless of whether the collection has a primary key.
- `update_<collection>_by_pk` and `delete_<collection>_by_pk` — derived only for collections
  that declare a primary key (`schema.Collection.primary_key.len > 0`); "by pk" is meaningless
  without one.

Names are a pure function of the collection name — `schema.resolveProcedure` parses a name
back into `(kind, collection)` by prefix/suffix matching (`insert_`, `update_..._by_pk`,
`delete_..._by_pk`) and checks the referenced collection exists, rather than building and
looking names up in a precomputed registry. There is nothing to precompute: the mapping is
computed the same way in both directions.

**Argument surface**, borrowing the well-known `object`/`_set`/`pk_columns` convention (the
same one Hasura's classic GraphQL mutations use, chosen here for its familiarity rather than
inventing new names):

- `insert_<t>(object: {<column>: <value>, ...})`
- `update_<t>_by_pk(pk_columns: {<pk column>: <value>, ...}, _set: {<column>: <value>, ...})`
- `delete_<t>_by_pk(pk_columns: {<pk column>: <value>, ...})`

`pk_columns` must supply a value for every declared primary-key column, no more and no fewer —
a partial or over-specified key is rejected (`Error.MissingPrimaryKeyColumn` /
`Error.UnexpectedPrimaryKeyColumn`) rather than silently ignored. `_set` must be non-empty
(`Error.EmptySetClause` otherwise) — an update with nothing to set is almost certainly a caller
bug, not a valid no-op request worth accepting silently.

**Insertability policy**, using the two new `schema.ObjectField` flags this milestone adds
(`has_default`, `is_generated`, populated from `information_schema.columns` — see
`schema/introspect.zig`):

- `is_generated` (`GENERATED ALWAYS AS (...) STORED`) columns are **excluded entirely** — an
  attempt to supply one to `object`/`_set` is a translation-time error
  (`Error.ColumnNotInsertable`), not a Postgres runtime error. Postgres itself would reject a
  write to a generated column, so catching it before generating SQL gives a clearer error.
- `has_default` columns (including serial/identity primary keys) remain **insertable and
  optional** — a caller may supply an explicit value or omit the key entirely; there's no
  special validation to enforce "optional," since a JSON object simply omitting a key already
  expresses that. `has_default` exists on the schema model for later consumption (documenting
  optionality in `GET /schema`'s procedures section and in generated GraphQL input types), not
  to gate anything in `sql_gen` itself.

RETURNING selections reuse the read-side `ndc_ir.FieldSelection`/`Field` union rather than a
dedicated mutation-returning type; only `Field.column` is meaningful in milestone 3
(`Field.relationship` is rejected with `Error.UnsupportedReturningField`) — relationship fields
inside `returning` are deferred, matching the milestone-3 scope in docs/roadmap.md.

## Consequences

- Procedure name resolution is O(string-parse), not O(registry lookup) — no persistent map of
  every derived procedure needs to be built or kept in sync with the schema.
- The naming convention is permanent API surface once milestone 4 exposes it as GraphQL SDL
  Mutation root fields — same category of decision as
  [0006](0006-relationship-naming-stopgap.md)'s relationship-naming hard gate, but this one
  ships as a real (not stopgap) decision from the start since it doesn't have 0006's
  collision problem.
- `insertableColumns`-style enumeration (which columns *may* appear in `object`) is deferred
  until `schema_json`'s procedures section or GraphQL input-type generation actually needs to
  list them — `sql_gen` validates per-key against `object_type.fields` instead of
  pre-enumerating an allowlist, which is sufficient for execution and avoids a helper with no
  caller yet.
