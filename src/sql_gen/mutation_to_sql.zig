const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");
const ast = @import("ast.zig");

pub const Error = schema.ProcedureError || error{
    MissingArgument,
    UnexpectedArgumentShape,
    UnknownColumn,
    ColumnNotInsertable,
    MissingPrimaryKeyColumn,
    UnexpectedPrimaryKeyColumn,
    EmptySetClause,
    UnsupportedReturningField,
    UnsupportedArgumentValue,
} || std.mem.Allocator.Error;

fn jsonValueToSqlValue(value: std.json.Value) Error!ast.Value {
    return switch (value) {
        .null => .null_,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .text = s },
        .number_string, .array, .object => Error.UnsupportedArgumentValue,
    };
}

fn objectArgument(operation: *const ndc_ir.MutationOperation, key: []const u8) Error!std.json.ObjectMap {
    const value = operation.arguments.get(key) orelse return Error.MissingArgument;
    return switch (value) {
        .object => |o| o,
        else => Error.UnexpectedArgumentShape,
    };
}

fn tableRefFor(collection: schema.Collection) ast.TableRef {
    return .{ .schema = collection.db_schema, .table = collection.db_table, .alias = collection.db_table };
}

fn translateInsert(
    allocator: std.mem.Allocator,
    operation: *const ndc_ir.MutationOperation,
    collection: schema.Collection,
    object_type: schema.ObjectType,
) Error!ast.InsertStatement {
    const object = try objectArgument(operation, "object");

    var columns: std.ArrayListUnmanaged([]const u8) = .empty;
    var values: std.ArrayListUnmanaged(ast.Value) = .empty;
    var it = object.iterator();
    while (it.next()) |entry| {
        const field = object_type.fields.get(entry.key_ptr.*) orelse return Error.UnknownColumn;
        if (field.is_generated) return Error.ColumnNotInsertable;
        try columns.append(allocator, entry.key_ptr.*);
        try values.append(allocator, try jsonValueToSqlValue(entry.value_ptr.*));
    }

    return .{
        .table = tableRefFor(collection),
        .columns = try columns.toOwnedSlice(allocator),
        .values = try values.toOwnedSlice(allocator),
    };
}

const PkColumns = struct { columns: []const []const u8, values: []const ast.Value };

/// Requires `pk_obj` to supply a value for every one of `collection`'s
/// declared primary-key columns, no more and no fewer -- a partial or
/// over-specified `pk_columns` argument is a caller error, not something to
/// silently ignore or pad.
fn translatePkColumns(allocator: std.mem.Allocator, pk_obj: std.json.ObjectMap, collection: schema.Collection) Error!PkColumns {
    if (pk_obj.count() != collection.primary_key.len) return Error.MissingPrimaryKeyColumn;

    var columns: std.ArrayListUnmanaged([]const u8) = .empty;
    var values: std.ArrayListUnmanaged(ast.Value) = .empty;
    for (collection.primary_key) |pk_col| {
        const v = pk_obj.get(pk_col) orelse return Error.MissingPrimaryKeyColumn;
        try columns.append(allocator, pk_col);
        try values.append(allocator, try jsonValueToSqlValue(v));
    }

    var it = pk_obj.iterator();
    while (it.next()) |entry| {
        var found = false;
        for (collection.primary_key) |pk_col| {
            if (std.mem.eql(u8, pk_col, entry.key_ptr.*)) {
                found = true;
                break;
            }
        }
        if (!found) return Error.UnexpectedPrimaryKeyColumn;
    }

    return .{ .columns = try columns.toOwnedSlice(allocator), .values = try values.toOwnedSlice(allocator) };
}

fn translateUpdateByPk(
    allocator: std.mem.Allocator,
    operation: *const ndc_ir.MutationOperation,
    collection: schema.Collection,
    object_type: schema.ObjectType,
) Error!ast.UpdateStatement {
    const pk_obj = try objectArgument(operation, "pk_columns");
    const pk = try translatePkColumns(allocator, pk_obj, collection);

    const set_obj = try objectArgument(operation, "_set");
    if (set_obj.count() == 0) return Error.EmptySetClause;

    var set_columns: std.ArrayListUnmanaged([]const u8) = .empty;
    var set_values: std.ArrayListUnmanaged(ast.Value) = .empty;
    var it = set_obj.iterator();
    while (it.next()) |entry| {
        const field = object_type.fields.get(entry.key_ptr.*) orelse return Error.UnknownColumn;
        if (field.is_generated) return Error.ColumnNotInsertable;
        try set_columns.append(allocator, entry.key_ptr.*);
        try set_values.append(allocator, try jsonValueToSqlValue(entry.value_ptr.*));
    }

    return .{
        .table = tableRefFor(collection),
        .set_columns = try set_columns.toOwnedSlice(allocator),
        .set_values = try set_values.toOwnedSlice(allocator),
        .pk_columns = pk.columns,
        .pk_values = pk.values,
    };
}

