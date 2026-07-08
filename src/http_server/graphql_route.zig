//! `POST /graphql`: the real-client-compatible surface, distinct from the
//! NDC-native `/query`/`/mutation` (see docs/decisions/0014-graphql-post-endpoint.md).
//! Reuses the existing parse -> resolve -> lower -> executor pipeline per
//! root field and reshapes NDC's JSON into `{"data": ..., "errors": [...]}`
//! via `graphql_schema/envelope.zig` -- a pure post-processing pass, so
//! `/query`/`/mutation` stay byte-exact and untouched.

const std = @import("std");
const pg_gql = @import("pg_gql");
const routes = @import("routes.zig");

/// Bundles what every request needs. `pool` is a lease source (see
/// docs/decisions/0015-connection-pool.md) -- every handler acquires exactly
/// one lease per request and releases it once at the end, marking it broken
/// if any operation on it hit anything other than a clean SQL-level error.
pub const ServerContext = struct {
    pool: *pg_gql.pg_wire.Pool,
    schema_model: *const pg_gql.schema.SchemaModel,
    type_system: *const pg_gql.graphql_schema.TypeSystem,
};

pub fn handle(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, ctx: *const ServerContext) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try routes.readJsonBody(a, request) orelse return;
    const body_obj = switch (parsed.value) {
        .object => |o| o,
        else => return respondBadRequest(request, a, "request body must be a JSON object"),
    };

    const query_text = switch (body_obj.get("query") orelse return respondBadRequest(request, a, "missing \"query\"")) {
        .string => |s| s,
        else => return respondBadRequest(request, a, "\"query\" must be a string"),
    };
    const operation_name: ?[]const u8 = if (body_obj.get("operationName")) |v| switch (v) {
        .string => |s| s,
        .null => null,
        else => return respondBadRequest(request, a, "\"operationName\" must be a string"),
    } else null;
    const variables: ?std.json.Value = if (body_obj.get("variables")) |v| (if (v == .null) null else v) else null;

    // Everything past this point is "the request was well-formed HTTP, but
    // execution itself may have failed" -- per graphql-over-http convention,
    // that's always HTTP 200 with an error envelope, never a 4xx/5xx (real
    // clients like Apollo treat non-2xx as a transport failure and discard
    // the body). Only a malformed JSON body / missing `query` (handled
    // above) gets 400.
    const document = pg_gql.graphql_parser.parse(a, query_text) catch |err| {
        return respondEnvelope(request, a, try pg_gql.graphql_schema.buildRequestErrorEnvelope(a, try errMessage(a, "invalid GraphQL syntax", err)));
    };
    const resolved = pg_gql.graphql_parser.resolveOperation(a, &document, operation_name, variables) catch |err| {
        return respondEnvelope(request, a, try pg_gql.graphql_schema.buildRequestErrorEnvelope(a, try errMessage(a, "failed to resolve operation", err)));
    };

    var lease = ctx.pool.acquire(io) catch |err| {
        return respondEnvelope(request, a, try pg_gql.graphql_schema.buildRequestErrorEnvelope(a, try errMessage(a, "no database connection available", err)));
    };
    defer lease.release(io);

    if (resolved.operation_type == .mutation) {
        return handleMutationOperation(a, request, ctx, &lease, resolved.root_fields);
    }
    return handleQueryOperation(a, request, ctx, &lease, resolved.root_fields);
}

fn errMessage(a: std.mem.Allocator, prefix: []const u8, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}: {t}", .{ prefix, err });
}

fn isIntrospectionField(field: pg_gql.graphql_parser.Field) bool {
    return std.mem.startsWith(u8, field.name, "__");
}

fn handleQueryOperation(
    a: std.mem.Allocator,
    request: *std.http.Server.Request,
    ctx: *const ServerContext,
    lease: *pg_gql.pg_wire.Pool.Lease,
    root_fields: []const pg_gql.graphql_parser.Field,
) !void {
    var data_fields: std.ArrayListUnmanaged(pg_gql.graphql_parser.Field) = .empty;
    var introspection_fields: std.ArrayListUnmanaged(pg_gql.graphql_parser.Field) = .empty;
    for (root_fields) |field| {
        if (isIntrospectionField(field)) try introspection_fields.append(a, field) else try data_fields.append(a, field);
    }

    // Every executor.run call owns its own arena (see executor/run.zig) --
    // those must outlive the envelope-building/serialization below, so they
    // aren't deinited until this whole function returns, not per-iteration.
    var parsed_results: std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)) = .empty;
    defer for (parsed_results.items) |*p| p.deinit();

    var outcomes: std.ArrayListUnmanaged(pg_gql.graphql_schema.FieldOutcome) = .empty;
    for (data_fields.items) |field| {
        const outcome = executeDataField(a, ctx, lease.conn, field, &parsed_results) catch |err| blk: {
            lease.markBrokenUnless(err);
            break :blk pg_gql.graphql_schema.FieldOutcome{ .err = try errMessage(a, "execution failed", err) };
        };
        try outcomes.append(a, outcome);
    }

    const envelope_value = try pg_gql.graphql_schema.buildQueryEnvelope(a, ctx.schema_model, data_fields.items, outcomes.items);

    if (introspection_fields.items.len > 0) {
        const introspection_data = pg_gql.graphql_schema.executeIntrospection(a, ctx.type_system, introspection_fields.items) catch |err| {
            return respondEnvelope(request, a, try pg_gql.graphql_schema.buildRequestErrorEnvelope(a, try errMessage(a, "introspection failed", err)));
        };
        var it = introspection_data.object.iterator();
        while (it.next()) |entry| try envelope_value.object.getPtr("data").?.object.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }

    return respondEnvelope(request, a, envelope_value);
}

