const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");

fn operatorJsonName(op: ndc_ir.BinaryOperator) []const u8 {
    return switch (op) {
        .eq => "_eq",
        .neq => "_neq",
        .gt => "_gt",
        .gte => "_gte",
        .lt => "_lt",
        .lte => "_lte",
        .in => "_in",
    };
}

fn emptyObject() std.json.Value {
    return .{ .object = std.json.ObjectMap.empty };
}

/// Serializes a SchemaModel into the NDC SchemaResponse JSON shape (see the
/// approved plan for the documented field names). This is a deliberately
/// simplified rendering -- e.g. every comparison operator is emitted as an
/// empty placeholder object rather than the full operatorKind/argumentType
/// detail the real NDC spec carries -- since /schema's job for milestone 1 is
/// to prove the shape and the introspection data are right end-to-end, not to
/// byte-match every field of the full spec (the hard, risky part of this
/// project is query execution correctness, already covered by the executor
/// and integration tests).
pub fn toJson(allocator: std.mem.Allocator, schema_model: *const schema.SchemaModel) !std.json.Value {
    var scalar_types: std.json.ObjectMap = .empty;
    var st_it = schema_model.scalar_types.iterator();
    while (st_it.next()) |entry| {
        var comparison_operators: std.json.ObjectMap = .empty;
        for (entry.value_ptr.comparison_operators) |op| {
            try comparison_operators.put(allocator, operatorJsonName(op), emptyObject());
        }
        if (entry.value_ptr.supports_is_null) {
            try comparison_operators.put(allocator, "is_null", emptyObject());
        }

        var scalar_obj: std.json.ObjectMap = .empty;
        try scalar_obj.put(allocator, "representation", .{ .string = entry.value_ptr.name });
        try scalar_obj.put(allocator, "comparison_operators", .{ .object = comparison_operators });
        try scalar_obj.put(allocator, "aggregate_functions", emptyObject());
        try scalar_types.put(allocator, entry.key_ptr.*, .{ .object = scalar_obj });
    }

    var object_types: std.json.ObjectMap = .empty;
    var ot_it = schema_model.object_types.iterator();
    while (ot_it.next()) |entry| {
        var fields_obj: std.json.ObjectMap = .empty;
        for (entry.value_ptr.fields.keys(), entry.value_ptr.fields.values()) |name, f| {
            var field_obj: std.json.ObjectMap = .empty;
            try field_obj.put(allocator, "type", .{ .string = f.scalar_type });
            try fields_obj.put(allocator, name, .{ .object = field_obj });
        }
        var ot_obj: std.json.ObjectMap = .empty;
        try ot_obj.put(allocator, "fields", .{ .object = fields_obj });
        try object_types.put(allocator, entry.key_ptr.*, .{ .object = ot_obj });
    }

    var collections: std.json.Array = .init(allocator);
    var c_it = schema_model.collections.iterator();
    while (c_it.next()) |entry| {
        var c_obj: std.json.ObjectMap = .empty;
        try c_obj.put(allocator, "name", .{ .string = entry.key_ptr.* });
        try c_obj.put(allocator, "type", .{ .string = entry.value_ptr.object_type });
        try c_obj.put(allocator, "arguments", emptyObject());
        try c_obj.put(allocator, "uniqueness_constraints", emptyObject());
        try collections.append(.{ .object = c_obj });
    }

    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "scalar_types", .{ .object = scalar_types });
    try root.put(allocator, "object_types", .{ .object = object_types });
    try root.put(allocator, "collections", .{ .array = collections });
    return .{ .object = root };
}

test "toJson renders collections, object types and scalar types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var model = schema.SchemaModel{};
    try model.scalar_types.put(allocator, "Int", .{ .name = "Int", .comparison_operators = &.{.eq} });

    var album_object_type = schema.ObjectType{};
    try album_object_type.fields.put(allocator, "album_id", .{ .scalar_type = "Int", .nullable = false });
    try model.object_types.put(allocator, "album", album_object_type);
    try model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    const json_value = try toJson(allocator, &model);

    const collections = json_value.object.get("collections").?.array;
    try std.testing.expectEqual(@as(usize, 1), collections.items.len);
    try std.testing.expectEqualStrings("album", collections.items[0].object.get("name").?.string);

    const album_fields = json_value.object.get("object_types").?.object.get("album").?.object.get("fields").?.object;
    try std.testing.expectEqualStrings("Int", album_fields.get("album_id").?.object.get("type").?.string);

    const int_operators = json_value.object.get("scalar_types").?.object.get("Int").?.object.get("comparison_operators").?.object;
    try std.testing.expect(int_operators.contains("_eq"));
    try std.testing.expect(int_operators.contains("is_null"));
}
