# 0006 — Relationship naming: stopgap for milestone 2, hard gate for milestone 4

## Status

**Superseded by [0012](0012-permanent-relationship-naming.md)**, as planned below. Kept for
historical context on why the stopgap existed and what it deliberately left unresolved.

## Context

Milestone 1 derived only the forward (object) direction of a foreign key and named the
relationship after the target collection (e.g. `album`'s FK to `artist` becomes a
relationship named `artist`). The code already noted this collides if a table has more than
one FK to the same target, and left it as a silent overwrite, acceptable only because
milestone 1 never exercised the case.

Milestone 2 adds the reverse (array) direction — every forward FK now also produces a
relationship on the *target* collection back to the *source* collection, named after the
source collection (e.g. `artist` gets a relationship named `album`). This forces the
collision question immediately, for two reasons the design review surfaced:

1. **Two FKs from the same table to the same target** (e.g. `album.artist_id` and
   `album.composer_id` both referencing `artist`) collide identically on the forward side —
   this isn't a self-referential-FK-only problem, it's the general "N:1 relationships named
   only by target" problem, and reverse derivation doesn't introduce it so much as make it
   impossible to keep ignoring.
2. **Self-referential foreign keys** (e.g. `employee.reports_to -> employee`) collide between
   their own forward and reverse relationships, since both are named after the same
   collection (`employee`) and land in the same per-collection relationship map.

## Decision

For milestone 2: keep naming relationships after the other collection's name (both
directions), but **turn the collision into a hard introspection error** (`error.DuplicateRelationshipName`)
instead of a silent overwrite. Do not design a permanent naming scheme yet.

Rationale for not designing the permanent scheme now: real usage patterns for what a "good"
relationship name looks like (constraint-name-derived? column-derived, e.g. stripping an
`_id` suffix? pluralization for array relationships?) aren't known yet from actual use of this
engine, and any scheme chosen prematurely risks being wrong in ways only real schemas would
reveal. An explicit error is cheap, correct (never silently drops a relationship), and buys
time.

**This is a hard gate on milestone 4**: once GraphQL SDL generation ships, relationship
names become public GraphQL field names. Changing them after that point is a breaking API
change for real clients. The permanent naming scheme (candidates: FK constraint name,
column-name-derived, or an explicit override in configuration) must be decided and shipped
*before* milestone 4's SDL generation, not after.

## Consequences

- A real schema with ambiguous FK relationships (multiple FKs between the same two tables,
  or self-referential FKs) will fail introspection with a clear error in milestone 2, rather
  than silently losing a relationship. This is a real limitation until milestone 4 lands a
  proper scheme — schemas like Chinook's `Employee.ReportsTo` cannot be fully introspected
  until then.
- Reverse relationship names are the singular source-collection name (e.g. `album`, not
  `albums`) — a known naming wart, deliberately not fixed here since pluralization is exactly
  the kind of decision the permanent scheme should make once, not patch incrementally.
- Milestone 4 must treat "finalize relationship naming" as a blocking prerequisite for SDL
  work, not a parallelizable nice-to-have.
