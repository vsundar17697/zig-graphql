const expression = @import("expression.zig");

pub const OrderDirection = enum { asc, desc };

pub const OrderByElement = struct {
    target: expression.ComparisonTarget,
    direction: OrderDirection,
};

const std = @import("std");

test "OrderByElement is a plain value type, no cleanup needed" {
    const element = OrderByElement{
        .target = .{ .name = "Title" },
        .direction = .asc,
    };
    try std.testing.expectEqual(OrderDirection.asc, element.direction);
}
