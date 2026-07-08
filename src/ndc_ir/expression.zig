const std = @import("std");

/// Milestone 1's comparison operator subset (see docs/roadmap.md).
pub const BinaryOperator = enum { eq, neq, gt, gte, lt, lte, in };
pub const UnaryOperator = enum { is_null };

/// Shared `_eq`/`_gt`/etc name mapping, used by every producer that lowers
/// GraphQL-style or NDC-wire-style operator names into BinaryOperator
/// (graphql_parser/to_ir.zig and http_server/ndc_request.zig) so the mapping
/// exists in exactly one place.
pub fn binaryOperatorFromName(name: []const u8) ?BinaryOperator {
    const table = .{
        .{ "_eq", BinaryOperator.eq },
        .{ "_neq", BinaryOperator.neq },
        .{ "_gt", BinaryOperator.gt },
        .{ "_gte", BinaryOperator.gte },
        .{ "_lt", BinaryOperator.lt },
        .{ "_lte", BinaryOperator.lte },
        .{ "_in", BinaryOperator.in },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

test "binaryOperatorFromName maps known names and rejects unknown ones" {
    try std.testing.expectEqual(BinaryOperator.eq, binaryOperatorFromName("_eq").?);
    try std.testing.expectEqual(BinaryOperator.in, binaryOperatorFromName("_in").?);
    try std.testing.expectEqual(@as(?BinaryOperator, null), binaryOperatorFromName("_bogus"));
}

/// A column reference, optionally reached by traversing relationships.
/// `path` is always empty in milestone 1 (no cross-relationship comparisons yet).
pub const ComparisonTarget = struct {
    name: []const u8,
    path: []const []const u8 = &.{},
};

/// Reuses std.json.Value rather than inventing a parallel scalar-value type:
/// GraphQL literals and query-builder literals both collapse to JSON-shaped
/// values before reaching sql_gen, and `_in`'s list argument is naturally a
/// JSON array.
pub const ScalarValue = std.json.Value;

pub const ComparisonValue = union(enum) {
    scalar: ScalarValue,
    /// Reserved for NDC query `variables` batching — unused until a later milestone.
    variable: []const u8,
};

pub const BinaryComparison = struct {
    column: ComparisonTarget,
    operator: BinaryOperator,
    value: ComparisonValue,
};

pub const UnaryComparison = struct {
    column: ComparisonTarget,
    operator: UnaryOperator,
};

/// Which collection an `exists` expression checks: `related` follows a named
/// relationship from the current collection (the common case, and the only
/// one that needs a join-condition fold in sql_gen); `unrelated` checks an
/// arbitrary collection with no join at all (a bare correlated-or-uncorrelated
/// existence check, predicate-only).
pub const ExistsInCollection = union(enum) {
    related: struct { relationship: []const u8 },
    unrelated: struct { collection: []const u8 },
};

pub const ExistsExpression = struct {
    in_collection: ExistsInCollection,
    /// Absent means "any row exists at all" with no further filtering.
    predicate: ?*Expression,
};

/// Recursive boolean expression tree (predicate / filter). `and_`/`or_`/`not_`
/// own their child expressions (and the `and_`/`or_` slice itself); `exists`
/// owns its boxed predicate the same way `not_` owns its child; leaf nodes
/// own nothing since ComparisonTarget/ComparisonValue only ever borrow slices
/// from an arena the caller controls.
pub const Expression = union(enum) {
    and_: []Expression,
    or_: []Expression,
    not_: *Expression,
    binary_op: BinaryComparison,
    unary_op: UnaryComparison,
    exists: ExistsExpression,

    pub fn deinit(self: *Expression, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .and_, .or_ => |list| {
                for (list) |*child| child.deinit(allocator);
                allocator.free(list);
            },
            .not_ => |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            },
            .exists => |*e| {
                if (e.predicate) |child| {
                    child.deinit(allocator);
                    allocator.destroy(child);
                }
            },
            .binary_op, .unary_op => {},
        }
    }
};

test "binary_op leaf needs no cleanup" {
    var expr = Expression{ .binary_op = .{
        .column = .{ .name = "Title" },
        .operator = .eq,
        .value = .{ .scalar = .{ .string = "Foo" } },
    } };
    expr.deinit(std.testing.allocator); // must not touch the allocator at all
}

test "not_ frees its boxed child" {
    const allocator = std.testing.allocator;
    const child = try allocator.create(Expression);
    child.* = .{ .unary_op = .{ .column = .{ .name = "ArtistId" }, .operator = .is_null } };

    var expr = Expression{ .not_ = child };
    expr.deinit(allocator); // leak-checked by std.testing.allocator
}

test "and_ frees the slice and recursively frees each child" {
    const allocator = std.testing.allocator;
    const children = try allocator.alloc(Expression, 2);
    children[0] = .{ .binary_op = .{
        .column = .{ .name = "AlbumId" },
        .operator = .gt,
        .value = .{ .scalar = .{ .integer = 1 } },
    } };
    const nested_child = try allocator.create(Expression);
    nested_child.* = .{ .unary_op = .{ .column = .{ .name = "Title" }, .operator = .is_null } };
    children[1] = .{ .not_ = nested_child };

    var expr = Expression{ .and_ = children };
    expr.deinit(allocator);
}

test "exists with no predicate needs no cleanup" {
    var expr = Expression{ .exists = .{
        .in_collection = .{ .related = .{ .relationship = "albums" } },
        .predicate = null,
    } };
    expr.deinit(std.testing.allocator);
}

test "exists frees its boxed predicate" {
    const allocator = std.testing.allocator;
    const predicate = try allocator.create(Expression);
    predicate.* = .{ .binary_op = .{
        .column = .{ .name = "Title" },
        .operator = .eq,
        .value = .{ .scalar = .{ .string = "Foo" } },
    } };

    var expr = Expression{ .exists = .{
        .in_collection = .{ .unrelated = .{ .collection = "album" } },
        .predicate = predicate,
    } };
    expr.deinit(allocator);
}

test "_in operator carries a JSON array scalar value" {
    var array = std.json.Array.init(std.testing.allocator);
    defer array.deinit();
    try array.append(.{ .string = "Album1" });
    try array.append(.{ .string = "Album2" });

    const expr = Expression{ .binary_op = .{
        .column = .{ .name = "Title" },
        .operator = .in,
        .value = .{ .scalar = .{ .array = array } },
    } };
    try std.testing.expectEqual(@as(usize, 2), expr.binary_op.value.scalar.array.items.len);
}
