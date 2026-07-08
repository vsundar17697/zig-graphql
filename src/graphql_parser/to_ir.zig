const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");
const ast = @import("ast.zig");
const request = @import("request.zig");

pub const Error = request.Error || error{
    UnknownCollection,
    UnknownRelationship,
    UnknownOperator,
    UnknownAggregateField,
    InvalidOrderDirection,
    InvalidArgumentType,
    UnsupportedComparisonValue,
    NotAQueryDocument,
    NotAMutationDocument,
    UnsupportedReturningField,
    ExpectedSingleRootField,
};

fn expectInt(value: ast.Value) Error!i64 {
    return switch (value) {
        .int => |i| i,
        else => Error.InvalidArgumentType,
    };
}

fn expectObject(value: ast.Value) Error![]const ast.ObjectField {
    return switch (value) {
        .object => |o| o,
        else => Error.InvalidArgumentType,
    };
}

fn expectList(value: ast.Value) Error![]const ast.Value {
    return switch (value) {
        .list => |l| l,
        else => Error.InvalidArgumentType,
    };
}

fn expectBool(value: ast.Value) Error!bool {
    return switch (value) {
        .boolean => |b| b,
        else => Error.InvalidArgumentType,
    };
}

fn toJsonValue(allocator: std.mem.Allocator, value: ast.Value) Error!std.json.Value {
    return switch (value) {
        .int => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = s },
        .boolean => |b| .{ .bool = b },
        .null_ => .null,
        .enum_ => |e| .{ .string = e },
        .list => |items| blk: {
            var arr = std.json.Array.init(allocator);
            for (items) |item| try arr.append(try toJsonValue(allocator, item));
            break :blk .{ .array = arr };
        },
        .object => Error.UnsupportedComparisonValue,
        // request.zig's resolution pass substitutes every `.variable`
        // reference with a concrete value before to_ir.zig ever sees an
        // ast.Field -- see `lower`/`lowerMutation`, which always resolve
        // first. Reaching here would mean that invariant broke.
        .variable => unreachable,
    };
}

fn lowerComparison(allocator: std.mem.Allocator, column: []const u8, op_field: ast.ObjectField) Error!ndc_ir.Expression {
    const target = ndc_ir.ComparisonTarget{ .name = column };

    if (std.mem.eql(u8, op_field.name, "_is_null")) {
        const want_null = try expectBool(op_field.value);
        const base = ndc_ir.Expression{ .unary_op = .{ .column = target, .operator = .is_null } };
        if (want_null) return base;
        const boxed = try allocator.create(ndc_ir.Expression);
        boxed.* = base;
        return .{ .not_ = boxed };
    }

    const op = ndc_ir.binaryOperatorFromName(op_field.name) orelse return Error.UnknownOperator;
    const scalar = try toJsonValue(allocator, op_field.value);
    return .{ .binary_op = .{ .column = target, .operator = op, .value = .{ .scalar = scalar } } };
}

