const std = @import("std");
const pg_gql = @import("pg_gql");

fn buildEquivalentQuery(allocator: std.mem.Allocator, schema_model: *const pg_gql.schema.SchemaModel) !pg_gql.ndc_ir.Query {
    // Deliberately the same query as graphql_query_test.zig's GraphQL text:
    // `{ album(where: {artist_id: {_eq: 1}}, order_by: [{title: asc}]) { title artist { name } } }`
    var nested_builder = pg_gql.query_builder.Builder.init(allocator, "artist");
    try nested_builder.select("name");

    var builder = pg_gql.query_builder.Builder.init(allocator, "album");
    try builder.select("title");
    try builder.selectRelationship(
        "artist",
        "artist",
        nested_builder.build(),
        schema_model.relationships.get("album").?.get("artist").?,
    );
    builder.where(pg_gql.query_builder.column("artist_id").eq(1));
    try builder.orderBy(&.{pg_gql.query_builder.column("title").asc()});

    const query = builder.build();
    try pg_gql.query_builder.validate(&query, schema_model);
    return query;
}

test "query-builder query with where/order_by/relationship returns the correct nested RowSet JSON" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const query = try buildEquivalentQuery(query_arena.allocator(), &schema_model);

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
    try std.testing.expectEqualStrings("AC/DC", first.get("artist").?.object.get("rows").?.array.items[0].object.get("name").?.string);
}

// The flagship producer-equivalence proof: unlike src/pg_gql.zig's unit test
// (which compares rendered SQL text -- fast, no DB needed), this proves
// equivalence through actual execution against real Postgres, comparing the
// two paths' re-serialized JSON output byte-for-byte. Field order surviving
// the round trip depends on ndc_ir.FieldSelection's insertion-order
// preservation (see docs/architecture.md) propagating all the way through
// sql_gen's generated SELECT list, Postgres's row_to_json, and back.
test "GraphQL-path and query-builder-path produce byte-identical JSON when executed against real Postgres" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const qa = query_arena.allocator();

    const graphql_query = try pg_gql.graphql_parser.parseToIr(
        qa,
        \\{ album(where: {artist_id: {_eq: 1}}, order_by: [{title: asc}]) { title artist { name } } }
    ,
        &schema_model,
    );
    const builder_query = try buildEquivalentQuery(qa, &schema_model);

    var graphql_result = try pg_gql.executor.run(allocator, conn, &graphql_query, &schema_model);
    defer graphql_result.deinit();
    var builder_result = try pg_gql.executor.run(allocator, conn, &builder_query, &schema_model);
    defer builder_result.deinit();

    const graphql_text = try std.json.Stringify.valueAlloc(allocator, graphql_result.value, .{});
    defer allocator.free(graphql_text);
    const builder_text = try std.json.Stringify.valueAlloc(allocator, builder_result.value, .{});
    defer allocator.free(builder_text);

    try std.testing.expectEqualStrings(graphql_text, builder_text);
}

// Extends the flagship equivalence proof to milestone 2's newer features
// (exists + aggregates together), not just relationships/where/order_by.
test "GraphQL-path and query-builder-path produce byte-identical JSON for an exists+aggregate query" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const qa = query_arena.allocator();

    const graphql_query = try pg_gql.graphql_parser.parseToIr(
        qa,
        \\{ album_aggregate(where: {artist: {name: {_eq: "AC/DC"}}}) { total: count } }
    ,
        &schema_model,
    );

    var builder = pg_gql.query_builder.Builder.init(qa, "album");
    try builder.registerRelationship("artist", schema_model.relationships.get("album").?.get("artist").?);
    builder.where(try pg_gql.query_builder.exists(qa, "artist", pg_gql.query_builder.column("name").eq("AC/DC")));
    try builder.aggregate("total", .star_count);
    const builder_query = builder.build();
    try pg_gql.query_builder.validate(&builder_query, &schema_model);

    var graphql_result = try pg_gql.executor.run(allocator, conn, &graphql_query, &schema_model);
    defer graphql_result.deinit();
    var builder_result = try pg_gql.executor.run(allocator, conn, &builder_query, &schema_model);
    defer builder_result.deinit();

    const graphql_text = try std.json.Stringify.valueAlloc(allocator, graphql_result.value, .{});
    defer allocator.free(graphql_text);
    const builder_text = try std.json.Stringify.valueAlloc(allocator, builder_result.value, .{});
    defer allocator.free(builder_text);

    try std.testing.expectEqualStrings(graphql_text, builder_text);
    try std.testing.expectEqual(@as(i64, 2), graphql_result.value.array.items[0].object.get("aggregates").?.object.get("total").?.integer);
}

