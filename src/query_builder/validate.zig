const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");

pub const Error = error{ UnknownCollection, UnknownColumn, UnknownRelationship };

/// Checks every collection/column/relationship a query_builder-constructed
/// Query references against the live introspected SchemaModel, failing fast
/// with a specific error rather than letting a typo become a confusing
/// sql_gen error or, worse, a silently wrong query. This is the milestone-1
/// "runtime validation, not codegen" reconciliation strategy -- see
/// docs/decisions/0004-schema-reconciliation-runtime-validation.md.
pub fn validate(query: *const ndc_ir.Query, schema_model: *const schema.SchemaModel) Error!void {
    const collection = schema_model.collections.get(query.collection) orelse return Error.UnknownCollection;
    const object_type = schema_model.object_types.get(collection.object_type) orelse return Error.UnknownCollection;

    var it = query.fields.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .column => |c| {
                if (!object_type.fields.contains(c.column)) return Error.UnknownColumn;
            },
            .relationship => |r| {
                const collection_relationships = schema_model.relationships.get(query.collection) orelse return Error.UnknownRelationship;
                if (!collection_relationships.contains(r.relationship)) return Error.UnknownRelationship;
                try validate(r.query, schema_model);
            },
        }
    }
}

fn testSchema(allocator: std.mem.Allocator) !schema.SchemaModel {
    var model = schema.SchemaModel{};
    var album_object_type = schema.ObjectType{};
    try album_object_type.fields.put(allocator, "AlbumId", .{ .scalar_type = "Int", .nullable = false });
    try album_object_type.fields.put(allocator, "Title", .{ .scalar_type = "String", .nullable = false });
    try model.object_types.put(allocator, "album", album_object_type);
    try model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var rel = ndc_ir.Relationship{ .target_collection = "artist", .relationship_type = .object };
    var album_rels = ndc_ir.RelationshipMap{};
    try album_rels.put(allocator, "artist", rel);
    _ = &rel;
    try model.relationships.put(allocator, "album", album_rels);

    return model;
}

test "validate accepts a query referencing only real columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "AlbumId", .{ .column = .{ .column = "AlbumId" } });

    try validate(&query, &schema_model);
}

test "validate rejects an unknown collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const query = ndc_ir.Query{ .collection = "nonexistent" };

    try std.testing.expectError(Error.UnknownCollection, validate(&query, &schema_model));
}

test "validate rejects an unknown column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "NotAColumn", .{ .column = .{ .column = "NotAColumn" } });

    try std.testing.expectError(Error.UnknownColumn, validate(&query, &schema_model));
}

test "validate rejects an unknown relationship" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const nested = try allocator.create(ndc_ir.Query);
    nested.* = .{ .collection = "album" };

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "publisher", .{ .relationship = .{ .relationship = "publisher", .query = nested } });

    try std.testing.expectError(Error.UnknownRelationship, validate(&query, &schema_model));
}

test "validate recurses into nested relationship queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const nested = try allocator.create(ndc_ir.Query);
    nested.* = .{ .collection = "album" };
    try nested.fields.put(allocator, "BadColumn", .{ .column = .{ .column = "BadColumn" } });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "artist", .{ .relationship = .{ .relationship = "artist", .query = nested } });

    try std.testing.expectError(Error.UnknownColumn, validate(&query, &schema_model));
}
