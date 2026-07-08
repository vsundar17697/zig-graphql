const std = @import("std");
const ndc_ir = @import("ndc_ir");
const model = @import("model.zig");

/// Raw row shapes mirror what `information_schema` returns for milestone 1's
/// introspection scope (single `public` schema, tables/views only, FK-derived
/// relationships only — see docs/roadmap.md). Kept separate from the actual SQL
/// so `build` below is a pure function, testable with hand-built fixture rows
/// and no live Postgres connection.
///
/// The thin wrapper that runs the introspection SQL via pg_wire.Connection and
/// feeds real rows into `build` lands once pg_wire exists (task #4) — its shape
/// doesn't affect `build`'s design, which is the point of this split.
pub const TableRow = struct {
    schema_name: []const u8,
    table_name: []const u8,
};

pub const ColumnRow = struct {
    table_name: []const u8,
    column_name: []const u8,
    /// Postgres type name as reported by information_schema.columns.data_type.
    pg_type: []const u8,
    nullable: bool,
    /// From information_schema.columns.column_default IS NOT NULL, OR'd with
    /// is_identity = 'YES' -- see model.ObjectField.has_default.
    has_default: bool = false,
    /// From information_schema.columns.is_generated = 'ALWAYS' -- see
    /// model.ObjectField.is_generated.
    is_generated: bool = false,
};

/// One column of one foreign key constraint -- a composite (multi-column) FK
/// is represented as several rows sharing `constraint_name`, distinguished by
/// `ordinal` (1-based position within the constraint). `constraint_name` is
/// what `build` groups rows by; Postgres constraint names are unique within
/// one schema, so grouping by name alone (not name+table) is sufficient.
pub const ForeignKeyRow = struct {
    constraint_name: []const u8,
    table_name: []const u8,
    column_name: []const u8,
    foreign_table_name: []const u8,
    foreign_column_name: []const u8,
    ordinal: u32 = 1,
};

pub const PrimaryKeyRow = struct {
    table_name: []const u8,
    column_name: []const u8,
};

pub const IntrospectionRows = struct {
    tables: []const TableRow,
    columns: []const ColumnRow,
    foreign_keys: []const ForeignKeyRow = &.{},
    primary_keys: []const PrimaryKeyRow = &.{},
};

pub const Error = error{ UnknownPgType, DuplicateRelationshipName } || std.mem.Allocator.Error;

const ALL_OPERATORS = [_]ndc_ir.BinaryOperator{ .eq, .neq, .gt, .gte, .lt, .lte, .in };

/// Fixed operator set applied to every scalar type in milestone 1 (see
/// docs/roadmap.md) rather than discovered per-type from pg_operator.
const SCALAR_TYPES = [_]model.ScalarType{
    .{ .name = "Int", .comparison_operators = &ALL_OPERATORS },
    .{ .name = "Float", .comparison_operators = &ALL_OPERATORS },
    .{ .name = "String", .comparison_operators = &ALL_OPERATORS },
    .{ .name = "Boolean", .comparison_operators = &ALL_OPERATORS },
    .{ .name = "Timestamp", .comparison_operators = &ALL_OPERATORS },
};

fn pgTypeToScalarName(pg_type: []const u8) ?[]const u8 {
    const int_types = [_][]const u8{ "smallint", "integer", "bigint" };
    const float_types = [_][]const u8{ "real", "double precision", "numeric" };
    const string_types = [_][]const u8{ "text", "character varying", "character" };
    const bool_types = [_][]const u8{"boolean"};
    const timestamp_types = [_][]const u8{ "timestamp without time zone", "timestamp with time zone", "date" };

    for (int_types) |t| if (std.mem.eql(u8, pg_type, t)) return "Int";
    for (float_types) |t| if (std.mem.eql(u8, pg_type, t)) return "Float";
    for (string_types) |t| if (std.mem.eql(u8, pg_type, t)) return "String";
    for (bool_types) |t| if (std.mem.eql(u8, pg_type, t)) return "Boolean";
    for (timestamp_types) |t| if (std.mem.eql(u8, pg_type, t)) return "Timestamp";
    return null;
}

