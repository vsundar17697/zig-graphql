//! Pure (Query, SchemaModel) -> (sql text, params) translation. No I/O.
//! See docs/decisions/0003-json-shaping-sql-in-generator.md for why the
//! generated SQL shapes its own JSON output rather than executor doing it.

const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");
const ast_mod = @import("ast.zig");
const ir_to_sql = @import("ir_to_sql.zig");
const mutation_to_sql = @import("mutation_to_sql.zig");
const render = @import("render.zig");

pub const ast = ast_mod;
pub const RenderedSql = render.RenderedSql;
pub const Error = ir_to_sql.Error;
pub const MutationError = mutation_to_sql.Error;

/// Translates and renders in one step: the entry point `executor` calls.
/// `allocator` is expected to be an arena (see docs/architecture.md) — both
/// the intermediate SQL AST and the returned sql/params slices come from it.
pub fn generate(allocator: std.mem.Allocator, query: *const ndc_ir.Query, schema_model: *const schema.SchemaModel) Error!RenderedSql {
    const row_set_query = try ir_to_sql.translate(allocator, query, schema_model);
    return render.renderRowSet(allocator, row_set_query);
}

/// Translates and renders one mutation operation in one step -- the
/// mutation-side counterpart to `generate`. See
/// docs/decisions/0011-mutation-transactions.md.
pub fn generateMutation(allocator: std.mem.Allocator, operation: *const ndc_ir.MutationOperation, schema_model: *const schema.SchemaModel) MutationError!RenderedSql {
    const stmt = try mutation_to_sql.translateMutation(allocator, operation, schema_model);
    return render.renderMutation(allocator, stmt);
}

test "generate produces a full statement end-to-end from IR + schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "Title", .{ .column = .{ .column = "Title" } });

    const rendered = try generate(allocator, &query, &schema_model);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "json_build_object('rows'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "\"album\".\"Title\" AS \"Title\"") != null);
}

test "generate renders _in with a variable as `= ANY($N)` bound to one array param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "Title", .{ .column = .{ .column = "Title" } });
    query.predicate = .{ .binary_op = .{
        .column = .{ .name = "Title" },
        .operator = .in,
        .value = .{ .variable = "titles" },
    } };

    const rendered = try generate(allocator, &query, &schema_model);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "\"album\".\"Title\" = ANY($1)") != null);
    try std.testing.expectEqual(@as(usize, 1), rendered.params.len);
    try std.testing.expectEqualStrings("titles", rendered.params[0].array_variable_ref);
}


test {
    std.testing.refAllDecls(@This());
}
