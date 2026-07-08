const std = @import("std");
const ast = @import("ast.zig");

pub const RenderedSql = struct {
    sql: []const u8,
    params: []const ast.Value,
};

/// Explicit (rather than inferred) because renderSelect/renderSelectItem/
/// appendRowSet call each other in a cycle (a relationship field's subquery
/// is itself a full Select) — Zig requires an explicit error set to break the
/// inferred-error-set dependency loop across mutually recursive functions.
pub const Error = std.mem.Allocator.Error;

const Buffers = struct {
    sql: std.ArrayListUnmanaged(u8) = .empty,
    params: std.ArrayListUnmanaged(ast.Value) = .empty,
};

/// Writes `"name"` with embedded double-quotes doubled, the standard SQL
/// identifier-escaping rule. Table/column names come from schema introspection
/// or from the query IR (never raw, unescaped user text), but escaping costs
/// nothing and removes an entire class of "what if a name is weird" bugs.
fn writeIdent(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8) Error!void {
    try buf.append(allocator, '"');
    for (name) |c| {
        if (c == '"') try buf.append(allocator, '"');
        try buf.append(allocator, c);
    }
    try buf.append(allocator, '"');
}

fn writeColumnRef(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, col: ast.ColumnRef) Error!void {
    try writeIdent(buf, allocator, col.table_alias);
    try buf.append(allocator, '.');
    try writeIdent(buf, allocator, col.column);
}

fn pushParam(bufs: *Buffers, allocator: std.mem.Allocator, value: ast.Value) Error!usize {
    try bufs.params.append(allocator, value);
    return bufs.params.items.len;
}

fn writePlaceholder(bufs: *Buffers, allocator: std.mem.Allocator, value: ast.Value) Error!void {
    const n = try pushParam(bufs, allocator, value);
    try bufs.sql.print(allocator, "${d}", .{n});
}

fn binaryOpText(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .eq => "=",
        .neq => "<>",
        .gt => ">",
        .gte => ">=",
        .lt => "<",
        .lte => "<=",
    };
}

fn renderExpr(bufs: *Buffers, allocator: std.mem.Allocator, expr: ast.SqlExpr) Error!void {
    switch (expr) {
        .and_ => |list| try renderBoolList(bufs, allocator, list, " AND "),
        .or_ => |list| try renderBoolList(bufs, allocator, list, " OR "),
        .not_ => |child| {
            try bufs.sql.appendSlice(allocator, "NOT (");
            try renderExpr(bufs, allocator, child.*);
            try bufs.sql.appendSlice(allocator, ")");
        },
        .binary => |b| {
            try writeColumnRef(&bufs.sql, allocator, b.column);
            try bufs.sql.appendSlice(allocator, " ");
            try bufs.sql.appendSlice(allocator, binaryOpText(b.op));
            try bufs.sql.appendSlice(allocator, " ");
            switch (b.rhs) {
                .value => |v| try writePlaceholder(bufs, allocator, v),
                .column => |c| try writeColumnRef(&bufs.sql, allocator, c),
            }
        },
        .in_ => |in_expr| {
            try writeColumnRef(&bufs.sql, allocator, in_expr.column);
            try bufs.sql.appendSlice(allocator, " IN (");
            for (in_expr.values, 0..) |value, i| {
                if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
                try writePlaceholder(bufs, allocator, value);
            }
            try bufs.sql.appendSlice(allocator, ")");
        },
        .is_null => |col| {
            try writeColumnRef(&bufs.sql, allocator, col);
            try bufs.sql.appendSlice(allocator, " IS NULL");
        },
        .exists => |sub_select| {
            try bufs.sql.appendSlice(allocator, "EXISTS (");
            try renderSelect(bufs, allocator, sub_select);
            try bufs.sql.appendSlice(allocator, ")");
        },
    }
}

fn renderBoolList(bufs: *Buffers, allocator: std.mem.Allocator, list: []const ast.SqlExpr, joiner: []const u8) Error!void {
    try bufs.sql.appendSlice(allocator, "(");
    for (list, 0..) |child, i| {
        if (i > 0) try bufs.sql.appendSlice(allocator, joiner);
        try renderExpr(bufs, allocator, child);
    }
    try bufs.sql.appendSlice(allocator, ")");
}