/// Lowers a `where`-shaped GraphQL object (`{Col: {_op: val}, _and: [...], ...}`)
/// into a single Expression, ANDing together every clause the object contains
/// (multiple operators on one column, or multiple columns, all combine with AND).
///
/// `collection` is whatever collection the fields in `fields` are relative to
/// -- the query's own collection at the top level, or a relationship's target
/// collection once recursing into a relationship-keyed clause (`{albums: {...}}`).
/// `query` accumulates every relationship referenced anywhere in the tree
/// (selections and now filters) into `query.relationships`, mirroring NDC's
/// wire-level `collection_relationships` (see docs/decisions/0007).
fn lowerWhereObject(allocator: std.mem.Allocator, query: *ndc_ir.Query, schema_model: *const schema.SchemaModel, collection: []const u8, fields: []const ast.ObjectField) Error!ndc_ir.Expression {
    var clauses: std.ArrayListUnmanaged(ndc_ir.Expression) = .empty;

    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "_and")) {
            const list = try expectList(field.value);
            const exprs = try allocator.alloc(ndc_ir.Expression, list.len);
            for (list, exprs) |item, *out| out.* = try lowerWhereObject(allocator, query, schema_model, collection, try expectObject(item));
            try clauses.append(allocator, .{ .and_ = exprs });
        } else if (std.mem.eql(u8, field.name, "_or")) {
            const list = try expectList(field.value);
            const exprs = try allocator.alloc(ndc_ir.Expression, list.len);
            for (list, exprs) |item, *out| out.* = try lowerWhereObject(allocator, query, schema_model, collection, try expectObject(item));
            try clauses.append(allocator, .{ .or_ = exprs });
        } else if (std.mem.eql(u8, field.name, "_not")) {
            const boxed = try allocator.create(ndc_ir.Expression);
            boxed.* = try lowerWhereObject(allocator, query, schema_model, collection, try expectObject(field.value));
            try clauses.append(allocator, .{ .not_ = boxed });
        } else if (relationshipNamed(schema_model, collection, field.name)) |rel| {
            // Relationship-keyed clause: {albums: {Title: {_eq: "X"}}} -> exists(related: "albums", ...).
            // Checked before treating `field.name` as a column -- a schema where a
            // relationship and a column share a name would resolve to the
            // relationship, a documented precedence rather than an error.
            const boxed = try allocator.create(ndc_ir.Expression);
            boxed.* = try lowerWhereObject(allocator, query, schema_model, rel.target_collection, try expectObject(field.value));
            try clauses.append(allocator, .{ .exists = .{
                .in_collection = .{ .related = .{ .relationship = field.name } },
                .predicate = boxed,
            } });
            try query.relationships.put(allocator, field.name, rel);
        } else {
            for (try expectObject(field.value)) |op_field| {
                try clauses.append(allocator, try lowerComparison(allocator, field.name, op_field));
            }
        }
    }

    if (clauses.items.len == 1) return clauses.items[0];
    return .{ .and_ = try clauses.toOwnedSlice(allocator) };
}

fn relationshipNamed(schema_model: *const schema.SchemaModel, collection: []const u8, name: []const u8) ?ndc_ir.Relationship {
    const collection_relationships = schema_model.relationships.get(collection) orelse return null;
    return collection_relationships.get(name);
}

fn lowerOrderBy(allocator: std.mem.Allocator, value: ast.Value) Error![]ndc_ir.OrderByElement {
    var elements: std.ArrayListUnmanaged(ndc_ir.OrderByElement) = .empty;
    for (try expectList(value)) |item| {
        for (try expectObject(item)) |field| {
            const direction_name = switch (field.value) {
                .enum_ => |e| e,
                else => return Error.InvalidArgumentType,
            };
            const direction: ndc_ir.OrderDirection = if (std.mem.eql(u8, direction_name, "asc"))
                .asc
            else if (std.mem.eql(u8, direction_name, "desc"))
                .desc
            else
                return Error.InvalidOrderDirection;
            try elements.append(allocator, .{ .target = .{ .name = field.name }, .direction = direction });
        }
    }
    return elements.toOwnedSlice(allocator);
}

