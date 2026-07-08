//! GraphQL text -> ndc_ir.Query, via a lexer/parser producing a GraphQL AST and a
//! schema-aware lowering pass. See docs/architecture.md: this and query_builder are
//! the two producers that must both target the exact same ndc_ir.Query shape.

const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const to_ir = @import("to_ir.zig");
const request_mod = @import("request.zig");

pub const Lexer = lexer.Lexer;
pub const Token = lexer.Token;
pub const Document = ast.Document;
pub const OperationType = ast.OperationType;
pub const Field = ast.Field;
pub const Value = ast.Value;
pub const Argument = ast.Argument;
pub const ObjectField = ast.ObjectField;
pub const Directive = ast.Directive;
pub const FragmentSpread = ast.FragmentSpread;
pub const Operation = ast.Operation;
pub const RawField = ast.RawField;
pub const Selection = ast.Selection;
pub const FragmentDefinition = ast.FragmentDefinition;
pub const VariableDefinition = ast.VariableDefinition;
pub const parse = parser.parse;
pub const lower = to_ir.lower;
pub const lowerAll = to_ir.lowerAll;
pub const RootQuery = to_ir.RootQuery;
pub const lowerMutation = to_ir.lowerMutation;
pub const lowerMutationAll = to_ir.lowerMutationAll;
pub const lowerRootField = to_ir.lowerRootField;
pub const lowerMutationField = to_ir.lowerMutationField;
pub const LowerError = to_ir.Error;
pub const resolveOperation = request_mod.resolveOperation;
pub const ResolvedOperation = request_mod.ResolvedOperation;
pub const RequestError = request_mod.Error;

/// Convenience entry point: GraphQL text -> ndc_ir.Query in one call. Only
/// usable for a document with exactly one operation and one root field (the
/// NDC-native producers' contract); see `lowerAll`/`parseRequestToIr` for a
/// `POST /graphql`-style request with multiple root fields, an
/// `operationName`, and/or `variables`.
pub fn parseToIr(
    allocator: @import("std").mem.Allocator,
    src: []const u8,
    schema_model: *const @import("schema").SchemaModel,
) (parser.Error || to_ir.Error)!@import("ndc_ir").Query {
    const document = try parser.parse(allocator, src);
    return to_ir.lower(allocator, document, schema_model);
}

/// Convenience entry point: `mutation { ... }` GraphQL text -> ndc_ir.MutationRequest
/// in one call. No schema needed here -- procedure names are resolved later,
/// inside sql_gen (see docs/decisions/0010-mutation-procedure-naming.md).
pub fn parseToMutationIr(
    allocator: @import("std").mem.Allocator,
    src: []const u8,
) (parser.Error || to_ir.Error)!@import("ndc_ir").MutationRequest {
    const document = try parser.parse(allocator, src);
    return to_ir.lowerMutation(allocator, document);
}

/// The full `POST /graphql` shape: GraphQL text, an optional `operationName`,
/// and an optional `variables` object -> one `ndc_ir.Query` per query-document
/// root field. See docs/decisions/0014-graphql-post-endpoint.md.
pub fn parseRequestToIr(
    allocator: @import("std").mem.Allocator,
    src: []const u8,
    operation_name: ?[]const u8,
    variables: ?@import("std").json.Value,
    schema_model: *const @import("schema").SchemaModel,
) (parser.Error || to_ir.Error)![]const to_ir.RootQuery {
    const document = try parser.parse(allocator, src);
    return to_ir.lowerAll(allocator, document, operation_name, variables, schema_model);
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = to_ir;
    _ = request_mod;
}
