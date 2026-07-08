//! extern "C" surface for embedding pg-gql from other languages (see
//! docs/architecture.md: c_abi is a consumer, not a participant -- it adds no
//! behavior beyond adapting the core to a C-compatible interface).
//!
//! Memory model: every `pg_gql_*_free_*` function must be called exactly once
//! per successful handle-returning call. Each handle owns an arena sized to
//! its own lifetime (a connection, a schema, one query result), so freeing it
//! is O(1) regardless of how much was allocated inside. C callers never touch
//! Zig allocators directly.
//!
//! Error reporting: C has no error unions, so every handle-returning function
//! returns `null` on failure; `pg_gql_last_error()` returns a thread-local
//! message describing the most recent failure on the calling thread.

const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");
const pg_wire = @import("pg_wire");
const graphql_parser = @import("graphql_parser");
const executor = @import("executor");

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], fmt, args) catch blk: {
        const truncated = "error message too long";
        @memcpy(last_error_buf[0..truncated.len], truncated);
        break :blk last_error_buf[0..truncated.len];
    };
    last_error_len = msg.len;
}

export fn pg_gql_last_error() [*:0]const u8 {
    last_error_buf[last_error_len] = 0;
    return @ptrCast(&last_error_buf);
}

pub const PgGqlConnection = struct {
    conn: *pg_wire.Connection,
};

export fn pg_gql_connect(
    host: [*:0]const u8,
    port: u16,
    user: [*:0]const u8,
    password: [*:0]const u8,
    database: [*:0]const u8,
) ?*PgGqlConnection {
    const allocator = std.heap.c_allocator;
    const conn = pg_wire.Connection.connect(allocator, .{
        .host = std.mem.span(host),
        .port = port,
        .user = std.mem.span(user),
        .password = std.mem.span(password),
        .database = std.mem.span(database),
    }) catch |err| {
        setLastError("connect failed: {t}", .{err});
        return null;
    };

    const handle = allocator.create(PgGqlConnection) catch {
        conn.close();
        setLastError("out of memory allocating connection handle", .{});
        return null;
    };
    handle.* = .{ .conn = conn };
    return handle;
}

export fn pg_gql_close(handle: *PgGqlConnection) void {
    handle.conn.close();
    std.heap.c_allocator.destroy(handle);
}

pub const PgGqlSchema = struct {
    arena: std.heap.ArenaAllocator,
    model: schema.SchemaModel,
};

export fn pg_gql_introspect_schema(handle: *PgGqlConnection) ?*PgGqlSchema {
    const allocator = std.heap.c_allocator;
    const schema_handle = allocator.create(PgGqlSchema) catch {
        setLastError("out of memory allocating schema handle", .{});
        return null;
    };
    schema_handle.arena = std.heap.ArenaAllocator.init(allocator);
    schema_handle.model = executor.introspectLive(schema_handle.arena.allocator(), handle.conn) catch |err| {
        setLastError("schema introspection failed: {t}", .{err});
        schema_handle.arena.deinit();
        allocator.destroy(schema_handle);
        return null;
    };
    return schema_handle;
}

export fn pg_gql_free_schema(handle: *PgGqlSchema) void {
    handle.arena.deinit();
    std.heap.c_allocator.destroy(handle);
}

pub const PgGqlQueryResult = struct {
    parsed: std.json.Parsed(std.json.Value),
    /// Lazily rendered on first `pg_gql_result_json` call and cached here,
    /// since C callers want a JSON string, not a parsed std.json.Value tree.
    json_text: ?[:0]u8 = null,
};

export fn pg_gql_query_graphql(
    conn_handle: *PgGqlConnection,
    schema_handle: *PgGqlSchema,
    query_text: [*:0]const u8,
) ?*PgGqlQueryResult {
    const allocator = std.heap.c_allocator;

    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();

    const query = graphql_parser.parseToIr(query_arena.allocator(), std.mem.span(query_text), &schema_handle.model) catch |err| {
        setLastError("GraphQL parse/lower failed: {t}", .{err});
        return null;
    };

    const parsed = executor.run(allocator, conn_handle.conn, &query, &schema_handle.model) catch |err| {
        setLastError("query execution failed: {t}", .{err});
        return null;
    };

    const result_handle = allocator.create(PgGqlQueryResult) catch {
        setLastError("out of memory allocating result handle", .{});
        return null;
    };
    result_handle.* = .{ .parsed = parsed };
    return result_handle;
}

export fn pg_gql_result_json(handle: *PgGqlQueryResult) ?[*:0]const u8 {
    if (handle.json_text == null) {
        const allocator = std.heap.c_allocator;
        const text = std.json.Stringify.valueAlloc(allocator, handle.parsed.value, .{}) catch |err| {
            setLastError("failed to serialize result: {t}", .{err});
            return null;
        };
        const z_text = allocator.allocSentinel(u8, text.len, 0) catch {
            allocator.free(text);
            setLastError("out of memory serializing result", .{});
            return null;
        };
        @memcpy(z_text, text);
        allocator.free(text);
        handle.json_text = z_text;
    }
    return handle.json_text.?.ptr;
}

export fn pg_gql_free_result(handle: *PgGqlQueryResult) void {
    const allocator = std.heap.c_allocator;
    if (handle.json_text) |text| allocator.free(text);
    handle.parsed.deinit();
    allocator.destroy(handle);
}

test "module compiles" {
    try std.testing.expect(true);
}
