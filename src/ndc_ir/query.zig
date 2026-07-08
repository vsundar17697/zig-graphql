const std = @import("std");
const expression = @import("expression.zig");
const order_by = @import("order_by.zig");
const relationship = @import("relationship.zig");
const aggregate = @import("aggregate.zig");

pub const Expression = expression.Expression;
pub const OrderByElement = order_by.OrderByElement;
pub const Relationship = relationship.Relationship;
pub const Aggregate = aggregate.Aggregate;

/// Preserves insertion order for the same reason FieldSelection does (see
/// below) -- deterministic 'aggregates' key order in the JSON output.
pub const AggregateSelection = std.StringArrayHashMapUnmanaged(Aggregate);

/// One binding of variable name -> concrete value, supplied alongside (not
/// inside) a Query at execution time -- see docs/decisions/0009-query-variables.md.
/// A request names N of these to get N RowSets back, one per set, all sharing
/// the same rendered SQL.
pub const VariableSet = std.StringArrayHashMapUnmanaged(std.json.Value);

/// Preserves insertion order so the field selection mirrors GraphQL field
/// order (or the order a query-builder call listed columns in) — this is
/// what makes response-field ordering deterministic, which the byte-identical
/// GraphQL-path-vs-query-builder-path integration test in task #10 depends on.
pub const FieldSelection = std.StringArrayHashMapUnmanaged(Field);

/// Order doesn't matter here — this mirrors NDC's `collection_relationships`,
/// looked up by name, never iterated for its own order.
pub const RelationshipMap = std.StringHashMapUnmanaged(Relationship);

pub const ColumnField = struct {
    column: []const u8,
};

pub const RelationshipField = struct {
    relationship: []const u8,
    query: *Query,

    pub fn deinit(self: *RelationshipField, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        allocator.destroy(self.query);
    }
};

pub const Field = union(enum) {
    column: ColumnField,
    relationship: RelationshipField,

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .column => {},
            .relationship => |*r| r.deinit(allocator),
        }
    }
};

/// A fully-resolved query against one collection. Both graphql_parser and
/// query_builder produce this same type (see docs/architecture.md) — sql_gen
/// cannot tell which producer built any given value.
///
/// String slices (collection/column/relationship names) are always borrowed
/// from an arena the caller controls; `deinit` only tears down containers and
/// pointers this type itself allocates (the fields map, the order_by slice,
/// the relationships map, and boxed nested Query/Expression values).
pub const Query = struct {
    collection: []const u8,
    fields: FieldSelection = .{},
    predicate: ?Expression = null,
    order_by: []OrderByElement = &.{},
    limit: ?u32 = null,
    offset: ?u32 = null,
    relationships: RelationshipMap = .{},
    /// Reserved slot per docs/roadmap.md's milestone 1 promise: adding
    /// aggregates only required this field plus a new sql_gen node kind, no
    /// change to Expression or the field-selection machinery.
    aggregates: AggregateSelection = .{},

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        var field_it = self.fields.iterator();
        while (field_it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.fields.deinit(allocator);

        if (self.predicate) |*p| p.deinit(allocator);

        allocator.free(self.order_by);

        var rel_it = self.relationships.valueIterator();
        while (rel_it.next()) |rel| {
            rel.deinit(allocator);
        }
        self.relationships.deinit(allocator);

        self.aggregates.deinit(allocator);

        self.* = undefined;
    }
};

test "empty Query needs no allocation to construct or free" {
    var q = Query{ .collection = "album" };
    q.deinit(std.testing.allocator);
}

test "Query with a column field selection" {
    const allocator = std.testing.allocator;
    var q = Query{ .collection = "album" };
    try q.fields.put(allocator, "AlbumId", .{ .column = .{ .column = "AlbumId" } });
    try q.fields.put(allocator, "Title", .{ .column = .{ .column = "Title" } });
    defer q.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), q.fields.count());
    // FieldSelection preserves insertion order.
    try std.testing.expectEqualStrings("AlbumId", q.fields.keys()[0]);
    try std.testing.expectEqualStrings("Title", q.fields.keys()[1]);
}

test "Query with one nested relationship field owns the nested Query" {
    const allocator = std.testing.allocator;
    var q = Query{ .collection = "album" };

    const nested = try allocator.create(Query);
    nested.* = Query{ .collection = "artist" };
    try nested.fields.put(allocator, "Name", .{ .column = .{ .column = "Name" } });

    try q.fields.put(allocator, "Artist", .{ .relationship = .{
        .relationship = "AlbumToArtist",
        .query = nested,
    } });

    var rel = Relationship{ .target_collection = "artist", .relationship_type = .object };
    try rel.column_mapping.put(allocator, "artist_id", "artist_id");
    try q.relationships.put(allocator, "AlbumToArtist", rel);

    q.deinit(allocator); // must free the nested Query, its fields map, and the relationship map
}

test "Query with a predicate, order_by, limit and offset" {
    const allocator = std.testing.allocator;
    var q = Query{ .collection = "album" };

    q.predicate = Expression{ .binary_op = .{
        .column = .{ .name = "ArtistId" },
        .operator = .eq,
        .value = .{ .scalar = .{ .integer = 1 } },
    } };

    const elements = try allocator.alloc(OrderByElement, 1);
    elements[0] = .{ .target = .{ .name = "Title" }, .direction = .asc };
    q.order_by = elements;

    q.limit = 10;
    q.offset = 0;

    defer q.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 10), q.limit);
    try std.testing.expectEqual(@as(usize, 1), q.order_by.len);
}
