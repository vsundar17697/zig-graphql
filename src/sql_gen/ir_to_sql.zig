const std = @import("std");
const ndc_ir = @import("ndc_ir");
const schema = @import("schema");
const ast = @import("ast.zig");

pub const Error = error{
    UnknownCollection,
    UnknownRelationship,
    UnsupportedComparisonValue,
    VariablesNotSupportedForIn,
} || std.mem.Allocator.Error;

fn toSqlValue(value: std.json.Value) Error!ast.Value {
    return switch (value) {
        .null => .null_,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .text = s },
        .number_string, .array, .object => Error.UnsupportedComparisonValue,
    };
}

fn toBinaryOp(op: ndc_ir.BinaryOperator) ast.BinaryOp {
    return switch (op) {
        .eq => .eq,
        .neq => .neq,
        .gt => .gt,
        .gte => .gte,
        .lt => .lt,
        .lte => .lte,
        .in => unreachable, // handled separately in translateExpr; never reaches here
    };
}

/// Appends the FK-equality conjuncts joining `source_alias` (the collection
/// already being queried) to `target_alias` (the collection a relationship or
/// exists check reaches into) onto `out`, from a Relationship's column_mapping
/// (key = source column, value = target column -- see docs/decisions/0006 and
/// schema/introspect.zig's forward/reverse derivation). Shared between
/// relationship-field lowering and `exists(related: ...)` lowering so the two
/// don't drift.
fn appendJoinConjuncts(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ast.SqlExpr),
    rel: ndc_ir.Relationship,
    source_alias: []const u8,
    target_alias: []const u8,
) Error!void {
    var mapping_it = rel.column_mapping.iterator();
    while (mapping_it.next()) |mapping| {
        try out.append(allocator, .{ .binary = .{
            .column = .{ .table_alias = target_alias, .column = mapping.value_ptr.* },
            .op = .eq,
            .rhs = .{ .column = .{ .table_alias = source_alias, .column = mapping.key_ptr.* } },
        } });
    }
}

/// `query`/`schema_model` are threaded through purely to resolve relationship
/// names inside `exists(related: ...)`; `current_collection` is the collection
/// `alias` refers to, which only equals `query.collection` at the top of the
/// tree -- see `resolveRelationship`'s doc comment for why that distinction
/// matters once `exists` changes collection context partway through a tree.
fn translateExpr(
    allocator: std.mem.Allocator,
    query: *const ndc_ir.Query,
    schema_model: *const schema.SchemaModel,
    current_collection: []const u8,
    alias: []const u8,
    expr: ndc_ir.Expression,
) Error!ast.SqlExpr {
    switch (expr) {
        .and_ => |list| {
            const out = try allocator.alloc(ast.SqlExpr, list.len);
            for (list, 0..) |child, i| out[i] = try translateExpr(allocator, query, schema_model, current_collection, alias, child);
            return .{ .and_ = out };
        },
        .or_ => |list| {
            const out = try allocator.alloc(ast.SqlExpr, list.len);
            for (list, 0..) |child, i| out[i] = try translateExpr(allocator, query, schema_model, current_collection, alias, child);
            return .{ .or_ = out };
        },
        .not_ => |child| {
            const inner = try allocator.create(ast.SqlExpr);
            inner.* = try translateExpr(allocator, query, schema_model, current_collection, alias, child.*);
            return .{ .not_ = inner };
        },
        .binary_op => |b| {
            const column = ast.ColumnRef{ .table_alias = alias, .column = b.column.name };
            if (b.operator == .in) {
                // `_in` with a variable would need array-parameter binding
                // (e.g. `= ANY($1::text[])`), which pg_wire's text-only
                // parameter encoding doesn't support yet -- deliberately
                // deferred, see docs/decisions/0009-query-variables.md.
                const scalar = switch (b.value) {
                    .scalar => |s| s,
                    .variable => return Error.VariablesNotSupportedForIn,
                };
                const array = switch (scalar) {
                    .array => |a| a,
                    else => return Error.UnsupportedComparisonValue,
                };
                const values = try allocator.alloc(ast.Value, array.items.len);
                for (array.items, 0..) |item, i| values[i] = try toSqlValue(item);
                return .{ .in_ = .{ .column = column, .values = values } };
            }
            const value: ast.Value = switch (b.value) {
                .scalar => |s| try toSqlValue(s),
                .variable => |name| .{ .variable_ref = name },
            };
            return .{ .binary = .{
                .column = column,
                .op = toBinaryOp(b.operator),
                .rhs = .{ .value = value },
            } };
        },
        .unary_op => |u| {
            // Milestone 1's only unary operator; see docs/roadmap.md.
            std.debug.assert(u.operator == .is_null);
            return .{ .is_null = .{ .table_alias = alias, .column = u.column.name } };
        },
        .exists => |e| {
            var conjuncts: std.ArrayListUnmanaged(ast.SqlExpr) = .empty;
            const target_alias = switch (e.in_collection) {
                .related => |r| blk: {
                    const rel = resolveRelationship(query, schema_model, current_collection, r.relationship) orelse return Error.UnknownRelationship;
                    try appendJoinConjuncts(allocator, &conjuncts, rel, alias, rel.target_collection);
                    break :blk rel.target_collection;
                },
                .unrelated => |u| u.collection,
            };
            const target_collection = schema_model.collections.get(target_alias) orelse return Error.UnknownCollection;

            if (e.predicate) |pred| {
                const translated = try translateExpr(allocator, query, schema_model, target_alias, target_alias, pred.*);
                try conjuncts.append(allocator, translated);
            }

            const sub_select = try allocator.create(ast.Select);
            sub_select.* = .{
                .items = &.{},
                .from = .{ .schema = target_collection.db_schema, .table = target_collection.db_table, .alias = target_alias },
                .where = if (conjuncts.items.len > 0) .{ .and_ = try conjuncts.toOwnedSlice(allocator) } else null,
            };
            return .{ .exists = sub_select };
        },
    }
}