fn renderSelectItem(bufs: *Buffers, allocator: std.mem.Allocator, item: ast.SelectItem) Error!void {
    switch (item) {
        .column => |c| {
            try writeColumnRef(&bufs.sql, allocator, c.column);
            try bufs.sql.appendSlice(allocator, " AS ");
            try writeIdent(&bufs.sql, allocator, c.alias);
        },
        .relationship => |r| {
            try bufs.sql.appendSlice(allocator, "(");
            try appendRowSet(bufs, allocator, r.subquery, r.single_row);
            try bufs.sql.appendSlice(allocator, ") AS ");
            try writeIdent(&bufs.sql, allocator, r.alias);
        },
    }
}

fn renderSelect(bufs: *Buffers, allocator: std.mem.Allocator, select: *const ast.Select) Error!void {
    try bufs.sql.appendSlice(allocator, "SELECT ");
    if (select.items.len == 0) {
        // A relationship/collection with no requested fields still needs a
        // valid (if useless) column list; NULL keeps the SQL well-formed.
        try bufs.sql.appendSlice(allocator, "NULL");
    }
    for (select.items, 0..) |item, i| {
        if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
        try renderSelectItem(bufs, allocator, item);
    }

    try bufs.sql.appendSlice(allocator, " FROM ");
    try writeIdent(&bufs.sql, allocator, select.from.schema);
    try bufs.sql.appendSlice(allocator, ".");
    try writeIdent(&bufs.sql, allocator, select.from.table);
    try bufs.sql.appendSlice(allocator, " AS ");
    try writeIdent(&bufs.sql, allocator, select.from.alias);

    if (select.where) |where_expr| {
        try bufs.sql.appendSlice(allocator, " WHERE ");
        try renderExpr(bufs, allocator, where_expr);
    }

    if (select.order_by.len > 0) {
        try bufs.sql.appendSlice(allocator, " ORDER BY ");
        for (select.order_by, 0..) |item, i| {
            if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
            try writeColumnRef(&bufs.sql, allocator, item.column);
            try bufs.sql.appendSlice(allocator, if (item.direction == .asc) " ASC" else " DESC");
        }
    }

    // A forced single_row LIMIT 1 (see appendRowSet) always wins over this;
    // appendRowSet is the only caller and passes select.limit through as-is,
    // overriding it there rather than here keeps this function a faithful,
    // context-free rendering of exactly the Select value it's given.
    if (select.limit) |limit| {
        try bufs.sql.print(allocator, " LIMIT {d}", .{limit});
    }
    if (select.offset) |offset| {
        try bufs.sql.print(allocator, " OFFSET {d}", .{offset});
    }
}

fn writeStringLiteral(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) Error!void {
    try buf.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try buf.append(allocator, '\'');
        try buf.append(allocator, c);
    }
    try buf.append(allocator, '\'');
}

fn aggregateFunctionText(f: ast.AggregateFunction) []const u8 {
    return switch (f) {
        .min => "min",
        .max => "max",
        .sum => "sum",
        .avg => "avg",
    };
}

/// Every aggregate reads from the row-set wrapper's own alias ("t", the same
/// one `appendRowSet` wraps `select` in), never the base table -- see
/// docs/decisions/0008-aggregate-rendering.md.
fn renderAggregateExpr(bufs: *Buffers, allocator: std.mem.Allocator, expr: ast.AggregateExpr) Error!void {
    switch (expr) {
        .star_count => try bufs.sql.appendSlice(allocator, "count(*)"),
        .column_count => |cc| {
            try bufs.sql.appendSlice(allocator, "count(");
            if (cc.distinct) try bufs.sql.appendSlice(allocator, "DISTINCT ");
            try writeColumnRef(&bufs.sql, allocator, .{ .table_alias = "t", .column = cc.column_alias });
            try bufs.sql.appendSlice(allocator, ")");
        },
        .single_column => |sc| {
            try bufs.sql.appendSlice(allocator, aggregateFunctionText(sc.function));
            try bufs.sql.appendSlice(allocator, "(");
            try writeColumnRef(&bufs.sql, allocator, .{ .table_alias = "t", .column = sc.column_alias });
            try bufs.sql.appendSlice(allocator, ")");
        },
    }
}

