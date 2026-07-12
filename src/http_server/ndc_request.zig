const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");

pub const Error = std.mem.Allocator.Error || error{
    InvalidRequest,
    UnknownCollection,
    UnknownRelationship,
    UnknownOperator,
    UnsupportedFeature,
};

fn field(obj: std.json.ObjectMap, name: []const u8) Error!std.json.Value {
    return obj.get(name) orelse Error.InvalidRequest;
}

fn asStr(v: std.json.Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => Error.InvalidRequest,
    };
}

fn asObj(v: std.json.Value) Error!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => Error.InvalidRequest,
    };
}

fn asArr(v: std.json.Value) Error!std.json.Array {
    return switch (v) {
        .array => |a| a,
        else => Error.InvalidRequest,
    };
}

fn asU32(v: std.json.Value) Error!u32 {
    return switch (v) {
        .integer => |i| std.math.cast(u32, i) orelse Error.InvalidRequest,
        else => Error.InvalidRequest,
    };
}

fn parseComparisonTarget(obj: std.json.ObjectMap) Error!ndc_ir.ComparisonTarget {
    // "path" (cross-relationship comparisons) is accepted but ignored --
    // unsupported in milestone 1 (see docs/roadmap.md); we don't reject it
    // outright so a request with an empty path (the common case) still works.
    return .{ .name = try asStr(try field(obj, "name")) };
}

/// `query`/`schema_model`/`current_collection` are only needed to resolve
/// `exists(related: ...)` relationship names against the schema and register
/// them into `query.relationships` (mirroring what relationship *fields*
/// already do -- see docs/decisions/0007). `current_collection` is threaded
/// separately from `query.collection` because `exists` changes context to the
/// target collection for its own nested predicate.
fn parseExpression(
    allocator: std.mem.Allocator,
    query: *ndc_ir.Query,
    schema_model: *const schema.SchemaModel,
    current_collection: []const u8,
    value: std.json.Value,
) Error!ndc_ir.Expression {
    const obj = try asObj(value);
    const expr_type = try asStr(try field(obj, "type"));

    if (std.mem.eql(u8, expr_type, "and")) {
        const list = try asArr(try field(obj, "expressions"));
        const out = try allocator.alloc(ndc_ir.Expression, list.items.len);
        for (list.items, out) |item, *dst| dst.* = try parseExpression(allocator, query, schema_model, current_collection, item);
        return .{ .and_ = out };
    }
    if (std.mem.eql(u8, expr_type, "or")) {
        const list = try asArr(try field(obj, "expressions"));
        const out = try allocator.alloc(ndc_ir.Expression, list.items.len);
        for (list.items, out) |item, *dst| dst.* = try parseExpression(allocator, query, schema_model, current_collection, item);
        return .{ .or_ = out };
    }
    if (std.mem.eql(u8, expr_type, "not")) {
        const boxed = try allocator.create(ndc_ir.Expression);
        boxed.* = try parseExpression(allocator, query, schema_model, current_collection, try field(obj, "expression"));
        return .{ .not_ = boxed };
    }
    if (std.mem.eql(u8, expr_type, "binary_comparison_operator")) {
        const target = try parseComparisonTarget(try asObj(try field(obj, "column")));
        const op = ndc_ir.binaryOperatorFromName(try asStr(try field(obj, "operator"))) orelse return Error.UnknownOperator;
        const value_obj = try asObj(try field(obj, "value"));
        const value_type = try asStr(try field(value_obj, "type"));
        const comparison_value: ndc_ir.ComparisonValue = if (std.mem.eql(u8, value_type, "scalar"))
            .{ .scalar = try field(value_obj, "value") }
        else if (std.mem.eql(u8, value_type, "variable"))
            .{ .variable = try asStr(try field(value_obj, "name")) }
        else
            return Error.UnsupportedFeature;
        return .{ .binary_op = .{ .column = target, .operator = op, .value = comparison_value } };
    }
    if (std.mem.eql(u8, expr_type, "unary_comparison_operator")) {
        const target = try parseComparisonTarget(try asObj(try field(obj, "column")));
        if (!std.mem.eql(u8, try asStr(try field(obj, "operator")), "is_null")) return Error.UnknownOperator;
        return .{ .unary_op = .{ .column = target, .operator = .is_null } };
    }
    if (std.mem.eql(u8, expr_type, "exists")) {
        const in_collection_obj = try asObj(try field(obj, "in_collection"));
        const in_collection_type = try asStr(try field(in_collection_obj, "type"));

        var target_collection = current_collection;
        const in_collection: ndc_ir.ExistsInCollection = if (std.mem.eql(u8, in_collection_type, "related")) blk: {
            const relationship_name = try asStr(try field(in_collection_obj, "relationship"));
            const collection_relationships = schema_model.relationships.get(current_collection) orelse return Error.UnknownRelationship;
            const rel = collection_relationships.get(relationship_name) orelse return Error.UnknownRelationship;
            target_collection = rel.target_collection;
            try query.relationships.put(allocator, relationship_name, rel);
            break :blk .{ .related = .{ .relationship = relationship_name } };
        } else if (std.mem.eql(u8, in_collection_type, "unrelated")) blk: {
            const collection_name = try asStr(try field(in_collection_obj, "collection"));
            target_collection = collection_name;
            break :blk .{ .unrelated = .{ .collection = collection_name } };
        } else return Error.UnsupportedFeature;

        const predicate: ?*ndc_ir.Expression = blk: {
            const pred_val = obj.get("predicate") orelse break :blk null;
            if (pred_val == .null) break :blk null;
            const boxed = try allocator.create(ndc_ir.Expression);
            boxed.* = try parseExpression(allocator, query, schema_model, target_collection, pred_val);
            break :blk boxed;
        };

        return .{ .exists = .{ .in_collection = in_collection, .predicate = predicate } };
    }
    return Error.UnsupportedFeature;
}