fn translateOrderBy(allocator: std.mem.Allocator, alias: []const u8, elements: []const ndc_ir.OrderByElement) Error![]const ast.OrderByItem {
    const out = try allocator.alloc(ast.OrderByItem, elements.len);
    for (elements, 0..) |element, i| {
        out[i] = .{
            .column = .{ .table_alias = alias, .column = element.target.name },
            .direction = switch (element.direction) {
                .asc => .asc,
                .desc => .desc,
            },
        };
    }
    return out;
}

/// Resolves a relationship by name, preferring `query.relationships` (populated
/// by every producer -- graphql_parser, query_builder, and the NDC-JSON
/// producer -- to mirror NDC's wire-level `collection_relationships`) and
/// falling back to the schema's own derived relationships. Honoring
/// `query.relationships` first is what makes `query_builder.selectRelationship`'s
/// "caller supplies the Relationship" contract real rather than illusory (see
/// docs/decisions/0007-sql-gen-honors-query-relationships.md).
///
/// `query.relationships` is only consulted when `current_collection` still
/// matches `query.collection` -- i.e. at the top of the expression/field tree.
/// Once `exists` changes context to a different collection partway through a
/// tree, further relationship lookups (nested exists inside an exists
/// predicate) resolve from the schema only, since `query.relationships` is
/// scoped to fields selected directly on `query`, not to an arbitrary
/// collection an expression happens to be evaluated against.
fn resolveRelationship(query: *const ndc_ir.Query, schema_model: *const schema.SchemaModel, current_collection: []const u8, name: []const u8) ?ndc_ir.Relationship {
    if (std.mem.eql(u8, current_collection, query.collection)) {
        if (query.relationships.get(name)) |rel| return rel;
    }
    const collection_relationships = schema_model.relationships.get(current_collection) orelse return null;
    return collection_relationships.get(name);
}

