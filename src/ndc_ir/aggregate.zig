const std = @import("std");

pub const AggregateFunction = enum { min, max, sum, avg };

/// NDC's three aggregate shapes: `star_count` needs no column, `column_count`
/// counts non-null (or distinct) values of one column, `single_column` applies
/// a numeric function to one column. See docs/roadmap.md for the milestone 2
/// aggregate scope.
pub const Aggregate = union(enum) {
    star_count,
    column_count: struct { column: []const u8, distinct: bool },
    single_column: struct { column: []const u8, function: AggregateFunction },
};

test "Aggregate variants are plain data" {
    const a: Aggregate = .star_count;
    try std.testing.expectEqual(Aggregate.star_count, a);

    const b = Aggregate{ .single_column = .{ .column = "AlbumId", .function = .max } };
    try std.testing.expectEqualStrings("AlbumId", b.single_column.column);
}