/// Lowers one GraphQL field (and recursively, its selection set) into an
/// ndc_ir.Query rooted at `collection`. Used for both the document's root
/// field and, recursively, every relationship field's nested selection.
fn lowerField(allocator: std.mem.Allocator, field: ast.Field, collection: []const u8, schema_model: *const schema.SchemaModel) Error!ndc_ir.Query {
    if (!schema_model.collections.contains(collection)) return Error.UnknownCollection;

    var query = ndc_ir.Query{ .collection = collection };

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            query.predicate = try lowerWhereObject(allocator, &query, schema_model, collection, try expectObject(arg.value));
        } else if (std.mem.eql(u8, arg.name, "order_by")) {
            query.order_by = try lowerOrderBy(allocator, arg.value);
        } else if (std.mem.eql(u8, arg.name, "limit")) {
            query.limit = std.math.cast(u32, try expectInt(arg.value)) orelse return Error.InvalidArgumentType;
        } else if (std.mem.eql(u8, arg.name, "offset")) {
            query.offset = std.math.cast(u32, try expectInt(arg.value)) orelse return Error.InvalidArgumentType;
        }
    }

    for (field.selection_set) |sub_field| {
        // `__typename` is a synthetic GraphQL field, not a real column --
        // sql_gen never learns about it (see docs/decisions/0014-graphql-post-endpoint.md);
        // the `/graphql` envelope injects its value into the decoded JSON
        // after execution, using the same collection/relationship walk this
        // function does.
        if (std.mem.eql(u8, sub_field.name, "__typename")) continue;

        if (sub_field.selection_set.len == 0) {
            try query.fields.put(allocator, sub_field.responseKey(), .{ .column = .{ .column = sub_field.name } });
            continue;
        }

        const collection_relationships = schema_model.relationships.get(collection) orelse return Error.UnknownRelationship;
        const rel = collection_relationships.get(sub_field.name) orelse return Error.UnknownRelationship;

        const nested = try allocator.create(ndc_ir.Query);
        nested.* = try lowerField(allocator, sub_field, rel.target_collection, schema_model);

        try query.fields.put(allocator, sub_field.responseKey(), .{ .relationship = .{
            .relationship = sub_field.name,
            .query = nested,
        } });
        // Relative to `collection` (not a single flat namespace across the whole
        // tree like the wire-level NDC QueryRequest) -- see graphql_parser/root.zig.
        try query.relationships.put(allocator, sub_field.name, rel);
    }

    return query;
}

fn findArgument(args: []const ast.Argument, name: []const u8) ?ast.Value {
    for (args) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.value;
    }
    return null;
}

fn expectColumnArgument(args: []const ast.Argument) Error![]const u8 {
    const value = findArgument(args, "column") orelse return Error.InvalidArgumentType;
    return switch (value) {
        .string => |s| s,
        else => Error.InvalidArgumentType,
    };
}

fn aggregateFunctionNamed(name: []const u8) ?ndc_ir.AggregateFunction {
    if (std.mem.eql(u8, name, "max")) return .max;
    if (std.mem.eql(u8, name, "min")) return .min;
    if (std.mem.eql(u8, name, "sum")) return .sum;
    if (std.mem.eql(u8, name, "avg")) return .avg;
    return null;
}

/// Lowers a `<collection>_aggregate` root field into `query.aggregates`.
/// `count` (optionally `count(column: "X", distinct: true)`) is a leaf field,
/// same as always -- its return type (`Int`) never depends on which column
/// is counted, so it was never an SDL problem. `max`/`min`/`sum`/`avg` are
/// **nested** (`max { AlbumId }`, one leaf column field per selection) rather
/// than the milestone-2 flat `max(column: "AlbumId")` shape -- see
/// docs/decisions/0013-graphql-type-system.md ("Gate 2"): a field whose
/// *return type* varies with an argument's value (an aggregate's own column
/// can be `Int` or `String` or ...) isn't expressible in GraphQL's type
/// system, whereas `max: <t>_max_fields` with one statically-typed field per
/// column is. Each column leaf becomes one flat `query.aggregates` entry
/// keyed `"<function>.<column response key>"` -- `sql_gen`'s `Aggregate`
/// union and NDC's own flat `/query` aggregates surface are completely
/// unaffected; only this lowering and the (future) GraphQL response envelope
/// know about the "." convention, needed so the envelope can re-nest a flat
/// NDC response back into the GraphQL shape the client asked for.
fn lowerAggregateField(allocator: std.mem.Allocator, field: ast.Field, collection: []const u8, schema_model: *const schema.SchemaModel) Error!ndc_ir.Query {
    if (!schema_model.collections.contains(collection)) return Error.UnknownCollection;

    var query = ndc_ir.Query{ .collection = collection };

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            query.predicate = try lowerWhereObject(allocator, &query, schema_model, collection, try expectObject(arg.value));
        } else if (std.mem.eql(u8, arg.name, "order_by")) {
            query.order_by = try lowerOrderBy(allocator, arg.value);
        } else if (std.mem.eql(u8, arg.name, "limit")) {
            query.limit = std.math.cast(u32, try expectInt(arg.value)) orelse return Error.InvalidArgumentType;
        } else if (std.mem.eql(u8, arg.name, "offset")) {
            query.offset = std.math.cast(u32, try expectInt(arg.value)) orelse return Error.InvalidArgumentType;
        }
    }

    for (field.selection_set) |sub_field| {
        if (std.mem.eql(u8, sub_field.name, "count")) {
            if (findArgument(sub_field.arguments, "column")) |_| {
                const column_name = try expectColumnArgument(sub_field.arguments);
                const distinct = if (findArgument(sub_field.arguments, "distinct")) |d| try expectBool(d) else false;
                try query.aggregates.put(allocator, sub_field.responseKey(), .{ .column_count = .{ .column = column_name, .distinct = distinct } });
            } else {
                try query.aggregates.put(allocator, sub_field.responseKey(), .star_count);
            }
            continue;
        }

        if (aggregateFunctionNamed(sub_field.name)) |f| {
            if (sub_field.selection_set.len == 0) return Error.UnknownAggregateField;
            for (sub_field.selection_set) |column_field| {
                if (column_field.selection_set.len != 0) return Error.UnknownAggregateField;
                const alias = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sub_field.name, column_field.responseKey() });
                try query.aggregates.put(allocator, alias, .{ .single_column = .{ .column = column_field.name, .function = f } });
            }
            continue;
        }

        return Error.UnknownAggregateField;
    }

    return query;
}