// M4.2 checkpoint (docs/decisions/0013-graphql-type-system.md's Gate 2): the
// nested `max { ... }` GraphQL syntax must still produce byte-identical NDC
// output to an equivalent query-builder aggregate -- sql_gen/ir_to_sql never
// changed, only the GraphQL producer's lowering of the aggregate shape.
test "GraphQL-path's nested max{} syntax and query-builder-path produce byte-identical JSON" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const qa = query_arena.allocator();

    const graphql_query = try pg_gql.graphql_parser.parseToIr(
        qa,
        \\{ album_aggregate(where: {artist_id: {_eq: 1}}) { max { highest: album_id } } }
    ,
        &schema_model,
    );

    var builder = pg_gql.query_builder.Builder.init(qa, "album");
    builder.where(pg_gql.query_builder.column("artist_id").eq(1));
    // The query-builder producer isn't GraphQL-shaped -- it registers the
    // aggregate directly under the same flat key the GraphQL lowering
    // synthesizes ("<function>.<response key>"), proving both producers reach
    // the identical flat NDC entry regardless of surface syntax.
    try builder.aggregate("max.highest", .{ .single_column = .{ .column = "album_id", .function = .max } });
    const builder_query = builder.build();
    try pg_gql.query_builder.validate(&builder_query, &schema_model);

    var graphql_result = try pg_gql.executor.run(allocator, conn, &graphql_query, &schema_model);
    defer graphql_result.deinit();
    var builder_result = try pg_gql.executor.run(allocator, conn, &builder_query, &schema_model);
    defer builder_result.deinit();

    const graphql_text = try std.json.Stringify.valueAlloc(allocator, graphql_result.value, .{});
    defer allocator.free(graphql_text);
    const builder_text = try std.json.Stringify.valueAlloc(allocator, builder_result.value, .{});
    defer allocator.free(builder_text);

    try std.testing.expectEqualStrings(graphql_text, builder_text);
    try std.testing.expect(graphql_result.value.array.items[0].object.get("aggregates").?.object.get("max.highest").?.integer > 0);
}

// Query variables/batching (docs/decisions/0009-query-variables.md): SQL is
// rendered once and re-executed per variable set on the same connection --
// exercised here via the query-builder producer, per the plan's note that
// variables are a builder/NDC-JSON-producer feature in milestone 2 (the
// GraphQL text producer has no request-level `$variable` syntax yet).
test "runWithVariables executes the same rendered query once per variable set" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const qa = query_arena.allocator();

    var builder = pg_gql.query_builder.Builder.init(qa, "album");
    try builder.select("title");
    builder.where(pg_gql.query_builder.column("artist_id").eqVar("target_artist_id"));
    try builder.orderBy(&.{pg_gql.query_builder.column("title").asc()});
    const query = builder.build();
    try pg_gql.query_builder.validate(&query, &schema_model);

    var set_1: pg_gql.ndc_ir.VariableSet = .{};
    try set_1.put(qa, "target_artist_id", .{ .integer = 1 });
    var set_2: pg_gql.ndc_ir.VariableSet = .{};
    try set_2.put(qa, "target_artist_id", .{ .integer = 2 });
    var set_3: pg_gql.ndc_ir.VariableSet = .{};
    try set_3.put(qa, "target_artist_id", .{ .integer = 999 });

    var parsed = try pg_gql.executor.runWithVariables(allocator, conn, &query, &schema_model, &.{ set_1, set_2, set_3 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);

    const first_rows = parsed.value.array.items[0].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 2), first_rows.items.len);
    try std.testing.expectEqualStrings("For Those About To Rock We Salute You", first_rows.items[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("Let There Be Rock", first_rows.items[1].object.get("title").?.string);

    const second_rows = parsed.value.array.items[1].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 1), second_rows.items.len);
    try std.testing.expectEqualStrings("Balls to the Wall", second_rows.items[0].object.get("title").?.string);

    const third_rows = parsed.value.array.items[2].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 0), third_rows.items.len);
}