/// Wraps a row-producing Select (plus any aggregates) as an NDC-shaped RowSet
/// JSON object: `{"rows": [...], "aggregates": {...}}`, either key omitted
/// when not applicable (see docs/decisions/0008-aggregate-rendering.md). Used
/// identically for the top-level query result and for every nested
/// relationship field, which is what makes both object and array
/// relationships (and now aggregates on either) render through the same code
/// path (`force_single_row` just caps the wrapped select at one row for
/// object relationships).
fn appendRowSet(bufs: *Buffers, allocator: std.mem.Allocator, rsq: *const ast.RowSetQuery, force_single_row: bool) Error!void {
    try bufs.sql.appendSlice(allocator, "SELECT json_build_object(");
    var wrote_any = false;

    if (rsq.row_field_aliases) |aliases| {
        // Some of select.items exist only to make a column available to
        // `aggregates`, not as a display field -- re-project "t" down to just
        // the requested aliases before json_agg'ing so those extra columns
        // don't leak into row output. Skipped entirely if there are zero
        // display fields (a pure-aggregate query).
        if (aliases.len > 0) {
            try bufs.sql.appendSlice(allocator, "'rows', (SELECT coalesce(json_agg(row_to_json(\"disp\")), '[]'::json) FROM (SELECT ");
            for (aliases, 0..) |alias, i| {
                if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
                try writeColumnRef(&bufs.sql, allocator, .{ .table_alias = "t", .column = alias });
                try bufs.sql.appendSlice(allocator, " AS ");
                try writeIdent(&bufs.sql, allocator, alias);
            }
            try bufs.sql.appendSlice(allocator, " FROM \"t\") AS \"disp\")");
            wrote_any = true;
        }
    } else if (rsq.select.items.len > 0 or rsq.aggregates.len == 0) {
        // Common case: every column in `select.items` is already a display
        // field (row_field_aliases is null), so "t" needs no re-projection.
        try bufs.sql.appendSlice(allocator, "'rows', coalesce(json_agg(row_to_json(\"t\")), '[]'::json)");
        wrote_any = true;
    }

    if (rsq.aggregates.len > 0) {
        if (wrote_any) try bufs.sql.appendSlice(allocator, ", ");
        try bufs.sql.appendSlice(allocator, "'aggregates', json_build_object(");
        for (rsq.aggregates, 0..) |agg, i| {
            if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
            try writeStringLiteral(&bufs.sql, allocator, agg.alias);
            try bufs.sql.appendSlice(allocator, ", ");
            try renderAggregateExpr(bufs, allocator, agg.expr);
        }
        try bufs.sql.appendSlice(allocator, ")");
    }

    try bufs.sql.appendSlice(allocator, ") FROM (");
    if (force_single_row) {
        var limited = rsq.select.*;
        limited.limit = 1;
        try renderSelect(bufs, allocator, &limited);
    } else {
        try renderSelect(bufs, allocator, rsq.select);
    }
    try bufs.sql.appendSlice(allocator, ") AS \"t\"");
}

/// Renders a top-level query as a single statement returning one row with one
/// JSON column shaped as `{"rows": [...], "aggregates": {...}}`, matching the
/// NDC QueryResponse RowSet shape directly — see
/// docs/decisions/0003-json-shaping-sql-in-generator.md and
/// docs/decisions/0008-aggregate-rendering.md.
pub fn renderRowSet(allocator: std.mem.Allocator, rsq: *const ast.RowSetQuery) Error!RenderedSql {
    var bufs = Buffers{};
    try appendRowSet(&bufs, allocator, rsq, false);
    return .{
        .sql = try bufs.sql.toOwnedSlice(allocator),
        .params = try bufs.params.toOwnedSlice(allocator),
    };
}

fn writeTableRef(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, table: ast.TableRef) Error!void {
    try writeIdent(buf, allocator, table.schema);
    try buf.append(allocator, '.');
    try writeIdent(buf, allocator, table.table);
}

