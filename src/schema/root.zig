//! Schema model (collections/object types/scalar types) and Postgres introspection.
//! See docs/architecture.md for why this is the one type both graphql_parser and
//! query_builder depend on to resolve names.

const model = @import("model.zig");
const introspect = @import("introspect.zig");
const procedures = @import("procedures.zig");

pub const SchemaModel = model.SchemaModel;
pub const ScalarType = model.ScalarType;
pub const ObjectField = model.ObjectField;
pub const ObjectType = model.ObjectType;
pub const Collection = model.Collection;

pub const TableRow = introspect.TableRow;
pub const ColumnRow = introspect.ColumnRow;
pub const ForeignKeyRow = introspect.ForeignKeyRow;
pub const PrimaryKeyRow = introspect.PrimaryKeyRow;
pub const IntrospectionRows = introspect.IntrospectionRows;
pub const buildSchemaModel = introspect.build;
pub const Error = introspect.Error;

pub const ProcedureKind = procedures.ProcedureKind;
pub const Procedure = procedures.Procedure;
pub const ProcedureError = procedures.Error;
pub const resolveProcedure = procedures.resolveProcedure;
pub const listProcedureNames = procedures.listProcedureNames;

test {
    @import("std").testing.refAllDecls(@This());
}
