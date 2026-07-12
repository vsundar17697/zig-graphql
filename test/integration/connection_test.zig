//! Connection-lifecycle integration tests (roadmap-v1.md milestone 6):
//! statement timeouts, cross-thread cancellation, and unnamed prepared
//! statements, all against the real fixture database.

const std = @import("std");
const pg_gql = @import("pg_gql");
const fixture = @import("fixture.zig");


test "statement_timeout turns a runaway query into a reusable ServerError" {
    const allocator = std.testing.allocator;

    var options = fixture.options();
    options.statement_timeout_ms = 50;
    const conn = try pg_gql.pg_wire.Connection.connect(allocator, options);
    defer conn.close();

    try std.testing.expectError(
        pg_gql.pg_wire.Error.ServerError,
        conn.query("SELECT pg_sleep(5)", &.{}),
    );

    // ServerError, not ConnectionLost: the connection must stay usable.
    var result = try conn.query("SELECT 1 AS one", &.{});
    defer result.deinit();
    try std.testing.expectEqualStrings("1", result.rows[0].columns[0].?);
}

test "cancel from another thread aborts a blocked query as ServerError" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, fixture.options());
    defer conn.close();

    const canceller = try std.Thread.spawn(.{}, struct {
        fn run(target: *pg_gql.pg_wire.Connection) void {
            var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
            const io = threaded.io();
            // Give the main thread time to get pg_sleep onto the wire; a
            // cancel landing before the statement starts is a no-op and the
            // test would then hang for the full sleep.
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake) catch {};
            target.cancel();
        }
    }.run, .{conn});

    try std.testing.expectError(
        pg_gql.pg_wire.Error.ServerError,
        conn.query("SELECT pg_sleep(30)", &.{}),
    );
    canceller.join();

    var result = try conn.query("SELECT 2 AS two", &.{});
    defer result.deinit();
    try std.testing.expectEqualStrings("2", result.rows[0].columns[0].?);
}

test "an unnamed prepared statement executes repeatedly with different params" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, fixture.options());
    defer conn.close();

    const prepared = try conn.prepare("SELECT $1::int + 1 AS v");

    var first = try prepared.query(&.{.{ .text = "1" }});
    defer first.deinit();
    try std.testing.expectEqualStrings("2", first.rows[0].columns[0].?);

    var second = try prepared.query(&.{.{ .text = "41" }});
    defer second.deinit();
    try std.testing.expectEqualStrings("42", second.rows[0].columns[0].?);
}

test "preparing invalid SQL is a ServerError and the connection survives" {
    const allocator = std.testing.allocator;

    const conn = try pg_gql.pg_wire.Connection.connect(allocator, fixture.options());
    defer conn.close();

    try std.testing.expectError(
        pg_gql.pg_wire.Error.ServerError,
        conn.prepare("SELECT FROM WHERE"),
    );

    var result = try conn.query("SELECT 3 AS three", &.{});
    defer result.deinit();
    try std.testing.expectEqualStrings("3", result.rows[0].columns[0].?);
}