fn renderInsert(bufs: *Buffers, allocator: std.mem.Allocator, ins: ast.InsertStatement) Error!void {
    try bufs.sql.appendSlice(allocator, "INSERT INTO ");
    try writeTableRef(&bufs.sql, allocator, ins.table);
    try bufs.sql.appendSlice(allocator, " (");
    for (ins.columns, 0..) |c, i| {
        if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
        try writeIdent(&bufs.sql, allocator, c);
    }
    try bufs.sql.appendSlice(allocator, ") VALUES (");
    for (ins.values, 0..) |v, i| {
        if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
        try writePlaceholder(bufs, allocator, v);
    }
    try bufs.sql.appendSlice(allocator, ")");
}

fn renderPkWhere(bufs: *Buffers, allocator: std.mem.Allocator, pk_columns: []const []const u8, pk_values: []const ast.Value) Error!void {
    try bufs.sql.appendSlice(allocator, " WHERE ");
    for (pk_columns, pk_values, 0..) |col, val, i| {
        if (i > 0) try bufs.sql.appendSlice(allocator, " AND ");
        try writeIdent(&bufs.sql, allocator, col);
        try bufs.sql.appendSlice(allocator, " = ");
        try writePlaceholder(bufs, allocator, val);
    }
}

fn renderUpdate(bufs: *Buffers, allocator: std.mem.Allocator, upd: ast.UpdateStatement) Error!void {
    try bufs.sql.appendSlice(allocator, "UPDATE ");
    try writeTableRef(&bufs.sql, allocator, upd.table);
    try bufs.sql.appendSlice(allocator, " SET ");
    for (upd.set_columns, upd.set_values, 0..) |col, val, i| {
        if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
        try writeIdent(&bufs.sql, allocator, col);
        try bufs.sql.appendSlice(allocator, " = ");
        try writePlaceholder(bufs, allocator, val);
    }
    try renderPkWhere(bufs, allocator, upd.pk_columns, upd.pk_values);
}

fn renderDelete(bufs: *Buffers, allocator: std.mem.Allocator, del: ast.DeleteStatement) Error!void {
    try bufs.sql.appendSlice(allocator, "DELETE FROM ");
    try writeTableRef(&bufs.sql, allocator, del.table);
    try renderPkWhere(bufs, allocator, del.pk_columns, del.pk_values);
}

/// Renders a mutation as `WITH mutated AS (<insert|update|delete> RETURNING
/// *) SELECT json_build_object('affected_rows', (SELECT count(*) FROM
/// mutated), 'returning', (...))`. Both `affected_rows` and `returning` are
/// scalar subqueries against the CTE composed directly into one
/// `json_build_object` call with no outer `FROM` clause of its own -- this is
/// what guarantees the statement always returns exactly one row even when
/// `mutated` itself has zero rows (a `*_by_pk` operation targeting a
/// nonexistent row), rather than the naive `SELECT ... FROM mutated` form
/// returning zero rows in that case. See
/// docs/decisions/0011-mutation-transactions.md.
pub fn renderMutation(allocator: std.mem.Allocator, stmt: *const ast.MutationStatement) Error!RenderedSql {
    var bufs = Buffers{};

    try bufs.sql.appendSlice(allocator, "WITH mutated AS (");
    switch (stmt.op) {
        .insert => |ins| try renderInsert(&bufs, allocator, ins),
        .update => |upd| try renderUpdate(&bufs, allocator, upd),
        .delete => |del| try renderDelete(&bufs, allocator, del),
    }
    try bufs.sql.appendSlice(allocator, " RETURNING *) SELECT json_build_object('affected_rows', (SELECT count(*) FROM mutated)");

    if (stmt.returning) |columns| {
        try bufs.sql.appendSlice(allocator, ", 'returning', (SELECT coalesce(json_agg(row_to_json(\"ret\")), '[]'::json) FROM (SELECT ");
        if (columns.len == 0) {
            try bufs.sql.appendSlice(allocator, "NULL");
        }
        for (columns, 0..) |c, i| {
            if (i > 0) try bufs.sql.appendSlice(allocator, ", ");
            try writeColumnRef(&bufs.sql, allocator, c.column);
            try bufs.sql.appendSlice(allocator, " AS ");
            try writeIdent(&bufs.sql, allocator, c.alias);
        }
        try bufs.sql.appendSlice(allocator, " FROM mutated) AS \"ret\")");
    }

    try bufs.sql.appendSlice(allocator, ")");

    return .{
        .sql = try bufs.sql.toOwnedSlice(allocator),
        .params = try bufs.params.toOwnedSlice(allocator),
    };
}

