# 0004 — Schema reconciliation via runtime validation

## Status

Accepted (milestone 1). Expected to be revisited in a later milestone.

## Context

Two things both need to agree on what collections and columns exist: the query-builder's
comptime table descriptors (hand-written Zig code, e.g. a descriptor for an `Album` table
exposing `.AlbumId`, `.Title` as comptime column references) and the runtime-introspected
`SchemaModel` (built by `schema/introspect.zig` from a live Postgres connection). These are
two independent sources of truth. Nothing in the original design specified how they'd be kept
from drifting apart — e.g. a column renamed in the database with the comptime descriptor left
stale.

Two ways to close this gap: (a) generate the comptime descriptors from the introspected
`SchemaModel` (codegen, Drizzle-style), or (b) validate hand-written descriptors against the
live `SchemaModel` at runtime and fail fast on mismatch.

## Decision

For milestone 1: runtime validation, not codegen. At connection/session setup, every
collection and column referenced by a comptime table descriptor is checked against the live
introspected `SchemaModel`; a mismatch produces a clear startup-time error rather than a
confusing failure at query time (or, worse, silently wrong SQL).

## Consequences

- Simpler to build than a codegen pipeline, appropriate for milestone 1's single-developer,
  narrow-schema scope.
- Descriptor/schema drift is caught at startup rather than compile time — a real gap compared
  to full codegen, but bounded: the validation runs once per connection/session, not per
  query, so it doesn't affect the hot path.
- This is intentionally not the final answer. Once the descriptor surface grows (more tables,
  more columns, used by more than one developer), revisit generating descriptors directly from
  `SchemaModel` (see [roadmap.md](../roadmap.md)) so the two sources of truth collapse into
  one. The runtime-validation code written now should be structured so it can be deleted
  outright once codegen lands, not built into something codegen has to route around.