/// Finds or creates a display-independent column selection for an aggregate
/// that needs a raw column value (`column_count`/`single_column`), returning
/// whatever alias it's available under in `items`. Reuses an existing display
/// field's alias if one already selects the same column (no point adding a
/// duplicate); otherwise appends a new item under the column's own name and
/// flags `added_extra.*` so the caller knows to re-project 'rows' down to only
/// the originally-requested aliases (see docs/decisions/0008-aggregate-rendering.md).
fn ensureColumnAvailable(
    items: *std.ArrayListUnmanaged(ast.SelectItem),
    allocator: std.mem.Allocator,
    table_alias: []const u8,
    column_name: []const u8,
    added_extra: *bool,
) Error![]const u8 {
    for (items.items) |item| {
        switch (item) {
            .column => |c| if (std.mem.eql(u8, c.column.column, column_name)) return c.alias,
            .relationship => {},
        }
    }
    try items.append(allocator, .{ .column = .{
        .column = .{ .table_alias = table_alias, .column = column_name },
        .alias = column_name,
    } });
    added_extra.* = true;
    return column_name;
}

fn toAstAggregateFunction(f: ndc_ir.AggregateFunction) ast.AggregateFunction {
    return switch (f) {
        .min => .min,
        .max => .max,
        .sum => .sum,
        .avg => .avg,
    };
}

/// Translates an ndc_ir.Query into a SQL AST, resolving collection/relationship
/// names against the given SchemaModel. Pure function: no I/O, no allocation
/// lifetime beyond what `allocator` owns (an arena is expected — see
/// docs/architecture.md's arena-per-request convention).
pub fn translate(allocator: std.mem.Allocator, query: *const ndc_ir.Query, schema_model: *const schema.SchemaModel) Error!*const ast.RowSetQuery {
    const collection = schema_model.collections.get(query.collection) orelse return Error.UnknownCollection;
    const alias = query.collection;

    var items = try std.ArrayListUnmanaged(ast.SelectItem).initCapacity(allocator, query.fields.count());
    var field_it = query.fields.iterator();
    while (field_it.next()) |entry| {
        const field_alias = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .column => |c| {
                try items.append(allocator, .{ .column = .{
                    .column = .{ .table_alias = alias, .column = c.column },
                    .alias = field_alias,
                } });
            },
            .relationship => |r| {
                const rel = resolveRelationship(query, schema_model, query.collection, r.relationship) orelse return Error.UnknownRelationship;

                const nested_rsq = try translate(allocator, r.query, schema_model);

                // Fold the FK join condition into the nested select's WHERE, ANDed
                // with whatever predicate the nested query already carries.
                const target_alias = r.query.collection;
                var join_conjuncts: std.ArrayListUnmanaged(ast.SqlExpr) = .empty;
                try appendJoinConjuncts(allocator, &join_conjuncts, rel, alias, target_alias);
                if (nested_rsq.select.where) |existing| try join_conjuncts.append(allocator, existing);

                var joined_select = nested_rsq.select.*;
                joined_select.where = .{ .and_ = try join_conjuncts.toOwnedSlice(allocator) };
                const joined_select_ptr = try allocator.create(ast.Select);
                joined_select_ptr.* = joined_select;

                var joined_rsq = nested_rsq.*;
                joined_rsq.select = joined_select_ptr;
                const joined_rsq_ptr = try allocator.create(ast.RowSetQuery);
                joined_rsq_ptr.* = joined_rsq;

                try items.append(allocator, .{ .relationship = .{
                    .alias = field_alias,
                    .subquery = joined_rsq_ptr,
                    .single_row = rel.relationship_type == .object,
                } });
            },
        }
    }

    // Snapshot the display-field aliases (both column and relationship items)
    // before the aggregate loop below might append aggregate-support-only
    // columns -- these are exactly the aliases 'rows' should expose if a
    // re-projection turns out to be needed.
    const display_aliases = try allocator.alloc([]const u8, items.items.len);
    for (items.items, display_aliases) |item, *out| {
        out.* = switch (item) {
            .column => |c| c.alias,
            .relationship => |r| r.alias,
        };
    }

    var aggregate_items: std.ArrayListUnmanaged(ast.AggregateItem) = .empty;
    var added_extra_column = false;
    var agg_it = query.aggregates.iterator();
    while (agg_it.next()) |entry| {
        const agg_alias = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .star_count => try aggregate_items.append(allocator, .{ .alias = agg_alias, .expr = .star_count }),
            .column_count => |cc| {
                const col_alias = try ensureColumnAvailable(&items, allocator, alias, cc.column, &added_extra_column);
                try aggregate_items.append(allocator, .{ .alias = agg_alias, .expr = .{ .column_count = .{ .column_alias = col_alias, .distinct = cc.distinct } } });
            },
            .single_column => |sc| {
                const col_alias = try ensureColumnAvailable(&items, allocator, alias, sc.column, &added_extra_column);
                try aggregate_items.append(allocator, .{ .alias = agg_alias, .expr = .{ .single_column = .{ .column_alias = col_alias, .function = toAstAggregateFunction(sc.function) } } });
            },
        }
    }

    const where = if (query.predicate) |predicate| try translateExpr(allocator, query, schema_model, query.collection, alias, predicate) else null;
    const order_by = try translateOrderBy(allocator, alias, query.order_by);

    const select = try allocator.create(ast.Select);
    select.* = .{
        .items = try items.toOwnedSlice(allocator),
        .from = .{ .schema = collection.db_schema, .table = collection.db_table, .alias = alias },
        .where = where,
        .order_by = order_by,
        .limit = query.limit,
        .offset = query.offset,
    };

    const rsq = try allocator.create(ast.RowSetQuery);
    rsq.* = .{
        .select = select,
        .row_field_aliases = if (added_extra_column) display_aliases else null,
        .aggregates = try aggregate_items.toOwnedSlice(allocator),
    };
    return rsq;
}