test "renders a scalar-only select with no predicate" {
    const allocator = std.testing.allocator;
    const select = ast.Select{
        .items = &.{
            .{ .column = .{ .column = .{ .table_alias = "album", .column = "AlbumId" }, .alias = "AlbumId" } },
        },
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
    };

    const rendered = try renderRowSet(allocator, &.{ .select = &select });
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "json_build_object('rows'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "\"album\".\"AlbumId\" AS \"AlbumId\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "FROM \"public\".\"album\" AS \"album\"") != null);
    try std.testing.expectEqual(@as(usize, 0), rendered.params.len);
}

test "renders a WHERE clause with and_/not_ nesting and correct param ordering" {
    const allocator = std.testing.allocator;

    const inner_not = ast.SqlExpr{ .is_null = .{ .table_alias = "album", .column = "Title" } };
    var children = [_]ast.SqlExpr{
        .{ .binary = .{
            .column = .{ .table_alias = "album", .column = "AlbumId" },
            .op = .gt,
            .rhs = .{ .value = .{ .integer = 1 } },
        } },
        .{ .not_ = &inner_not },
    };
    const select = ast.Select{
        .items = &.{},
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
        .where = .{ .and_ = &children },
    };

    const rendered = try renderRowSet(allocator, &.{ .select = &select });
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "WHERE (\"album\".\"AlbumId\" > $1 AND NOT (\"album\".\"Title\" IS NULL))") != null);
    try std.testing.expectEqual(@as(usize, 1), rendered.params.len);
    try std.testing.expectEqual(@as(i64, 1), rendered.params[0].integer);
}

test "renders IN with one placeholder per value" {
    const allocator = std.testing.allocator;
    const values = [_]ast.Value{ .{ .text = "Album1" }, .{ .text = "Album2" } };
    const select = ast.Select{
        .items = &.{},
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
        .where = .{ .in_ = .{ .column = .{ .table_alias = "album", .column = "Title" }, .values = &values } },
    };

    const rendered = try renderRowSet(allocator, &.{ .select = &select });
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "\"album\".\"Title\" IN ($1, $2)") != null);
    try std.testing.expectEqual(@as(usize, 2), rendered.params.len);
}

test "renders order_by, limit and offset" {
    const allocator = std.testing.allocator;
    const order_by = [_]ast.OrderByItem{
        .{ .column = .{ .table_alias = "album", .column = "Title" }, .direction = .asc },
    };
    const select = ast.Select{
        .items = &.{},
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
        .order_by = &order_by,
        .limit = 10,
        .offset = 5,
    };

    const rendered = try renderRowSet(allocator, &.{ .select = &select });
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "ORDER BY \"album\".\"Title\" ASC LIMIT 10 OFFSET 5") != null);
}

test "renders a relationship field as a correlated subquery, forcing LIMIT 1 for object relationships" {
    const allocator = std.testing.allocator;
    const nested_items = [_]ast.SelectItem{
        .{ .column = .{ .column = .{ .table_alias = "artist", .column = "Name" }, .alias = "Name" } },
    };
    const join_condition = ast.SqlExpr{ .binary = .{
        .column = .{ .table_alias = "artist", .column = "artist_id" },
        .op = .eq,
        .rhs = .{ .column = .{ .table_alias = "album", .column = "artist_id" } },
    } };
    const nested_select = ast.Select{
        .items = &nested_items,
        .from = .{ .schema = "public", .table = "artist", .alias = "artist" },
        .where = join_condition,
        .limit = 99, // must be overridden to 1 by force_single_row
    };
    const nested_rsq = ast.RowSetQuery{ .select = &nested_select };
    const items = [_]ast.SelectItem{
        .{ .relationship = .{ .alias = "Artist", .subquery = &nested_rsq, .single_row = true } },
    };
    const select = ast.Select{
        .items = &items,
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
    };

    const rendered = try renderRowSet(allocator, &.{ .select = &select });
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "\"artist\".\"artist_id\" = \"album\".\"artist_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "LIMIT 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, ") AS \"Artist\"") != null);
    // The join condition is column-to-column, so it must not consume a parameter slot.
    try std.testing.expectEqual(@as(usize, 0), rendered.params.len);
}

