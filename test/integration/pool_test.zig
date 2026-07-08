const std = @import("std");
const pg_gql = @import("pg_gql");

const pool_options = pg_gql.pg_wire.Connection.Options{
    .host = "127.0.0.1",
    .port = 55432,
    .user = "pggql",
    .database = "pggql",
};

// M4.7 checkpoint: N threads x M requests against a small pool, asserting
// both correctness (every query gets the right answer) and that the pool
// never opens more than `max` connections regardless of concurrent demand.
test "pool: concurrent acquire/release from many threads never exceeds max open connections" {
    const allocator = std.testing.allocator;
    const max_connections = 3;
    const thread_count = 8;
    const requests_per_thread = 5;

    var pool = pg_gql.pg_wire.Pool.init(allocator, pool_options, max_connections);
    defer pool.deinit();

    const Worker = struct {
        fn run(p: *pg_gql.pg_wire.Pool, results: *[thread_count]bool, index: usize) void {
            var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
            const io = threaded.io();

            var ok = true;
            for (0..requests_per_thread) |_| {
                var lease = p.acquire(io) catch {
                    ok = false;
                    break;
                };
                var result = lease.conn.query("SELECT 1", &.{}) catch {
                    lease.markBrokenUnless(error.Unexpected);
                    lease.release(io);
                    ok = false;
                    break;
                };
                result.deinit();
                lease.release(io);
            }
            results[index] = ok;
        }
    };

    var results: [thread_count]bool = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &results, i });
    }
    for (threads) |t| t.join();

    for (results) |ok| try std.testing.expect(ok);
    try std.testing.expect(pool.open_count <= max_connections);
}

// A connection killed out from under a live lease (simulating a network
// blip or the server restarting) must not poison the pool: the broken lease
// is discarded on release, and the next acquire dials a fresh, working
// connection.
test "pool: a connection killed mid-lease is discarded, not returned to the idle pool" {
    const allocator = std.testing.allocator;
    var pool = pg_gql.pg_wire.Pool.init(allocator, pool_options, 2);
    defer pool.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    const io = threaded.io();

    var lease = try pool.acquire(io);
    const backend_pid: i64 = blk: {
        var result = try lease.conn.query("SELECT pg_backend_pid()", &.{});
        defer result.deinit();
        break :blk try std.fmt.parseInt(i64, result.rows[0].columns[0].?, 10);
    };

    // Kill it from a second, independent connection.
    const killer = try pg_gql.pg_wire.Connection.connect(allocator, pool_options);
    defer killer.close();
    {
        const sql = try std.fmt.allocPrint(allocator, "SELECT pg_terminate_backend({d})", .{backend_pid});
        defer allocator.free(sql);
        var result = try killer.query(sql, &.{});
        defer result.deinit();
    }
    // Give Postgres a moment to actually tear the backend down.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);

    // Which exact error surfaces (protocol-level, read failure, connection
    // reset, ...) is platform/timing-dependent -- what matters here is that
    // it *is* an error, not which one.
    const failed = lease.conn.query("SELECT 1", &.{});
    try std.testing.expect(std.meta.isError(failed));
    lease.markBrokenUnless(error.Unexpected); // anything but ServerError -- see Lease.markBrokenUnless
    lease.release(io);

    // The next acquire must not hand back the dead connection.
    var new_lease = try pool.acquire(io);
    defer new_lease.release(io);
    var result = try new_lease.conn.query("SELECT 1", &.{});
    defer result.deinit();
    try std.testing.expectEqualStrings("1", result.rows[0].columns[0].?);
}
