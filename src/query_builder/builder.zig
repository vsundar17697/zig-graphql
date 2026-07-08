const std = @import("std");
const ndc_ir = @import("ndc_ir");

/// Milestone 1 skips compile-time schema codegen (see
/// docs/decisions/0004-schema-reconciliation-runtime-validation.md) -- column
/// and collection names are plain strings, checked at runtime by `validate`,
/// not verified at compile time against a generated schema type. What *is*
/// compile-time-checked here is the comparison value's type (`toJsonValue`
/// rejects unsupported types with a `@compileError` at the call site).
pub const Column = struct {
    name: []const u8,

    pub fn eq(self: Column, value: anytype) ndc_ir.Expression {
        return self.compare(.eq, value);
    }
    pub fn neq(self: Column, value: anytype) ndc_ir.Expression {
        return self.compare(.neq, value);
    }
    pub fn gt(self: Column, value: anytype) ndc_ir.Expression {
        return self.compare(.gt, value);
    }
    pub fn gte(self: Column, value: anytype) ndc_ir.Expression {
        return self.compare(.gte, value);
    }
    pub fn lt(self: Column, value: anytype) ndc_ir.Expression {
        return self.compare(.lt, value);
    }
    pub fn lte(self: Column, value: anytype) ndc_ir.Expression {
        return self.compare(.lte, value);
    }

    /// Compares against a named query variable (resolved at execution time via
    /// `executor.runWithVariables`, not at build time) rather than a literal --
    /// see docs/decisions/0009-query-variables.md. Only `eq`/`neq`/`gt`/`gte`/
    /// `lt`/`lte` support variables; `_in` with a variable is unsupported.
    pub fn eqVar(self: Column, variable_name: []const u8) ndc_ir.Expression {
        return self.compareVar(.eq, variable_name);
    }
    pub fn neqVar(self: Column, variable_name: []const u8) ndc_ir.Expression {
        return self.compareVar(.neq, variable_name);
    }
    pub fn gtVar(self: Column, variable_name: []const u8) ndc_ir.Expression {
        return self.compareVar(.gt, variable_name);
    }
    pub fn gteVar(self: Column, variable_name: []const u8) ndc_ir.Expression {
        return self.compareVar(.gte, variable_name);
    }
    pub fn ltVar(self: Column, variable_name: []const u8) ndc_ir.Expression {
        return self.compareVar(.lt, variable_name);
    }
    pub fn lteVar(self: Column, variable_name: []const u8) ndc_ir.Expression {
        return self.compareVar(.lte, variable_name);
    }

    pub fn isNull(self: Column) ndc_ir.Expression {
        return .{ .unary_op = .{ .column = .{ .name = self.name }, .operator = .is_null } };
    }

    pub fn isNotNull(self: Column, allocator: std.mem.Allocator) !ndc_ir.Expression {
        const boxed = try allocator.create(ndc_ir.Expression);
        boxed.* = self.isNull();
        return .{ .not_ = boxed };
    }

    pub fn asc(self: Column) ndc_ir.OrderByElement {
        return .{ .target = .{ .name = self.name }, .direction = .asc };
    }
    pub fn desc(self: Column) ndc_ir.OrderByElement {
        return .{ .target = .{ .name = self.name }, .direction = .desc };
    }

    fn compare(self: Column, op: ndc_ir.BinaryOperator, value: anytype) ndc_ir.Expression {
        return .{ .binary_op = .{
            .column = .{ .name = self.name },
            .operator = op,
            .value = .{ .scalar = toJsonValue(value) },
        } };
    }

    fn compareVar(self: Column, op: ndc_ir.BinaryOperator, variable_name: []const u8) ndc_ir.Expression {
        return .{ .binary_op = .{
            .column = .{ .name = self.name },
            .operator = op,
            .value = .{ .variable = variable_name },
        } };
    }
};

pub fn column(comptime name: []const u8) Column {
    return .{ .name = name };
}

fn boxPredicate(allocator: std.mem.Allocator, predicate: ?ndc_ir.Expression) !?*ndc_ir.Expression {
    const p = predicate orelse return null;
    const boxed = try allocator.create(ndc_ir.Expression);
    boxed.* = p;
    return boxed;
}

