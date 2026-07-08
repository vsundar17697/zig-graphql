const std = @import("std");
const model = @import("model.zig");

pub const ProcedureKind = enum { insert, update_by_pk, delete_by_pk };

pub const Procedure = struct {
    kind: ProcedureKind,
    /// Borrowed from the input `name` string (e.g. "album" out of
    /// "insert_album") -- valid exactly as long as `name` is, which is always
    /// an arena-owned request value (see docs/architecture.md).
    collection: []const u8,
};

pub const Error = error{UnknownProcedure};

/// Resolves an auto-derived procedure name into its kind and target
/// collection by pattern (`insert_<t>`, `update_<t>_by_pk`,
/// `delete_<t>_by_pk` -- see docs/decisions/0010-mutation-procedure-naming.md).
/// Procedure names are a pure function of collection names, so there's no
/// registry to precompute or look up -- this just parses `name` and checks
/// the referenced collection exists (and, for the two `_by_pk` kinds,
/// declares a primary key -- deleting/updating "by pk" is meaningless
/// without one).
pub fn resolveProcedure(schema_model: *const model.SchemaModel, name: []const u8) Error!Procedure {
    if (std.mem.startsWith(u8, name, "insert_")) {
        const collection_name = name["insert_".len..];
        if (!schema_model.collections.contains(collection_name)) return Error.UnknownProcedure;
        return .{ .kind = .insert, .collection = collection_name };
    }
    if (std.mem.startsWith(u8, name, "update_") and std.mem.endsWith(u8, name, "_by_pk")) {
        const collection_name = name["update_".len .. name.len - "_by_pk".len];
        const collection = schema_model.collections.get(collection_name) orelse return Error.UnknownProcedure;
        if (collection.primary_key.len == 0) return Error.UnknownProcedure;
        return .{ .kind = .update_by_pk, .collection = collection_name };
    }
    if (std.mem.startsWith(u8, name, "delete_") and std.mem.endsWith(u8, name, "_by_pk")) {
        const collection_name = name["delete_".len .. name.len - "_by_pk".len];
        const collection = schema_model.collections.get(collection_name) orelse return Error.UnknownProcedure;
        if (collection.primary_key.len == 0) return Error.UnknownProcedure;
        return .{ .kind = .delete_by_pk, .collection = collection_name };
    }
    return Error.UnknownProcedure;
}

/// Enumerates every procedure name the schema exposes -- `insert_<t>` for
/// every collection, plus `update_<t>_by_pk`/`delete_<t>_by_pk` for
/// collections with a primary key. Used by schema introspection (`GET
/// /schema`'s procedures section) and GraphQL SDL generation, not by mutation
/// execution itself (which goes straight through `resolveProcedure`).
pub fn listProcedureNames(allocator: std.mem.Allocator, schema_model: *const model.SchemaModel) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = schema_model.collections.iterator();
    while (it.next()) |entry| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "insert_{s}", .{entry.key_ptr.*}));
        if (entry.value_ptr.primary_key.len > 0) {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "update_{s}_by_pk", .{entry.key_ptr.*}));
            try out.append(allocator, try std.fmt.allocPrint(allocator, "delete_{s}_by_pk", .{entry.key_ptr.*}));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn testSchema(allocator: std.mem.Allocator) !model.SchemaModel {
    var schema = model.SchemaModel{};
    try schema.collections.put(allocator, "album", .{
        .db_schema = "public",
        .db_table = "album",
        .object_type = "album",
        .primary_key = &.{"album_id"},
    });
    try schema.collections.put(allocator, "promotion", .{
        .db_schema = "public",
        .db_table = "promotion",
        .object_type = "promotion",
        // No primary key -- update/delete-by-pk procedures must not exist for this collection.
    });
    return schema;
}

test "resolveProcedure resolves insert_<t> for any collection, pk or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema = try testSchema(allocator);

    const proc = try resolveProcedure(&schema, "insert_promotion");
    try std.testing.expectEqual(ProcedureKind.insert, proc.kind);
    try std.testing.expectEqualStrings("promotion", proc.collection);
}

test "resolveProcedure resolves update_<t>_by_pk and delete_<t>_by_pk for a PK'd collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema = try testSchema(allocator);

    const update_proc = try resolveProcedure(&schema, "update_album_by_pk");
    try std.testing.expectEqual(ProcedureKind.update_by_pk, update_proc.kind);
    try std.testing.expectEqualStrings("album", update_proc.collection);

    const delete_proc = try resolveProcedure(&schema, "delete_album_by_pk");
    try std.testing.expectEqual(ProcedureKind.delete_by_pk, delete_proc.kind);
    try std.testing.expectEqualStrings("album", delete_proc.collection);
}

test "resolveProcedure rejects *_by_pk procedures for a collection with no primary key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema = try testSchema(allocator);

    try std.testing.expectError(Error.UnknownProcedure, resolveProcedure(&schema, "update_promotion_by_pk"));
    try std.testing.expectError(Error.UnknownProcedure, resolveProcedure(&schema, "delete_promotion_by_pk"));
}

test "resolveProcedure rejects an unknown collection or malformed name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema = try testSchema(allocator);

    try std.testing.expectError(Error.UnknownProcedure, resolveProcedure(&schema, "insert_nonexistent"));
    try std.testing.expectError(Error.UnknownProcedure, resolveProcedure(&schema, "not_a_procedure"));
}

test "listProcedureNames enumerates insert for every collection and by_pk only for PK'd ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema = try testSchema(allocator);

    const names = try listProcedureNames(allocator, &schema);

    var has_insert_album = false;
    var has_insert_promotion = false;
    var has_update_album = false;
    var has_update_promotion = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "insert_album")) has_insert_album = true;
        if (std.mem.eql(u8, name, "insert_promotion")) has_insert_promotion = true;
        if (std.mem.eql(u8, name, "update_album_by_pk")) has_update_album = true;
        if (std.mem.eql(u8, name, "update_promotion_by_pk")) has_update_promotion = true;
    }
    try std.testing.expect(has_insert_album);
    try std.testing.expect(has_insert_promotion);
    try std.testing.expect(has_update_album);
    try std.testing.expect(!has_update_promotion);
    try std.testing.expectEqual(@as(usize, 4), names.len); // insert_album, insert_promotion, update_album_by_pk, delete_album_by_pk
}
