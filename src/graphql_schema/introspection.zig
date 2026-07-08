const std = @import("std");
const graphql_parser = @import("graphql_parser");
const type_system = @import("type_system.zig");

const ast = graphql_parser;
const TypeSystem = type_system.TypeSystem;
const TypeRef = type_system.TypeRef;

pub const Error = std.mem.Allocator.Error || error{UnknownRootField};

/// Executes the resolved (fragment/directive/variable-free -- see
/// `graphql_parser/request.zig`) root fields of an introspection query
/// (`__schema`, `__type(name: ...)`) against `ts`, producing the `data`
/// object's contents directly (caller wraps in `{"data": ...}`). This is a
/// small interpreter over the requested selection set, not a generic GraphQL
/// executor -- it only ever answers the fixed, well-known introspection
/// field names (`__Schema`/`__Type`/`__Field`/`__InputValue`/`__EnumValue`/
/// `__Directive`), which is all `__schema`/`__type` ever ask for.
pub fn execute(allocator: std.mem.Allocator, ts: *const TypeSystem, root_fields: []const ast.Field) Error!std.json.Value {
    var data: std.json.ObjectMap = .empty;
    for (root_fields) |field| {
        if (std.mem.eql(u8, field.name, "__schema")) {
            try data.put(allocator, field.responseKey(), try resolveSchema(allocator, ts, field.selection_set));
        } else if (std.mem.eql(u8, field.name, "__type")) {
            const type_name = findStringArg(field.arguments, "name") orelse return Error.UnknownRootField;
            const value = if (ts.get(type_name) != null)
                try resolveTypeRef(allocator, ts, .{ .named = type_name }, field.selection_set)
            else
                std.json.Value.null;
            try data.put(allocator, field.responseKey(), value);
        } else if (std.mem.eql(u8, field.name, "__typename")) {
            try data.put(allocator, field.responseKey(), .{ .string = if (root_fields.len == 1) "query_root" else "query_root" });
        } else {
            return Error.UnknownRootField;
        }
    }
    return .{ .object = data };
}

fn findStringArg(arguments: []const ast.Argument, name: []const u8) ?[]const u8 {
    for (arguments) |arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            return switch (arg.value) {
                .string => |s| s,
                else => null,
            };
        }
    }
    return null;
}

fn sortedTypeNames(allocator: std.mem.Allocator, ts: *const TypeSystem) Error![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (ts.types.keys()) |name| try names.append(allocator, name);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(allocator);
}

fn resolveSchema(allocator: std.mem.Allocator, ts: *const TypeSystem, selection_set: []const ast.Field) Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (selection_set) |f| {
        if (std.mem.eql(u8, f.name, "queryType")) {
            try obj.put(allocator, f.responseKey(), try resolveTypeRef(allocator, ts, .{ .named = ts.query_type_name }, f.selection_set));
        } else if (std.mem.eql(u8, f.name, "mutationType")) {
            const value = if (ts.mutation_type_name) |name|
                try resolveTypeRef(allocator, ts, .{ .named = name }, f.selection_set)
            else
                std.json.Value.null;
            try obj.put(allocator, f.responseKey(), value);
        } else if (std.mem.eql(u8, f.name, "subscriptionType")) {
            try obj.put(allocator, f.responseKey(), .null);
        } else if (std.mem.eql(u8, f.name, "types")) {
            var arr = std.json.Array.init(allocator);
            for (try sortedTypeNames(allocator, ts)) |name| {
                try arr.append(try resolveTypeRef(allocator, ts, .{ .named = name }, f.selection_set));
            }
            try obj.put(allocator, f.responseKey(), .{ .array = arr });
        } else if (std.mem.eql(u8, f.name, "directives")) {
            try obj.put(allocator, f.responseKey(), try resolveDirectives(allocator, f.selection_set));
        } else if (std.mem.eql(u8, f.name, "description")) {
            try obj.put(allocator, f.responseKey(), .null);
        } else if (std.mem.eql(u8, f.name, "__typename")) {
            try obj.put(allocator, f.responseKey(), .{ .string = "__Schema" });
        }
    }
    return .{ .object = obj };
}

fn kindOf(ts: *const TypeSystem, ref: TypeRef) []const u8 {
    return switch (ref) {
        .non_null => "NON_NULL",
        .list => "LIST",
        .named => |name| switch (ts.get(name).?) {
            .scalar => "SCALAR",
            .object => "OBJECT",
            .input_object => "INPUT_OBJECT",
            .enum_ => "ENUM",
        },
    };
}

