const std = @import("std");
const pg_gql = @import("pg_gql");
const fixture = @import("fixture.zig");

fn insertOperation(allocator: std.mem.Allocator, title: []const u8, artist_id: i64) !pg_gql.ndc_ir.MutationOperation {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "title", .{ .string = title });
    try object.put(allocator, "artist_id", .{ .integer = artist_id });

    var arguments: pg_gql.ndc_ir.ArgumentMap = .{};
    try arguments.put(allocator, "object", .{ .object = object });

    var fields: pg_gql.ndc_ir.FieldSelection = .{};
    try fields.put(allocator, "album_id", .{ .column = .{ .column = "album_id" } });
    try fields.put(allocator, "title", .{ .column = .{ .column = "title" } });

    return .{ .name = "insert_album", .arguments = arguments, .fields = fields };
}

test "runMutation: insert_album returns affected_rows and the new row via returning" {
    const allocator = std.testing.allocator;
    const conn = try fixture.connect(allocator);
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var op_arena = std.heap.ArenaAllocator.init(allocator);
    defer op_arena.deinit();
    const oa = op_arena.allocator();

    const operation = try insertOperation(oa, "Back in Black", 1);
    const operations = try oa.dupe(pg_gql.ndc_ir.MutationOperation, &.{operation});
    const request = pg_gql.ndc_ir.MutationRequest{ .operations = operations };

    var parsed = try pg_gql.executor.runMutation(allocator, conn, &request, &schema_model);
    defer parsed.deinit();

    const results = parsed.value.object.get("operation_results").?.array;
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    const first = results.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), first.get("affected_rows").?.integer);
    const returning = first.get("returning").?.array;
    try std.testing.expectEqual(@as(usize, 1), returning.items.len);
    try std.testing.expectEqualStrings("Back in Black", returning.items[0].object.get("title").?.string);

    // Clean up -- other integration tests assert exact album counts for
    // artist_id 1 against the seed data; leaving this insert in place would
    // silently corrupt every test run after this one.
    const new_album_id = returning.items[0].object.get("album_id").?.integer;
    var cleanup_pk: std.json.ObjectMap = .empty;
    try cleanup_pk.put(oa, "album_id", .{ .integer = new_album_id });
    var cleanup_args: pg_gql.ndc_ir.ArgumentMap = .{};
    try cleanup_args.put(oa, "pk_columns", .{ .object = cleanup_pk });
    const cleanup_operations = try oa.dupe(pg_gql.ndc_ir.MutationOperation, &.{.{ .name = "delete_album_by_pk", .arguments = cleanup_args }});
    var cleanup_request = pg_gql.ndc_ir.MutationRequest{ .operations = cleanup_operations };
    var cleanup_result = try pg_gql.executor.runMutation(allocator, conn, &cleanup_request, &schema_model);
    cleanup_result.deinit();
}