/// Builds a SchemaModel from already-fetched introspection rows. `allocator` is
/// expected to be an arena allocator (or another allocator the caller is happy
/// to free wholesale) since SchemaModel does not provide fine-grained `deinit`
/// (see the doc comment on `model.SchemaModel`).
pub fn build(allocator: std.mem.Allocator, rows: IntrospectionRows) Error!model.SchemaModel {
    var schema = model.SchemaModel{};

    for (SCALAR_TYPES) |scalar_type| {
        try schema.scalar_types.put(allocator, scalar_type.name, scalar_type);
    }

    for (rows.tables) |table| {
        try schema.collections.put(allocator, table.table_name, .{
            .db_schema = table.schema_name,
            .db_table = table.table_name,
            .object_type = table.table_name,
        });
        try schema.object_types.put(allocator, table.table_name, .{});
    }

    for (rows.columns) |col| {
        const scalar_name = pgTypeToScalarName(col.pg_type) orelse return Error.UnknownPgType;
        const object_type = schema.object_types.getPtr(col.table_name) orelse continue;
        try object_type.fields.put(allocator, col.column_name, .{
            .scalar_type = scalar_name,
            .nullable = col.nullable,
            .has_default = col.has_default,
            .is_generated = col.is_generated,
        });
    }

    if (rows.primary_keys.len > 0) {
        var pk_columns: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{};
        for (rows.primary_keys) |pk| {
            const gop = try pk_columns.getOrPut(allocator, pk.table_name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, pk.column_name);
        }
        var pk_it = pk_columns.iterator();
        while (pk_it.next()) |entry| {
            if (schema.collections.getPtr(entry.key_ptr.*)) |collection| {
                collection.primary_key = try entry.value_ptr.toOwnedSlice(allocator);
            }
        }
    }

    const grouped = try groupForeignKeys(allocator, rows.foreign_keys);
    const pending = try buildPendingRelationships(allocator, grouped);
    try addRelationships(allocator, &schema, pending);

    return schema;
}

/// One column of one FK constraint, source/target column names paired up
/// (ordinal order already applied by `groupForeignKeys`).
const ColumnPair = struct { source: []const u8, target: []const u8 };

/// One fully-grouped multi-column-aware foreign key: every row sharing a
/// `constraint_name` collapsed into one entry with an ordered column list.
const GroupedForeignKey = struct {
    constraint_name: []const u8,
    table_name: []const u8,
    foreign_table_name: []const u8,
    columns: []const ColumnPair,
};

/// Groups `rows` (one row per FK column, see `ForeignKeyRow`'s doc comment)
/// by `constraint_name`, sorting each group's columns by `ordinal` -- this is
/// what makes a composite (multi-column) FK become one `Relationship` with a
/// multi-entry `column_mapping` instead of colliding as N single-column
/// relationships (the milestone-1..3 behavior, which also had a live-query
/// bug producing a cross-product of wrong column pairs for composite FKs --
/// see docs/decisions/0012-permanent-relationship-naming.md).
fn groupForeignKeys(allocator: std.mem.Allocator, rows: []const ForeignKeyRow) Error![]const GroupedForeignKey {
    const Entry = struct {
        table_name: []const u8,
        foreign_table_name: []const u8,
        rows: std.ArrayListUnmanaged(ForeignKeyRow) = .empty,
    };
    var by_constraint: std.StringArrayHashMapUnmanaged(Entry) = .{};

    for (rows) |row| {
        const gop = try by_constraint.getOrPut(allocator, row.constraint_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .table_name = row.table_name, .foreign_table_name = row.foreign_table_name };
        }
        try gop.value_ptr.rows.append(allocator, row);
    }

    const out = try allocator.alloc(GroupedForeignKey, by_constraint.count());
    for (by_constraint.keys(), by_constraint.values(), out) |constraint_name, *entry, *dst| {
        std.mem.sort(ForeignKeyRow, entry.rows.items, {}, struct {
            fn lessThan(_: void, a: ForeignKeyRow, b: ForeignKeyRow) bool {
                return a.ordinal < b.ordinal;
            }
        }.lessThan);

        const columns = try allocator.alloc(ColumnPair, entry.rows.items.len);
        for (entry.rows.items, columns) |row, *pair| pair.* = .{ .source = row.column_name, .target = row.foreign_column_name };

        dst.* = .{ .constraint_name = constraint_name, .table_name = entry.table_name, .foreign_table_name = entry.foreign_table_name, .columns = columns };
    }
    return out;
}

