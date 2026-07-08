const std = @import("std");

/// Milestone 1 requires `object`; `array` is reserved so sql_gen can add a
/// second lowering case later without changing this type (see
/// docs/decisions/0003-json-shaping-sql-in-generator.md).
pub const RelationshipType = enum { object, array };

/// Source column name -> target column name, derived from a foreign key.
pub const ColumnMapping = std.StringHashMapUnmanaged([]const u8);

pub const Relationship = struct {
    target_collection: []const u8,
    relationship_type: RelationshipType,
    column_mapping: ColumnMapping = .{},

    pub fn deinit(self: *Relationship, allocator: std.mem.Allocator) void {
        self.column_mapping.deinit(allocator);
    }
};

test "Relationship owns its column_mapping map" {
    const allocator = std.testing.allocator;
    var rel = Relationship{
        .target_collection = "artist",
        .relationship_type = .object,
    };
    try rel.column_mapping.put(allocator, "artist_id", "artist_id");
    rel.deinit(allocator);
}
