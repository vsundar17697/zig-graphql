const std = @import("std");
const ast = @import("ast.zig");

pub const Error = std.mem.Allocator.Error || error{
    UnknownOperation,
    AmbiguousOperation,
    UnknownFragment,
    FragmentCycle,
    MissingDirectiveArgument,
    InvalidDirectiveArgumentType,
};

pub const ResolvedOperation = struct {
    operation_type: ast.OperationType,
    root_fields: []const ast.Field,
};

/// Selects one operation from `document` (by `operation_name`, or the sole
/// operation if there's exactly one and no name was given -- the
/// graphql-over-HTTP operation-selection rule), then resolves its selection
/// tree into a flat, fragment-free, directive-free `ast.Field` tree:
/// fragment spreads are expanded in place (with cycle detection),
/// `@skip`/`@include` are evaluated against `variables` and stripped, and
/// every `$variable` reference in an argument value is substituted with its
/// concrete value (from `variables`, falling back to the variable
/// definition's default, falling back to `null`). This is what makes
/// `graphql_parser/to_ir.zig` need no awareness of fragments, directives, or
/// variables at all -- see docs/decisions/0014-graphql-post-endpoint.md.
pub fn resolveOperation(
    allocator: std.mem.Allocator,
    document: *const ast.Document,
    operation_name: ?[]const u8,
    variables: ?std.json.Value,
) Error!ResolvedOperation {
    const operation = try selectOperation(document, operation_name);

    var resolver = Resolver{
        .allocator = allocator,
        .document = document,
        .variables = variables,
        .variable_definitions = operation.variable_definitions,
    };

    const root_fields = try resolver.resolveSelectionSet(operation.selection_set, &.{});
    return .{ .operation_type = operation.operation_type, .root_fields = root_fields };
}

fn selectOperation(document: *const ast.Document, operation_name: ?[]const u8) Error!*const ast.Operation {
    if (operation_name) |name| {
        for (document.operations) |*op| {
            if (op.name != null and std.mem.eql(u8, op.name.?, name)) return op;
        }
        return Error.UnknownOperation;
    }
    if (document.operations.len != 1) return Error.AmbiguousOperation;
    return &document.operations[0];
}

const Resolver = struct {
    allocator: std.mem.Allocator,
    document: *const ast.Document,
    variables: ?std.json.Value,
    variable_definitions: []const ast.VariableDefinition,

    /// `visiting` tracks fragment names being expanded on the current path,
    /// for cycle detection -- without it a self-referential fragment would
    /// recurse until stack overflow rather than a clean error.
    fn resolveSelectionSet(self: *Resolver, selections: []const ast.Selection, visiting: []const []const u8) Error![]const ast.Field {
        var fields: std.ArrayListUnmanaged(ast.Field) = .empty;
        for (selections) |selection| {
            switch (selection) {
                .field => |raw| {
                    if (!try self.directivesAllow(raw.directives)) continue;
                    try fields.append(self.allocator, try self.resolveField(raw, visiting));
                },
                .fragment_spread => |spread| {
                    if (!try self.directivesAllow(spread.directives)) continue;
                    for (visiting) |name| {
                        if (std.mem.eql(u8, name, spread.name)) return Error.FragmentCycle;
                    }
                    const fragment = self.findFragment(spread.name) orelse return Error.UnknownFragment;

                    const next_visiting = try self.allocator.alloc([]const u8, visiting.len + 1);
                    @memcpy(next_visiting[0..visiting.len], visiting);
                    next_visiting[visiting.len] = spread.name;

                    const expanded = try self.resolveSelectionSet(fragment.selection_set, next_visiting);
                    try fields.appendSlice(self.allocator, expanded);
                },
            }
        }
        return fields.toOwnedSlice(self.allocator);
    }

    fn resolveField(self: *Resolver, raw: ast.RawField, visiting: []const []const u8) Error!ast.Field {
        return .{
            .alias = raw.alias,
            .name = raw.name,
            .arguments = try self.resolveArguments(raw.arguments),
            .selection_set = try self.resolveSelectionSet(raw.selection_set, visiting),
        };
    }

    fn resolveArguments(self: *Resolver, arguments: []const ast.Argument) Error![]const ast.Argument {
        const out = try self.allocator.alloc(ast.Argument, arguments.len);
        for (arguments, out) |arg, *dst| dst.* = .{ .name = arg.name, .value = try self.resolveValue(arg.value) };
        return out;
    }

    fn resolveValue(self: *Resolver, value: ast.Value) Error!ast.Value {
        return switch (value) {
            .variable => |name| try self.resolveVariable(name),
            .list => |items| blk: {
                const out = try self.allocator.alloc(ast.Value, items.len);
                for (items, out) |item, *dst| dst.* = try self.resolveValue(item);
                break :blk .{ .list = out };
            },
            .object => |object_fields| blk: {
                const out = try self.allocator.alloc(ast.ObjectField, object_fields.len);
                for (object_fields, out) |f, *dst| dst.* = .{ .name = f.name, .value = try self.resolveValue(f.value) };
                break :blk .{ .object = out };
            },
            else => value,
        };
    }

    fn resolveVariable(self: *Resolver, name: []const u8) Error!ast.Value {
        if (self.variables) |vars_value| {
            if (vars_value == .object) {
                if (vars_value.object.get(name)) |json_value| {
                    return jsonValueToAstValue(self.allocator, json_value);
                }
            }
        }
        for (self.variable_definitions) |def| {
            if (std.mem.eql(u8, def.name, name)) {
                return def.default_value orelse .null_;
            }
        }
        return .null_;
    }

    /// `false` means "skip this selection entirely." Unknown directives are
    /// ignored (permissive) -- this engine has no directive registry to
    /// validate against yet.
    fn directivesAllow(self: *Resolver, directives: []const ast.Directive) Error!bool {
        for (directives) |d| {
            if (std.mem.eql(u8, d.name, "skip")) {
                if (try self.directiveIfArg(d)) return false;
            } else if (std.mem.eql(u8, d.name, "include")) {
                if (!try self.directiveIfArg(d)) return false;
            }
        }
        return true;
    }

    fn directiveIfArg(self: *Resolver, directive: ast.Directive) Error!bool {
        for (directive.arguments) |arg| {
            if (std.mem.eql(u8, arg.name, "if")) {
                return switch (try self.resolveValue(arg.value)) {
                    .boolean => |b| b,
                    else => Error.InvalidDirectiveArgumentType,
                };
            }
        }
        return Error.MissingDirectiveArgument;
    }

    fn findFragment(self: *Resolver, name: []const u8) ?*const ast.FragmentDefinition {
        for (self.document.fragments) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

fn jsonValueToAstValue(allocator: std.mem.Allocator, value: std.json.Value) Error!ast.Value {
    return switch (value) {
        .null => .null_,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string, .string => |s| .{ .string = s },
        .array => |arr| blk: {
            const out = try allocator.alloc(ast.Value, arr.items.len);
            for (arr.items, out) |item, *dst| dst.* = try jsonValueToAstValue(allocator, item);
            break :blk .{ .list = out };
        },
        .object => |obj| blk: {
            const out = try allocator.alloc(ast.ObjectField, obj.count());
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                out[i] = .{ .name = entry.key_ptr.*, .value = try jsonValueToAstValue(allocator, entry.value_ptr.*) };
            }
            break :blk .{ .object = out };
        },
    };
}

const parser = @import("parser.zig");

test "resolves a simple document with no fragments/directives/variables unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "{ album { AlbumId Title } }");
    const resolved = try resolveOperation(allocator, &doc, null, null);

    try std.testing.expectEqual(ast.OperationType.query, resolved.operation_type);
    try std.testing.expectEqual(@as(usize, 1), resolved.root_fields.len);
    try std.testing.expectEqualStrings("album", resolved.root_fields[0].name);
    try std.testing.expectEqual(@as(usize, 2), resolved.root_fields[0].selection_set.len);
}