const aggregate_suffix = "_aggregate";

/// Lowers one already-resolved root field (fragment-free, directive-free,
/// variable-free -- see `request.zig`) into an `ndc_ir.Query`.
pub fn lowerRootField(allocator: std.mem.Allocator, root: ast.Field, schema_model: *const schema.SchemaModel) Error!ndc_ir.Query {
    if (std.mem.endsWith(u8, root.name, aggregate_suffix)) {
        const collection = root.name[0 .. root.name.len - aggregate_suffix.len];
        return lowerAggregateField(allocator, root, collection, schema_model);
    }
    return lowerField(allocator, root, root.name, schema_model);
}

pub const RootQuery = struct {
    response_key: []const u8,
    query: ndc_ir.Query,
};

/// Lowers every root field of a query document independently -- one
/// `ndc_ir.Query` per field, keyed by its GraphQL response key. `operation_name`/
/// `variables` thread through to `request.resolveOperation` for the
/// `POST /graphql` case (see docs/decisions/0014-graphql-post-endpoint.md);
/// `null`/`null` selects the document's sole operation with no substitution,
/// which is all `lower()` below (and every existing NDC-producer caller)
/// needs. A query document may have more than one root field (`{ albums
/// {...} artists {...} }`) -- `lower()` keeps the older single-root
/// contract every existing caller (the NDC-native producers, which have no
/// concept of "multiple root fields" at the wire level) relies on; this is
/// the entry point for callers, like the future GraphQL envelope, that need
/// to run all of them.
pub fn lowerAll(
    allocator: std.mem.Allocator,
    document: ast.Document,
    operation_name: ?[]const u8,
    variables: ?std.json.Value,
    schema_model: *const schema.SchemaModel,
) Error![]const RootQuery {
    const resolved = try request.resolveOperation(allocator, &document, operation_name, variables);
    if (resolved.operation_type != .query) return Error.NotAQueryDocument;

    const out = try allocator.alloc(RootQuery, resolved.root_fields.len);
    for (resolved.root_fields, out) |root, *dst| {
        dst.* = .{ .response_key = root.responseKey(), .query = try lowerRootField(allocator, root, schema_model) };
    }
    return out;
}

pub fn lower(allocator: std.mem.Allocator, document: ast.Document, schema_model: *const schema.SchemaModel) Error!ndc_ir.Query {
    const all = try lowerAll(allocator, document, null, null, schema_model);
    if (all.len != 1) return Error.ExpectedSingleRootField;
    return all[0].query;
}

