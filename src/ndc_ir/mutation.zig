const std = @import("std");
const query_mod = @import("query.zig");

pub const FieldSelection = query_mod.FieldSelection;

/// A named argument's value -- in practice always a JSON object (the `object`,
/// `pk_columns`, or `_set` argument every auto-derived procedure takes, see
/// docs/decisions/0010-mutation-procedure-naming.md), but kept as the raw
/// std.json.Value the caller supplied rather than a narrower type so parsing
/// (ndc_request.zig) and building (MutationBuilder) don't need a dedicated
/// argument-shape type -- schema-aware validation of that shape happens later,
/// in schema/procedures.zig + sql_gen, not here.
pub const ArgumentMap = std.StringArrayHashMapUnmanaged(std.json.Value);

/// One call to an auto-derived procedure. `name` (e.g. "insert_album") is
/// resolved against the schema by `schema/procedures.zig`, not here -- ndc_ir
/// stays schema-agnostic, exactly like Query/Expression (see
/// docs/architecture.md).
pub const MutationOperation = struct {
    name: []const u8,
    arguments: ArgumentMap = .{},
    /// RETURNING selection. Reuses the read-side FieldSelection/Field union so
    /// producers don't need a second field-selection type; only `Field.column`
    /// is meaningful in milestone 3 -- relationship fields inside `returning`
    /// are deferred (see docs/roadmap.md). `null` means the caller requested no
    /// returning data at all (only `affected_rows`).
    fields: ?FieldSelection = null,

    /// Frees the containers this type itself allocates (the arguments map,
    /// the fields map) -- like ndc_ir.Expression's deinit, it does not
    /// recursively free any std.json.Value.object/.array an argument value
    /// happens to carry (see docs/architecture.md's arena-per-request
    /// convention, which is why nothing here needs to).
    pub fn deinit(self: *MutationOperation, allocator: std.mem.Allocator) void {
        self.arguments.deinit(allocator);
        if (self.fields) |*f| {
            var it = f.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(allocator);
            f.deinit(allocator);
        }
        self.* = undefined;
    }
};

/// NDC's `operations[]`: a multi-operation request runs as one all-or-nothing
/// transaction (see docs/decisions/0011-mutation-transactions.md).
pub const MutationRequest = struct {
    operations: []MutationOperation,

    pub fn deinit(self: *MutationRequest, allocator: std.mem.Allocator) void {
        for (self.operations) |*op| op.deinit(allocator);
        allocator.free(self.operations);
        self.* = undefined;
    }
};

test "MutationOperation with no arguments or fields needs no allocation to construct or free" {
    var op = MutationOperation{ .name = "insert_album" };
    op.deinit(std.testing.allocator);
}

test "MutationOperation owns its arguments map and returning field selection" {
    // Mirrors ndc_ir.Expression's convention (see expression.zig): deinit frees
    // the containers this type itself allocates (the arguments map, the
    // fields map), not any nested std.json.Value substructure a value happens
    // to carry -- that's the caller's/arena's responsibility. A bare scalar
    // argument value here (not an object/array) is enough to exercise that.
    const allocator = std.testing.allocator;
    var op = MutationOperation{ .name = "delete_album_by_pk" };
    try op.arguments.put(allocator, "album_id", .{ .integer = 1 });

    var fields: FieldSelection = .{};
    try fields.put(allocator, "AlbumId", .{ .column = .{ .column = "AlbumId" } });
    op.fields = fields;

    op.deinit(allocator);
}

test "MutationRequest owns and frees a slice of operations" {
    const allocator = std.testing.allocator;
    const operations = try allocator.alloc(MutationOperation, 2);
    operations[0] = .{ .name = "insert_album" };
    operations[1] = .{ .name = "delete_album_by_pk" };

    var request = MutationRequest{ .operations = operations };
    request.deinit(allocator);
}