/// Answers a `__Type` selection set -- the one function that has to handle
/// both named types (SCALAR/OBJECT/INPUT_OBJECT/ENUM) and the NON_NULL/LIST
/// wrappers uniformly, since GraphQL's own introspection query walks
/// arbitrarily deep through `ofType` for wrapped types (see
/// docs/decisions/0013-graphql-type-system.md on why this is the highest
/// mutual-recursion risk in the milestone -- `Error` is explicit throughout
/// this file for exactly that reason).
fn resolveTypeRef(allocator: std.mem.Allocator, ts: *const TypeSystem, ref: TypeRef, selection_set: []const ast.Field) Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (selection_set) |f| {
        if (std.mem.eql(u8, f.name, "kind")) {
            try obj.put(allocator, f.responseKey(), .{ .string = kindOf(ts, ref) });
        } else if (std.mem.eql(u8, f.name, "name")) {
            try obj.put(allocator, f.responseKey(), switch (ref) {
                .named => |n| std.json.Value{ .string = n },
                else => .null,
            });
        } else if (std.mem.eql(u8, f.name, "description")) {
            try obj.put(allocator, f.responseKey(), .null);
        } else if (std.mem.eql(u8, f.name, "specifiedByURL")) {
            try obj.put(allocator, f.responseKey(), .null);
        } else if (std.mem.eql(u8, f.name, "fields")) {
            try obj.put(allocator, f.responseKey(), try resolveFieldsList(allocator, ts, ref, f.selection_set));
        } else if (std.mem.eql(u8, f.name, "inputFields")) {
            try obj.put(allocator, f.responseKey(), try resolveInputFieldsList(allocator, ts, ref, f.selection_set));
        } else if (std.mem.eql(u8, f.name, "interfaces")) {
            try obj.put(allocator, f.responseKey(), switch (ref) {
                .named => |n| if (ts.get(n).? == .object) std.json.Value{ .array = std.json.Array.init(allocator) } else .null,
                else => .null,
            });
        } else if (std.mem.eql(u8, f.name, "enumValues")) {
            try obj.put(allocator, f.responseKey(), try resolveEnumValuesList(allocator, ts, ref, f.selection_set));
        } else if (std.mem.eql(u8, f.name, "possibleTypes")) {
            try obj.put(allocator, f.responseKey(), .null);
        } else if (std.mem.eql(u8, f.name, "ofType")) {
            const inner: ?TypeRef = switch (ref) {
                .list => |i| i.*,
                .non_null => |i| i.*,
                .named => null,
            };
            try obj.put(allocator, f.responseKey(), if (inner) |r| try resolveTypeRef(allocator, ts, r, f.selection_set) else .null);
        } else if (std.mem.eql(u8, f.name, "__typename")) {
            try obj.put(allocator, f.responseKey(), .{ .string = "__Type" });
        }
    }
    return .{ .object = obj };
}

fn resolveFieldsList(allocator: std.mem.Allocator, ts: *const TypeSystem, ref: TypeRef, selection_set: []const ast.Field) Error!std.json.Value {
    const name = switch (ref) {
        .named => |n| n,
        else => return .null,
    };
    const object_def = switch (ts.get(name).?) {
        .object => |o| o,
        else => return .null,
    };
    var arr = std.json.Array.init(allocator);
    for (object_def.fields) |field| try arr.append(try resolveFieldIntrospection(allocator, ts, field, selection_set));
    return .{ .array = arr };
}

fn resolveFieldIntrospection(allocator: std.mem.Allocator, ts: *const TypeSystem, field: type_system.ObjectField, selection_set: []const ast.Field) Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (selection_set) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            try obj.put(allocator, f.responseKey(), .{ .string = field.name });
        } else if (std.mem.eql(u8, f.name, "description")) {
            try obj.put(allocator, f.responseKey(), .null);
        } else if (std.mem.eql(u8, f.name, "args")) {
            var args_arr = std.json.Array.init(allocator);
            for (field.arguments) |arg| try args_arr.append(try resolveInputValue(allocator, ts, arg.name, arg.type, f.selection_set));
            try obj.put(allocator, f.responseKey(), .{ .array = args_arr });
        } else if (std.mem.eql(u8, f.name, "type")) {
            try obj.put(allocator, f.responseKey(), try resolveTypeRef(allocator, ts, field.type, f.selection_set));
        } else if (std.mem.eql(u8, f.name, "isDeprecated")) {
            try obj.put(allocator, f.responseKey(), .{ .bool = false });
        } else if (std.mem.eql(u8, f.name, "deprecationReason")) {
            try obj.put(allocator, f.responseKey(), .null);
        }
    }
    return .{ .object = obj };
}