fn translateDeleteByPk(
    allocator: std.mem.Allocator,
    operation: *const ndc_ir.MutationOperation,
    collection: schema.Collection,
) Error!ast.DeleteStatement {
    const pk_obj = try objectArgument(operation, "pk_columns");
    const pk = try translatePkColumns(allocator, pk_obj, collection);

    return .{
        .table = tableRefFor(collection),
        .pk_columns = pk.columns,
        .pk_values = pk.values,
    };
}

/// Only `Field.column` is meaningful for RETURNING in milestone 3 --
/// relationship fields inside `returning` are deferred (see docs/roadmap.md).
fn translateReturning(allocator: std.mem.Allocator, fields: ndc_ir.FieldSelection) Error![]const ast.ColumnItem {
    const out = try allocator.alloc(ast.ColumnItem, fields.count());
    var it = fields.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = switch (entry.value_ptr.*) {
            .column => |c| .{ .column = .{ .table_alias = "mutated", .column = c.column }, .alias = entry.key_ptr.* },
            .relationship => return Error.UnsupportedReturningField,
        };
    }
    return out;
}

/// Translates one ndc_ir.MutationOperation into a SQL AST, resolving the
/// procedure name and validating its arguments' shape against the target
/// collection's schema. Pure function, like ir_to_sql.translate -- no I/O.
pub fn translateMutation(
    allocator: std.mem.Allocator,
    operation: *const ndc_ir.MutationOperation,
    schema_model: *const schema.SchemaModel,
) Error!*const ast.MutationStatement {
    const proc = try schema.resolveProcedure(schema_model, operation.name);
    // resolveProcedure already verified the collection exists.
    const collection = schema_model.collections.get(proc.collection).?;
    const object_type = schema_model.object_types.get(proc.collection) orelse schema.ObjectType{};

    const op: ast.MutationOp = switch (proc.kind) {
        .insert => .{ .insert = try translateInsert(allocator, operation, collection, object_type) },
        .update_by_pk => .{ .update = try translateUpdateByPk(allocator, operation, collection, object_type) },
        .delete_by_pk => .{ .delete = try translateDeleteByPk(allocator, operation, collection) },
    };

    const returning = if (operation.fields) |fields| try translateReturning(allocator, fields) else null;

    const stmt = try allocator.create(ast.MutationStatement);
    stmt.* = .{ .op = op, .returning = returning };
    return stmt;
}

fn testSchema(allocator: std.mem.Allocator) !schema.SchemaModel {
    var model = schema.SchemaModel{};
    try model.collections.put(allocator, "album", .{
        .db_schema = "public",
        .db_table = "album",
        .object_type = "album",
        .primary_key = &.{"AlbumId"},
    });

    var album_type = schema.ObjectType{};
    try album_type.fields.put(allocator, "AlbumId", .{ .scalar_type = "Int", .nullable = false, .has_default = true });
    try album_type.fields.put(allocator, "Title", .{ .scalar_type = "String", .nullable = false });
    try album_type.fields.put(allocator, "ArtistId", .{ .scalar_type = "Int", .nullable = false });
    try album_type.fields.put(allocator, "SearchText", .{ .scalar_type = "String", .nullable = true, .is_generated = true });
    try model.object_types.put(allocator, "album", album_type);

    return model;
}

fn objectArg(allocator: std.mem.Allocator, pairs: anytype) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    inline for (pairs) |pair| {
        try obj.put(allocator, pair[0], pair[1]);
    }
    return .{ .object = obj };
}