/// Full range of argument-value shapes a mutation argument can take --
/// unlike `toJsonValue` (used for `where`-clause comparison values, which are
/// never bare objects), mutation arguments (`object`/`pk_columns`/`_set`) are
/// always objects, recursively.
fn argumentValueToJson(allocator: std.mem.Allocator, value: ast.Value) Error!std.json.Value {
    return switch (value) {
        .int => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = s },
        .boolean => |b| .{ .bool = b },
        .null_ => .null,
        .enum_ => |e| .{ .string = e },
        .list => |items| blk: {
            var arr = std.json.Array.init(allocator);
            for (items) |item| try arr.append(try argumentValueToJson(allocator, item));
            break :blk .{ .array = arr };
        },
        .object => |fields| blk: {
            var obj: std.json.ObjectMap = .empty;
            for (fields) |f| try obj.put(allocator, f.name, try argumentValueToJson(allocator, f.value));
            break :blk .{ .object = obj };
        },
        .variable => unreachable, // see toJsonValue's identical note
    };
}

/// A mutation field's selection set is its RETURNING selection -- flat,
/// column-only in milestone 3 (relationship fields inside `returning` are
/// deferred, see docs/roadmap.md).
fn lowerMutationReturning(allocator: std.mem.Allocator, selection_set: []const ast.Field) Error!ndc_ir.FieldSelection {
    var fields: ndc_ir.FieldSelection = .{};
    for (selection_set) |sub_field| {
        if (std.mem.eql(u8, sub_field.name, "__typename")) continue;
        if (sub_field.selection_set.len > 0) return Error.UnsupportedReturningField;
        try fields.put(allocator, sub_field.responseKey(), .{ .column = .{ .column = sub_field.name } });
    }
    return fields;
}

/// Lowers one mutation root field into one `ndc_ir.MutationOperation`. Unlike
/// `lowerField`, this needs no schema access at all -- `field.name` (e.g.
/// "insert_album") is resolved against the schema later, by
/// `schema.resolveProcedure` inside `sql_gen` (see
/// docs/decisions/0010-mutation-procedure-naming.md); ndc_ir and this lowering
/// stay schema-agnostic, exactly like the read-path IR.
pub fn lowerMutationField(allocator: std.mem.Allocator, field: ast.Field) Error!ndc_ir.MutationOperation {
    var arguments: ndc_ir.ArgumentMap = .{};
    for (field.arguments) |arg| {
        try arguments.put(allocator, arg.name, try argumentValueToJson(allocator, arg.value));
    }

    const fields: ?ndc_ir.FieldSelection = if (field.selection_set.len > 0)
        try lowerMutationReturning(allocator, field.selection_set)
    else
        null;

    return .{ .name = field.name, .arguments = arguments, .fields = fields };
}

/// Lowers a `mutation { ... }` document into an `ndc_ir.MutationRequest` --
/// one `MutationOperation` per root field, preserving document order (NDC's
/// `operations[]` runs in the order given, see
/// docs/decisions/0011-mutation-transactions.md). `operation_name`/`variables`
/// mirror `lowerAll`'s -- see its doc comment.
pub fn lowerMutationAll(
    allocator: std.mem.Allocator,
    document: ast.Document,
    operation_name: ?[]const u8,
    variables: ?std.json.Value,
) Error!ndc_ir.MutationRequest {
    const resolved = try request.resolveOperation(allocator, &document, operation_name, variables);
    if (resolved.operation_type != .mutation) return Error.NotAMutationDocument;

    const operations = try allocator.alloc(ndc_ir.MutationOperation, resolved.root_fields.len);
    for (resolved.root_fields, operations) |field, *out| out.* = try lowerMutationField(allocator, field);
    return .{ .operations = operations };
}

pub fn lowerMutation(allocator: std.mem.Allocator, document: ast.Document) Error!ndc_ir.MutationRequest {
    return lowerMutationAll(allocator, document, null, null);
}