// `_in` with a variable binds the whole array as one `= ANY($N)` parameter
// (Postgres array-literal encoding, executor/pg_array.zig) -- the milestone 2
// deferral lifted by libpq (ADRs 0009/0016). The hostile-string set proves
// the array-literal escaping end-to-end: elements containing quotes, commas,
// braces, and backslashes must neither error, nor corrupt the match for the
// legitimate element travelling in the same array.
test "runWithVariables binds an _in variable as one array parameter" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const qa = query_arena.allocator();

    var builder = pg_gql.query_builder.Builder.init(qa, "album");
    try builder.select("title");
    builder.where(pg_gql.query_builder.column("title").inVar("titles"));
    try builder.orderBy(&.{pg_gql.query_builder.column("title").asc()});
    const query = builder.build();
    try pg_gql.query_builder.validate(&query, &schema_model);

    // Set 1: two matches among the three seeded albums.
    var titles_1 = std.json.Array.init(qa);
    try titles_1.append(.{ .string = "Balls to the Wall" });
    try titles_1.append(.{ .string = "Let There Be Rock" });
    var set_1: pg_gql.ndc_ir.VariableSet = .{};
    try set_1.put(qa, "titles", .{ .array = titles_1 });

    // Set 2: one legitimate match travelling with hostile elements and a
    // JSON null (SQL `= ANY` never matches NULL, it must simply not error).
    var titles_2 = std.json.Array.init(qa);
    try titles_2.append(.{ .string = "Let There Be Rock" });
    try titles_2.append(.{ .string = "say \"hi\", {brace}" });
    try titles_2.append(.{ .string = "C:\\path\\" });
    try titles_2.append(.null);
    var set_2: pg_gql.ndc_ir.VariableSet = .{};
    try set_2.put(qa, "titles", .{ .array = titles_2 });

    // Set 3: the empty array matches nothing and must not error.
    var set_3: pg_gql.ndc_ir.VariableSet = .{};
    try set_3.put(qa, "titles", .{ .array = std.json.Array.init(qa) });

    var parsed = try pg_gql.executor.runWithVariables(allocator, conn, &query, &schema_model, &.{ set_1, set_2, set_3 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);

    const first_rows = parsed.value.array.items[0].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 2), first_rows.items.len);
    try std.testing.expectEqualStrings("Balls to the Wall", first_rows.items[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("Let There Be Rock", first_rows.items[1].object.get("title").?.string);

    const second_rows = parsed.value.array.items[1].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 1), second_rows.items.len);
    try std.testing.expectEqualStrings("Let There Be Rock", second_rows.items[0].object.get("title").?.string);

    const third_rows = parsed.value.array.items[2].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 0), third_rows.items.len);
}

// Same mechanism against an integer column: Postgres infers the parameter's
// array type from the compared column (`album_id = ANY($1)` makes $1 an
// int array), so the text literal `{"2","3"}` must coerce cleanly.
test "runWithVariables binds an _in variable against an integer column" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    });
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const qa = query_arena.allocator();

    var builder = pg_gql.query_builder.Builder.init(qa, "album");
    try builder.select("album_id");
    builder.where(pg_gql.query_builder.column("album_id").inVar("ids"));
    try builder.orderBy(&.{pg_gql.query_builder.column("album_id").asc()});
    const query = builder.build();
    try pg_gql.query_builder.validate(&query, &schema_model);

    var ids = std.json.Array.init(qa);
    try ids.append(.{ .integer = 2 });
    try ids.append(.{ .integer = 3 });
    try ids.append(.{ .integer = 999 });
    var set: pg_gql.ndc_ir.VariableSet = .{};
    try set.put(qa, "ids", .{ .array = ids });

    var parsed = try pg_gql.executor.runWithVariables(allocator, conn, &query, &schema_model, &.{set});
    defer parsed.deinit();

    const rows = parsed.value.array.items[0].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqual(@as(i64, 2), rows.items[0].object.get("album_id").?.integer);
    try std.testing.expectEqual(@as(i64, 3), rows.items[1].object.get("album_id").?.integer);
}
