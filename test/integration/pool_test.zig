const std = @import("std");
const pg_gql = @import("pg_gql");
const fixture = @import("fixture.zig");


// M4.7 checkpoint: N threads x M requests against a small pool, asserting
// both correctness (every query gets the right answer) and that the pool
// never opens more than `max` connections regardless of concurrent demand.
test "pool: concurrent acquire/release from many threads never exceeds max open connections" {
    const allocator = std.testing.allocator;
    const max_connections = 3;
    const thread_count = 8;
    const requests_per_thread = 5;

    var pool = pg_gql.pg_wire.Pool.init(allocator, fixture.options(), max_connections);
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
    var pool = pg_gql.pg_wire.Pool.init(allocator, fixture.options(), 2);
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
    const killer = try pg_gql.pg_wire.Connection.connect(allocator, fixture.options());
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

// Milestone 6 exit criterion, the "kill the database mid-query" test: the
// backend dies while a query is actually in flight (not between queries,
// which the mid-lease test above covers). The blocked query must come back
// as an error -- promptly, not by hanging until some timeout -- and the pool
// must hand out a working connection afterwards.
test "pool: a backend killed mid-query fails the in-flight query and the pool recovers" {
    const allocator = std.testing.allocator;
    var pool = pg_gql.pg_wire.Pool.init(allocator, fixture.options(), 2);
    defer pool.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    const io = threaded.io();

    var lease = try pool.acquire(io);
    const backend_pid: i64 = blk: {
        var result = try lease.conn.query("SELECT pg_backend_pid()", &.{});
        defer result.deinit();
        break :blk try std.fmt.parseInt(i64, result.rows[0].columns[0].?, 10);
    };

    // The victim query blocks server-side; run it on its own thread so this
    // thread can pull the rug out from under it.
    const Victim = struct {
        fn run(conn: *pg_gql.pg_wire.Connection, failed: *bool) void {
            const result = conn.query("SELECT pg_sleep(30)", &.{});
            failed.* = std.meta.isError(result);
            if (result) |*r| @constCast(r).deinit() else |_| {}
        }
    };
    var query_failed = false;
    const victim = try std.Thread.spawn(.{}, Victim.run, .{ lease.conn, &query_failed });

    // Let the query reach the server before terminating its backend.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake);
    const killer = try pg_gql.pg_wire.Connection.connect(allocator, fixture.options());
    defer killer.close();
    {
        const sql = try std.fmt.allocPrint(allocator, "SELECT pg_terminate_backend({d})", .{backend_pid});
        defer allocator.free(sql);
        var result = try killer.query(sql, &.{});
        defer result.deinit();
    }

    // join() doubles as the no-hang assertion: if the client never notices
    // the dead backend, the 30s pg_sleep (not any client logic) is what
    // eventually unblocks this, and the test times out loudly.
    victim.join();
    try std.testing.expect(query_failed);

    lease.markBrokenUnless(error.Unexpected);
    lease.release(io);

    // The pool must recover: fresh acquire, working connection.
    var new_lease = try pool.acquire(io);
    defer new_lease.release(io);
    var result = try new_lease.conn.query("SELECT 1", &.{});
    defer result.deinit();
    try std.testing.expectEqualStrings("1", result.rows[0].columns[0].?);
}

// Milestone 6 staleness policy: a connection past max_lifetime_ms is
// recycled on acquire even though it is perfectly healthy -- proven by the
// backend PID changing across a release/acquire pair.
test "pool: max-lifetime recycling dials a fresh connection on acquire" {
    const allocator = std.testing.allocator;
    var pool = pg_gql.pg_wire.Pool.init(allocator, fixture.options(), 1);
    defer pool.deinit();
    pool.max_lifetime_ms = -1; // every connection is instantly "too old"

    var threaded: std.Io.Threaded = .init(allocator, .{});
    const io = threaded.io();

    var lease_1 = try pool.acquire(io);
    const pid_1 = try backendPid(lease_1.conn);
    lease_1.release(io);

    var lease_2 = try pool.acquire(io);
    defer lease_2.release(io);
    const pid_2 = try backendPid(lease_2.conn);

    try std.testing.expect(pid_1 != pid_2);
    try std.testing.expect(pool.open_count <= 1);
}

// Milestone 6 staleness policy: an idle connection whose backend died is
// caught by the validate-on-acquire ping and replaced transparently -- the
// caller sees a working connection, never the dead one. (Contrast with the
// mid-lease kill test above, where the *caller* owns the failure; here the
// death happens while the pool holds the connection.)
test "pool: a dead idle connection is caught by validation and replaced on acquire" {
    const allocator = std.testing.allocator;
    var pool = pg_gql.pg_wire.Pool.init(allocator, fixture.options(), 1);
    defer pool.deinit();
    pool.validate_after_idle_ms = -1; // ping on every acquire

    var threaded: std.Io.Threaded = .init(allocator, .{});
    const io = threaded.io();

    var lease_1 = try pool.acquire(io);
    const pid_1 = try backendPid(lease_1.conn);
    lease_1.release(io);

    // Kill the idle connection's backend from an independent connection.
    const killer = try pg_gql.pg_wire.Connection.connect(allocator, fixture.options());
    defer killer.close();
    {
        const sql = try std.fmt.allocPrint(allocator, "SELECT pg_terminate_backend({d})", .{pid_1});
        defer allocator.free(sql);
        var result = try killer.query(sql, &.{});
        defer result.deinit();
    }
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);

    var lease_2 = try pool.acquire(io);
    defer lease_2.release(io);
    const pid_2 = try backendPid(lease_2.conn);

    try std.testing.expect(pid_1 != pid_2);
    try std.testing.expect(pool.open_count <= 1);
}

fn backendPid(conn: *pg_gql.pg_wire.Connection) !i64 {
    var result = try conn.query("SELECT pg_backend_pid()", &.{});
    defer result.deinit();
    return std.fmt.parseInt(i64, result.rows[0].columns[0].?, 10);
}
