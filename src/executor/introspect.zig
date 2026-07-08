const std = @import("std");
const schema = @import("schema");
const pg_wire = @import("pg_wire");

pub const Error = pg_wire.Error || schema.Error || std.mem.Allocator.Error || std.fmt.ParseIntError;

const tables_query =
    \\SELECT table_name FROM information_schema.tables
    \\WHERE table_schema = 'public' AND table_type IN ('BASE TABLE', 'VIEW')
;

/// `has_default`/`is_generated` feed `schema.ColumnRow` -- see
/// docs/decisions/0010-mutation-procedure-naming.md's insertability policy.
/// A column "has a default" if Postgres supplies a value when none is given,
/// which includes identity columns (`is_identity`) as well as an explicit
/// `DEFAULT` expression (`column_default IS NOT NULL`).
const columns_query =
    \\SELECT table_name, column_name, data_type, is_nullable,
    \\  (column_default IS NOT NULL OR is_identity = 'YES') AS has_default,
    \\  (is_generated = 'ALWAYS') AS is_generated
    \\FROM information_schema.columns
    \\WHERE table_schema = 'public'
;

/// Moved to `pg_catalog` (unlike the other introspection queries, still on
/// `information_schema`) specifically to fix a real bug the old
/// `information_schema`-based join had: joining `key_column_usage` ×
/// `constraint_column_usage` on `constraint_name` alone, with no ordinal
/// position, produced a cross-product of (wrong) column pairs for any
/// composite (multi-column) FK. `pg_constraint.conkey`/`confkey` are parallel
/// arrays of attribute numbers in constraint-column order; `unnest(...) WITH
/// ORDINALITY` zips them together with the position needed to reconstruct a
/// composite key's column order in `schema/introspect.zig`. See
/// docs/decisions/0012-permanent-relationship-naming.md.
const foreign_keys_query =
    \\SELECT con.conname, child.relname, child_att.attname, parent.relname, parent_att.attname, cols.ord
    \\FROM pg_constraint con
    \\JOIN pg_class child ON child.oid = con.conrelid
    \\JOIN pg_class parent ON parent.oid = con.confrelid
    \\JOIN pg_namespace ns ON ns.oid = child.relnamespace
    \\CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS cols(child_attnum, parent_attnum, ord)
    \\JOIN pg_attribute child_att ON child_att.attrelid = child.oid AND child_att.attnum = cols.child_attnum
    \\JOIN pg_attribute parent_att ON parent_att.attrelid = parent.oid AND parent_att.attnum = cols.parent_attnum
    \\WHERE con.contype = 'f' AND ns.nspname = 'public'
    \\ORDER BY con.conname, cols.ord
;

const primary_keys_query =
    \\SELECT tc.table_name, kcu.column_name
    \\FROM information_schema.table_constraints tc
    \\JOIN information_schema.key_column_usage kcu
    \\  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
    \\WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = 'public'
;

/// Runs milestone 1's introspection SQL (single `public` schema, tables/views
/// only, FK-derived relationships -- see docs/roadmap.md) against a live
/// connection and builds a SchemaModel via schema.buildSchemaModel's pure
/// row-based builder. `allocator` is expected to be an arena the caller owns
/// for the SchemaModel's whole lifetime (same convention as `buildSchemaModel`
/// itself) -- each intermediate QueryResult is freed before this returns, so
/// every string is copied into `allocator` rather than borrowed.
pub fn introspectLive(allocator: std.mem.Allocator, connection: *pg_wire.Connection) Error!schema.SchemaModel {
    var tables_result = try connection.query(tables_query, &.{});
    defer tables_result.deinit();
    const tables = try allocator.alloc(schema.TableRow, tables_result.rows.len);
    for (tables_result.rows, tables) |row, *out| {
        out.* = .{
            .schema_name = "public",
            .table_name = try allocator.dupe(u8, row.columns[0].?),
        };
    }

    var columns_result = try connection.query(columns_query, &.{});
    defer columns_result.deinit();
    const columns = try allocator.alloc(schema.ColumnRow, columns_result.rows.len);
    for (columns_result.rows, columns) |row, *out| {
        out.* = .{
            .table_name = try allocator.dupe(u8, row.columns[0].?),
            .column_name = try allocator.dupe(u8, row.columns[1].?),
            .pg_type = try allocator.dupe(u8, row.columns[2].?),
            .nullable = std.mem.eql(u8, row.columns[3].?, "YES"),
            // Postgres's text format for boolean is "t"/"f".
            .has_default = std.mem.eql(u8, row.columns[4].?, "t"),
            .is_generated = std.mem.eql(u8, row.columns[5].?, "t"),
        };
    }

    var fk_result = try connection.query(foreign_keys_query, &.{});
    defer fk_result.deinit();
    const foreign_keys = try allocator.alloc(schema.ForeignKeyRow, fk_result.rows.len);
    for (fk_result.rows, foreign_keys) |row, *out| {
        out.* = .{
            .constraint_name = try allocator.dupe(u8, row.columns[0].?),
            .table_name = try allocator.dupe(u8, row.columns[1].?),
            .column_name = try allocator.dupe(u8, row.columns[2].?),
            .foreign_table_name = try allocator.dupe(u8, row.columns[3].?),
            .foreign_column_name = try allocator.dupe(u8, row.columns[4].?),
            .ordinal = try std.fmt.parseInt(u32, row.columns[5].?, 10),
        };
    }

    var pk_result = try connection.query(primary_keys_query, &.{});
    defer pk_result.deinit();
    const primary_keys = try allocator.alloc(schema.PrimaryKeyRow, pk_result.rows.len);
    for (pk_result.rows, primary_keys) |row, *out| {
        out.* = .{
            .table_name = try allocator.dupe(u8, row.columns[0].?),
            .column_name = try allocator.dupe(u8, row.columns[1].?),
        };
    }

    return schema.buildSchemaModel(allocator, .{
        .tables = tables,
        .columns = columns,
        .foreign_keys = foreign_keys,
        .primary_keys = primary_keys,
    });
}