test "renders an exists expression as EXISTS (SELECT ... FROM ... WHERE ...)" {
    const allocator = std.testing.allocator;

    const join_condition = ast.SqlExpr{ .binary = .{
        .column = .{ .table_alias = "artist", .column = "artist_id" },
        .op = .eq,
        .rhs = .{ .column = .{ .table_alias = "album", .column = "artist_id" } },
    } };
    const name_predicate = ast.SqlExpr{ .binary = .{
        .column = .{ .table_alias = "artist", .column = "name" },
        .op = .eq,
        .rhs = .{ .value = .{ .text = "AC/DC" } },
    } };
    const conjuncts = [_]ast.SqlExpr{ join_condition, name_predicate };
    const exists_select = ast.Select{
        .items = &.{},
        .from = .{ .schema = "public", .table = "artist", .alias = "artist" },
        .where = .{ .and_ = &conjuncts },
    };

    const select = ast.Select{
        .items = &.{},
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
        .where = .{ .exists = &exists_select },
    };

    const rendered = try renderRowSet(allocator, &.{ .select = &select });
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "WHERE EXISTS (SELECT NULL FROM \"public\".\"artist\" AS \"artist\" WHERE (\"artist\".\"artist_id\" = \"album\".\"artist_id\" AND \"artist\".\"name\" = $1))") != null);
    try std.testing.expectEqual(@as(usize, 1), rendered.params.len);
    try std.testing.expectEqualStrings("AC/DC", rendered.params[0].text);
}

test "renders rows and aggregates together, computed over the same wrapped subquery" {
    const allocator = std.testing.allocator;
    const items = [_]ast.SelectItem{
        .{ .column = .{ .column = .{ .table_alias = "album", .column = "Title" }, .alias = "Title" } },
    };
    const select = ast.Select{
        .items = &items,
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
    };
    const aggregates = [_]ast.AggregateItem{
        .{ .alias = "count", .expr = .star_count },
        .{ .alias = "max_id", .expr = .{ .single_column = .{ .column_alias = "AlbumId", .function = .max } } },
    };
    const rsq = ast.RowSetQuery{ .select = &select, .aggregates = &aggregates };

    const rendered = try renderRowSet(allocator, &rsq);
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    // Exactly one FROM-subquery scan ("t"), referenced by both 'rows' and 'aggregates'.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered.sql, "FROM ("));
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "'rows', coalesce(json_agg(row_to_json(\"t\")), '[]'::json)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "'aggregates', json_build_object('count', count(*), 'max_id', max(\"t\".\"AlbumId\"))") != null);
}

test "aggregate-only query (no display fields) omits the 'rows' key" {
    const allocator = std.testing.allocator;
    const select = ast.Select{
        .items = &.{},
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
    };
    const aggregates = [_]ast.AggregateItem{.{ .alias = "count", .expr = .star_count }};
    const rsq = ast.RowSetQuery{ .select = &select, .row_field_aliases = &.{}, .aggregates = &aggregates };

    const rendered = try renderRowSet(allocator, &rsq);
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "'rows'") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "'aggregates', json_build_object('count', count(*))") != null);
}

test "row_field_aliases re-projects 't' so an aggregate-only column doesn't leak into rows" {
    const allocator = std.testing.allocator;
    // "t" carries both the display field (Title) and an aggregate-support-only
    // column (AlbumId) -- row_field_aliases says only "Title" should appear in
    // the 'rows' JSON, even though "t" itself has both columns.
    const items = [_]ast.SelectItem{
        .{ .column = .{ .column = .{ .table_alias = "album", .column = "Title" }, .alias = "Title" } },
        .{ .column = .{ .column = .{ .table_alias = "album", .column = "AlbumId" }, .alias = "AlbumId" } },
    };
    const select = ast.Select{
        .items = &items,
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
    };
    const row_field_aliases = [_][]const u8{"Title"};
    const aggregates = [_]ast.AggregateItem{
        .{ .alias = "max_id", .expr = .{ .single_column = .{ .column_alias = "AlbumId", .function = .max } } },
    };
    const rsq = ast.RowSetQuery{ .select = &select, .row_field_aliases = &row_field_aliases, .aggregates = &aggregates };

    const rendered = try renderRowSet(allocator, &rsq);
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "'rows', (SELECT coalesce(json_agg(row_to_json(\"disp\")), '[]'::json) FROM (SELECT \"t\".\"Title\" AS \"Title\" FROM \"t\") AS \"disp\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "max(\"t\".\"AlbumId\")") != null);
    // "AlbumId" is selected in "t" (for the aggregate) but must not appear in the disp projection.
    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "\"disp\") AS \"AlbumId\"") == null);
}