test "translates insert_<t> into an InsertStatement using the object argument's keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "insert_album" };
    try operation.arguments.put(allocator, "object", try objectArg(allocator, .{
        .{ "Title", std.json.Value{ .string = "Highway to Hell" } },
        .{ "ArtistId", std.json.Value{ .integer = 1 } },
    }));

    const stmt = try translateMutation(allocator, &operation, &schema_model);

    try std.testing.expectEqualStrings("album", stmt.op.insert.table.table);
    try std.testing.expectEqual(@as(usize, 2), stmt.op.insert.columns.len);
    try std.testing.expect(stmt.returning == null);
}

test "insert rejects a generated column supplied in the object argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "insert_album" };
    try operation.arguments.put(allocator, "object", try objectArg(allocator, .{
        .{ "SearchText", std.json.Value{ .string = "hack" } },
    }));

    try std.testing.expectError(Error.ColumnNotInsertable, translateMutation(allocator, &operation, &schema_model));
}

test "insert rejects an unknown column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "insert_album" };
    try operation.arguments.put(allocator, "object", try objectArg(allocator, .{
        .{ "NotAColumn", std.json.Value{ .integer = 1 } },
    }));

    try std.testing.expectError(Error.UnknownColumn, translateMutation(allocator, &operation, &schema_model));
}

test "insert with a returning selection produces a translateable ColumnItem list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "insert_album" };
    try operation.arguments.put(allocator, "object", try objectArg(allocator, .{
        .{ "Title", std.json.Value{ .string = "Highway to Hell" } },
    }));
    var fields: ndc_ir.FieldSelection = .{};
    try fields.put(allocator, "id", .{ .column = .{ .column = "AlbumId" } });
    operation.fields = fields;

    const stmt = try translateMutation(allocator, &operation, &schema_model);

    try std.testing.expect(stmt.returning != null);
    try std.testing.expectEqual(@as(usize, 1), stmt.returning.?.len);
    try std.testing.expectEqualStrings("AlbumId", stmt.returning.?[0].column.column);
    try std.testing.expectEqualStrings("id", stmt.returning.?[0].alias);
}

test "translates update_<t>_by_pk into an UpdateStatement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "update_album_by_pk" };
    try operation.arguments.put(allocator, "pk_columns", try objectArg(allocator, .{
        .{ "AlbumId", std.json.Value{ .integer = 1 } },
    }));
    try operation.arguments.put(allocator, "_set", try objectArg(allocator, .{
        .{ "Title", std.json.Value{ .string = "Renamed" } },
    }));

    const stmt = try translateMutation(allocator, &operation, &schema_model);

    try std.testing.expectEqual(@as(usize, 1), stmt.op.update.set_columns.len);
    try std.testing.expectEqual(@as(usize, 1), stmt.op.update.pk_columns.len);
}

test "update_by_pk rejects an empty _set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "update_album_by_pk" };
    try operation.arguments.put(allocator, "pk_columns", try objectArg(allocator, .{
        .{ "AlbumId", std.json.Value{ .integer = 1 } },
    }));
    try operation.arguments.put(allocator, "_set", try objectArg(allocator, .{}));

    try std.testing.expectError(Error.EmptySetClause, translateMutation(allocator, &operation, &schema_model));
}

test "update_by_pk rejects a partial pk_columns argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "update_album_by_pk" };
    try operation.arguments.put(allocator, "pk_columns", try objectArg(allocator, .{}));
    try operation.arguments.put(allocator, "_set", try objectArg(allocator, .{
        .{ "Title", std.json.Value{ .string = "Renamed" } },
    }));

    try std.testing.expectError(Error.MissingPrimaryKeyColumn, translateMutation(allocator, &operation, &schema_model));
}

test "translates delete_<t>_by_pk into a DeleteStatement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    var operation = ndc_ir.MutationOperation{ .name = "delete_album_by_pk" };
    try operation.arguments.put(allocator, "pk_columns", try objectArg(allocator, .{
        .{ "AlbumId", std.json.Value{ .integer = 1 } },
    }));

    const stmt = try translateMutation(allocator, &operation, &schema_model);

    try std.testing.expectEqual(@as(usize, 1), stmt.op.delete.pk_columns.len);
}

test "rejects an unknown procedure name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schema_model = try testSchema(allocator);

    const operation = ndc_ir.MutationOperation{ .name = "nonexistent_procedure" };

    try std.testing.expectError(Error.UnknownProcedure, translateMutation(allocator, &operation, &schema_model));
}
