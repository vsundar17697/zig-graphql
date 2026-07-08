const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");
const sql_gen = @import("sql_gen");
const pg_wire = @import("pg_wire");
const pg_array = @import("pg_array.zig");

pub const Error = sql_gen.Error || pg_wire.Error || std.mem.Allocator.Error ||
    std.json.ParseError(std.json.Scanner) || error{ UnexpectedResultShape, UnboundVariable, UnsupportedVariableValue };

/// Maps sql_gen's bindable Value to pg_wire's text-format QueryParam. This
/// mapping is the reason `executor` is allowed to depend on both `sql_gen`
/// and `pg_wire` when neither of those may depend on each other directly
/// (see docs/architecture.md). `variable_ref` reaching here means `run` (the
/// no-variables entry point) was given a query that actually needs variables
/// -- see docs/decisions/0009-query-variables.md.
fn toQueryParam(allocator: std.mem.Allocator, value: sql_gen.ast.Value) Error!pg_wire.QueryParam {
    return switch (value) {
        .null_ => .null_,
        .boolean => |b| .{ .text = if (b) "t" else "f" },
        .integer => |i| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
        .float => |f| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{f}) },
        .text => |t| .{ .text = t },
        .variable_ref, .array_variable_ref => Error.UnboundVariable,
    };
}

/// Renders one JSON scalar to the text encoding Postgres expects for a bound
/// parameter; JSON null maps to Zig null. Shared between scalar variable
/// resolution and array-element encoding so the two encodings can never
/// drift apart. Nested arrays/objects are rejected -- NDC variable values
/// are scalars or flat scalar arrays, nothing deeper.
fn jsonScalarText(allocator: std.mem.Allocator, value: std.json.Value) Error!?[]const u8 {
    return switch (value) {
        .null => null,
        .bool => |b| if (b) "t" else "f",
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .string => |s| s,
        .number_string, .array, .object => Error.UnsupportedVariableValue,
    };
}

/// Resolves a `variable_ref`/`array_variable_ref` against one VariableSet's
/// JSON value into a bindable QueryParam; every other Value variant passes
/// through `toQueryParam` unchanged (a variable set only needs to supply
/// values for the columns that actually reference variables). An array
/// variable binds as a single Postgres array-literal text parameter (see
/// pg_array.zig), which `= ANY($N)` consumes server-side.
fn resolveQueryParam(allocator: std.mem.Allocator, value: sql_gen.ast.Value, variables: *const ndc_ir.VariableSet) Error!pg_wire.QueryParam {
    return switch (value) {
        .variable_ref => |name| blk: {
            const json_value = variables.get(name) orelse return Error.UnboundVariable;
            const text = (try jsonScalarText(allocator, json_value)) orelse break :blk .null_;
            break :blk .{ .text = text };
        },
        .array_variable_ref => |name| blk: {
            const json_value = variables.get(name) orelse return Error.UnboundVariable;
            const array = switch (json_value) {
                .array => |a| a,
                else => return Error.UnsupportedVariableValue,
            };
            const elements = try allocator.alloc(?[]const u8, array.items.len);
            for (array.items, 0..) |item, i| elements[i] = try jsonScalarText(allocator, item);
            break :blk .{ .text = try pg_array.encodeLiteral(allocator, elements) };
        },
        else => try toQueryParam(allocator, value),
    };
}

/// Executes already-rendered SQL with the given bound params and decodes the
/// single JSON column every generated statement returns into one NDC RowSet
/// value (`{"rows": [...], "aggregates": {...}}` -- see
/// docs/decisions/0003-json-shaping-sql-in-generator.md and
/// docs/decisions/0008-aggregate-rendering.md). `allocator` owns the decoded
/// value's memory (expected to be an arena the caller controls).
fn executeAndDecodeOne(
    allocator: std.mem.Allocator,
    connection: *pg_wire.Connection,
    sql: []const u8,
    params: []const pg_wire.QueryParam,
) Error!std.json.Value {
    var result = try connection.query(sql, params);
    defer result.deinit();

    if (result.rows.len != 1 or result.rows[0].columns.len != 1) return Error.UnexpectedResultShape;
    const json_text = result.rows[0].columns[0] orelse return Error.UnexpectedResultShape;

    return std.json.parseFromSliceLeaky(std.json.Value, allocator, json_text, .{});
}

/// Runs an ndc_ir.Query end to end: translate to SQL (sql_gen), execute over
/// the wire (pg_wire), and decode the result (see `executeAndDecodeOne`).
///
/// Returns the full NDC `QueryResponse` shape: a JSON *array* of RowSets (see
/// docs/decisions/0005-query-response-array-of-rowsets.md) -- exactly one
/// element for this entry point; see `runWithVariables` for N variable sets
/// producing N elements from the same rendered SQL.
///
/// The returned `std.json.Parsed` owns its own memory; the caller calls
/// `.deinit()` on it.
pub fn run(
    allocator: std.mem.Allocator,
    connection: *pg_wire.Connection,
    query: *const ndc_ir.Query,
    schema_model: *const schema.SchemaModel,
) Error!std.json.Parsed(std.json.Value) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rendered = try sql_gen.generate(a, query, schema_model);

    const params = try a.alloc(pg_wire.QueryParam, rendered.params.len);
    for (rendered.params, 0..) |value, i| params[i] = try toQueryParam(a, value);

    const heap_arena = try allocator.create(std.heap.ArenaAllocator);
    heap_arena.* = std.heap.ArenaAllocator.init(allocator);
    const row_set = try executeAndDecodeOne(heap_arena.allocator(), connection, rendered.sql, params);

    var response_array = std.json.Array.init(heap_arena.allocator());
    try response_array.append(row_set);
    return .{ .arena = heap_arena, .value = .{ .array = response_array } };
}