fn testSchema(allocator: std.mem.Allocator) !schema.SchemaModel {
    var model = schema.SchemaModel{};
    try model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });
    try model.collections.put(allocator, "artist", .{ .db_schema = "public", .db_table = "artist", .object_type = "artist" });

    var rel = ndc_ir.Relationship{ .target_collection = "artist", .relationship_type = .object };
    try rel.column_mapping.put(allocator, "artist_id", "artist_id");
    var album_rels = ndc_ir.RelationshipMap{};
    try album_rels.put(allocator, "artist", rel);
    try model.relationships.put(allocator, "album", album_rels);

    return model;
}

const parser = @import("parser.zig");

test "lowers a scalar-only selection into a Query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ album { AlbumId Title } }");
    const query = try lower(allocator, doc, &schema_model);

    try std.testing.expectEqualStrings("album", query.collection);
    try std.testing.expectEqual(@as(usize, 2), query.fields.count());
}

test "lowers where with _and/_not into a nested Expression tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator,
        \\{ album(where: {_and: [{AlbumId: {_gt: 1}}, {_not: {Title: {_is_null: true}}}]}) { AlbumId } }
    );
    const query = try lower(allocator, doc, &schema_model);

    const and_exprs = query.predicate.?.and_;
    try std.testing.expectEqual(@as(usize, 2), and_exprs.len);
    try std.testing.expectEqual(ndc_ir.BinaryOperator.gt, and_exprs[0].binary_op.operator);
    try std.testing.expectEqual(ndc_ir.UnaryOperator.is_null, and_exprs[1].not_.unary_op.operator);
}

test "_is_null: false lowers to NOT (IS NULL)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ album(where: {Title: {_is_null: false}}) { AlbumId } }");
    const query = try lower(allocator, doc, &schema_model);

    try std.testing.expectEqual(ndc_ir.UnaryOperator.is_null, query.predicate.?.not_.unary_op.operator);
}

test "lowers order_by, limit and offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ album(order_by: [{Title: asc}], limit: 10, offset: 5) { AlbumId } }");
    const query = try lower(allocator, doc, &schema_model);

    try std.testing.expectEqual(@as(usize, 1), query.order_by.len);
    try std.testing.expectEqual(ndc_ir.OrderDirection.asc, query.order_by[0].direction);
    try std.testing.expectEqual(@as(?u32, 10), query.limit);
    try std.testing.expectEqual(@as(?u32, 5), query.offset);
}

test "lowers a nested relationship field and registers it in query.relationships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ album { AlbumId artist { Name } } }");
    const query = try lower(allocator, doc, &schema_model);

    const artist_field = query.fields.get("artist").?;
    try std.testing.expectEqualStrings("artist", artist_field.relationship.query.collection);
    try std.testing.expect(query.relationships.contains("artist"));
}

test "lowers a relationship-keyed where clause into exists(related: ...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ album(where: {artist: {Name: {_eq: \"AC/DC\"}}}) { AlbumId } }");
    const query = try lower(allocator, doc, &schema_model);

    const exists_expr = query.predicate.?.exists;
    try std.testing.expectEqualStrings("artist", exists_expr.in_collection.related.relationship);
    const inner = exists_expr.predicate.?.binary_op;
    try std.testing.expectEqualStrings("Name", inner.column.name);
    try std.testing.expectEqualStrings("AC/DC", inner.value.scalar.string);

    // The relationship referenced only in `where` (no matching selection here)
    // still gets registered, mirroring NDC's wire-level collection_relationships.
    try std.testing.expect(query.relationships.contains("artist"));
}