fn resolveInputValue(allocator: std.mem.Allocator, ts: *const TypeSystem, name: []const u8, type_ref: TypeRef, selection_set: []const ast.Field) Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (selection_set) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            try obj.put(allocator, f.responseKey(), .{ .string = name });
        } else if (std.mem.eql(u8, f.name, "description")) {
            try obj.put(allocator, f.responseKey(), .null);
        } else if (std.mem.eql(u8, f.name, "type")) {
            try obj.put(allocator, f.responseKey(), try resolveTypeRef(allocator, ts, type_ref, f.selection_set));
        } else if (std.mem.eql(u8, f.name, "defaultValue")) {
            try obj.put(allocator, f.responseKey(), .null);
        }
    }
    return .{ .object = obj };
}

fn resolveInputFieldsList(allocator: std.mem.Allocator, ts: *const TypeSystem, ref: TypeRef, selection_set: []const ast.Field) Error!std.json.Value {
    const name = switch (ref) {
        .named => |n| n,
        else => return .null,
    };
    const input_def = switch (ts.get(name).?) {
        .input_object => |o| o,
        else => return .null,
    };
    var arr = std.json.Array.init(allocator);
    for (input_def.fields) |field| try arr.append(try resolveInputValue(allocator, ts, field.name, field.type, selection_set));
    return .{ .array = arr };
}

fn resolveEnumValuesList(allocator: std.mem.Allocator, ts: *const TypeSystem, ref: TypeRef, selection_set: []const ast.Field) Error!std.json.Value {
    const name = switch (ref) {
        .named => |n| n,
        else => return .null,
    };
    const enum_def = switch (ts.get(name).?) {
        .enum_ => |e| e,
        else => return .null,
    };
    var arr = std.json.Array.init(allocator);
    for (enum_def.values) |value_name| {
        var obj: std.json.ObjectMap = .empty;
        for (selection_set) |f| {
            if (std.mem.eql(u8, f.name, "name")) {
                try obj.put(allocator, f.responseKey(), .{ .string = value_name });
            } else if (std.mem.eql(u8, f.name, "description")) {
                try obj.put(allocator, f.responseKey(), .null);
            } else if (std.mem.eql(u8, f.name, "isDeprecated")) {
                try obj.put(allocator, f.responseKey(), .{ .bool = false });
            } else if (std.mem.eql(u8, f.name, "deprecationReason")) {
                try obj.put(allocator, f.responseKey(), .null);
            }
        }
        try arr.append(.{ .object = obj });
    }
    return .{ .array = arr };
}

/// Emits the three directives every GraphQL schema must report
/// (`skip`/`include`/`deprecated`) -- their `args`/`locations` are answered
/// with empty placeholders rather than full fidelity, a deliberate scope cut
/// since no client validates a connector's own directive introspection this
/// closely to load a schema.
fn resolveDirectives(allocator: std.mem.Allocator, selection_set: []const ast.Field) Error!std.json.Value {
    var arr = std.json.Array.init(allocator);
    const directive_names = [_][]const u8{ "skip", "include", "deprecated" };
    for (directive_names) |directive_name| {
        var obj: std.json.ObjectMap = .empty;
        for (selection_set) |f| {
            if (std.mem.eql(u8, f.name, "name")) {
                try obj.put(allocator, f.responseKey(), .{ .string = directive_name });
            } else if (std.mem.eql(u8, f.name, "description")) {
                try obj.put(allocator, f.responseKey(), .null);
            } else if (std.mem.eql(u8, f.name, "locations")) {
                try obj.put(allocator, f.responseKey(), .{ .array = std.json.Array.init(allocator) });
            } else if (std.mem.eql(u8, f.name, "args")) {
                try obj.put(allocator, f.responseKey(), .{ .array = std.json.Array.init(allocator) });
            } else if (std.mem.eql(u8, f.name, "isRepeatable")) {
                try obj.put(allocator, f.responseKey(), .{ .bool = false });
            }
        }
        try arr.append(.{ .object = obj });
    }
    return .{ .array = arr };
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

fn parseAndResolve(allocator: std.mem.Allocator, src: []const u8) ![]const ast.Field {
    const document = try graphql_parser.parse(allocator, src);
    const resolved = try graphql_parser.resolveOperation(allocator, &document, null, null);
    return resolved.root_fields;
}

test "executes __schema { queryType { name } }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try type_system.build(allocator, &schema_model);

    const root_fields = try parseAndResolve(allocator, "{ __schema { queryType { name } mutationType { name } } }");
    const result = try execute(allocator, &ts, root_fields);

    const schema_obj = result.object.get("__schema").?.object;
    try std.testing.expectEqualStrings("query_root", schema_obj.get("queryType").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("mutation_root", schema_obj.get("mutationType").?.object.get("name").?.string);
}

test "executes __type(name: ...) for a scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try type_system.build(allocator, &schema_model);

    const root_fields = try parseAndResolve(allocator, "{ __type(name: \"String\") { kind name } }");
    const result = try execute(allocator, &ts, root_fields);

    const type_obj = result.object.get("__type").?.object;
    try std.testing.expectEqualStrings("SCALAR", type_obj.get("kind").?.string);
    try std.testing.expectEqualStrings("String", type_obj.get("name").?.string);
}