test "translates a scalar-only query against a schema fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "AlbumId", .{ .column = .{ .column = "AlbumId" } });

    const rsq = try translate(allocator, &query, &schema_model);

    try std.testing.expectEqualStrings("album", rsq.select.from.table);
    try std.testing.expectEqual(@as(usize, 1), rsq.select.items.len);
    try std.testing.expectEqualStrings("AlbumId", rsq.select.items[0].column.alias);
    try std.testing.expect(rsq.row_field_aliases == null);
    try std.testing.expectEqual(@as(usize, 0), rsq.aggregates.len);
}

test "translates a predicate, order_by, limit and offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var query = ndc_ir.Query{ .collection = "album" };
    query.predicate = .{ .binary_op = .{
        .column = .{ .name = "ArtistId" },
        .operator = .eq,
        .value = .{ .scalar = .{ .integer = 1 } },
    } };
    query.order_by = try allocator.dupe(ndc_ir.OrderByElement, &.{
        .{ .target = .{ .name = "Title" }, .direction = .asc },
    });
    query.limit = 10;
    query.offset = 5;

    const rsq = try translate(allocator, &query, &schema_model);

    try std.testing.expect(rsq.select.where != null);
    try std.testing.expectEqual(ast.BinaryOp.eq, rsq.select.where.?.binary.op);
    try std.testing.expectEqual(@as(usize, 1), rsq.select.order_by.len);
    try std.testing.expectEqual(@as(?u32, 10), rsq.select.limit);
    try std.testing.expectEqual(@as(?u32, 5), rsq.select.offset);
}

