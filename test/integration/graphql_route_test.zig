const std = @import("std");
const pg_gql = @import("pg_gql");

// M4.6 checkpoint: the same parse -> resolve -> lower -> executor.run ->
// envelope pipeline `http_server/graphql_route.zig` runs per request,
// exercised directly against real Postgres (the HTTP transport layer itself
// is thin glue already covered by compilation + a manual curl smoke test,
// not worth re-deriving a fake HTTP request for).

fn connect(allocator: std.mem.Allocator) !*pg_gql.pg_wire.Connection {
    return pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
}

test "/graphql pipeline: __typename, object relationship reshaping, and multiple root fields" {
    const allocator = std.testing.allocator;
    const conn = try connect(allocator);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_model = try pg_gql.executor.introspectLive(a, conn);

    const document = try pg_gql.graphql_parser.parse(a,
        \\{
        \\  album(where: {artist_id: {_eq: 1}}, order_by: [{title: asc}]) {
        \\    __typename
        \\    title
        \\    artist { __typename name }
        \\  }
        \\  artist(where: {name: {_eq: "Accept"}}) { name }
        \\}
    );
    const resolved = try pg_gql.graphql_parser.resolveOperation(a, &document, null, null);
    try std.testing.expectEqual(pg_gql.graphql_parser.OperationType.query, resolved.operation_type);
    try std.testing.expectEqual(@as(usize, 2), resolved.root_fields.len);

    var outcomes: std.ArrayListUnmanaged(pg_gql.graphql_schema.FieldOutcome) = .empty;
    for (resolved.root_fields) |field| {
        const query = try pg_gql.graphql_parser.lowerRootField(a, field, &schema_model);
        var result = try pg_gql.executor.run(allocator, conn, &query, &schema_model);
        defer result.deinit();
        // Deep-copy the row set into the long-lived arena `a` (rather than
        // the per-field `result`'s own arena, which is about to be freed) by
        // round-tripping through JSON text -- adequate for a test, not a
        // pattern the real route uses (see graphql_route.zig, which instead
        // keeps every `result` alive until the whole response is serialized).
        const text = try std.json.Stringify.valueAlloc(allocator, result.value.array.items[0], .{});
        defer allocator.free(text);
        const copied = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        try outcomes.append(a, .{ .ok = copied });
    }

    const envelope = try pg_gql.graphql_schema.buildQueryEnvelope(a, &schema_model, resolved.root_fields, outcomes.items);
    try std.testing.expect(envelope.object.get("errors") == null);

    const data = envelope.object.get("data").?.object;
    const albums = data.get("album").?.array;
    try std.testing.expectEqual(@as(usize, 2), albums.items.len);
    try std.testing.expectEqualStrings("album", albums.items[0].object.get("__typename").?.string);
    try std.testing.expectEqualStrings("For Those About To Rock We Salute You", albums.items[0].object.get("title").?.string);

    // Object relationship reshapes to a single object, not an array.
    const artist_obj = albums.items[0].object.get("artist").?.object;
    try std.testing.expectEqualStrings("artist", artist_obj.get("__typename").?.string);
    try std.testing.expectEqualStrings("AC/DC", artist_obj.get("name").?.string);

    const artists = data.get("artist").?.array;
    try std.testing.expectEqual(@as(usize, 1), artists.items.len);
    try std.testing.expectEqualStrings("Accept", artists.items[0].object.get("name").?.string);
}

test "/graphql pipeline: aggregate reshaping into the nested GraphQL shape" {
    const allocator = std.testing.allocator;
    const conn = try connect(allocator);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_model = try pg_gql.executor.introspectLive(a, conn);

    const document = try pg_gql.graphql_parser.parse(a,
        \\{ album_aggregate(where: {artist_id: {_eq: 1}}) { count max { album_id } } }
    );
    const resolved = try pg_gql.graphql_parser.resolveOperation(a, &document, null, null);
    const field = resolved.root_fields[0];

    const query = try pg_gql.graphql_parser.lowerRootField(a, field, &schema_model);
    var result = try pg_gql.executor.run(allocator, conn, &query, &schema_model);
    defer result.deinit();

    const envelope = try pg_gql.graphql_schema.buildQueryEnvelope(a, &schema_model, &.{field}, &.{.{ .ok = result.value.array.items[0] }});

    const aggregate = envelope.object.get("data").?.object.get("album_aggregate").?.object;
    try std.testing.expectEqual(@as(i64, 2), aggregate.get("count").?.integer);
    try std.testing.expect(aggregate.get("max").?.object.get("album_id").?.integer > 0);
}

test "/graphql pipeline: a lowering error for one field becomes a path-tagged error, not a request failure" {
    const allocator = std.testing.allocator;
    const conn = try connect(allocator);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_model = try pg_gql.executor.introspectLive(a, conn);

    const document = try pg_gql.graphql_parser.parse(a, "{ nonexistent_collection { title } }");
    const resolved = try pg_gql.graphql_parser.resolveOperation(a, &document, null, null);
    const field = resolved.root_fields[0];

    const outcome: pg_gql.graphql_schema.FieldOutcome = if (pg_gql.graphql_parser.lowerRootField(a, field, &schema_model)) |_|
        unreachable
    else |err|
        .{ .err = @errorName(err) };

    const envelope = try pg_gql.graphql_schema.buildQueryEnvelope(a, &schema_model, &.{field}, &.{outcome});
    try std.testing.expect(envelope.object.get("data").?.object.get("nonexistent_collection").? == .null);
    try std.testing.expectEqual(@as(usize, 1), envelope.object.get("errors").?.array.items.len);
}