fn parseOrderBy(allocator: std.mem.Allocator, value: std.json.Value) Error![]ndc_ir.OrderByElement {
    const obj = try asObj(value);
    const elements = try asArr(try field(obj, "elements"));
    const out = try allocator.alloc(ndc_ir.OrderByElement, elements.items.len);
    for (elements.items, out) |item, *dst| {
        const item_obj = try asObj(item);
        const dir_str = try asStr(try field(item_obj, "order_direction"));
        const direction: ndc_ir.OrderDirection = if (std.mem.eql(u8, dir_str, "asc"))
            .asc
        else if (std.mem.eql(u8, dir_str, "desc"))
            .desc
        else
            return Error.InvalidRequest;
        const target = try parseComparisonTarget(try asObj(try field(item_obj, "target")));
        dst.* = .{ .target = target, .direction = direction };
    }
    return out;
}

/// Parses one NDC `query` object (fields/predicate/order_by/limit/offset) --
/// the shape nested both at the QueryRequest top level and inside every
/// relationship field -- into an ndc_ir.Query rooted at `collection`.
fn parseQueryObject(allocator: std.mem.Allocator, collection: []const u8, query_obj: std.json.ObjectMap, schema_model: *const schema.SchemaModel) Error!ndc_ir.Query {
    if (!schema_model.collections.contains(collection)) return Error.UnknownCollection;
    var query = ndc_ir.Query{ .collection = collection };

    if (query_obj.get("fields")) |fields_val| {
        if (fields_val != .null) {
            const fields_obj = try asObj(fields_val);
            var it = fields_obj.iterator();
            while (it.next()) |entry| {
                const field_alias = entry.key_ptr.*;
                const field_obj = try asObj(entry.value_ptr.*);
                const field_type = try asStr(try field(field_obj, "type"));

                if (std.mem.eql(u8, field_type, "column")) {
                    const column_name = try asStr(try field(field_obj, "column"));
                    try query.fields.put(allocator, field_alias, .{ .column = .{ .column = column_name } });
                } else if (std.mem.eql(u8, field_type, "relationship")) {
                    const relationship_name = try asStr(try field(field_obj, "relationship"));
                    const collection_relationships = schema_model.relationships.get(collection) orelse return Error.UnknownRelationship;
                    const rel = collection_relationships.get(relationship_name) orelse return Error.UnknownRelationship;

                    const nested = try allocator.create(ndc_ir.Query);
                    nested.* = try parseQueryObject(allocator, rel.target_collection, try asObj(try field(field_obj, "query")), schema_model);

                    try query.fields.put(allocator, field_alias, .{ .relationship = .{ .relationship = relationship_name, .query = nested } });
                    try query.relationships.put(allocator, relationship_name, rel);
                } else {
                    return Error.UnsupportedFeature;
                }
            }
        }
    }

    if (query_obj.get("aggregates")) |aggregates_val| {
        if (aggregates_val != .null) {
            const aggregates_obj = try asObj(aggregates_val);
            var it = aggregates_obj.iterator();
            while (it.next()) |entry| {
                const alias = entry.key_ptr.*;
                const agg_obj = try asObj(entry.value_ptr.*);
                const agg_type = try asStr(try field(agg_obj, "type"));

                if (std.mem.eql(u8, agg_type, "star_count")) {
                    try query.aggregates.put(allocator, alias, .star_count);
                } else if (std.mem.eql(u8, agg_type, "column_count")) {
                    const column_name = try asStr(try field(agg_obj, "column"));
                    const distinct = if (agg_obj.get("distinct")) |d| (d == .bool and d.bool) else false;
                    try query.aggregates.put(allocator, alias, .{ .column_count = .{ .column = column_name, .distinct = distinct } });
                } else if (std.mem.eql(u8, agg_type, "single_column")) {
                    const column_name = try asStr(try field(agg_obj, "column"));
                    const function_name = try asStr(try field(agg_obj, "function"));
                    const function: ndc_ir.AggregateFunction = if (std.mem.eql(u8, function_name, "min"))
                        .min
                    else if (std.mem.eql(u8, function_name, "max"))
                        .max
                    else if (std.mem.eql(u8, function_name, "sum"))
                        .sum
                    else if (std.mem.eql(u8, function_name, "avg"))
                        .avg
                    else
                        return Error.UnsupportedFeature;
                    try query.aggregates.put(allocator, alias, .{ .single_column = .{ .column = column_name, .function = function } });
                } else {
                    return Error.UnsupportedFeature;
                }
            }
        }
    }

    if (query_obj.get("predicate")) |pred_val| {
        if (pred_val != .null) query.predicate = try parseExpression(allocator, &query, schema_model, collection, pred_val);
    }
    if (query_obj.get("order_by")) |ob_val| {
        if (ob_val != .null) query.order_by = try parseOrderBy(allocator, ob_val);
    }
    if (query_obj.get("limit")) |limit_val| {
        if (limit_val != .null) query.limit = try asU32(limit_val);
    }
    if (query_obj.get("offset")) |offset_val| {
        if (offset_val != .null) query.offset = try asU32(offset_val);
    }

    return query;
}

