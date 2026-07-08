//! Native Postgres wire protocol client (see docs/decisions/0001, 0002).

const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const connection = @import("connection.zig");
const pool = @import("pool.zig");

pub const QueryParam = protocol.QueryParam;
pub const FieldDescription = protocol.FieldDescription;
pub const Connection = connection.Connection;
pub const QueryResult = connection.QueryResult;
pub const Row = connection.Row;
pub const Error = connection.Error;
pub const Pool = pool.Pool;

test {
    @import("std").testing.refAllDecls(@This());
    _ = protocol;
    _ = auth;
    _ = pool;
}
