const std = @import("std");
const pg_gql = @import("pg_gql");

test "GraphQL query with where/order_by/relationship returns the correct nested RowSet JSON" {
    const allocator = std.testing.allocator;

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();

    const query = try pg_gql.graphql_parser.parseToIr(
        query_arena.allocator(),
        \\{ album(where: {artist_id: {_eq: 1}}, order_by: [{title: asc}]) { title artist { name } } }
    ,
        &schema_model,
    );

    var parsed = try pg_gql.executor.run(allocator, conn, &query, &schema_model);
    defer parsed.deinit();

    // executor.run returns the full NDC QueryResponse shape: an array of
    // RowSets (see docs/decisions/0005-query-response-array-of-rowsets.md).
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const row_set = parsed.value.array.items[0].object;

    const rows = row_set.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);

    const first = rows.items[0].object;
    try std.testing.expectEqualStrings("For Those About To Rock We Salute You", first.get("title").?.string);
    const second = rows.items[1].object;
    try std.testing.expectEqualStrings("Let There Be Rock", second.get("title").?.string);

    const artist_rows = first.get("artist").?.object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 1), artist_rows.items.len);
    try std.testing.expectEqualStrings("AC/DC", artist_rows.items[0].object.get("name").?.string);
}

// Confirms the array-relationship claim from docs/decisions/0006 and the milestone 2
// design: the reverse (array) relationship derived by schema/introspect.zig requires
// zero changes anywhere else in the pipeline (sql_gen, pg_wire, executor, this
// producer) to work correctly end to end -- it returns *all* matching child rows,
// not just one (which LIMIT-1-forcing object-relationship handling would wrongly do).
test "array relationship (artist -> album, reverse FK) returns all matching child rows" {
    const allocator = std.testing.allocator;

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();

    // Reverse relationships are always named `<child>_by_<column>` (see
    // docs/decisions/0012-permanent-relationship-naming.md), never the bare
    // child collection name.
    const query = try pg_gql.graphql_parser.parseToIr(
        query_arena.allocator(),
        \\{ artist(where: {name: {_eq: "AC/DC"}}) { name album_by_artist_id(order_by: [{title: asc}]) { title } } }
    ,
        &schema_model,
    );

    var parsed = try pg_gql.executor.run(allocator, conn, &query, &schema_model);
    defer parsed.deinit();

    const row_set = parsed.value.array.items[0].object;
    const rows = row_set.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);

    const albums = rows.items[0].object.get("album_by_artist_id").?.object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 2), albums.items.len);
    try std.testing.expectEqualStrings("For Those About To Rock We Salute You", albums.items[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("Let There Be Rock", albums.items[1].object.get("title").?.string);
}

test "exists(related: ...) filters artists to those with a matching album" {
    const allocator = std.testing.allocator;

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();

    // Only "Accept" has an album titled "Balls to the Wall" (see test/fixtures/seed.sql);
    // AC/DC has two albums, neither with that title.
    const query = try pg_gql.graphql_parser.parseToIr(
        query_arena.allocator(),
        \\{ artist(where: {album_by_artist_id: {title: {_eq: "Balls to the Wall"}}}) { name } }
    ,
        &schema_model,
    );

    var parsed = try pg_gql.executor.run(allocator, conn, &query, &schema_model);
    defer parsed.deinit();

    const rows = parsed.value.array.items[0].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("Accept", rows.items[0].object.get("name").?.string);
}

test "album_aggregate returns count and max(album_id) over the filtered row set" {
    const allocator = std.testing.allocator;

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();

    // AC/DC (artist_id 1) has exactly two albums in the seed data. `max` is
    // nested (docs/decisions/0013-graphql-type-system.md's Gate 2), not
    // milestone 2's `max(column: "album_id")`.
    const query = try pg_gql.graphql_parser.parseToIr(
        query_arena.allocator(),
        \\{ album_aggregate(where: {artist_id: {_eq: 1}}) { total: count max { highest: album_id } } }
    ,
        &schema_model,
    );

    var parsed = try pg_gql.executor.run(allocator, conn, &query, &schema_model);
    defer parsed.deinit();

    const row_set = parsed.value.array.items[0].object;
    try std.testing.expect(row_set.get("rows") == null); // no display fields requested
    const aggregates = row_set.get("aggregates").?.object;
    try std.testing.expectEqual(@as(i64, 2), aggregates.get("total").?.integer);
    // The flat NDC key is "<function>.<column response key>" -- album_id is a
    // serial PK; the higher of AC/DC's two albums' ids.
    try std.testing.expect(aggregates.get("max.highest").?.integer > 0);
}