test "translates a nested object relationship, folding the FK join into the nested WHERE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });
    try schema_model.collections.put(allocator, "artist", .{ .db_schema = "public", .db_table = "artist", .object_type = "artist" });

    var rel = ndc_ir.Relationship{ .target_collection = "artist", .relationship_type = .object };
    try rel.column_mapping.put(allocator, "artist_id", "artist_id");
    var album_relationships = ndc_ir.RelationshipMap{};
    try album_relationships.put(allocator, "artist", rel);
    try schema_model.relationships.put(allocator, "album", album_relationships);

    var nested_query = try allocator.create(ndc_ir.Query);
    nested_query.* = ndc_ir.Query{ .collection = "artist" };
    try nested_query.fields.put(allocator, "Name", .{ .column = .{ .column = "Name" } });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "Artist", .{ .relationship = .{ .relationship = "artist", .query = nested_query } });

    const rsq = try translate(allocator, &query, &schema_model);

    try std.testing.expectEqual(@as(usize, 1), rsq.select.items.len);
    const rel_item = rsq.select.items[0].relationship;
    try std.testing.expectEqualStrings("Artist", rel_item.alias);
    try std.testing.expect(rel_item.single_row);
    try std.testing.expectEqualStrings("artist", rel_item.subquery.select.from.table);
    try std.testing.expect(rel_item.subquery.select.where != null);
    try std.testing.expectEqual(@as(usize, 1), rel_item.subquery.select.where.?.and_.len);
    const join_expr = rel_item.subquery.select.where.?.and_[0].binary;
    try std.testing.expectEqualStrings("artist_id", join_expr.column.column);
    try std.testing.expectEqualStrings("artist_id", join_expr.rhs.column.column);
    try std.testing.expectEqualStrings("album", join_expr.rhs.column.table_alias);
}

test "query.relationships takes precedence over the schema's own derived relationships (docs/decisions/0007)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });
    try schema_model.collections.put(allocator, "artist", .{ .db_schema = "public", .db_table = "artist", .object_type = "artist" });
    // Deliberately no schema_model.relationships entry for "album" at all --
    // this relationship exists only because the query carries it.

    var nested_query = try allocator.create(ndc_ir.Query);
    nested_query.* = ndc_ir.Query{ .collection = "artist" };
    try nested_query.fields.put(allocator, "Name", .{ .column = .{ .column = "Name" } });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "Artist", .{ .relationship = .{ .relationship = "artist", .query = nested_query } });

    var caller_supplied_rel = ndc_ir.Relationship{ .target_collection = "artist", .relationship_type = .object };
    try caller_supplied_rel.column_mapping.put(allocator, "artist_id", "artist_id");
    try query.relationships.put(allocator, "artist", caller_supplied_rel);

    const rsq = try translate(allocator, &query, &schema_model);

    try std.testing.expectEqual(@as(usize, 1), rsq.select.items.len);
    try std.testing.expectEqualStrings("artist", rsq.select.items[0].relationship.subquery.select.from.table);
}

test "translates exists(related: ...) into a joined EXISTS subquery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });
    try schema_model.collections.put(allocator, "artist", .{ .db_schema = "public", .db_table = "artist", .object_type = "artist" });

    var rel = ndc_ir.Relationship{ .target_collection = "artist", .relationship_type = .object };
    try rel.column_mapping.put(allocator, "artist_id", "artist_id");
    var album_relationships = ndc_ir.RelationshipMap{};
    try album_relationships.put(allocator, "artist", rel);
    try schema_model.relationships.put(allocator, "album", album_relationships);

    const inner_predicate = try allocator.create(ndc_ir.Expression);
    inner_predicate.* = .{ .binary_op = .{
        .column = .{ .name = "name" },
        .operator = .eq,
        .value = .{ .scalar = .{ .string = "AC/DC" } },
    } };

    var query = ndc_ir.Query{ .collection = "album" };
    query.predicate = .{ .exists = .{
        .in_collection = .{ .related = .{ .relationship = "artist" } },
        .predicate = inner_predicate,
    } };

    const rsq = try translate(allocator, &query, &schema_model);

    try std.testing.expect(rsq.select.where != null);
    const exists_select = rsq.select.where.?.exists;
    try std.testing.expectEqualStrings("artist", exists_select.from.table);
    try std.testing.expectEqual(@as(usize, 2), exists_select.where.?.and_.len);

    const join_expr = exists_select.where.?.and_[0].binary;
    try std.testing.expectEqualStrings("artist_id", join_expr.column.column);
    try std.testing.expectEqualStrings("artist", join_expr.column.table_alias);
    try std.testing.expectEqualStrings("artist_id", join_expr.rhs.column.column);
    try std.testing.expectEqualStrings("album", join_expr.rhs.column.table_alias);

    const name_expr = exists_select.where.?.and_[1].binary;
    try std.testing.expectEqualStrings("name", name_expr.column.column);
    try std.testing.expectEqualStrings("AC/DC", name_expr.rhs.value.text);
}

