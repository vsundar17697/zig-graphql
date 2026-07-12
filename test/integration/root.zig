//! Postgres-backed integration tests. Run via `zig build test-integration` after
//! `docker compose up -d --wait`.
//!
//! Deliberately not colocated with src/ — see docs/architecture.md on why integration
//! tests need their own gated build step rather than a colocated `test {}` block.
//!
//! - schema_introspect_test.zig: live introspection against the seeded fixture.
//! - graphql_query_test.zig: the GraphQL-text producer path, end to end.
//! - query_builder_test.zig: the query-builder producer path, end to end, plus the
//!   flagship "both producers, byte-identical JSON, through real execution" proof
//!   (see src/pg_gql.zig for the faster SQL-text-only version of this same claim).
//! - mutation_test.zig: executor.runMutation against real Postgres -- insert/update/
//!   delete-by-pk, and the all-or-nothing transaction + pg_wire protocol-resync proof.
//! - graphql_schema_test.zig: SDL + introspection execution against the live fixture (M4.4/4.5).
//! - graphql_route_test.zig: the /graphql parse->resolve->lower->execute->envelope
//!   pipeline against real Postgres (M4.6).
//! - pool_test.zig: pg_wire.Pool concurrency, broken-connection recovery (M4.7), and
//!   the milestone 6 staleness policy (max-lifetime recycling, validate-on-acquire).
//! - connection_test.zig: statement timeouts, cross-thread cancellation, and unnamed
//!   prepared statements (milestone 6).
//! - tls_test.zig: negotiated-TLS assertions driven by the environment; the
//!   suite-wide connection settings themselves live in fixture.zig (milestone 6).

const std = @import("std");

const schema_introspect_test = @import("schema_introspect_test.zig");
const graphql_query_test = @import("graphql_query_test.zig");
const query_builder_test = @import("query_builder_test.zig");
const mutation_test = @import("mutation_test.zig");
const graphql_schema_test = @import("graphql_schema_test.zig");
const graphql_route_test = @import("graphql_route_test.zig");
const pool_test = @import("pool_test.zig");
const connection_test = @import("connection_test.zig");
const tls_test = @import("tls_test.zig");

test {
    std.testing.refAllDecls(@This());
    _ = schema_introspect_test;
    _ = graphql_query_test;
    _ = query_builder_test;
    _ = mutation_test;
    _ = graphql_schema_test;
    _ = graphql_route_test;
    _ = pool_test;
    _ = connection_test;
    _ = tls_test;
}