fn joinColumnNames(allocator: std.mem.Allocator, columns: []const ColumnPair, comptime side: enum { source, target }) Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (columns, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, '_');
        try buf.appendSlice(allocator, if (side == .source) c.source else c.target);
    }
    return buf.toOwnedSlice(allocator);
}

/// Strips one trailing `_id` (the overwhelmingly common FK-column
/// convention), e.g. `artist_id` -> `artist`. Columns without that suffix
/// (e.g. self-referential `reports_to`) are used verbatim.
fn stripTrailingId(name: []const u8) []const u8 {
    const suffix = "_id";
    if (name.len > suffix.len and std.mem.endsWith(u8, name, suffix)) {
        return name[0 .. name.len - suffix.len];
    }
    return name;
}

/// A relationship candidate before naming collisions are resolved --
/// `qualified_name` is the fully-qualified fallback to try if `preferred_name`
/// collides; `null` means there is no further fallback (the reverse
/// direction's name is already maximally qualified) and a collision there is
/// an immediate hard error.
const PendingRelationship = struct {
    from_collection: []const u8,
    preferred_name: []const u8,
    qualified_name: ?[]const u8,
    relationship: ndc_ir.Relationship,
};

/// See docs/decisions/0012-permanent-relationship-naming.md for the full
/// rationale. Forward (object, child->parent): the FK source column with one
/// trailing `_id` stripped, or the qualified `<target>_by_<columns>` form on
/// collision. Reverse (array, parent->children): *always* qualified,
/// `<child>_by_<columns>` -- deliberately never the shorter form, since a
/// conditional name would silently rename an already-shipped GraphQL field
/// the moment an unrelated migration adds a second FK to the same target.
///
/// Self-referential FK special case: when `table_name == foreign_table_name`,
/// forward's qualified fallback (`<target>_by_<cols>`) and reverse's name
/// (`<child>_by_<cols>`) are the exact same formula applied to the exact same
/// table, so they'd collide with each other whenever forward actually needs
/// to fall back (which is *always* true for a non-`_id`-suffixed self-FK
/// column, since the preferred name then equals the column's own name and
/// necessarily collides with that column). Forward's fallback uses the
/// constraint name instead in that one case -- globally unique by
/// construction, and it's the only scenario where the two formulas can ever
/// coincide (any non-self-referential FK has `table_name != foreign_table_name`,
/// which alone keeps the two formulas textually distinct).
fn buildPendingRelationships(allocator: std.mem.Allocator, grouped: []const GroupedForeignKey) Error![]const PendingRelationship {
    var pending: std.ArrayListUnmanaged(PendingRelationship) = .empty;

    for (grouped) |g| {
        var forward_mapping: ndc_ir.RelationshipColumnMapping = .{};
        var reverse_mapping: ndc_ir.RelationshipColumnMapping = .{};
        for (g.columns) |c| {
            try forward_mapping.put(allocator, c.source, c.target);
            try reverse_mapping.put(allocator, c.target, c.source);
        }

        const joined_source = try joinColumnNames(allocator, g.columns, .source);
        const is_self_referential = std.mem.eql(u8, g.table_name, g.foreign_table_name);
        const qualified_forward = if (is_self_referential)
            g.constraint_name
        else
            try std.fmt.allocPrint(allocator, "{s}_by_{s}", .{ g.foreign_table_name, joined_source });
        const preferred_forward = if (g.columns.len == 1) stripTrailingId(g.columns[0].source) else qualified_forward;

        try pending.append(allocator, .{
            .from_collection = g.table_name,
            .preferred_name = preferred_forward,
            .qualified_name = qualified_forward,
            .relationship = .{ .target_collection = g.foreign_table_name, .relationship_type = .object, .column_mapping = forward_mapping },
        });

        const reverse_name = try std.fmt.allocPrint(allocator, "{s}_by_{s}", .{ g.table_name, joined_source });
        try pending.append(allocator, .{
            .from_collection = g.foreign_table_name,
            .preferred_name = reverse_name,
            .qualified_name = null,
            .relationship = .{ .target_collection = g.table_name, .relationship_type = .array, .column_mapping = reverse_mapping },
        });
    }

    return pending.toOwnedSlice(allocator);
}