fn executeDataField(
    a: std.mem.Allocator,
    ctx: *const ServerContext,
    conn: *pg_gql.pg_wire.Connection,
    field: pg_gql.graphql_parser.Field,
    parsed_results: *std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)),
) !pg_gql.graphql_schema.FieldOutcome {
    const query = try pg_gql.graphql_parser.lowerRootField(a, field, ctx.schema_model);
    const result = try pg_gql.executor.run(a, conn, &query, ctx.schema_model);
    try parsed_results.append(a, result);
    // executor.run always returns a one-element response array for a single
    // query with no variables (see docs/decisions/0005) -- NDC variable-set
    // batching has no `/graphql` equivalent (request-level `$variables`
    // resolve at lowering time instead, see docs/decisions/0014).
    return .{ .ok = result.value.array.items[0] };
}

fn handleMutationOperation(
    a: std.mem.Allocator,
    request: *std.http.Server.Request,
    ctx: *const ServerContext,
    lease: *pg_gql.pg_wire.Pool.Lease,
    root_fields: []const pg_gql.graphql_parser.Field,
) !void {
    // Every mutation root field in one GraphQL document becomes one NDC
    // MutationOperation in one MutationRequest -- the same all-or-nothing
    // transaction `mutation { op1 op2 }` GraphQL text already gets via
    // `graphql_parser.lowerMutation` (see docs/decisions/0011), just built
    // from the already-resolved fields instead of re-parsing.
    const operations = try a.alloc(pg_gql.ndc_ir.MutationOperation, root_fields.len);
    for (root_fields, operations) |field, *out| {
        out.* = pg_gql.graphql_parser.lowerMutationField(a, field) catch |err| {
            return respondEnvelope(request, a, try pg_gql.graphql_schema.buildRequestErrorEnvelope(a, try errMessage(a, "failed to lower mutation field", err)));
        };
    }
    const mutation_request = pg_gql.ndc_ir.MutationRequest{ .operations = operations };

    var result = pg_gql.executor.runMutation(a, lease.conn, &mutation_request, ctx.schema_model) catch |err| {
        lease.markBrokenUnless(err);
        return respondEnvelope(request, a, try pg_gql.graphql_schema.buildRequestErrorEnvelope(a, try errMessage(a, "mutation failed", err)));
    };
    defer result.deinit();

    const operation_results = result.value.object.get("operation_results").?.array;
    var data: std.json.ObjectMap = .empty;
    for (root_fields, operation_results.items) |field, op_result| {
        try data.put(a, field.responseKey(), op_result);
    }
    var envelope_obj: std.json.ObjectMap = .empty;
    try envelope_obj.put(a, "data", .{ .object = data });

    return respondEnvelope(request, a, .{ .object = envelope_obj });
}

fn respondEnvelope(request: *std.http.Server.Request, a: std.mem.Allocator, envelope_value: std.json.Value) !void {
    const text = std.json.Stringify.valueAlloc(a, envelope_value, .{}) catch {
        return routes.respondJson(request, "{\"errors\":[{\"message\":\"failed to serialize response\"}]}", .internal_server_error);
    };
    // Execution outcomes (including per-field errors) are always HTTP 200;
    // see the module doc comment.
    return routes.respondJson(request, text, .ok);
}

fn respondBadRequest(request: *std.http.Server.Request, a: std.mem.Allocator, message: []const u8) !void {
    const envelope_value = pg_gql.graphql_schema.buildRequestErrorEnvelope(a, message) catch {
        return routes.respondJson(request, "{\"errors\":[{\"message\":\"bad request\"}]}", .bad_request);
    };
    const text = std.json.Stringify.valueAlloc(a, envelope_value, .{}) catch {
        return routes.respondJson(request, "{\"errors\":[{\"message\":\"bad request\"}]}", .bad_request);
    };
    return routes.respondJson(request, text, .bad_request);
}
