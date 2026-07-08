const std = @import("std");
const schema = @import("schema");
const graphql_parser = @import("graphql_parser");

const ast = graphql_parser;

pub const Error = std.mem.Allocator.Error;

/// One root field's outcome, already unwrapped from NDC's response-array
/// shape (see docs/decisions/0005) to the single value for that field --
/// `executor.run`'s one-element array or `executor.runMutation`'s single
/// `operation_results` entry, whichever applies.
pub const FieldOutcome = union(enum) {
    /// A decoded NDC RowSet (`{"rows": [...], "aggregates": {...}}`) for a
    /// query field, or a mutation's `{"affected_rows": N, "returning": [...]}`.
    ok: std.json.Value,
    err: []const u8,
};

const aggregate_suffix = "_aggregate";

/// Builds the `{"data": ..., "errors": [...]}` envelope from a query
/// document's resolved root fields and their outcomes, reshaping NDC's
/// wire-native JSON into the shape a GraphQL client expects: a collection
/// field's RowSet unwraps to a plain array (or, for an object relationship,
/// to a single object or `null`); an `_aggregate` field's flat `aggregates`
/// map re-nests into `{count, max: {...}, min: {...}, ...}` (see
/// docs/decisions/0013's Gate 2); `__typename` is injected into every row
/// that asked for it. `errors` is omitted entirely when every field
/// succeeded. See docs/decisions/0014-graphql-post-endpoint.md.
pub fn buildQueryEnvelope(
    allocator: std.mem.Allocator,
    schema_model: *const schema.SchemaModel,
    fields: []const ast.Field,
    outcomes: []const FieldOutcome,
) Error!std.json.Value {
    var data: std.json.ObjectMap = .empty;
    var errors: std.json.Array = std.json.Array.init(allocator);
    var has_error = false;

    for (fields, outcomes) |field, outcome| {
        switch (outcome) {
            .ok => |value| {
                const reshaped = try reshapeRootField(allocator, schema_model, field, value);
                try data.put(allocator, field.responseKey(), reshaped);
            },
            .err => |message| {
                has_error = true;
                try data.put(allocator, field.responseKey(), .null);
                try errors.append(try errorObject(allocator, message, field.responseKey()));
            },
        }
    }

    var envelope: std.json.ObjectMap = .empty;
    try envelope.put(allocator, "data", .{ .object = data });
    if (has_error) try envelope.put(allocator, "errors", .{ .array = errors });
    return .{ .object = envelope };
}

/// A malformed-request-level error envelope (`{"errors": [...]}`, no `data`
/// key at all) -- used before any root field could even be resolved (e.g.
/// invalid GraphQL syntax).
pub fn buildRequestErrorEnvelope(allocator: std.mem.Allocator, message: []const u8) Error!std.json.Value {
    var errors = std.json.Array.init(allocator);
    try errors.append(try errorObject(allocator, message, null));
    var envelope: std.json.ObjectMap = .empty;
    try envelope.put(allocator, "errors", .{ .array = errors });
    return .{ .object = envelope };
}

fn errorObject(allocator: std.mem.Allocator, message: []const u8, path_head: ?[]const u8) Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "message", .{ .string = message });
    if (path_head) |head| {
        var path = std.json.Array.init(allocator);
        try path.append(.{ .string = head });
        try obj.put(allocator, "path", .{ .array = path });
    }
    return .{ .object = obj };
}

fn reshapeRootField(allocator: std.mem.Allocator, schema_model: *const schema.SchemaModel, field: ast.Field, row_set: std.json.Value) Error!std.json.Value {
    if (std.mem.endsWith(u8, field.name, aggregate_suffix)) {
        const aggregates = row_set.object.get("aggregates") orelse return .{ .object = .empty };
        return reshapeAggregates(allocator, aggregates.object);
    }
    return reshapeRowSet(allocator, schema_model, field.name, field.selection_set, row_set, true);
}

/// Splits each flat `"<function>.<column>"` aggregate key (see
/// `graphql_parser/to_ir.zig`'s `lowerAggregateField`) back into its nested
/// GraphQL shape: `count` stays top-level; `max.AlbumId`/`min.AlbumId`/...
/// group under `max`/`min`/... as `{AlbumId: value}`.
fn reshapeAggregates(allocator: std.mem.Allocator, aggregates: std.json.ObjectMap) Error!std.json.Value {
    var out: std.json.ObjectMap = .empty;
    var it = aggregates.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.indexOfScalar(u8, key, '.')) |dot| {
            const function_name = key[0..dot];
            const column_key = key[dot + 1 ..];
            const gop = try out.getOrPut(allocator, function_name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .object = .empty };
            try gop.value_ptr.object.put(allocator, column_key, entry.value_ptr.*);
        } else {
            try out.put(allocator, key, entry.value_ptr.*);
        }
    }
    return .{ .object = out };
}

