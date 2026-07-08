const std = @import("std");

pub const OperationType = enum { query, mutation };

/// GraphQL input value. `variable` (a `$name` reference) is resolved to a
/// concrete literal by `request.zig` before `to_ir.zig` ever sees it -- see
/// docs/decisions/0014-graphql-post-endpoint.md's note on request-level
/// variables being a document-level substitution, distinct from NDC's
/// IR-level variable-set batching (ADR 0009).
pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    null_,
    /// A bare identifier used as a value, e.g. `asc`/`desc` in `order_by`.
    enum_: []const u8,
    variable: []const u8,
    list: []Value,
    object: []ObjectField,
};

pub const ObjectField = struct {
    name: []const u8,
    value: Value,
};

pub const Argument = struct {
    name: []const u8,
    value: Value,
};

pub const Directive = struct {
    name: []const u8,
    arguments: []const Argument = &.{},
};

/// A fully **resolved** field: fragments already spread in, `@skip`/`@include`
/// already evaluated and stripped, `$variable` references already substituted
/// with concrete values. This is what `graphql_parser/to_ir.zig` consumes --
/// it is deliberately identical in shape to milestone 1-3's `Field` type, so
/// lowering needed no changes for fragment/directive/variable support (see
/// `request.zig`, which produces this from the parser's raw `RawField` tree).
pub const Field = struct {
    alias: ?[]const u8 = null,
    name: []const u8,
    arguments: []const Argument = &.{},
    /// Empty means a scalar leaf field; non-empty means an object/relationship field.
    selection_set: []const Field = &.{},

    pub fn responseKey(self: Field) []const u8 {
        return self.alias orelse self.name;
    }
};

/// The parser's raw output for one field, before fragment expansion and
/// directive evaluation -- its selection set may mix plain fields and
/// fragment spreads (`Selection`), unlike the resolved `Field` above.
pub const RawField = struct {
    alias: ?[]const u8 = null,
    name: []const u8,
    arguments: []const Argument = &.{},
    directives: []const Directive = &.{},
    selection_set: []const Selection = &.{},

    pub fn responseKey(self: RawField) []const u8 {
        return self.alias orelse self.name;
    }
};

/// `...FragmentName @directive` -- inline fragments (`... on Type { }`) are
/// not supported (see docs/roadmap.md): every collection/object type in this
/// engine's generated schema is a concrete type, never an interface or union,
/// so real GraphQL documents (including the standard introspection query)
/// never need one here.
pub const FragmentSpread = struct {
    name: []const u8,
    directives: []const Directive = &.{},
};

pub const Selection = union(enum) {
    field: RawField,
    fragment_spread: FragmentSpread,
};

pub const FragmentDefinition = struct {
    name: []const u8,
    type_condition: []const u8,
    selection_set: []const Selection,
};

/// `type_name` is kept as raw source text (e.g. `"Int"`, `"[String!]!"`)
/// rather than parsed into a structured type reference -- this engine never
/// type-checks a variable's declared type against its supplied value (Postgres
/// will reject an ill-typed value at execution time regardless), so there is
/// nothing a structured representation would be used for.
pub const VariableDefinition = struct {
    name: []const u8,
    type_name: []const u8,
    /// `$limit: Int = 10` -- used by `request.zig` when the request's
    /// `variables` object omits this name entirely.
    default_value: ?Value = null,
};

pub const Operation = struct {
    operation_type: OperationType = .query,
    name: ?[]const u8 = null,
    variable_definitions: []const VariableDefinition = &.{},
    selection_set: []const Selection,
};

/// The parser's raw output for a full GraphQL document: one or more
/// operations (named or the single anonymous-shorthand form) plus any
/// fragment definitions, which may be referenced before or after their own
/// definition (forward references are legal GraphQL) -- see `request.zig`
/// for fragment-expansion/operation-selection/directive-evaluation, which is
/// what turns this into the resolved `Field` tree `to_ir.zig` consumes.
pub const Document = struct {
    operations: []const Operation,
    fragments: []const FragmentDefinition = &.{},
};