test "translates exists(unrelated: ...) with no join conjuncts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });
    try schema_model.collections.put(allocator, "promotion", .{ .db_schema = "public", .db_table = "promotion", .object_type = "promotion" });

    var query = ndc_ir.Query{ .collection = "album" };
    query.predicate = .{ .exists = .{
        .in_collection = .{ .unrelated = .{ .collection = "promotion" } },
        .predicate = null,
    } };

    const rsq = try translate(allocator, &query, &schema_model);

    const exists_select = rsq.select.where.?.exists;
    try std.testing.expectEqualStrings("promotion", exists_select.from.table);
    try std.testing.expect(exists_select.where == null);
}

test "translates aggregates that only reference already-selected display columns (no reprojection needed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "AlbumId", .{ .column = .{ .column = "AlbumId" } });
    try query.aggregates.put(allocator, "count", .star_count);
    try query.aggregates.put(allocator, "max_id", .{ .single_column = .{ .column = "AlbumId", .function = .max } });

    const rsq = try translate(allocator, &query, &schema_model);

    try std.testing.expectEqual(@as(usize, 1), rsq.select.items.len); // AlbumId reused, not duplicated
    try std.testing.expect(rsq.row_field_aliases == null); // no extra column added
    try std.testing.expectEqual(@as(usize, 2), rsq.aggregates.len);
    try std.testing.expectEqual(ast.AggregateExpr.star_count, rsq.aggregates[0].expr);
    try std.testing.expectEqualStrings("AlbumId", rsq.aggregates[1].expr.single_column.column_alias);
    try std.testing.expectEqual(ast.AggregateFunction.max, rsq.aggregates[1].expr.single_column.function);
}

test "translates an aggregate referencing a column not otherwise selected, triggering reprojection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.fields.put(allocator, "Title", .{ .column = .{ .column = "Title" } });
    try query.aggregates.put(allocator, "max_id", .{ .single_column = .{ .column = "AlbumId", .function = .max } });

    const rsq = try translate(allocator, &query, &schema_model);

    // AlbumId was added to items to support the aggregate, alongside the
    // originally-requested Title.
    try std.testing.expectEqual(@as(usize, 2), rsq.select.items.len);
    try std.testing.expectEqualStrings("Title", rsq.select.items[0].column.alias);
    try std.testing.expectEqualStrings("AlbumId", rsq.select.items[1].column.alias);

    // row_field_aliases is set to exactly the original display aliases (Title only).
    try std.testing.expect(rsq.row_field_aliases != null);
    try std.testing.expectEqual(@as(usize, 1), rsq.row_field_aliases.?.len);
    try std.testing.expectEqualStrings("Title", rsq.row_field_aliases.?[0]);
}

test "a pure-aggregate query (no display fields) sets row_field_aliases to an empty, non-null slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_model = schema.SchemaModel{};
    try schema_model.collections.put(allocator, "album", .{ .db_schema = "public", .db_table = "album", .object_type = "album" });

    var query = ndc_ir.Query{ .collection = "album" };
    try query.aggregates.put(allocator, "count", .{ .column_count = .{ .column = "AlbumId", .distinct = false } });

    const rsq = try translate(allocator, &query, &schema_model);

    try std.testing.expectEqual(@as(usize, 1), rsq.select.items.len); // just the aggregate-support column
    try std.testing.expect(rsq.row_field_aliases != null);
    try std.testing.expectEqual(@as(usize, 0), rsq.row_field_aliases.?.len);
    try std.testing.expect(!rsq.aggregates[0].expr.column_count.distinct);
}

test "rejects a query against an unknown collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = schema.SchemaModel{};
    const query = ndc_ir.Query{ .collection = "nonexistent" };

    try std.testing.expectError(Error.UnknownCollection, translate(allocator, &query, &schema_model));
}