test "__type for a nonexistent type returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try type_system.build(allocator, &schema_model);

    const root_fields = try parseAndResolve(allocator, "{ __type(name: \"Nonexistent\") { kind } }");
    const result = try execute(allocator, &ts, root_fields);

    try std.testing.expect(result.object.get("__type").? == .null);
}

test "resolves arbitrarily nested ofType for a NON_NULL LIST NON_NULL wrapped type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try type_system.build(allocator, &schema_model);

    // query_root.artist is [artist!]! -- NON_NULL(LIST(NON_NULL(NAMED artist))).
    const root_fields = try parseAndResolve(allocator,
        \\{ __type(name: "query_root") { fields { name type { kind ofType { kind ofType { kind name } } } } } }
    );
    const result = try execute(allocator, &ts, root_fields);

    const fields = result.object.get("__type").?.object.get("fields").?.array;
    var artist_field: ?std.json.Value = null;
    for (fields.items) |f| {
        if (std.mem.eql(u8, f.object.get("name").?.string, "artist")) artist_field = f;
    }
    const artist_type = artist_field.?.object.get("type").?.object;
    try std.testing.expectEqualStrings("NON_NULL", artist_type.get("kind").?.string);
    const list_type = artist_type.get("ofType").?.object;
    try std.testing.expectEqualStrings("LIST", list_type.get("kind").?.string);
    const inner_non_null = list_type.get("ofType").?.object;
    try std.testing.expectEqualStrings("NON_NULL", inner_non_null.get("kind").?.string);
}

test "executes the standard introspection query's fragment-heavy shape without error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try type_system.build(allocator, &schema_model);

    const root_fields = try parseAndResolve(allocator,
        \\query IntrospectionQuery {
        \\  __schema {
        \\    queryType { name }
        \\    mutationType { name }
        \\    types { ...FullType }
        \\    directives { name locations args { ...InputValue } }
        \\  }
        \\}
        \\fragment FullType on __Type {
        \\  kind
        \\  name
        \\  fields(includeDeprecated: true) {
        \\    name
        \\    args { ...InputValue }
        \\    type { ...TypeRef }
        \\    isDeprecated
        \\    deprecationReason
        \\  }
        \\  inputFields { ...InputValue }
        \\  interfaces { ...TypeRef }
        \\  enumValues(includeDeprecated: true) { name isDeprecated deprecationReason }
        \\  possibleTypes { ...TypeRef }
        \\}
        \\fragment InputValue on __InputValue {
        \\  name
        \\  type { ...TypeRef }
        \\  defaultValue
        \\}
        \\fragment TypeRef on __Type {
        \\  kind
        \\  name
        \\  ofType {
        \\    kind
        \\    name
        \\    ofType {
        \\      kind
        \\      name
        \\      ofType {
        \\        kind
        \\        name
        \\        ofType {
        \\          kind
        \\          name
        \\          ofType {
        \\            kind
        \\            name
        \\            ofType {
        \\              kind
        \\              name
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    );
    const result = try execute(allocator, &ts, root_fields);
    try std.testing.expect(result.object.get("__schema").?.object.get("types").?.array.items.len > 0);
}
