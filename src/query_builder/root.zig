//! Comptime typed query-builder API producing the same ndc_ir.Query as graphql_parser.
//! See docs/decisions/0004-schema-reconciliation-runtime-validation.md for how this
//! module's plain-string column/collection references get checked against the schema.

const builder = @import("builder.zig");
const validate_mod = @import("validate.zig");

pub const Column = builder.Column;
pub const column = builder.column;
pub const exists = builder.exists;
pub const existsUnrelated = builder.existsUnrelated;
pub const Builder = builder.Builder;
pub const MutationBuilder = builder.MutationBuilder;
pub const validate = validate_mod.validate;
pub const ValidateError = validate_mod.Error;

test {
    @import("std").testing.refAllDecls(@This());
    _ = builder;
    _ = validate_mod;
}
