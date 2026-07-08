const std = @import("std");

/// A bindable scalar value. Never interpolated into SQL text directly — render.zig
/// always emits these as `$N` placeholders (see docs/architecture.md's SQL-injection
/// safety note), so this is a pure data carrier, not a rendering concern.
///
/// `variable_ref` slots into a `$N` placeholder exactly like every other
/// variant (render.zig needs no special handling for it -- see
/// docs/decisions/0009-query-variables.md); it just names a variable whose
/// concrete value isn't known until `executor` resolves it against one
/// `VariableSet` at execution time, after SQL has already been rendered once.
pub const Value = union(enum) {
    null_,
    boolean: bool,
    integer: i64,
    float: f64,
    text: []const u8,
    variable_ref: []const u8,
};

pub const ColumnRef = struct {
    table_alias: []const u8,
    column: []const u8,
};

pub const BinaryOp = enum { eq, neq, gt, gte, lt, lte };

/// A binary comparison's right-hand side is either a bindable value (the common
/// case: a WHERE-clause literal from GraphQL/query-builder input) or another
/// column (needed for relationship join conditions, which compare two columns
/// and carry no user-supplied value at all).
pub const BinaryRhs = union(enum) {
    value: Value,
    column: ColumnRef,
};

pub const BinaryExpr = struct {
    column: ColumnRef,
    op: BinaryOp,
    rhs: BinaryRhs,
};

pub const InExpr = struct {
    column: ColumnRef,
    values: []const Value,
};

pub const SqlExpr = union(enum) {
    and_: []const SqlExpr,
    or_: []const SqlExpr,
    not_: *const SqlExpr,
    binary: BinaryExpr,
    in_: InExpr,
    is_null: ColumnRef,
    /// Rendered as `EXISTS (SELECT 1 FROM ... WHERE ...)`. `items` on the
    /// referenced Select is always empty (an existence check needs no column
    /// list); render.zig's ordinary empty-items handling renders `SELECT NULL`,
    /// which is valid and semantically equivalent to the conventional `SELECT 1`.
    exists: *const Select,
};

pub const OrderDirection = enum { asc, desc };

pub const OrderByItem = struct {
    column: ColumnRef,
    direction: OrderDirection,
};

pub const TableRef = struct {
    schema: []const u8,
    table: []const u8,
    alias: []const u8,
};

pub const ColumnItem = struct {
    column: ColumnRef,
    alias: []const u8,
};

/// A relationship field is rendered as a correlated scalar subquery in the
/// SELECT list (`(SELECT json_build_object(...) FROM (...) AS "t") AS "alias"`)
/// rather than a LATERAL join. Plain correlated subqueries are standard SQL
/// (no LATERAL needed since they appear in the SELECT list, not the FROM
/// clause) and this single shape handles both object and array relationships
/// uniformly — `single_row` just forces `LIMIT 1` on the nested select for
/// object relationships. See docs/decisions/0003-json-shaping-sql-in-generator.md.
pub const RelationshipItem = struct {
    alias: []const u8,
    subquery: *const RowSetQuery,
    single_row: bool,
};

pub const SelectItem = union(enum) {
    column: ColumnItem,
    relationship: RelationshipItem,
};

pub const Select = struct {
    items: []const SelectItem,
    from: TableRef,
    where: ?SqlExpr = null,
    order_by: []const OrderByItem = &.{},
    limit: ?u32 = null,
    offset: ?u32 = null,
};

pub const AggregateFunction = enum { min, max, sum, avg };

/// Every aggregate is computed against the row-set wrapper render.zig builds
/// around `Select` (the alias it calls "t"), never against the base table
/// directly -- `column` is therefore just the alias a column was given inside
/// `Select.items` (or one added solely to support this aggregate; see
/// docs/decisions/0008-aggregate-rendering.md), not a raw table column name.
pub const AggregateExpr = union(enum) {
    star_count,
    column_count: struct { column_alias: []const u8, distinct: bool },
    single_column: struct { column_alias: []const u8, function: AggregateFunction },
};

pub const AggregateItem = struct {
    alias: []const u8,
    expr: AggregateExpr,
};

/// The unit sql_gen renders as one NDC RowSet JSON object
/// (`{"rows": [...], "aggregates": {...}}`, either key optional -- see
/// docs/decisions/0008-aggregate-rendering.md). Every top-level query and
/// every relationship field is one of these.
pub const RowSetQuery = struct {
    select: *const Select,
    /// Non-null only when `select.items` contains columns added solely to
    /// support `aggregates` and not requested as display fields -- lists the
    /// aliases (a subset of `select.items`'s column aliases) to actually
    /// expose under 'rows'. Null (the common case, no such extra columns)
    /// skips the re-projection this would otherwise require entirely.
    row_field_aliases: ?[]const []const u8 = null,
    aggregates: []const AggregateItem = &.{},
};

/// A data-modifying statement always writes to one base table, addressed
/// exactly like a Select's `from` -- `alias` is unused for mutations (there's
/// nothing to self-join against) but kept for type reuse; render.zig always
/// names the CTE that wraps this "mutated" instead. See
/// docs/decisions/0011-mutation-transactions.md.
pub const InsertStatement = struct {
    table: TableRef,
    columns: []const []const u8,
    values: []const Value,
};

pub const UpdateStatement = struct {
    table: TableRef,
    set_columns: []const []const u8,
    set_values: []const Value,
    pk_columns: []const []const u8,
    pk_values: []const Value,
};

pub const DeleteStatement = struct {
    table: TableRef,
    pk_columns: []const []const u8,
    pk_values: []const Value,
};

pub const MutationOp = union(enum) {
    insert: InsertStatement,
    update: UpdateStatement,
    delete: DeleteStatement,
};

/// Renders as a `WITH mutated AS (...) SELECT json_build_object(...)`
/// statement that always returns exactly one row, regardless of how many
/// rows the data-modifying CTE itself affected -- see
/// docs/decisions/0011-mutation-transactions.md for why the naive
/// `SELECT ... FROM mutated` form is wrong. `returning` is `null` when the
/// caller requested no RETURNING data at all (only `affected_rows` is
/// computed then); a non-null, possibly-empty slice includes the `returning`
/// key. Each item reads from the CTE's own alias ("mutated"), reusing
/// `ColumnItem` since the shape (column + response alias) is identical to a
/// read-path display field.
pub const MutationStatement = struct {
    op: MutationOp,
    returning: ?[]const ColumnItem = null,
};

test "ast types are plain data, no behavior to test directly" {
    const select = Select{
        .items = &.{},
        .from = .{ .schema = "public", .table = "album", .alias = "album" },
    };
    try std.testing.expectEqualStrings("album", select.from.table);
}