test "renders an insert with RETURNING data as one always-one-row statement" {
    const allocator = std.testing.allocator;
    const stmt = ast.MutationStatement{
        .op = .{ .insert = .{
            .table = .{ .schema = "public", .table = "album", .alias = "album" },
            .columns = &.{ "Title", "ArtistId" },
            .values = &.{ .{ .text = "Highway to Hell" }, .{ .integer = 1 } },
        } },
        .returning = &.{
            .{ .column = .{ .table_alias = "mutated", .column = "AlbumId" }, .alias = "AlbumId" },
        },
    };

    const rendered = try renderMutation(allocator, &stmt);
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expectEqualStrings(
        "WITH mutated AS (INSERT INTO \"public\".\"album\" (\"Title\", \"ArtistId\") VALUES ($1, $2) RETURNING *) SELECT json_build_object('affected_rows', (SELECT count(*) FROM mutated), 'returning', (SELECT coalesce(json_agg(row_to_json(\"ret\")), '[]'::json) FROM (SELECT \"mutated\".\"AlbumId\" AS \"AlbumId\" FROM mutated) AS \"ret\"))",
        rendered.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), rendered.params.len);
    try std.testing.expectEqualStrings("Highway to Hell", rendered.params[0].text);
    try std.testing.expectEqual(@as(i64, 1), rendered.params[1].integer);
}

test "renders an update by pk with a multi-column SET and WHERE" {
    const allocator = std.testing.allocator;
    const stmt = ast.MutationStatement{
        .op = .{ .update = .{
            .table = .{ .schema = "public", .table = "album", .alias = "album" },
            .set_columns = &.{"Title"},
            .set_values = &.{.{ .text = "Renamed" }},
            .pk_columns = &.{"AlbumId"},
            .pk_values = &.{.{ .integer = 1 }},
        } },
    };

    const rendered = try renderMutation(allocator, &stmt);
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expectEqualStrings(
        "WITH mutated AS (UPDATE \"public\".\"album\" SET \"Title\" = $1 WHERE \"AlbumId\" = $2 RETURNING *) SELECT json_build_object('affected_rows', (SELECT count(*) FROM mutated))",
        rendered.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), rendered.params.len);
}

test "renders a delete by pk with no RETURNING key when fields were not requested" {
    const allocator = std.testing.allocator;
    const stmt = ast.MutationStatement{
        .op = .{ .delete = .{
            .table = .{ .schema = "public", .table = "album", .alias = "album" },
            .pk_columns = &.{"AlbumId"},
            .pk_values = &.{.{ .integer = 1 }},
        } },
    };

    const rendered = try renderMutation(allocator, &stmt);
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expectEqualStrings(
        "WITH mutated AS (DELETE FROM \"public\".\"album\" WHERE \"AlbumId\" = $1 RETURNING *) SELECT json_build_object('affected_rows', (SELECT count(*) FROM mutated))",
        rendered.sql,
    );
    try std.testing.expectEqual(@as(usize, 1), rendered.params.len);
}

test "a multi-column primary key ANDs every pk equality in WHERE" {
    const allocator = std.testing.allocator;
    const stmt = ast.MutationStatement{
        .op = .{ .delete = .{
            .table = .{ .schema = "public", .table = "order_item", .alias = "order_item" },
            .pk_columns = &.{ "OrderId", "LineNo" },
            .pk_values = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
        } },
    };

    const rendered = try renderMutation(allocator, &stmt);
    defer allocator.free(rendered.sql);
    defer allocator.free(rendered.params);

    try std.testing.expect(std.mem.indexOf(u8, rendered.sql, "WHERE \"OrderId\" = $1 AND \"LineNo\" = $2") != null);
}