test "expands a fragment spread in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator,
        \\{ album { ...AlbumFields AlbumId } }
        \\fragment AlbumFields on Album { Title }
    );
    const resolved = try resolveOperation(allocator, &doc, null, null);

    const album = resolved.root_fields[0];
    try std.testing.expectEqual(@as(usize, 2), album.selection_set.len);
    try std.testing.expectEqualStrings("Title", album.selection_set[0].name);
    try std.testing.expectEqualStrings("AlbumId", album.selection_set[1].name);
}

test "detects a fragment cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator,
        \\{ album { ...A } }
        \\fragment A on Album { ...B }
        \\fragment B on Album { ...A }
    );
    try std.testing.expectError(Error.FragmentCycle, resolveOperation(allocator, &doc, null, null));
}

test "an unknown fragment spread is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "{ album { ...Nonexistent } }");
    try std.testing.expectError(Error.UnknownFragment, resolveOperation(allocator, &doc, null, null));
}

test "@skip(if: true) removes the field, @skip(if: false) keeps it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "{ album { Title @skip(if: true) AlbumId @skip(if: false) } }");
    const resolved = try resolveOperation(allocator, &doc, null, null);

    try std.testing.expectEqual(@as(usize, 1), resolved.root_fields[0].selection_set.len);
    try std.testing.expectEqualStrings("AlbumId", resolved.root_fields[0].selection_set[0].name);
}

test "@include(if: $var) resolves against a supplied variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "query($wantTitle: Boolean!) { album { Title @include(if: $wantTitle) AlbumId } }");

    var vars_obj: std.json.ObjectMap = .empty;
    try vars_obj.put(allocator, "wantTitle", .{ .bool = false });
    const resolved = try resolveOperation(allocator, &doc, null, .{ .object = vars_obj });

    try std.testing.expectEqual(@as(usize, 1), resolved.root_fields[0].selection_set.len);
    try std.testing.expectEqualStrings("AlbumId", resolved.root_fields[0].selection_set[0].name);
}

test "substitutes a $variable argument value from the variables object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "query($limit: Int!) { album(limit: $limit) { Title } }");

    var vars_obj: std.json.ObjectMap = .empty;
    try vars_obj.put(allocator, "limit", .{ .integer = 5 });
    const resolved = try resolveOperation(allocator, &doc, null, .{ .object = vars_obj });

    try std.testing.expectEqual(@as(i64, 5), resolved.root_fields[0].arguments[0].value.int);
}

test "falls back to a variable's default value when variables omits it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "query($limit: Int = 10) { album(limit: $limit) { Title } }");
    const resolved = try resolveOperation(allocator, &doc, null, null);

    try std.testing.expectEqual(@as(i64, 10), resolved.root_fields[0].arguments[0].value.int);
}

test "selects a named operation out of a multi-operation document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator,
        \\query GetAlbums { album { Title } }
        \\query GetArtists { artist { Name } }
    );
    const resolved = try resolveOperation(allocator, &doc, "GetArtists", null);

    try std.testing.expectEqualStrings("artist", resolved.root_fields[0].name);
}

test "no operation name with multiple operations is ambiguous" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator,
        \\query GetAlbums { album { Title } }
        \\query GetArtists { artist { Name } }
    );
    try std.testing.expectError(Error.AmbiguousOperation, resolveOperation(allocator, &doc, null, null));
}

test "an unknown operation name is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "query GetAlbums { album { Title } }");
    try std.testing.expectError(Error.UnknownOperation, resolveOperation(allocator, &doc, "Nonexistent", null));
}