test "lowers an album_aggregate root field into a flat aggregate selection, nested max/min/sum/avg syntax" {
    // See docs/decisions/0013-graphql-type-system.md's Gate 2: max/min/sum/avg
    // are nested (`max { AlbumId }`) rather than milestone 2's
    // `max(column: "AlbumId")`, since a field whose return type depends on an
    // argument's value isn't SDL-typeable. `count` stays a leaf -- its return
    // type (Int) never varies by column.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator,
        \\{ album_aggregate(where: {artist_id: {_eq: 1}}) { total: count max { highest: AlbumId } unique_artists: count(column: "artist_id", distinct: true) } }
    );
    const query = try lower(allocator, doc, &schema_model);

    try std.testing.expectEqualStrings("album", query.collection);
    try std.testing.expectEqual(ndc_ir.BinaryOperator.eq, query.predicate.?.binary_op.operator);
    try std.testing.expectEqual(@as(usize, 3), query.aggregates.count());

    try std.testing.expectEqual(ndc_ir.Aggregate.star_count, query.aggregates.get("total").?);

    // Flat key is "<function>.<column response key>" -- see lowerAggregateField's doc comment.
    const highest = query.aggregates.get("max.highest").?.single_column;
    try std.testing.expectEqualStrings("AlbumId", highest.column);
    try std.testing.expectEqual(ndc_ir.AggregateFunction.max, highest.function);

    const unique_artists = query.aggregates.get("unique_artists").?.column_count;
    try std.testing.expectEqualStrings("artist_id", unique_artists.column);
    try std.testing.expect(unique_artists.distinct);
}

test "an aggregate function with no column selection is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ album_aggregate { max } }");
    try std.testing.expectError(Error.UnknownAggregateField, lower(allocator, doc, &schema_model));
}

test "multiple columns under one aggregate function each become their own flat entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ album_aggregate { max { AlbumId ArtistId } } }");
    const query = try lower(allocator, doc, &schema_model);

    try std.testing.expectEqual(@as(usize, 2), query.aggregates.count());
    try std.testing.expectEqualStrings("AlbumId", query.aggregates.get("max.AlbumId").?.single_column.column);
    try std.testing.expectEqualStrings("ArtistId", query.aggregates.get("max.ArtistId").?.single_column.column);
}

test "rejects an unknown collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "{ nonexistent { AlbumId } }");
    try std.testing.expectError(Error.UnknownCollection, lower(allocator, doc, &schema_model));
}

test "lower rejects a mutation document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const doc = try parser.parse(allocator, "mutation { insert_album(object: {title: \"X\"}) { album_id } }");
    try std.testing.expectError(Error.NotAQueryDocument, lower(allocator, doc, &schema_model));
}

test "lowerMutation lowers a single insert operation with a returning selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator,
        \\mutation { insert_album(object: {title: "Highway to Hell", artist_id: 1}) { album_id title } }
    );
    const mutation_request = try lowerMutation(allocator, doc);

    try std.testing.expectEqual(@as(usize, 1), mutation_request.operations.len);
    const op = mutation_request.operations[0];
    try std.testing.expectEqualStrings("insert_album", op.name);

    const object = op.arguments.get("object").?.object;
    try std.testing.expectEqualStrings("Highway to Hell", object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 1), object.get("artist_id").?.integer);

    try std.testing.expect(op.fields != null);
    try std.testing.expectEqual(@as(usize, 2), op.fields.?.count());
}

test "lowerMutation lowers multiple root fields into multiple operations, in document order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator,
        \\mutation {
        \\  insert_album(object: {title: "A", artist_id: 1}) { album_id }
        \\  delete_album_by_pk(pk_columns: {album_id: 1}) { album_id }
        \\}
    );
    const mutation_request = try lowerMutation(allocator, doc);

    try std.testing.expectEqual(@as(usize, 2), mutation_request.operations.len);
    try std.testing.expectEqualStrings("insert_album", mutation_request.operations[0].name);
    try std.testing.expectEqualStrings("delete_album_by_pk", mutation_request.operations[1].name);
}

test "lowerMutation with no returning selection leaves fields null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "mutation { delete_album_by_pk(pk_columns: {album_id: 1}) }");
    const mutation_request = try lowerMutation(allocator, doc);

    try std.testing.expect(mutation_request.operations[0].fields == null);
}

test "lowerMutation rejects a query document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc = try parser.parse(allocator, "{ album { AlbumId } }");
    try std.testing.expectError(Error.NotAMutationDocument, lowerMutation(allocator, doc));
}
