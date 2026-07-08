const std = @import("std");
const pg_gql = @import("pg_gql");
const ndc_request = @import("ndc_request.zig");
const schema_json = @import("schema_json.zig");
const graphql_route = @import("graphql_route.zig");

pub const ServerContext = graphql_route.ServerContext;

/// Capabilities document reflecting the connector's current feature set --
/// array relationships, exists, aggregates, and variables landed in
/// milestone 2 (see docs/roadmap.md); `mutation.transactional` is non-null as
/// of milestone 3 (see docs/decisions/0011-mutation-transactions.md: every
/// multi-operation MutationRequest runs as one all-or-nothing transaction).
const capabilities_json =
    \\{"query":{"variables":{},"aggregates":{},"explain":null,"exists":{"nested_collections":null,"named_scopes":null,"unrelated":{},"nested_scalar_collections":null},"nested_fields":{"filter_by":null,"order_by":null,"aggregates":null,"nested_collections":null}},"mutation":{"transactional":{},"explain":null},"relationships":{"relation_comparisons":{},"order_by_aggregate":null,"nested":null},"relational_query":null,"relational_mutation":null}
;

pub fn handle(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, ctx: *const ServerContext) !void {
    const target = request.head.target;
    const method = request.head.method;

    // CORS preflight -- without this, browser-based tools (GraphiQL, Apollo
    // Sandbox) fail their very first request. Handled generically for every
    // path, not just /graphql, since it's harmless for the NDC endpoints too.
    if (method == .OPTIONS) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = corsHeaders(),
        });
        return;
    }

    if (method == .GET and std.mem.eql(u8, target, "/capabilities")) {
        return respondJson(request, capabilities_json, .ok);
    }

    if (method == .GET and std.mem.eql(u8, target, "/schema")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const json_value = schema_json.toJson(arena.allocator(), ctx.schema_model) catch {
            return respondJson(request, "{\"error\":\"failed to render schema\"}", .internal_server_error);
        };
        const text = std.json.Stringify.valueAlloc(arena.allocator(), json_value, .{}) catch {
            return respondJson(request, "{\"error\":\"failed to serialize schema\"}", .internal_server_error);
        };
        return respondJson(request, text, .ok);
    }

    if (method == .POST and std.mem.eql(u8, target, "/query")) {
        return handleQuery(allocator, io, request, ctx);
    }

    if (method == .POST and std.mem.eql(u8, target, "/mutation")) {
        return handleMutation(allocator, io, request, ctx);
    }

    if (method == .POST and std.mem.eql(u8, target, "/graphql")) {
        return graphql_route.handle(allocator, io, request, ctx);
    }

    return respondJson(request, "{\"error\":\"not found\"}", .not_found);
}

/// Reads the request body into `arena`, requiring Content-Length -- the
/// simplest correct choice for a JSON-body-only API; every real HTTP client
/// (curl, fetch, NDC's own gateway) sends one for a POST body this small, so
/// this isn't a practical limitation. Returns `null` (having already sent an
/// error response) on any failure, matching this file's existing
/// early-return-on-error style. `pub` since `graphql_route.zig` reuses it.
pub fn readJsonBody(arena: std.mem.Allocator, request: *std.http.Server.Request) !?std.json.Parsed(std.json.Value) {
    const content_length = request.head.content_length orelse {
        try respondJson(request, "{\"error\":\"Content-Length required\"}", .length_required);
        return null;
    };
    var body_buf: [64 * 1024]u8 = undefined;
    if (content_length > body_buf.len) {
        try respondJson(request, "{\"error\":\"request body too large\"}", .payload_too_large);
        return null;
    }
    const body_reader = request.readerExpectNone(&body_buf);
    const body_text = body_reader.take(@intCast(content_length)) catch {
        try respondJson(request, "{\"error\":\"failed to read request body\"}", .bad_request);
        return null;
    };

    return std.json.parseFromSlice(std.json.Value, arena, body_text, .{}) catch {
        try respondJson(request, "{\"error\":\"invalid JSON\"}", .bad_request);
        return null;
    };
}

fn handleQuery(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, ctx: *const ServerContext) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try readJsonBody(a, request) orelse return;

    const query = ndc_request.parseQueryRequest(a, parsed.value, ctx.schema_model) catch |err| {
        const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"bad request\"}";
        return respondJson(request, message, .bad_request);
    };

    const variable_sets = ndc_request.parseVariableSets(a, parsed.value) catch |err| {
        const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"bad request\"}";
        return respondJson(request, message, .bad_request);
    };

    var lease = ctx.pool.acquire(io) catch |err| {
        const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"no database connection available\"}";
        return respondJson(request, message, .internal_server_error);
    };
    defer lease.release(io);

    // A request carrying an explicit `"variables"` array executes the same
    // rendered SQL once per set (docs/decisions/0009-query-variables.md);
    // otherwise `run` behaves exactly as before milestone 2.
    var result = if (variable_sets.len > 0)
        pg_gql.executor.runWithVariables(a, lease.conn, &query, ctx.schema_model, variable_sets) catch |err| {
            lease.markBrokenUnless(err);
            const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"query failed\"}";
            return respondJson(request, message, .internal_server_error);
        }
    else
        pg_gql.executor.run(a, lease.conn, &query, ctx.schema_model) catch |err| {
            lease.markBrokenUnless(err);
            const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"query failed\"}";
            return respondJson(request, message, .internal_server_error);
        };
    defer result.deinit();

    const text = std.json.Stringify.valueAlloc(a, result.value, .{}) catch {
        return respondJson(request, "{\"error\":\"failed to serialize result\"}", .internal_server_error);
    };
    return respondJson(request, text, .ok);
}

fn handleMutation(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, ctx: *const ServerContext) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try readJsonBody(a, request) orelse return;

    const mutation_request = ndc_request.parseMutationRequest(a, parsed.value) catch |err| {
        const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"bad request\"}";
        return respondJson(request, message, .bad_request);
    };

    var lease = ctx.pool.acquire(io) catch |err| {
        const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"no database connection available\"}";
        return respondJson(request, message, .internal_server_error);
    };
    defer lease.release(io);

    var result = pg_gql.executor.runMutation(a, lease.conn, &mutation_request, ctx.schema_model) catch |err| {
        lease.markBrokenUnless(err);
        const message = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"mutation failed\"}";
        return respondJson(request, message, .internal_server_error);
    };
    defer result.deinit();

    const text = std.json.Stringify.valueAlloc(a, result.value, .{}) catch {
        return respondJson(request, "{\"error\":\"failed to serialize result\"}", .internal_server_error);
    };
    return respondJson(request, text, .ok);
}

fn corsHeaders() []const std.http.Header {
    return &.{
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
        .{ .name = "access-control-allow-headers", .value = "content-type" },
    };
}

/// `pub` since `graphql_route.zig` reuses it for the `/graphql` responses.
pub fn respondJson(request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });
}