/// Reshapes one NDC RowSet (`{"rows": [...]}`) into the GraphQL value a
/// client expects at `collection`: an array of rows if `is_array`, else the
/// single row object or `null`. Recurses into every nested relationship
/// field's own RowSet the same way, and injects `__typename` (the
/// collection name -- object type names equal collection names in this
/// engine's type system, see docs/decisions/0013) wherever a selection asks
/// for it. Mutates the already-decoded row objects in place (they live in
/// the caller's arena regardless) rather than copying.
fn reshapeRowSet(
    allocator: std.mem.Allocator,
    schema_model: *const schema.SchemaModel,
    collection: []const u8,
    selection_set: []const ast.Field,
    row_set: std.json.Value,
    is_array: bool,
) Error!std.json.Value {
    const rows: []std.json.Value = if (row_set.object.get("rows")) |r| r.array.items else &.{};

    for (rows) |*row| {
        try reshapeRow(allocator, schema_model, collection, selection_set, row);
    }

    if (is_array) {
        var arr = try std.json.Array.initCapacity(allocator, rows.len);
        for (rows) |row| arr.appendAssumeCapacity(row);
        return .{ .array = arr };
    }
    return if (rows.len > 0) rows[0] else .null;
}

fn reshapeRow(
    allocator: std.mem.Allocator,
    schema_model: *const schema.SchemaModel,
    collection: []const u8,
    selection_set: []const ast.Field,
    row: *std.json.Value,
) Error!void {
    for (selection_set) |field| {
        if (std.mem.eql(u8, field.name, "__typename")) {
            try row.object.put(allocator, field.responseKey(), .{ .string = collection });
            continue;
        }
        if (field.selection_set.len == 0) continue; // plain column, nothing to reshape

        const collection_relationships = schema_model.relationships.get(collection) orelse continue;
        const rel = collection_relationships.get(field.name) orelse continue;
        const nested_value = row.object.get(field.responseKey()) orelse continue;

        const reshaped = try reshapeRowSet(allocator, schema_model, rel.target_collection, field.selection_set, nested_value, rel.relationship_type == .array);
        try row.object.put(allocator, field.responseKey(), reshaped);
    }
}

fn testSchema(allocator: std.mem.Allocator) !schema.SchemaModel {
    return schema.buildSchemaModel(allocator, .{
        .tables = &.{
            .{ .schema_name = "public", .table_name = "artist" },
            .{ .schema_name = "public", .table_name = "album" },
        },
        .columns = &.{
            .{ .table_name = "artist", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "artist", .column_name = "name", .pg_type = "text", .nullable = false },
            .{ .table_name = "album", .column_name = "album_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "album", .column_name = "title", .pg_type = "text", .nullable = false },
            .{ .table_name = "album", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
        },
        .foreign_keys = &.{
            .{ .constraint_name = "album_artist_id_fkey", .table_name = "album", .column_name = "artist_id", .foreign_table_name = "artist", .foreign_column_name = "artist_id" },
        },
    });
}

fn resolvedField(allocator: std.mem.Allocator, src: []const u8) !ast.Field {
    const document = try graphql_parser.parse(allocator, src);
    const resolved = try graphql_parser.resolveOperation(allocator, &document, null, null);
    return resolved.root_fields[0];
}

test "reshapes a collection RowSet into a plain array, injecting __typename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const field = try resolvedField(allocator, "{ album { __typename title } }");

    const row_set = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"rows\": [{\"title\": \"Highway to Hell\"}]}", .{});
    const envelope = try buildQueryEnvelope(allocator, &schema_model, &.{field}, &.{.{ .ok = row_set }});

    const rows = envelope.object.get("data").?.object.get("album").?.array;
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("album", rows.items[0].object.get("__typename").?.string);
    try std.testing.expectEqualStrings("Highway to Hell", rows.items[0].object.get("title").?.string);
    try std.testing.expect(envelope.object.get("errors") == null);
}

test "reshapes a nested object relationship RowSet to a single object, not an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const field = try resolvedField(allocator, "{ album { title artist { name } } }");

    const row_set = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"rows": [{"title": "Highway to Hell", "artist": {"rows": [{"name": "AC/DC"}]}}]}
    , .{});
    const envelope = try buildQueryEnvelope(allocator, &schema_model, &.{field}, &.{.{ .ok = row_set }});

    const album_row = envelope.object.get("data").?.object.get("album").?.array.items[0];
    try std.testing.expectEqualStrings("AC/DC", album_row.object.get("artist").?.object.get("name").?.string);
}

test "reshapes a flat aggregates map into the nested GraphQL shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const field = try resolvedField(allocator, "{ album_aggregate { count max { album_id } } }");

    const row_set = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"aggregates": {"count": 2, "max.album_id": 5}}
    , .{});
    const envelope = try buildQueryEnvelope(allocator, &schema_model, &.{field}, &.{.{ .ok = row_set }});

    const aggregate = envelope.object.get("data").?.object.get("album_aggregate").?.object;
    try std.testing.expectEqual(@as(i64, 2), aggregate.get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 5), aggregate.get("max").?.object.get("album_id").?.integer);
}

test "a field-level error nulls that field's data and adds a path-tagged error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const field = try resolvedField(allocator, "{ album { title } }");

    const envelope = try buildQueryEnvelope(allocator, &schema_model, &.{field}, &.{.{ .err = "boom" }});

    try std.testing.expect(envelope.object.get("data").?.object.get("album").? == .null);
    const errors = envelope.object.get("errors").?.array;
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqualStrings("boom", errors.items[0].object.get("message").?.string);
    try std.testing.expectEqualStrings("album", errors.items[0].object.get("path").?.array.items[0].string);
}
