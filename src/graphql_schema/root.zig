//! Derives a GraphQL type system from `schema.SchemaModel` + the procedure
//! registry, and provides pure consumers of it: SDL text rendering,
//! `__schema`/`__type` introspection execution, and (M4.6) NDC-response ->
//! GraphQL-envelope reshaping. Deliberately outside `http_server` -- see
//! docs/decisions/0013-graphql-type-system.md and
//! docs/decisions/0014-graphql-post-endpoint.md.

const type_system = @import("type_system.zig");
const sdl = @import("sdl.zig");
const introspection = @import("introspection.zig");
const envelope = @import("envelope.zig");

pub const TypeSystem = type_system.TypeSystem;
pub const TypeDef = type_system.TypeDef;
pub const TypeRef = type_system.TypeRef;
pub const ObjectField = type_system.ObjectField;
pub const ObjectTypeDef = type_system.ObjectTypeDef;
pub const InputField = type_system.InputField;
pub const InputObjectTypeDef = type_system.InputObjectTypeDef;
pub const EnumTypeDef = type_system.EnumTypeDef;
pub const FieldArgument = type_system.FieldArgument;
pub const buildTypeSystem = type_system.build;
pub const Error = type_system.Error;

pub const renderSdl = sdl.render;
pub const executeIntrospection = introspection.execute;
pub const IntrospectionError = introspection.Error;
pub const FieldOutcome = envelope.FieldOutcome;
pub const buildQueryEnvelope = envelope.buildQueryEnvelope;
pub const buildRequestErrorEnvelope = envelope.buildRequestErrorEnvelope;

test {
    @import("std").testing.refAllDecls(@This());
    _ = type_system;
    _ = sdl;
    _ = introspection;
    _ = envelope;
}
