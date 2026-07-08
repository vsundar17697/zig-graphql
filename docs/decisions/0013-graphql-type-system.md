# 0013 — GraphQL type system as a cached derived artifact; SDL naming and Gate 2

## Status

Accepted.

## Context

Milestone 4 needs a real GraphQL type system: SDL text for client tooling (GraphiQL,
codegen) and, in milestone 4.5, `__schema`/`__type` introspection execution for
Apollo/Relay-class clients. Two design questions needed answers before writing any code:
where does this derived structure live and get consumed from, and — the second hard gate
flagged during planning — how does the milestone-2 GraphQL aggregate surface
(`max(column: "AlbumId")`) get fixed, since a field whose *return type* depends on an
argument's *value* (a column's own scalar type varies per column) isn't expressible in
GraphQL's type system at all.

## Decision

**One `TypeSystem`, two independent pure consumers.** `graphql_schema/type_system.zig`'s
`build(allocator, *const SchemaModel) -> TypeSystem` derives the full type system once, at
server startup, into the schema's long-lived arena — never per request. `graphql_schema/sdl.zig`
renders it to SDL text; milestone 4.5's introspection execution will walk it directly to answer
`__Type` queries. Neither consumer builds the other's output; `TypeSystem` is the only shared
artifact. Query-builder codegen (deferred to a later milestone, cut from M4 entirely) will
consume `SchemaModel` directly instead of `TypeSystem` — it needs Postgres types and comptime
descriptors, not GraphQL types, so forcing it through this structure would be a false economy.

**Gate 2 — aggregate surface restructure**: `<t>_aggregate` is now typed as
`<t>_aggregate_fields!` directly (flat, matching NDC's own flat `aggregates` map — no
`{aggregate: {...}, nodes: [...]}` wrapper). `count(distinct: Boolean): Int!` stays a leaf
field (its return type never varies by column, so it was never actually a problem). `max`,
`min`, `sum`, `avg` are now **object-typed fields** (`max: <t>_max_fields`, etc.), each
returning an object type with one **nullable** field per column, statically typed as that
column's own scalar type (nullable because an aggregate over zero rows is null, even for a
`NOT NULL` source column). This makes every aggregate field's return type static and
SDL-expressible. `graphql_parser/to_ir.zig`'s `lowerAggregateField` translates the nested
GraphQL shape (`max { AlbumId }`) into flat `ndc_ir.Aggregate` entries keyed
`"<function>.<column response key>"` — `ndc_ir`, `sql_gen`, and NDC's own `/query` aggregate
surface are completely untouched; this is a GraphQL-surface-only change.

**Naming conventions frozen by this ADR:**

- Object type per collection: named exactly as the collection (`album`). Column fields keep
  their column name; relationship fields keep their (now-permanent, see
  [0012](0012-permanent-relationship-naming.md)) relationship name.
- `<t>_bool_exp`: one field per column, typed `<Scalar>_comparison_exp` (one comparison-exp
  input type per scalar, shared across every column of that scalar type across every
  collection — built once, referenced everywhere), plus `_and`/`_or: [<t>_bool_exp!]` and
  `_not: <t>_bool_exp`. `<Scalar>_comparison_exp` has `_eq`/`_neq`/`_gt`/`_gte`/`_lt`/`_lte`
  (the scalar itself) and `_in: [<Scalar>!]`. `_is_null` is deliberately **not** on this type —
  it's a unary operator in the IR (`ndc_ir.UnaryOperator.is_null`), not a binary comparison
  against a value, so giving it a place on `<t>_bool_exp` directly (not nested under a column's
  comparison-exp) would need a parser change beyond this milestone's scope; deferred.
- `<t>_order_by`: one field per column, typed `order_by` (a two-value `asc`/`desc` enum, not
  per-scalar).
- `<t>_insert_input`: one field per column excluding `is_generated` ones; optional
  (`nullable or has_default`) or required otherwise — mirrors
  [0010](0010-mutation-procedure-naming.md)'s insertability policy exactly.
- `<t>_set_input`: same column set as insert, every field optional (a partial update).
- `<t>_pk_columns_input`: one required field per declared primary-key column; only built for
  collections that have one.
- Mutation root fields (`insert_<t>`, `update_<t>_by_pk`, `delete_<t>_by_pk`) return `<t>`
  **nullable** — a `*_by_pk` mutation against a nonexistent row is a normal null, not an error
  (per [0011](0011-mutation-transactions.md)).
- Relationship field nullability: array relationships are always `[<target>!]!`; object
  relationships are `<target>!` only when every source-side column in the FK's column mapping
  is itself `NOT NULL`, else nullable `<target>`.
- **Name-grammar exclusion**: any collection/column/relationship name failing
  `/[_A-Za-z][_0-9A-Za-z]*/` is silently excluded from every GraphQL type it would otherwise
  appear in (object type field, bool_exp field, insert_input field, ...) — the NDC surface
  keeps exposing it unchanged. No warning log exists yet for this (deferred; low-risk since
  Postgres identifiers failing this pattern are rare and the exclusion is a strict subset, not
  a silent corruption).

## Consequences

- SDL type names (`<t>_bool_exp`, `<t>_insert_input`, `<Scalar>_comparison_exp`, ...) are now
  frozen public API the moment a real client's codegen runs against them — same category of
  commitment as [0012](0012-permanent-relationship-naming.md)'s relationship names.
- `TypeSystem` construction walks `SchemaModel`'s unordered hash maps (`collections`,
  `relationships`, `object_types.fields` is already insertion-ordered) — `type_system.zig`
  sorts collection and relationship names alphabetically before deriving anything from them,
  and `sdl.zig` independently sorts all type names before rendering, so SDL output is
  deterministic regardless of hash map iteration order.
- A real Zig gotcha surfaced and got fixed during implementation: `&.{...}` (taking the address
  of an anonymous composite literal) is only safe when every element is comptime-known: The
  moment an element is a runtime function call (`try nonNull(allocator, ...)`), Zig allocates
  the literal on the stack, and returning `&.{...}` from the function that built it is a
  dangling-pointer bug — caught by a "switch on corrupt value" test crash, fixed by allocating
  through `allocator.alloc` explicitly wherever a `FieldArgument`/similar slice is built from
  non-comptime values.