/// Builds an `exists(related: ...)` expression -- "at least one row exists via
/// this relationship" (optionally further filtered by `predicate`, evaluated
/// against the relationship's target collection). The caller must also
/// register the relationship on the Builder (`Builder.registerRelationship`)
/// so `sql_gen` can resolve it -- see docs/decisions/0007.
pub fn exists(allocator: std.mem.Allocator, relationship_name: []const u8, predicate: ?ndc_ir.Expression) !ndc_ir.Expression {
    return .{ .exists = .{
        .in_collection = .{ .related = .{ .relationship = relationship_name } },
        .predicate = try boxPredicate(allocator, predicate),
    } };
}

/// Builds an `exists(unrelated: ...)` expression against an arbitrary
/// collection with no join -- no relationship registration needed.
pub fn existsUnrelated(allocator: std.mem.Allocator, collection: []const u8, predicate: ?ndc_ir.Expression) !ndc_ir.Expression {
    return .{ .exists = .{
        .in_collection = .{ .unrelated = .{ .collection = collection } },
        .predicate = try boxPredicate(allocator, predicate),
    } };
}

fn toJsonValue(value: anytype) std.json.Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .comptime_int, .int => .{ .integer = @intCast(value) },
        .comptime_float, .float => .{ .float = value },
        .bool => .{ .bool = value },
        .pointer => .{ .string = value },
        else => @compileError("query_builder: unsupported comparison value type " ++ @typeName(T)),
    };
}

/// Constructs an ndc_ir.Query directly -- no text parsing at all. Must produce
/// structurally equivalent Query values to graphql_parser for an equivalent
/// query (see root.zig's test comparing both producers' sql_gen output).
pub const Builder = struct {
    allocator: std.mem.Allocator,
    query: ndc_ir.Query,

    pub fn init(allocator: std.mem.Allocator, collection: []const u8) Builder {
        return .{ .allocator = allocator, .query = .{ .collection = collection } };
    }

    pub fn select(self: *Builder, column_name: []const u8) !void {
        try self.query.fields.put(self.allocator, column_name, .{ .column = .{ .column = column_name } });
    }

    /// `relationship_info` is the schema's Relationship value (e.g. from
    /// `schema_model.relationships.get(collection).?.get(relationship_name)`)
    /// -- the builder doesn't look anything up itself, keeping it schema-model-
    /// shape-agnostic; `validate` is what checks the reference is real.
    pub fn selectRelationship(
        self: *Builder,
        field_name: []const u8,
        relationship_name: []const u8,
        nested_query: ndc_ir.Query,
        relationship_info: ndc_ir.Relationship,
    ) !void {
        const nested = try self.allocator.create(ndc_ir.Query);
        nested.* = nested_query;
        try self.query.fields.put(self.allocator, field_name, .{ .relationship = .{
            .relationship = relationship_name,
            .query = nested,
        } });
        try self.query.relationships.put(self.allocator, relationship_name, relationship_info);
    }

    pub fn where(self: *Builder, expr: ndc_ir.Expression) void {
        self.query.predicate = expr;
    }

    /// Registers a relationship referenced only in `where` (via `exists`), with
    /// no corresponding selected field -- `selectRelationship` registers as a
    /// side effect of selecting a field, but an `exists`-only reference needs
    /// this explicit call instead.
    pub fn registerRelationship(self: *Builder, name: []const u8, info: ndc_ir.Relationship) !void {
        try self.query.relationships.put(self.allocator, name, info);
    }

    pub fn orderBy(self: *Builder, elements: []const ndc_ir.OrderByElement) !void {
        self.query.order_by = try self.allocator.dupe(ndc_ir.OrderByElement, elements);
    }

    /// Adds one entry to `query.aggregates`, keyed by `alias` (the response
    /// key) -- e.g. `builder.aggregate("count", .star_count)` or
    /// `builder.aggregate("max_id", .{.single_column = .{.column = "AlbumId", .function = .max}})`.
    pub fn aggregate(self: *Builder, alias: []const u8, agg: ndc_ir.Aggregate) !void {
        try self.query.aggregates.put(self.allocator, alias, agg);
    }

    pub fn limit(self: *Builder, n: u32) void {
        self.query.limit = n;
    }

    pub fn offset(self: *Builder, n: u32) void {
        self.query.offset = n;
    }

    pub fn build(self: *const Builder) ndc_ir.Query {
        return self.query;
    }
};