/// Parses a full NDC QueryRequest JSON document
/// (`{"collection": ..., "query": {...}, ...}`) into an ndc_ir.Query. This is
/// a third IR producer alongside graphql_parser and query_builder -- reading
/// an already-parsed JSON tree rather than GraphQL text, so it needs no
/// lexer/parser of its own, just the same kind of structural lowering
/// graphql_parser/to_ir.zig does.
pub fn parseQueryRequest(allocator: std.mem.Allocator, request: std.json.Value, schema_model: *const schema.SchemaModel) Error!ndc_ir.Query {
    const obj = try asObj(request);
    const collection = try asStr(try field(obj, "collection"));
    const query_obj = try asObj(try field(obj, "query"));
    return parseQueryObject(allocator, collection, query_obj, schema_model);
}

/// Parses the QueryRequest's top-level `variables` array (a list of flat
/// name -> JSON value objects, NDC's batching mechanism -- see
/// docs/decisions/0009-query-variables.md), if present. Returns an empty
/// slice when the request has no `variables` field, matching the "one
/// implicit set" behavior `executor.run` already provides.
pub fn parseVariableSets(allocator: std.mem.Allocator, request: std.json.Value) Error![]const ndc_ir.VariableSet {
    const obj = try asObj(request);
    const variables_val = obj.get("variables") orelse return &.{};
    if (variables_val == .null) return &.{};

    const list = try asArr(variables_val);
    const out = try allocator.alloc(ndc_ir.VariableSet, list.items.len);
    for (list.items, out) |item, *dst| {
        const set_obj = try asObj(item);
        var set: ndc_ir.VariableSet = .{};
        var it = set_obj.iterator();
        while (it.next()) |entry| {
            try set.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        dst.* = set;
    }
    return out;
}

/// Parses one MutationRequest operation
/// (`{"type": "procedure", "name": ..., "arguments": {...}, "fields": {...}}`)
/// into an ndc_ir.MutationOperation. No schema access needed -- `name`
/// resolution happens later, in `sql_gen` via `schema.resolveProcedure` (see
/// docs/decisions/0010-mutation-procedure-naming.md), mirroring
/// graphql_parser's mutation lowering.
fn parseMutationOperation(allocator: std.mem.Allocator, op_val: std.json.Value) Error!ndc_ir.MutationOperation {
    const obj = try asObj(op_val);
    const name = try asStr(try field(obj, "name"));

    var arguments: ndc_ir.ArgumentMap = .{};
    if (obj.get("arguments")) |args_val| {
        if (args_val != .null) {
            const args_obj = try asObj(args_val);
            var it = args_obj.iterator();
            while (it.next()) |entry| {
                try arguments.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    var fields: ?ndc_ir.FieldSelection = null;
    if (obj.get("fields")) |fields_val| {
        if (fields_val != .null) {
            const fields_obj = try asObj(fields_val);
            var f: ndc_ir.FieldSelection = .{};
            var it = fields_obj.iterator();
            while (it.next()) |entry| {
                const field_alias = entry.key_ptr.*;
                const field_obj = try asObj(entry.value_ptr.*);
                const field_type = try asStr(try field(field_obj, "type"));
                // Only column fields are supported in RETURNING for milestone
                // 3 (see docs/roadmap.md) -- a relationship field here is a
                // client error, not silently dropped.
                if (!std.mem.eql(u8, field_type, "column")) return Error.UnsupportedFeature;
                const column_name = try asStr(try field(field_obj, "column"));
                try f.put(allocator, field_alias, .{ .column = .{ .column = column_name } });
            }
            fields = f;
        }
    }

    return .{ .name = name, .arguments = arguments, .fields = fields };
}

/// Parses a full NDC MutationRequest JSON document (`{"operations": [...]}`)
/// into an ndc_ir.MutationRequest -- the mutation-side counterpart to
/// `parseQueryRequest`.
pub fn parseMutationRequest(allocator: std.mem.Allocator, request: std.json.Value) Error!ndc_ir.MutationRequest {
    const obj = try asObj(request);
    const operations_arr = try asArr(try field(obj, "operations"));
    const operations = try allocator.alloc(ndc_ir.MutationOperation, operations_arr.items.len);
    for (operations_arr.items, operations) |item, *dst| dst.* = try parseMutationOperation(allocator, item);
    return .{ .operations = operations };
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

test "parses a literal NDC QueryRequest with predicate, order_by, limit and a relationship" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const request_text =
        \\{
        \\  "collection": "album",
        \\  "query": {
        \\    "fields": {
        \\      "title": {"type": "column", "column": "title"},
        \\      "artist": {"type": "relationship", "relationship": "artist", "arguments": {}, "query": {
        \\        "fields": {"name": {"type": "column", "column": "name"}}
        \\      }}
        \\    },
        \\    "predicate": {
        \\      "type": "binary_comparison_operator",
        \\      "column": {"type": "column", "name": "artist_id", "path": []},
        \\      "operator": "_eq",
        \\      "value": {"type": "scalar", "value": 1}
        \\    },
        \\    "order_by": {"elements": [{"order_direction": "asc", "target": {"type": "column", "name": "title", "path": []}}]},
        \\    "limit": 10
        \\  },
        \\  "arguments": {},
        \\  "collection_relationships": {}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const query = try parseQueryRequest(allocator, parsed.value, &schema_model);

    try std.testing.expectEqualStrings("album", query.collection);
    try std.testing.expectEqual(@as(usize, 2), query.fields.count());
    try std.testing.expectEqual(ndc_ir.BinaryOperator.eq, query.predicate.?.binary_op.operator);
    try std.testing.expectEqual(@as(i64, 1), query.predicate.?.binary_op.value.scalar.integer);
    try std.testing.expectEqual(@as(usize, 1), query.order_by.len);
    try std.testing.expectEqual(@as(?u32, 10), query.limit);

    const artist_field = query.fields.get("artist").?;
    try std.testing.expectEqualStrings("artist", artist_field.relationship.query.collection);
}

test "parses exists(related: ...) with a nested predicate, registering the relationship" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const request_text =
        \\{
        \\  "collection": "album",
        \\  "query": {
        \\    "predicate": {
        \\      "type": "exists",
        \\      "in_collection": {"type": "related", "relationship": "artist"},
        \\      "predicate": {
        \\        "type": "binary_comparison_operator",
        \\        "column": {"type": "column", "name": "Name", "path": []},
        \\        "operator": "_eq",
        \\        "value": {"type": "scalar", "value": "AC/DC"}
        \\      }
        \\    }
        \\  },
        \\  "arguments": {},
        \\  "collection_relationships": {}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const query = try parseQueryRequest(allocator, parsed.value, &schema_model);

    const exists_expr = query.predicate.?.exists;
    try std.testing.expectEqualStrings("artist", exists_expr.in_collection.related.relationship);
    try std.testing.expectEqualStrings("AC/DC", exists_expr.predicate.?.binary_op.value.scalar.string);
    try std.testing.expect(query.relationships.contains("artist"));
}

test "parses exists(unrelated: ...) with no predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = try testSchema(allocator);
    try schema_model.collections.put(allocator, "promotion", .{ .db_schema = "public", .db_table = "promotion", .object_type = "promotion" });

    const request_text =
        \\{
        \\  "collection": "album",
        \\  "query": {
        \\    "predicate": {"type": "exists", "in_collection": {"type": "unrelated", "collection": "promotion"}}
        \\  },
        \\  "arguments": {},
        \\  "collection_relationships": {}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const query = try parseQueryRequest(allocator, parsed.value, &schema_model);

    const exists_expr = query.predicate.?.exists;
    try std.testing.expectEqualStrings("promotion", exists_expr.in_collection.unrelated.collection);
    try std.testing.expect(exists_expr.predicate == null);
}

test "parses star_count, column_count and single_column aggregates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const request_text =
        \\{
        \\  "collection": "album",
        \\  "query": {
        \\    "aggregates": {
        \\      "total": {"type": "star_count"},
        \\      "distinct_artists": {"type": "column_count", "column": "artist_id", "distinct": true},
        \\      "max_id": {"type": "single_column", "column": "album_id", "function": "max"}
        \\    }
        \\  },
        \\  "arguments": {},
        \\  "collection_relationships": {}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const query = try parseQueryRequest(allocator, parsed.value, &schema_model);

    try std.testing.expectEqual(@as(usize, 3), query.aggregates.count());
    try std.testing.expectEqual(ndc_ir.Aggregate.star_count, query.aggregates.get("total").?);

    const distinct_artists = query.aggregates.get("distinct_artists").?.column_count;
    try std.testing.expectEqualStrings("artist_id", distinct_artists.column);
    try std.testing.expect(distinct_artists.distinct);

    const max_id = query.aggregates.get("max_id").?.single_column;
    try std.testing.expectEqualStrings("album_id", max_id.column);
    try std.testing.expectEqual(ndc_ir.AggregateFunction.max, max_id.function);
}

test "parses a variable-typed comparison value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const request_text =
        \\{
        \\  "collection": "album",
        \\  "query": {
        \\    "predicate": {
        \\      "type": "binary_comparison_operator",
        \\      "column": {"type": "column", "name": "artist_id", "path": []},
        \\      "operator": "_eq",
        \\      "value": {"type": "variable", "name": "target_artist_id"}
        \\    }
        \\  },
        \\  "arguments": {},
        \\  "collection_relationships": {}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const query = try parseQueryRequest(allocator, parsed.value, &schema_model);

    try std.testing.expectEqualStrings("target_artist_id", query.predicate.?.binary_op.value.variable);
}

test "parseVariableSets parses the top-level variables array into VariableSets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const request_text =
        \\{"collection": "album", "query": {}, "arguments": {}, "collection_relationships": {},
        \\ "variables": [{"target_artist_id": 1}, {"target_artist_id": 2}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const sets = try parseVariableSets(allocator, parsed.value);

    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expectEqual(@as(i64, 1), sets[0].get("target_artist_id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), sets[1].get("target_artist_id").?.integer);
}

test "parseVariableSets returns an empty slice when variables is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"collection\": \"album\", \"query\": {}}", .{});
    const sets = try parseVariableSets(allocator, parsed.value);
    try std.testing.expectEqual(@as(usize, 0), sets.len);
}

test "rejects a request for an unknown collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"collection\": \"nope\", \"query\": {}}", .{});
    try std.testing.expectError(Error.UnknownCollection, parseQueryRequest(allocator, parsed.value, &schema_model));
}

test "parseMutationRequest parses a single insert operation with a returning selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const request_text =
        \\{
        \\  "operations": [
        \\    {
        \\      "type": "procedure",
        \\      "name": "insert_album",
        \\      "arguments": {"object": {"title": "Highway to Hell", "artist_id": 1}},
        \\      "fields": {
        \\        "album_id": {"type": "column", "column": "album_id"},
        \\        "title": {"type": "column", "column": "title"}
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const request = try parseMutationRequest(allocator, parsed.value);

    try std.testing.expectEqual(@as(usize, 1), request.operations.len);
    const op = request.operations[0];
    try std.testing.expectEqualStrings("insert_album", op.name);
    try std.testing.expectEqualStrings("Highway to Hell", op.arguments.get("object").?.object.get("title").?.string);
    try std.testing.expectEqual(@as(usize, 2), op.fields.?.count());
}

test "parseMutationRequest parses multiple operations in document order, with a no-fields operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const request_text =
        \\{
        \\  "operations": [
        \\    {"type": "procedure", "name": "insert_album", "arguments": {"object": {"title": "A"}}},
        \\    {"type": "procedure", "name": "delete_album_by_pk", "arguments": {"pk_columns": {"album_id": 1}}}
        \\  ]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    const request = try parseMutationRequest(allocator, parsed.value);

    try std.testing.expectEqual(@as(usize, 2), request.operations.len);
    try std.testing.expectEqualStrings("insert_album", request.operations[0].name);
    try std.testing.expect(request.operations[0].fields == null);
    try std.testing.expectEqualStrings("delete_album_by_pk", request.operations[1].name);
}

test "parseMutationRequest rejects a relationship field inside returning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const request_text =
        \\{
        \\  "operations": [
        \\    {"type": "procedure", "name": "insert_album", "arguments": {"object": {"title": "A"}},
        \\     "fields": {"artist": {"type": "relationship", "relationship": "artist"}}}
        \\  ]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    try std.testing.expectError(Error.UnsupportedFeature, parseMutationRequest(allocator, parsed.value));
}

// Coverage-guided fuzz target (roadmap-v1.md milestone 5): these decoders sit
// on the untrusted-input boundary (`POST /query` / `POST /mutation` hand them
// client-controlled JSON), so arbitrary bytes must produce an IR value or an
// Error -- never a crash, hang, or leak. std.json filters syntax; what this
// exercises is the Value-walking layer (type confusion, missing fields,
// absurd nesting) against a small fixture schema. Runs once as a plain test;
// runs coverage-guided under `zig build test --fuzz`.
test "fuzz: request decoders never crash on arbitrary JSON" {
    try std.testing.fuzz({}, fuzzDecoders, .{ .corpus = &.{
        \\{"collection":"album","query":{"fields":{"title":{"type":"column","column":"title"}},"limit":5,"predicate":{"type":"binary_comparison_operator","column":{"name":"album_id"},"operator":"_in","value":{"type":"variable","name":"ids"}}},"arguments":{},"collection_relationships":{},"variables":[{"ids":[1,2]}]}
        ,
        \\{"operations":[{"type":"procedure","name":"insert_album","arguments":{"object":{"title":"x","artist_id":1}},"fields":{"affected_rows":{"type":"column","column":"affected_rows"}}}],"collection_relationships":{}}
        ,
    } });
}

fn fuzzDecoders(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, buf[0..len], .{}) catch return;

    var schema_model = schema.SchemaModel{};
    schema_model.collections.put(a, "album", .{
        .db_schema = "public",
        .db_table = "album",
        .object_type = "album",
    }) catch return;

    _ = parseQueryRequest(a, parsed, &schema_model) catch {};
    _ = parseVariableSets(a, parsed) catch {};
    _ = parseMutationRequest(a, parsed) catch {};
}