/// Resolves naming collisions and inserts every relationship into `schema`.
/// A `preferred_name` collision (with a column of the owning object type, or
/// with another relationship being added to the same collection in this same
/// call) falls back to `qualified_name` if one exists; a collision there, or
/// a `preferred_name` collision with no fallback available (the reverse
/// direction), is a hard `Error.DuplicateRelationshipName` -- silently
/// overwriting or dropping a relationship would be worse than refusing to
/// introspect.
fn addRelationships(allocator: std.mem.Allocator, schema: *model.SchemaModel, pending: []const PendingRelationship) Error!void {
    var by_collection: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(*const PendingRelationship)) = .{};
    for (pending) |*p| {
        const gop = try by_collection.getOrPut(allocator, p.from_collection);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, p);
    }

    var it = by_collection.iterator();
    while (it.next()) |entry| {
        const collection_name = entry.key_ptr.*;
        const object_type = schema.object_types.get(collection_name);
        var chosen_names: std.StringHashMapUnmanaged(void) = .{};

        for (entry.value_ptr.items) |p| {
            var name = p.preferred_name;
            var collides = (object_type != null and object_type.?.fields.contains(name)) or chosen_names.contains(name);
            if (collides) {
                if (p.qualified_name) |qualified| {
                    name = qualified;
                    collides = (object_type != null and object_type.?.fields.contains(name)) or chosen_names.contains(name);
                }
            }
            if (collides) return Error.DuplicateRelationshipName;

            try chosen_names.put(allocator, name, {});

            const gop = try schema.relationships.getOrPut(allocator, collection_name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.put(allocator, name, p.relationship);
        }
    }
}

test "build populates the fixed scalar type registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = try build(arena.allocator(), .{ .tables = &.{}, .columns = &.{} });

    try std.testing.expectEqual(@as(usize, 5), schema.scalar_types.count());
    try std.testing.expect(schema.scalar_types.contains("Int"));
    try std.testing.expect(schema.scalar_types.contains("Timestamp"));
}

test "build maps tables and columns into collections and object types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = try build(arena.allocator(), .{
        .tables = &.{
            .{ .schema_name = "public", .table_name = "artist" },
            .{ .schema_name = "public", .table_name = "album" },
        },
        .columns = &.{
            .{ .table_name = "artist", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "artist", .column_name = "name", .pg_type = "text", .nullable = false },
            .{ .table_name = "album", .column_name = "album_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "album", .column_name = "title", .pg_type = "text", .nullable = false },
            .{ .table_name = "album", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
        },
        .primary_keys = &.{
            .{ .table_name = "artist", .column_name = "artist_id" },
            .{ .table_name = "album", .column_name = "album_id" },
        },
    });

    try std.testing.expectEqual(@as(usize, 2), schema.collections.count());

    const album_collection = schema.collections.get("album").?;
    try std.testing.expectEqualStrings("album", album_collection.object_type);
    try std.testing.expectEqualStrings("album_id", album_collection.primary_key[0]);

    const album_object_type = schema.object_types.get("album").?;
    try std.testing.expectEqual(@as(usize, 3), album_object_type.fields.count());
    // ObjectType.fields preserves column order.
    try std.testing.expectEqualStrings("album_id", album_object_type.fields.keys()[0]);

    const title_field = album_object_type.fields.get("title").?;
    try std.testing.expectEqualStrings("String", title_field.scalar_type);
}

test "build derives both an object relationship and its reverse array relationship from one foreign key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = try build(arena.allocator(), .{
        .tables = &.{
            .{ .schema_name = "public", .table_name = "artist" },
            .{ .schema_name = "public", .table_name = "album" },
        },
        .columns = &.{
            .{ .table_name = "artist", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "album", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
        },
        .foreign_keys = &.{
            .{ .constraint_name = "album_artist_id_fkey", .table_name = "album", .column_name = "artist_id", .foreign_table_name = "artist", .foreign_column_name = "artist_id" },
        },
    });

    // Forward: album -> artist, object, named "artist" (the "_id" suffix stripped from the FK column).
    const album_relationships = schema.relationships.get("album").?;
    const forward = album_relationships.get("artist").?;
    try std.testing.expectEqualStrings("artist", forward.target_collection);
    try std.testing.expectEqual(ndc_ir.RelationshipType.object, forward.relationship_type);
    try std.testing.expectEqualStrings("artist_id", forward.column_mapping.get("artist_id").?);

    // Reverse: artist -> album, array, always qualified as "<child>_by_<column>"
    // (see docs/decisions/0012-permanent-relationship-naming.md), with inverted column mapping.
    const artist_relationships = schema.relationships.get("artist").?;
    const reverse = artist_relationships.get("album_by_artist_id").?;
    try std.testing.expectEqualStrings("album", reverse.target_collection);
    try std.testing.expectEqual(ndc_ir.RelationshipType.array, reverse.relationship_type);
    try std.testing.expectEqualStrings("artist_id", reverse.column_mapping.get("artist_id").?);
}

