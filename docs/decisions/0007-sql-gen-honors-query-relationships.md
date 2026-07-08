# 0007 — `sql_gen` resolves relationships from `query.relationships` first

## Status

Accepted.

## Context

`ndc_ir.Query.relationships` exists to mirror NDC's wire-level `collection_relationships` —
every producer (`graphql_parser`, `query_builder`, and the NDC-JSON producer in
`http_server/ndc_request.zig`) populates it as relationship fields are lowered. Milestone 1's
`sql_gen/ir_to_sql.zig`, however, never read it: it resolved every relationship fresh from
`SchemaModel.relationships` instead. This was discovered during milestone 2 planning, not by
a failing test — the field was silently dead code.

The practical consequence: `query_builder.Builder.selectRelationship`'s signature accepts an
arbitrary `ndc_ir.Relationship` value from the caller, appearing to let host code describe a
relationship `sql_gen` doesn't already know about from schema introspection. In reality this
was illusory — `sql_gen` ignored whatever the caller passed and looked the relationship up in
the schema anyway, silently discarding any caller-supplied `Relationship` that didn't match
what introspection had already derived.

## Decision

`sql_gen/ir_to_sql.zig` resolves a relationship by name from `query.relationships` first,
falling back to `SchemaModel.relationships` if not present there. Every current producer
already populates `query.relationships` as a side effect of lowering relationship fields, so
this is a behavior-preserving change for all of milestone 1's existing tests; it just makes
the field's presence load-bearing instead of decorative.

## Consequences

- `query_builder.selectRelationship`'s "caller supplies the Relationship" contract is now
  real: a builder-constructed query can describe a relationship that doesn't come from
  `SchemaModel` at all (useful, for example, if a future milestone wants to support ad hoc
  relationships not derivable from FK introspection).
- No producer needs to change: all three already write to `query.relationships`, so this is a
  `sql_gen`-only fix.
- `query.relationships` is no longer dead code, closing a real gap between the IR's stated
  design intent (mirroring NDC's wire-level relationship map) and what `sql_gen` actually did.
