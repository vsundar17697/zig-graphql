//! Postgres access via libpq (see docs/decisions/0016-adopt-libpq.md, which
//! supersedes the native wire-protocol client of ADRs 0001/0002).

const connection = @import("connection.zig");
const pool = @import("pool.zig");

pub const QueryParam = connection.QueryParam;
pub const FieldDescription = connection.FieldDescription;
pub const Connection = connection.Connection;
pub const QueryResult = connection.QueryResult;
pub const Row = connection.Row;
pub const Error = connection.Error;
pub const Pool = pool.Pool;

test {
    @import("std").testing.refAllDecls(@This());
    _ = pool;
}
