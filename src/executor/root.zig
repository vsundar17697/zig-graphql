//! Glues ndc_ir.Query + SchemaModel + pg_wire.Connection through sql_gen and pg_wire.
//! The only module allowed to depend on both sql_gen and pg_wire -- see docs/architecture.md.

const run_mod = @import("run.zig");
const introspect_mod = @import("introspect.zig");
const mutation_mod = @import("mutation.zig");

pub const run = run_mod.run;
pub const runWithVariables = run_mod.runWithVariables;
pub const Error = run_mod.Error;
pub const introspectLive = introspect_mod.introspectLive;
pub const runMutation = mutation_mod.runMutation;
pub const MutationError = mutation_mod.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