test "runMutation: update_album_by_pk changes the row, delete_album_by_pk removes it" {
    const allocator = std.testing.allocator;
    const conn = try fixture.connect(allocator);
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var op_arena = std.heap.ArenaAllocator.init(allocator);
    defer op_arena.deinit();
    const oa = op_arena.allocator();

    // Insert a row to update/delete, capturing its generated album_id.
    const insert_op = try insertOperation(oa, "Highway to Hell", 1);
    const insert_operations = try oa.dupe(pg_gql.ndc_ir.MutationOperation, &.{insert_op});
    var insert_request = pg_gql.ndc_ir.MutationRequest{ .operations = insert_operations };
    var insert_result = try pg_gql.executor.runMutation(allocator, conn, &insert_request, &schema_model);
    defer insert_result.deinit();
    const album_id = insert_result.value.object.get("operation_results").?.array.items[0].object.get("returning").?.array.items[0].object.get("album_id").?.integer;

    // update_album_by_pk.
    var pk_obj: std.json.ObjectMap = .empty;
    try pk_obj.put(oa, "album_id", .{ .integer = album_id });
    var set_obj: std.json.ObjectMap = .empty;
    try set_obj.put(oa, "title", .{ .string = "Renamed Title" });
    var update_args: pg_gql.ndc_ir.ArgumentMap = .{};
    try update_args.put(oa, "pk_columns", .{ .object = pk_obj });
    try update_args.put(oa, "_set", .{ .object = set_obj });
    var update_fields: pg_gql.ndc_ir.FieldSelection = .{};
    try update_fields.put(oa, "title", .{ .column = .{ .column = "title" } });

    const update_operations = try oa.dupe(pg_gql.ndc_ir.MutationOperation, &.{.{ .name = "update_album_by_pk", .arguments = update_args, .fields = update_fields }});
    var update_request = pg_gql.ndc_ir.MutationRequest{ .operations = update_operations };
    var update_result = try pg_gql.executor.runMutation(allocator, conn, &update_request, &schema_model);
    defer update_result.deinit();

    const update_first = update_result.value.object.get("operation_results").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), update_first.get("affected_rows").?.integer);
    try std.testing.expectEqualStrings("Renamed Title", update_first.get("returning").?.array.items[0].object.get("title").?.string);

    // delete_album_by_pk.
    var delete_pk_obj: std.json.ObjectMap = .empty;
    try delete_pk_obj.put(oa, "album_id", .{ .integer = album_id });
    var delete_args: pg_gql.ndc_ir.ArgumentMap = .{};
    try delete_args.put(oa, "pk_columns", .{ .object = delete_pk_obj });

    const delete_operations = try oa.dupe(pg_gql.ndc_ir.MutationOperation, &.{.{ .name = "delete_album_by_pk", .arguments = delete_args }});
    var delete_request = pg_gql.ndc_ir.MutationRequest{ .operations = delete_operations };
    var delete_result = try pg_gql.executor.runMutation(allocator, conn, &delete_request, &schema_model);
    defer delete_result.deinit();
    try std.testing.expectEqual(@as(i64, 1), delete_result.value.object.get("operation_results").?.array.items[0].object.get("affected_rows").?.integer);

    // delete_album_by_pk on the now-nonexistent row is a normal affected_rows: 0, not an error.
    const redelete_operations = try oa.dupe(pg_gql.ndc_ir.MutationOperation, &.{.{ .name = "delete_album_by_pk", .arguments = delete_args }});
    var redelete_request = pg_gql.ndc_ir.MutationRequest{ .operations = redelete_operations };
    var redelete_result = try pg_gql.executor.runMutation(allocator, conn, &redelete_request, &schema_model);
    defer redelete_result.deinit();
    try std.testing.expectEqual(@as(i64, 0), redelete_result.value.object.get("operation_results").?.array.items[0].object.get("affected_rows").?.integer);
}

// The correctness point docs/decisions/0011-mutation-transactions.md exists
// for: a multi-operation request is all-or-nothing, AND the connection must
// remain fully usable afterward (proving the pg_wire protocol-resync fix --
// without it, every query after this test's failed transaction would
// desynchronize and start returning wrong results).
test "runMutation: a transaction with a later FK violation rolls back the earlier operation, and the connection stays usable" {
    const allocator = std.testing.allocator;
    const conn = try fixture.connect(allocator);
    defer conn.close();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(schema_arena.allocator(), conn);

    var op_arena = std.heap.ArenaAllocator.init(allocator);
    defer op_arena.deinit();
    const oa = op_arena.allocator();

    const good_op = try insertOperation(oa, "Should Be Rolled Back", 1);
    const bad_op = try insertOperation(oa, "Never Committed", 999999); // no artist 999999 -- FK violation

    const operations = try oa.dupe(pg_gql.ndc_ir.MutationOperation, &.{ good_op, bad_op });
    const request = pg_gql.ndc_ir.MutationRequest{ .operations = operations };

    const result = pg_gql.executor.runMutation(allocator, conn, &request, &schema_model);
    try std.testing.expectError(pg_gql.pg_wire.Error.ServerError, result);

    // The first (otherwise valid) operation must not have been committed.
    var check_arena = std.heap.ArenaAllocator.init(allocator);
    defer check_arena.deinit();
    var builder = pg_gql.query_builder.Builder.init(check_arena.allocator(), "album");
    try builder.select("album_id");
    builder.where(pg_gql.query_builder.column("title").eq("Should Be Rolled Back"));
    const check_query = builder.build();

    var check_result = try pg_gql.executor.run(allocator, conn, &check_query, &schema_model);
    defer check_result.deinit();
    const rows = check_result.value.array.items[0].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 0), rows.items.len);

    // The connection must still be protocol-synced: an ordinary query right
    // after the failed transaction must succeed and return correct data.
    var sanity_arena = std.heap.ArenaAllocator.init(allocator);
    defer sanity_arena.deinit();
    var sanity_builder = pg_gql.query_builder.Builder.init(sanity_arena.allocator(), "artist");
    try sanity_builder.select("name");
    sanity_builder.where(pg_gql.query_builder.column("artist_id").eq(1));
    const sanity_query = sanity_builder.build();

    var sanity_result = try pg_gql.executor.run(allocator, conn, &sanity_query, &schema_model);
    defer sanity_result.deinit();
    const sanity_rows = sanity_result.value.array.items[0].object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 1), sanity_rows.items.len);
    try std.testing.expectEqualStrings("AC/DC", sanity_rows.items[0].object.get("name").?.string);
}