test "build carries has_default and is_generated through to ObjectField" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = try build(arena.allocator(), .{
        .tables = &.{.{ .schema_name = "public", .table_name = "album" }},
        .columns = &.{
            .{ .table_name = "album", .column_name = "album_id", .pg_type = "integer", .nullable = false, .has_default = true },
            .{ .table_name = "album", .column_name = "title", .pg_type = "text", .nullable = false },
            .{ .table_name = "album", .column_name = "search_text", .pg_type = "text", .nullable = true, .is_generated = true },
        },
    });

    const album_object_type = schema.object_types.get("album").?;
    try std.testing.expect(album_object_type.fields.get("album_id").?.has_default);
    try std.testing.expect(!album_object_type.fields.get("title").?.has_default);
    try std.testing.expect(album_object_type.fields.get("search_text").?.is_generated);
    try std.testing.expect(!album_object_type.fields.get("title").?.is_generated);
}

test "two foreign keys from the same table to the same target resolve to distinct names, no collision" {
    // The exact scenario ADR 0006's stopgap hard-errored on. The permanent
    // scheme (docs/decisions/0012-permanent-relationship-naming.md) resolves
    // it cleanly, and neither direction even needs its collision fallback
    // here: forward names come from each FK's own *source column*
    // ("artist_id" -> "artist", "composer_id" -> "composer" -- distinct
    // because the columns are), and reverse names are always qualified by
    // column ("album_by_artist_id"/"album_by_composer_id" -- distinct for
    // the same reason). See the separate "falls back to the qualified form"
    // test below for a case that actually exercises the fallback.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema = try build(allocator, .{
        .tables = &.{
            .{ .schema_name = "public", .table_name = "artist" },
            .{ .schema_name = "public", .table_name = "album" },
        },
        .columns = &.{
            .{ .table_name = "artist", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "album", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "album", .column_name = "composer_id", .pg_type = "integer", .nullable = true },
        },
        .foreign_keys = &.{
            .{ .constraint_name = "album_artist_id_fkey", .table_name = "album", .column_name = "artist_id", .foreign_table_name = "artist", .foreign_column_name = "artist_id" },
            .{ .constraint_name = "album_composer_id_fkey", .table_name = "album", .column_name = "composer_id", .foreign_table_name = "artist", .foreign_column_name = "artist_id" },
        },
    });

    const album_relationships = schema.relationships.get("album").?;
    try std.testing.expectEqualStrings("artist_id", album_relationships.get("artist").?.column_mapping.get("artist_id").?);
    try std.testing.expectEqualStrings("artist_id", album_relationships.get("composer").?.column_mapping.get("composer_id").?);

    const artist_relationships = schema.relationships.get("artist").?;
    try std.testing.expect(artist_relationships.contains("album_by_artist_id"));
    try std.testing.expect(artist_relationships.contains("album_by_composer_id"));
}