/// Builds one field of a JSON object argument (`object`/`_set`/`pk_columns`,
/// see docs/decisions/0010-mutation-procedure-naming.md) from a comptime
/// struct literal, e.g. `.{ .title = "X", .artist_id = 1 }` -- reuses
/// `toJsonValue`'s scalar conversion (and its `@compileError` on unsupported
/// types), so it has the same type support as `Column.eq`.
fn jsonObjectFromStruct(allocator: std.mem.Allocator, obj: anytype) !std.json.Value {
    var map: std.json.ObjectMap = .empty;
    const info = @typeInfo(@TypeOf(obj)).@"struct";
    inline for (info.fields) |field| {
        try map.put(allocator, field.name, toJsonValue(@field(obj, field.name)));
    }
    return .{ .object = map };
}

/// Builds `ndc_ir.MutationOperation` values matching the auto-derived
/// procedure convention (`insert_<t>(object:...)`,
/// `update_<t>_by_pk(pk_columns:..., _set:...)`,
/// `delete_<t>_by_pk(pk_columns:...)` -- see
/// docs/decisions/0010-mutation-procedure-naming.md). Like `Builder`, this
/// does no schema lookups itself -- procedure-name resolution happens later,
/// in `sql_gen` via `schema.resolveProcedure`.
pub const MutationBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MutationBuilder {
        return .{ .allocator = allocator };
    }

    /// `object` is a comptime struct literal, e.g. `.{ .title = "X", .artist_id = 1 }`.
    pub fn insert(self: MutationBuilder, collection: []const u8, object: anytype) !ndc_ir.MutationOperation {
        var arguments: ndc_ir.ArgumentMap = .{};
        try arguments.put(self.allocator, "object", try jsonObjectFromStruct(self.allocator, object));
        return .{
            .name = try std.fmt.allocPrint(self.allocator, "insert_{s}", .{collection}),
            .arguments = arguments,
        };
    }

    /// `pk_columns` and `set` are comptime struct literals, e.g.
    /// `.{ .album_id = 1 }` and `.{ .title = "Renamed" }`.
    pub fn updateByPk(self: MutationBuilder, collection: []const u8, pk_columns: anytype, set: anytype) !ndc_ir.MutationOperation {
        var arguments: ndc_ir.ArgumentMap = .{};
        try arguments.put(self.allocator, "pk_columns", try jsonObjectFromStruct(self.allocator, pk_columns));
        try arguments.put(self.allocator, "_set", try jsonObjectFromStruct(self.allocator, set));
        return .{
            .name = try std.fmt.allocPrint(self.allocator, "update_{s}_by_pk", .{collection}),
            .arguments = arguments,
        };
    }

    /// `pk_columns` is a comptime struct literal, e.g. `.{ .album_id = 1 }`.
    pub fn deleteByPk(self: MutationBuilder, collection: []const u8, pk_columns: anytype) !ndc_ir.MutationOperation {
        var arguments: ndc_ir.ArgumentMap = .{};
        try arguments.put(self.allocator, "pk_columns", try jsonObjectFromStruct(self.allocator, pk_columns));
        return .{
            .name = try std.fmt.allocPrint(self.allocator, "delete_{s}_by_pk", .{collection}),
            .arguments = arguments,
        };
    }

    /// Adds a RETURNING selection to an already-built operation -- separate
    /// from `insert`/`updateByPk`/`deleteByPk` since not every mutation wants
    /// one (a `null` `fields` means "only affected_rows", see
    /// docs/decisions/0010-mutation-procedure-naming.md).
    pub fn returning(self: MutationBuilder, operation: *ndc_ir.MutationOperation, columns: []const []const u8) !void {
        var fields: ndc_ir.FieldSelection = .{};
        for (columns) |c| {
            try fields.put(self.allocator, c, .{ .column = .{ .column = c } });
        }
        operation.fields = fields;
    }
};

test "Column comparison helpers build the expected Expression shape" {
    const title = column("Title");
    const expr = title.eq("Foo");
    try std.testing.expectEqual(ndc_ir.BinaryOperator.eq, expr.binary_op.operator);
    try std.testing.expectEqualStrings("Title", expr.binary_op.column.name);
    try std.testing.expectEqualStrings("Foo", expr.binary_op.value.scalar.string);
}

test "Column.eqVar builds a variable-referencing Expression" {
    const artist_id = column("artist_id");
    const expr = artist_id.eqVar("target_artist_id");
    try std.testing.expectEqual(ndc_ir.BinaryOperator.eq, expr.binary_op.operator);
    try std.testing.expectEqualStrings("target_artist_id", expr.binary_op.value.variable);
}

