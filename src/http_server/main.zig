//! pg-gql-server: exposes the NDC HTTP surface (GET /capabilities, GET /schema,
//! POST /query, POST /mutation) and the GraphQL-client-compatible POST /graphql.
//!
//! Connects to Postgres through a fixed-size connection pool (see
//! docs/decisions/0015-connection-pool.md) and introspects the schema once at
//! startup through one leased connection; `SchemaModel`/`TypeSystem` are then
//! shared read-only across every request and every pooled connection. Each
//! accepted connection is handled on its own OS thread (see the same ADR for
//! why a pool needs this to have any effect at all).

const std = @import("std");
const pg_gql = @import("pg_gql");
const routes = @import("routes.zig");

fn getEnvOrDefault(allocator: std.mem.Allocator, name: [*:0]const u8, default: []const u8) ![]const u8 {
    if (std.c.getenv(name)) |value| return allocator.dupe(u8, std.mem.span(value));
    return allocator.dupe(u8, default);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const db_host = try getEnvOrDefault(allocator, "PG_GQL_DB_HOST", "127.0.0.1");
    defer allocator.free(db_host);
    const db_port_str = try getEnvOrDefault(allocator, "PG_GQL_DB_PORT", "55432");
    defer allocator.free(db_port_str);
    const db_user = try getEnvOrDefault(allocator, "PG_GQL_DB_USER", "pggql");
    defer allocator.free(db_user);
    const db_password = try getEnvOrDefault(allocator, "PG_GQL_DB_PASSWORD", "");
    defer allocator.free(db_password);
    const db_name = try getEnvOrDefault(allocator, "PG_GQL_DB_NAME", "pggql");
    defer allocator.free(db_name);
    const listen_port_str = try getEnvOrDefault(allocator, "PG_GQL_LISTEN_PORT", "8080");
    defer allocator.free(listen_port_str);
    const pool_size_str = try getEnvOrDefault(allocator, "PG_GQL_POOL_SIZE", "5");
    defer allocator.free(pool_size_str);

    const db_port = try std.fmt.parseInt(u16, db_port_str, 10);
    const listen_port = try std.fmt.parseInt(u16, listen_port_str, 10);
    const pool_size = try std.fmt.parseInt(usize, pool_size_str, 10);

    const db_options = pg_gql.pg_wire.Connection.Options{
        .host = db_host,
        .port = db_port,
        .user = db_user,
        .password = db_password,
        .database = db_name,
    };

    var pool = pg_gql.pg_wire.Pool.init(allocator, db_options, pool_size);
    defer pool.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    const io = threaded.io();

    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();

    const schema_model = blk: {
        var lease = try pool.acquire(io);
        defer lease.release(io);
        break :blk try pg_gql.executor.introspectLive(schema_arena.allocator(), lease.conn);
    };
    std.log.info("introspected {d} collection(s)", .{schema_model.collections.count()});

    // Built once at startup, alongside the schema -- never per request (see
    // docs/decisions/0013-graphql-type-system.md).
    const type_system = try pg_gql.graphql_schema.buildTypeSystem(schema_arena.allocator(), &schema_model);

    const ctx = routes.ServerContext{
        .pool = &pool,
        .schema_model = &schema_model,
        .type_system = &type_system,
    };

    const bind_addr = try std.Io.net.IpAddress.parse("0.0.0.0", listen_port);
    var server = try std.Io.net.IpAddress.listen(&bind_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("pg-gql-server listening on :{d} (pool size {d})", .{ listen_port, pool_size });

    while (true) {
        const client_stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };

        // One OS thread per connection -- a pool of database connections has
        // no observable effect on a server that only ever handles one HTTP
        // connection at a time (see docs/decisions/0015-connection-pool.md).
        // Each thread gets its own `std.Io.Threaded` instance rather than
        // sharing the accept loop's, since `std.Io.Threaded` coordinates its
        // own internal worker pool and nothing documents it as safe to drive
        // concurrently from arbitrary external OS threads.
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ allocator, client_stream, &ctx }) catch |err| {
            std.log.err("failed to spawn connection thread: {t}", .{err});
            client_stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnectionThread(allocator: std.mem.Allocator, stream: std.Io.net.Stream, ctx: *const routes.ServerContext) void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    const io = threaded.io();
    defer stream.close(io);

    handleConnection(allocator, io, stream, ctx) catch |err| {
        if (err != error.HttpConnectionClosing) std.log.err("request handling failed: {t}", .{err});
    };
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    ctx: *const routes.ServerContext,
) !void {
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try http_server.receiveHead();
    try routes.handle(allocator, io, &request, ctx);
}

// `main()`'s body (where `routes` is actually referenced) isn't analyzed by
// the test runner, so without this, routes.zig -- and transitively
// ndc_request.zig/schema_json.zig -- would never be analyzed and their test
// blocks would silently never run. Same pattern as every other root.zig in
// this codebase (see e.g. graphql_parser/root.zig).
test {
    std.testing.refAllDecls(@This());
    _ = routes;
}