/// Renders `query` to SQL exactly once, then executes that same SQL once per
/// entry in `variable_sets`, resolving each `variable_ref` against that set's
/// values -- one connection throughout, no re-parsing or re-rendering per set
/// (see docs/decisions/0009-query-variables.md on why this N-sequential-
/// round-trips shape is acceptable for milestone 2 and how it upgrades to
/// prepared-statement reuse later without changing this function's contract).
///
/// Returns one NDC RowSet per variable set, in order, as the QueryResponse array.
pub fn runWithVariables(
    allocator: std.mem.Allocator,
    connection: *pg_wire.Connection,
    query: *const ndc_ir.Query,
    schema_model: *const schema.SchemaModel,
    variable_sets: []const ndc_ir.VariableSet,
) Error!std.json.Parsed(std.json.Value) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rendered = try sql_gen.generate(a, query, schema_model);

    const heap_arena = try allocator.create(std.heap.ArenaAllocator);
    heap_arena.* = std.heap.ArenaAllocator.init(allocator);
    const ha = heap_arena.allocator();

    var response_array = try std.json.Array.initCapacity(ha, variable_sets.len);
    for (variable_sets) |*variables| {
        const params = try a.alloc(pg_wire.QueryParam, rendered.params.len);
        for (rendered.params, 0..) |value, i| params[i] = try resolveQueryParam(a, value, variables);

        const row_set = try executeAndDecodeOne(ha, connection, rendered.sql, params);
        try response_array.append(row_set);
    }

    return .{ .arena = heap_arena, .value = .{ .array = response_array } };
}

test "toQueryParam maps every sql_gen.ast.Value variant to a text QueryParam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqual(pg_wire.QueryParam.null_, try toQueryParam(allocator, .null_));

    const int_param = try toQueryParam(allocator, .{ .integer = 42 });
    try std.testing.expectEqualStrings("42", int_param.text);

    const bool_param = try toQueryParam(allocator, .{ .boolean = true });
    try std.testing.expectEqualStrings("t", bool_param.text);

    const text_param = try toQueryParam(allocator, .{ .text = "hello" });
    try std.testing.expectEqualStrings("hello", text_param.text);
}

test "toQueryParam rejects an unresolved variable_ref" {
    const result = toQueryParam(std.testing.allocator, .{ .variable_ref = "x" });
    try std.testing.expectError(Error.UnboundVariable, result);
}

test "resolveQueryParam resolves a variable_ref against a VariableSet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var variables = ndc_ir.VariableSet{};
    try variables.put(allocator, "artist_id", .{ .integer = 1 });

    const param = try resolveQueryParam(allocator, .{ .variable_ref = "artist_id" }, &variables);
    try std.testing.expectEqualStrings("1", param.text);
}

test "resolveQueryParam rejects a variable name not present in the set" {
    var variables = ndc_ir.VariableSet{};
    const result = resolveQueryParam(std.testing.allocator, .{ .variable_ref = "missing" }, &variables);
    try std.testing.expectError(Error.UnboundVariable, result);
}

test "resolveQueryParam passes non-variable values straight through to toQueryParam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var variables = ndc_ir.VariableSet{};
    const param = try resolveQueryParam(allocator, .{ .integer = 7 }, &variables);
    try std.testing.expectEqualStrings("7", param.text);
}

test "resolveQueryParam encodes an array variable as one Postgres array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var items = std.json.Array.init(allocator);
    try items.append(.{ .string = "plain" });
    try items.append(.{ .string = "with \"quotes\" and \\slash" });
    try items.append(.{ .integer = 42 });
    try items.append(.null);
    try items.append(.{ .bool = true });

    var variables = ndc_ir.VariableSet{};
    try variables.put(allocator, "values", .{ .array = items });

    const param = try resolveQueryParam(allocator, .{ .array_variable_ref = "values" }, &variables);
    try std.testing.expectEqualStrings(
        \\{"plain","with \"quotes\" and \\slash","42",NULL,"t"}
    , param.text);
}

test "resolveQueryParam rejects a non-array value bound in array position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var variables = ndc_ir.VariableSet{};
    try variables.put(allocator, "values", .{ .integer = 1 });

    const result = resolveQueryParam(allocator, .{ .array_variable_ref = "values" }, &variables);
    try std.testing.expectError(Error.UnsupportedVariableValue, result);
}

test "resolveQueryParam rejects nested arrays inside an array variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inner = std.json.Array.init(allocator);
    var items = std.json.Array.init(allocator);
    try items.append(.{ .array = inner });
    _ = &inner;

    var variables = ndc_ir.VariableSet{};
    try variables.put(allocator, "values", .{ .array = items });

    const result = resolveQueryParam(allocator, .{ .array_variable_ref = "values" }, &variables);
    try std.testing.expectError(Error.UnsupportedVariableValue, result);
}

test "toQueryParam rejects an unresolved array_variable_ref" {
    const result = toQueryParam(std.testing.allocator, .{ .array_variable_ref = "x" });
    try std.testing.expectError(Error.UnboundVariable, result);
}
