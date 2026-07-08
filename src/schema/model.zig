const std = @import("std");
const ndc_ir = @import("ndc_ir");

/// Milestone 1 hardcodes the same operator set for every scalar type rather
/// than discovering per-type operators from pg_operator (see docs/roadmap.md).
pub const ScalarType = struct {
    name: []const u8,
    comparison_operators: []const ndc_ir.BinaryOperator,
    supports_is_null: bool = true,
};

pub const ObjectField = struct {
    /// Key into SchemaModel.scalar_types.
    scalar_type: []const u8,
    nullable: bool,
    /// True if Postgres supplies a value when one isn't given (a literal
    /// DEFAULT expression, or a serial/identity column) -- the column may
    /// still be explicitly supplied to `insert_<t>`, it's just optional (see
    /// docs/decisions/0010-mutation-procedure-naming.md).
    has_default: bool = false,
    /// True for `GENERATED ALWAYS AS (...) STORED` columns -- Postgres
    /// rejects writes to these outright, so `insert_<t>`/`update_<t>_by_pk`
    /// must exclude them entirely, not just mark them optional.
    is_generated: bool = false,
};

/// Preserves insertion order so field order is deterministic (matches the
/// column order Postgres reports), the same determinism concern as
/// ndc_ir.FieldSelection.
pub const ObjectType = struct {
    fields: std.StringArrayHashMapUnmanaged(ObjectField) = .{},
};

pub const Collection = struct {
    db_schema: []const u8,
    db_table: []const u8,
    /// Key into SchemaModel.object_types. Always equal to the collection's own
    /// name in milestone 1 (no renaming) — kept as a separate field so a later
    /// milestone can introduce renaming without changing this type's shape.
    object_type: []const u8,
    primary_key: []const []const u8 = &.{},
};

/// A schema, once built, is treated as immutable and is expected to be owned
/// by an arena (built once per connection/session, torn down all at once via
/// `arena.deinit()`) rather than field-by-field — see `build` in introspect.zig.
/// This sidesteps fine-grained ownership tracking for a data structure whose
/// entire lifecycle is "build once, read many times, discard as a whole."
pub const SchemaModel = struct {
    scalar_types: std.StringHashMapUnmanaged(ScalarType) = .{},
    object_types: std.StringHashMapUnmanaged(ObjectType) = .{},
    collections: std.StringHashMapUnmanaged(Collection) = .{},
    /// Per-collection relationship maps: collection name -> (relationship name -> Relationship).
    /// Reuses ndc_ir.Relationship/RelationshipMap rather than inventing a parallel type,
    /// since a schema-derived relationship and a query's relationship reference are the
    /// same shape (target collection + join columns).
    relationships: std.StringHashMapUnmanaged(ndc_ir.RelationshipMap) = .{},
};

test "SchemaModel default-initializes to empty maps" {
    const s = SchemaModel{};
    try std.testing.expectEqual(@as(usize, 0), s.collections.count());
}