test "a self-referential foreign key resolves forward and reverse to distinct names" {
    // Forward's "preferred" name (no "_id" suffix to strip off "reports_to")
    // is identical to the FK column's own literal name, which always exists
    // as a column on that object type -- so it always collides and falls
    // back. The fallback can't be the usual "<target>_by_<cols>" qualified
    // form here, since target == source (self-referential) makes that
    // formula collide with reverse's own name; the constraint name
    // disambiguates instead (see docs/decisions/0012, buildPendingRelationships's
    // self-referential special case).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema = try build(allocator, .{
        .tables = &.{.{ .schema_name = "public", .table_name = "employee" }},
        .columns = &.{
            .{ .table_name = "employee", .column_name = "employee_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "employee", .column_name = "reports_to", .pg_type = "integer", .nullable = true },
        },
        .foreign_keys = &.{
            .{ .constraint_name = "employee_reports_to_fkey", .table_name = "employee", .column_name = "reports_to", .foreign_table_name = "employee", .foreign_column_name = "employee_id" },
        },
    });

    const employee_relationships = schema.relationships.get("employee").?;
    try std.testing.expect(!employee_relationships.contains("reports_to")); // claimed by the column

    const forward = employee_relationships.get("employee_reports_to_fkey").?;
    try std.testing.expectEqual(ndc_ir.RelationshipType.object, forward.relationship_type);

    const reverse = employee_relationships.get("employee_by_reports_to").?;
    try std.testing.expectEqual(ndc_ir.RelationshipType.array, reverse.relationship_type);
}

test "a composite (multi-column) foreign key becomes one relationship, not one per column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema = try build(allocator, .{
        .tables = &.{
            .{ .schema_name = "public", .table_name = "publisher" },
            .{ .schema_name = "public", .table_name = "book" },
        },
        .columns = &.{
            .{ .table_name = "publisher", .column_name = "region", .pg_type = "text", .nullable = false },
            .{ .table_name = "publisher", .column_name = "code", .pg_type = "text", .nullable = false },
            .{ .table_name = "book", .column_name = "publisher_region", .pg_type = "text", .nullable = false },
            .{ .table_name = "book", .column_name = "publisher_code", .pg_type = "text", .nullable = false },
        },
        .foreign_keys = &.{
            .{ .constraint_name = "book_publisher_fkey", .table_name = "book", .column_name = "publisher_region", .foreign_table_name = "publisher", .foreign_column_name = "region", .ordinal = 1 },
            .{ .constraint_name = "book_publisher_fkey", .table_name = "book", .column_name = "publisher_code", .foreign_table_name = "publisher", .foreign_column_name = "code", .ordinal = 2 },
        },
    });

    // Forward: named "publisher_by_<cols>" since a >1-column FK has no single
    // column to strip "_id" from -- always the qualified form.
    const book_relationships = schema.relationships.get("book").?;
    const forward = book_relationships.get("publisher_by_publisher_region_publisher_code").?;
    try std.testing.expectEqual(@as(usize, 2), forward.column_mapping.count());
    try std.testing.expectEqualStrings("region", forward.column_mapping.get("publisher_region").?);
    try std.testing.expectEqualStrings("code", forward.column_mapping.get("publisher_code").?);

    const publisher_relationships = schema.relationships.get("publisher").?;
    const reverse = publisher_relationships.get("book_by_publisher_region_publisher_code").?;
    try std.testing.expectEqual(@as(usize, 2), reverse.column_mapping.count());
    try std.testing.expectEqualStrings("publisher_region", reverse.column_mapping.get("region").?);
}

test "a relationship name colliding with a column name falls back to the qualified form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema = try build(allocator, .{
        .tables = &.{
            .{ .schema_name = "public", .table_name = "artist" },
            .{ .schema_name = "public", .table_name = "album" },
        },
        .columns = &.{
            .{ .table_name = "artist", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
            .{ .table_name = "album", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
            // A denormalized text column that happens to share the preferred relationship name.
            .{ .table_name = "album", .column_name = "artist", .pg_type = "text", .nullable = true },
        },
        .foreign_keys = &.{
            .{ .constraint_name = "album_artist_id_fkey", .table_name = "album", .column_name = "artist_id", .foreign_table_name = "artist", .foreign_column_name = "artist_id" },
        },
    });

    const album_relationships = schema.relationships.get("album").?;
    try std.testing.expect(!album_relationships.contains("artist")); // claimed by the column
    try std.testing.expect(album_relationships.contains("artist_by_artist_id"));
}

test "build rejects an unrecognized Postgres type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = build(arena.allocator(), .{
        .tables = &.{.{ .schema_name = "public", .table_name = "widget" }},
        .columns = &.{
            .{ .table_name = "widget", .column_name = "payload", .pg_type = "jsonb", .nullable = true },
        },
    });

    try std.testing.expectError(Error.UnknownPgType, result);
}
