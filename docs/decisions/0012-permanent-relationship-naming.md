# 0012 — Permanent relationship naming (supersedes 0006)

## Status

Accepted.

## Context

[0006](0006-relationship-naming-stopgap.md) deliberately deferred a permanent relationship
naming scheme, turning collisions into a hard `error.DuplicateRelationshipName` instead of a
silent overwrite, with an explicit hard gate: the permanent scheme must ship before milestone
4's GraphQL SDL generation, since relationship names become public GraphQL field names the
moment they appear in served SDL — renaming one after that point is a breaking API change for
real clients.

Two additional defects surfaced while implementing this milestone, fixed as part of the same
work since the naming scheme needs the same underlying data (FK constraint identity and
per-column ordinality) that fixing them requires:

- `executor/introspect.zig`'s old `information_schema`-based FK query joined
  `key_column_usage` × `constraint_column_usage` on `constraint_name` alone, with no ordinal
  position — a 2-column FK produced a 2×2 cross-product of wrong column pairs.
- `schema/introspect.zig`'s old `build()` called `addRelationship` once per FK *row*, so even a
  correctly-fetched multi-column FK would immediately collide as N separate single-column
  relationships.

## Decision

**Forward (object, child→parent) relationships** are named after the FK's own source column,
with one trailing `_id` stripped (`artist_id` → `artist`; `reports_to`, with no `_id` suffix,
used verbatim). Composite (multi-column) FKs use the qualified form directly:
`<target>_by_<col1>_<col2>...` in constraint column order — there's no single column to derive
a short name from.

**Reverse (array, parent→children) relationships are *always* qualified**, unconditionally:
`<child_table>_by_<child_col>` (composite: `..._by_<col1>_<col2>...`). No pluralization, no
inflection engine — one deterministic rule, always applied, never conditional on whether a
shorter name happens to be free.

**Collision fallback**: after computing every collection's preferred names, any name that
collides with a column of that collection's object type, or with another relationship's name
already claimed in the same collection, falls back to its fully-qualified form
(`<target>_by_<cols>` for forward — the reverse direction has no further fallback, since it's
already maximally qualified). A collision surviving the fallback is a hard
`error.DuplicateRelationshipName`.

**Self-referential special case**: when a FK's source and target collection are the same table,
forward's qualified-fallback formula (`<target>_by_<cols>`) and reverse's name formula
(`<child>_by_<cols>`) become textually identical (target == child), so they would collide with
each other whenever forward actually needs to fall back — which, for any FK column without an
`_id` suffix, is *always* true (that column's "stripped" preferred name is identical to the
column's own literal name, which is guaranteed to exist as a column on that object type,
guaranteeing a fallback is needed). In this one case, forward's fallback uses the FK constraint
name instead — globally unique by construction. Every non-self-referential FK keeps
`table_name != foreign_table_name`, which alone keeps the two formulas textually distinct, so
this special case never triggers outside self-reference.

**Why unconditional reverse qualification** (verbose but frozen-safe) rather than "pretty when
unique, qualified only when ambiguous": names are public GraphQL API the moment SDL ships, and
a conditional scheme would silently rename an *already-shipped* field the instant an unrelated
migration adds a second FK to the same target. A per-relationship config override remains the
designated future escape hatch for vanity names — not built now.

**What changed**: `schema/introspect.zig` — `ForeignKeyRow` gained `constraint_name` and
`ordinal`, becoming one-row-per-column; `build()` now groups rows by constraint
(`groupForeignKeys`), builds both directions' naming candidates (`buildPendingRelationships`),
then resolves collisions per-collection and inserts (`addRelationships`) — replacing the old
`addRelationship` stopgap entirely. `executor/introspect.zig`'s `foreign_keys_query` moved to
`pg_catalog` (`pg_constraint.conkey`/`confkey` with `unnest ... WITH ORDINALITY`), fixing the
composite-FK cross-product bug as a side effect of fetching what the naming scheme needs
anyway. **No shape change** to `schema/model.zig`'s `SchemaModel.relationships` — names stay
opaque strings; `sql_gen/ir_to_sql.zig`'s `resolveRelationship` needed zero changes (verified:
it only ever looks names up in maps, never assumes a name equals a collection name).

## Consequences

- Every existing integration fixture/test referencing the old stopgap's reverse names (e.g.
  `artist`'s reverse relationship to `album`, previously named `album`) was updated to the new
  qualified names (`album_by_artist_id`) — a one-time, expected cost, confirmed against real
  Postgres.
- The two scenarios ADR 0006's stopgap hard-errored on (two FKs from one table to the same
  target; a self-referential FK) now both resolve successfully with distinct, deterministic
  names instead of failing introspection — a real capability gain, not just a rename.
- Relationship names are now frozen, safe to expose as public GraphQL SDL field names in
  milestone 4 — the hard gate ADR 0006 imposed is satisfied.
