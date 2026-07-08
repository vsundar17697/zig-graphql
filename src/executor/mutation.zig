const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");
const sql_gen = @import("sql_gen");
const pg_wire = @import("pg_wire");

pub const Error = sql_gen.MutationError || pg_wire.Error || std.mem.Allocator.Error ||
    std.json.ParseError(std.json.Scanner) || error{UnexpectedResultShape};

/// Mutation operations never produce a `variable_ref` param -- `mutation_to_sql.zig`'s
/// argument translation only ever emits concrete scalar values (see
/// docs/decisions/0010-mutation-procedure-naming.md) -- so unlike `run.zig`'s
/// `toQueryParam`, that case is truly unreachable here rather than an error.
fn toQueryParam(allocator: std.mem.Allocator, value: sql_gen.ast.Value) Error!pg_wire.QueryParam {
    return switch (value) {
        .null_ => .null_,
        .boolean => |b| .{ .text = if (b) "t" else "f" },
        .integer => |i| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
        .float => |f| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{f}) },
        .text => |t| .{ .text = t },
        .variable_ref => unreachable,
    };
}

/// Executes every operation's generated SQL in order, collecting each
/// operation's decoded JSON result (`{"affected_rows": N, "returning": [...]}`
/// -- see docs/decisions/0011-mutation-transactions.md). Does not itself
/// BEGIN/COMMIT/ROLLBACK -- `runMutation` owns the transaction boundary so it
/// can roll back on any error this raises.
fn executeOperations(
    a: std.mem.Allocator,
    ha: std.mem.Allocator,
    connection: *pg_wire.Connection,
    request: *const ndc_ir.MutationRequest,
    schema_model: *const schema.SchemaModel,
) Error!std.json.Array {
    var results = try std.json.Array.initCapacity(ha, request.operations.len);
    for (request.operations) |*operation| {
        const rendered = try sql_gen.generateMutation(a, operation, schema_model);

        const params = try a.alloc(pg_wire.QueryParam, rendered.params.len);
        for (rendered.params, 0..) |value, i| params[i] = try toQueryParam(a, value);

        var result = try connection.query(rendered.sql, params);
        defer result.deinit();

        if (result.rows.len != 1 or result.rows[0].columns.len != 1) return Error.UnexpectedResultShape;
        const json_text = result.rows[0].columns[0] orelse return Error.UnexpectedResultShape;

        const decoded = try std.json.parseFromSliceLeaky(std.json.Value, ha, json_text, .{});
        try results.append(decoded);
    }
    return results;
}

/// Runs an ndc_ir.MutationRequest as one all-or-nothing transaction: `BEGIN`,
/// each operation's generated SQL in order, `COMMIT`; any operation failing
/// rolls back the whole request (see docs/decisions/0011-mutation-transactions.md).
///
/// Returns `{"operation_results": [...]}`, one already NDC-shaped result per
/// operation. The returned `std.json.Parsed` owns its own memory; the caller
/// calls `.deinit()` on it.
pub fn runMutation(
    allocator: std.mem.Allocator,
    connection: *pg_wire.Connection,
    request: *const ndc_ir.MutationRequest,
    schema_model: *const schema.SchemaModel,
) Error!std.json.Parsed(std.json.Value) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const heap_arena = try allocator.create(std.heap.ArenaAllocator);
    heap_arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        heap_arena.deinit();
        allocator.destroy(heap_arena);
    }
    const ha = heap_arena.allocator();

    try connection.begin();

    const results = executeOperations(a, ha, connection, request, schema_model) catch |err| {
        connection.rollback() catch {}; // best-effort: propagate the original error either way
        return err;
    };

    try connection.commit();

    var response_obj: std.json.ObjectMap = .empty;
    try response_obj.put(ha, "operation_results", .{ .array = results });

    return .{ .arena = heap_arena, .value = .{ .object = response_obj } };
}
