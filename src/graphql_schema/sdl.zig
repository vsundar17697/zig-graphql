const std = @import("std");
const type_system = @import("type_system.zig");

const TypeSystem = type_system.TypeSystem;
const TypeDef = type_system.TypeDef;
const TypeRef = type_system.TypeRef;

pub const Error = std.mem.Allocator.Error;

fn renderTypeRef(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, ref: TypeRef) Error!void {
    switch (ref) {
        .named => |name| try buf.appendSlice(allocator, name),
        .list => |inner| {
            try buf.append(allocator, '[');
            try renderTypeRef(buf, allocator, inner.*);
            try buf.append(allocator, ']');
        },
        .non_null => |inner| {
            try renderTypeRef(buf, allocator, inner.*);
            try buf.append(allocator, '!');
        },
    }
}

fn renderArguments(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, arguments: []const type_system.FieldArgument) Error!void {
    if (arguments.len == 0) return;
    try buf.append(allocator, '(');
    for (arguments, 0..) |arg, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, arg.name);
        try buf.appendSlice(allocator, ": ");
        try renderTypeRef(buf, allocator, arg.type);
    }
    try buf.append(allocator, ')');
}

fn renderObjectType(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, keyword: []const u8, def: type_system.ObjectTypeDef) Error!void {
    try buf.appendSlice(allocator, keyword);
    try buf.appendSlice(allocator, " ");
    try buf.appendSlice(allocator, def.name);
    try buf.appendSlice(allocator, " {\n");
    for (def.fields) |field| {
        try buf.appendSlice(allocator, "  ");
        try buf.appendSlice(allocator, field.name);
        try renderArguments(buf, allocator, field.arguments);
        try buf.appendSlice(allocator, ": ");
        try renderTypeRef(buf, allocator, field.type);
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "}\n\n");
}

fn renderInputObjectType(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, def: type_system.InputObjectTypeDef) Error!void {
    try buf.appendSlice(allocator, "input ");
    try buf.appendSlice(allocator, def.name);
    try buf.appendSlice(allocator, " {\n");
    for (def.fields) |field| {
        try buf.appendSlice(allocator, "  ");
        try buf.appendSlice(allocator, field.name);
        try buf.appendSlice(allocator, ": ");
        try renderTypeRef(buf, allocator, field.type);
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "}\n\n");
}

fn renderEnumType(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, def: type_system.EnumTypeDef) Error!void {
    try buf.appendSlice(allocator, "enum ");
    try buf.appendSlice(allocator, def.name);
    try buf.appendSlice(allocator, " {\n");
    for (def.values) |value| {
        try buf.appendSlice(allocator, "  ");
        try buf.appendSlice(allocator, value);
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "}\n\n");
}

/// The five built-in GraphQL scalars need no `scalar` declaration; every
/// other scalar (our own `Int`/`Float`/`String`/`Boolean`, plus any custom
/// one like `Timestamp`) does. `Int`/`Float`/`String`/`Boolean` happen to be
/// both this engine's scalar names *and* GraphQL's built-ins, so they're
/// skipped here even though `ID` never appears.
fn isBuiltinScalar(name: []const u8) bool {
    const builtins = [_][]const u8{ "Int", "Float", "String", "Boolean", "ID" };
    for (builtins) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

/// Renders `ts` as GraphQL SDL text. Pure function of `TypeSystem` -- see its
/// doc comment. Type names are sorted alphabetically before rendering so
/// output is deterministic regardless of `TypeSystem.types`' insertion order
/// (itself partly derived from unordered `SchemaModel` maps).
pub fn render(allocator: std.mem.Allocator, ts: *const TypeSystem) Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (ts.types.keys()) |name| try names.append(allocator, name);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try buf.appendSlice(allocator, "schema {\n  query: ");
    try buf.appendSlice(allocator, ts.query_type_name);
    try buf.append(allocator, '\n');
    if (ts.mutation_type_name) |mutation_name| {
        try buf.appendSlice(allocator, "  mutation: ");
        try buf.appendSlice(allocator, mutation_name);
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "}\n\n");

    for (names.items) |name| {
        const def = ts.types.get(name).?;
        switch (def) {
            .scalar => |scalar_name| {
                if (isBuiltinScalar(scalar_name)) continue;
                try buf.appendSlice(allocator, "scalar ");
                try buf.appendSlice(allocator, scalar_name);
                try buf.appendSlice(allocator, "\n\n");
            },
            .object => |object_def| try renderObjectType(&buf, allocator, "type", object_def),
            .input_object => |input_def| try renderInputObjectType(&buf, allocator, input_def),
            .enum_ => |enum_def| try renderEnumType(&buf, allocator, enum_def),
        }
    }

    return buf.toOwnedSlice(allocator);
}

const schema = @import("schema");

fn testSchema(allocator: std.mem.Allocator) !schema.SchemaModel {
    return schema.buildSchemaModel(allocator, .{
        .tables = &.{.{ .schema_name = "public", .table_name = "artist" }},
        .columns = &.{
            .{ .table_name = "artist", .column_name = "artist_id", .pg_type = "integer", .nullable = false, .has_default = true },
            .{ .table_name = "artist", .column_name = "name", .pg_type = "text", .nullable = false },
        },
        .primary_keys = &.{.{ .table_name = "artist", .column_name = "artist_id" }},
    });
}

test "render produces a schema block and the artist object type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try type_system.build(allocator, &schema_model);
    const text = try render(allocator, &ts);

    try std.testing.expect(std.mem.indexOf(u8, text, "schema {\n  query: query_root\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type artist {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  name: String!\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mutation: mutation_root") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "input artist_insert_input {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "enum order_by {\n") != null);
}

test "render skips scalar declarations for GraphQL's own built-in scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try type_system.build(allocator, &schema_model);
    const text = try render(allocator, &ts);

    try std.testing.expect(std.mem.indexOf(u8, text, "scalar Int") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scalar String") == null);
}