test "Column.isNull and isNotNull" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const title = column("Title");
    try std.testing.expectEqual(ndc_ir.UnaryOperator.is_null, title.isNull().unary_op.operator);

    const not_null = try title.isNotNull(arena.allocator());
    try std.testing.expectEqual(ndc_ir.UnaryOperator.is_null, not_null.not_.unary_op.operator);
}

test "exists() builds a related-existence Expression with a boxed predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expr = try exists(allocator, "artist", column("Name").eq("AC/DC"));
    try std.testing.expectEqualStrings("artist", expr.exists.in_collection.related.relationship);
    try std.testing.expectEqualStrings("AC/DC", expr.exists.predicate.?.binary_op.value.scalar.string);
}

test "existsUnrelated() builds an unrelated-existence Expression with no predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expr = try existsUnrelated(allocator, "promotion", null);
    try std.testing.expectEqualStrings("promotion", expr.exists.in_collection.unrelated.collection);
    try std.testing.expect(expr.exists.predicate == null);
}

test "Builder constructs a Query with where/orderBy/limit/offset" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var builder = Builder.init(a, "album");
    try builder.select("AlbumId");
    try builder.select("Title");
    builder.where(column("ArtistId").eq(1));
    try builder.orderBy(&.{column("Title").asc()});
    builder.limit(10);
    builder.offset(5);

    const query = builder.build();
    try std.testing.expectEqualStrings("album", query.collection);
    try std.testing.expectEqual(@as(usize, 2), query.fields.count());
    try std.testing.expectEqual(@as(?u32, 10), query.limit);
    try std.testing.expectEqual(@as(?u32, 5), query.offset);
}

test "Builder.aggregate registers an aggregate keyed by alias" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var builder = Builder.init(a, "album");
    try builder.aggregate("count", .star_count);
    try builder.aggregate("max_id", .{ .single_column = .{ .column = "AlbumId", .function = .max } });

    const query = builder.build();
    try std.testing.expectEqual(@as(usize, 2), query.aggregates.count());
    try std.testing.expectEqual(ndc_ir.Aggregate.star_count, query.aggregates.get("count").?);
    try std.testing.expectEqualStrings("AlbumId", query.aggregates.get("max_id").?.single_column.column);
}

test "MutationBuilder.insert builds an insert_<t>(object:...) operation" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mutations = MutationBuilder.init(a);
    const op = try mutations.insert("album", .{ .title = "Highway to Hell", .artist_id = 1 });

    try std.testing.expectEqualStrings("insert_album", op.name);
    const object = op.arguments.get("object").?.object;
    try std.testing.expectEqualStrings("Highway to Hell", object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 1), object.get("artist_id").?.integer);
    try std.testing.expect(op.fields == null);
}

test "MutationBuilder.updateByPk builds pk_columns and _set arguments" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mutations = MutationBuilder.init(a);
    const op = try mutations.updateByPk("album", .{ .album_id = 1 }, .{ .title = "Renamed" });

    try std.testing.expectEqualStrings("update_album_by_pk", op.name);
    try std.testing.expectEqual(@as(i64, 1), op.arguments.get("pk_columns").?.object.get("album_id").?.integer);
    try std.testing.expectEqualStrings("Renamed", op.arguments.get("_set").?.object.get("title").?.string);
}

test "MutationBuilder.deleteByPk builds a pk_columns-only argument" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mutations = MutationBuilder.init(a);
    const op = try mutations.deleteByPk("album", .{ .album_id = 1 });

    try std.testing.expectEqualStrings("delete_album_by_pk", op.name);
    try std.testing.expectEqual(@as(i64, 1), op.arguments.get("pk_columns").?.object.get("album_id").?.integer);
    try std.testing.expect(op.arguments.get("_set") == null);
}

test "MutationBuilder.returning adds a column-only field selection to an operation" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mutations = MutationBuilder.init(a);
    var op = try mutations.insert("album", .{ .title = "X" });
    try mutations.returning(&op, &.{ "album_id", "title" });

    try std.testing.expect(op.fields != null);
    try std.testing.expectEqual(@as(usize, 2), op.fields.?.count());
    try std.testing.expectEqualStrings("album_id", op.fields.?.get("album_id").?.column.column);
}
