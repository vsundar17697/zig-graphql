//! Postgres connection over libpq (see docs/decisions/0016-adopt-libpq.md,
//! which supersedes the native wire-protocol client of ADRs 0001/0002).

const std = @import("std");

const c = @cImport(@cInclude("libpq-fe.h"));

/// Text-format query parameter, matching what sql_gen emits (values are
/// always rendered to text; see sql_gen's Value union).
pub const QueryParam = union(enum) {
    null_,
    text: []const u8,
};

pub const FieldDescription = struct {
    name: []const u8,
    type_oid: u32,
};

pub const Error = std.mem.Allocator.Error || error{
    /// Could not establish a connection (unreachable host, refused, bad
    /// credentials, ...).
    ConnectionFailed,
    /// The connection dropped mid-use; its state is unknown and the pool
    /// treats it as poison (see pool.zig's markBrokenUnless).
    ConnectionLost,
    /// A healthy connection reporting a SQL-level failure. libpq resyncs
    /// the connection automatically after an error, so it stays safe to
    /// reuse -- the invariant pool.zig's markBrokenUnless and ADR 0011's
    /// ROLLBACK-after-failure path rely on.
    ServerError,
};

pub const Row = struct {
    /// Text-format column values, borrowed from the QueryResult's own arena.
    /// null means SQL NULL.
    columns: []?[]const u8,
};

pub const QueryResult = struct {
    arena: std.heap.ArenaAllocator,
    fields: []FieldDescription,
    rows: []Row,

    pub fn deinit(self: *QueryResult) void {
        self.arena.deinit();
    }
};

/// A single Postgres connection. Heap-allocated via `connect` so the handle's
/// address is stable for the pool's pointer-based idle list (pool.zig). Not
/// safe for concurrent use; one connection serves one request at a time,
/// which the pool enforces by construction.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    pg: *c.PGconn,

    pub const Options = struct {
        host: []const u8,
        port: u16,
        user: []const u8,
        password: []const u8 = "",
        database: []const u8,
    };

    pub fn connect(allocator: std.mem.Allocator, options: Options) Error!*Connection {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        const keywords = [_][*c]const u8{ "host", "port", "user", "password", "dbname", null };
        const values = [_][*c]const u8{
            (try a.dupeZ(u8, options.host)).ptr,
            (try std.fmt.allocPrintSentinel(a, "{d}", .{options.port}, 0)).ptr,
            (try a.dupeZ(u8, options.user)).ptr,
            (try a.dupeZ(u8, options.password)).ptr,
            (try a.dupeZ(u8, options.database)).ptr,
            null,
        };

        // Null return means libpq itself couldn't allocate; every other
        // failure (auth, unreachable, ...) comes back as a PGconn in
        // CONNECTION_BAD state.
        const maybe_pg: ?*c.PGconn = c.PQconnectdbParams(&keywords, &values, 0);
        const pg = maybe_pg orelse return Error.OutOfMemory;
        errdefer c.PQfinish(pg);

        // Log at warn, not err, throughout this file: every failure here is
        // also reported to the caller as a Zig error, and the caller (not
        // this library) owns deciding how severe it is -- a client's failed
        // INSERT is the client's error, not the process's. Error-level logs
        // also fail `zig build test-integration` outright (the test runner
        // counts them), and several integration tests trigger these paths
        // deliberately.
        if (c.PQstatus(pg) != c.CONNECTION_OK) {
            std.log.warn("postgres connection failed: {s}", .{trimmed(c.PQerrorMessage(pg))});
            return Error.ConnectionFailed;
        }

        const self = try allocator.create(Connection);
        self.* = .{ .allocator = allocator, .pg = pg };
        return self;
    }

    pub fn close(self: *Connection) void {
        c.PQfinish(self.pg);
        self.allocator.destroy(self);
    }

    /// Runs one parameterized query. Text-format params and results only;
    /// sql_gen always emits values as text (see sql_gen's Value union).
    ///
    /// The returned QueryResult owns an arena sized to this one query; the
    /// caller frees it with `QueryResult.deinit`.
    pub fn query(self: *Connection, sql: []const u8, params: []const QueryParam) Error!QueryResult {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        // libpq wants C strings: the SQL and each text param need a NUL,
        // which []const u8 slices don't carry.
        const sql_z = try sa.dupeZ(u8, sql);
        const values = try sa.alloc([*c]const u8, params.len);
        for (params, 0..) |param, i| {
            values[i] = switch (param) {
                .null_ => null,
                .text => |text| (try sa.dupeZ(u8, text)).ptr,
            };
        }

        const maybe_res: ?*c.PGresult = c.PQexecParams(
            self.pg,
            sql_z.ptr,
            @intCast(params.len),
            null, // param types: let the server infer, as the native client did
            if (params.len == 0) null else values.ptr,
            null, // param lengths: ignored for text-format params
            null, // param formats: all text
            0, // result format: text
        );
        const res = maybe_res orelse return self.transportFailure();
        defer c.PQclear(res);

        const status = c.PQresultStatus(res);
        if (status != c.PGRES_TUPLES_OK and status != c.PGRES_COMMAND_OK) {
            // A dropped connection also surfaces as a failed result; only a
            // failure on a still-healthy connection is a SQL-level error.
            if (c.PQstatus(self.pg) != c.CONNECTION_OK) return self.transportFailure();
            const sqlstate = c.PQresultErrorField(res, c.PG_DIAG_SQLSTATE);
            std.log.warn("postgres error [{s}]: {s}", .{
                if (sqlstate != null) std.mem.span(@as([*:0]const u8, @ptrCast(sqlstate))) else "-----",
                trimmed(c.PQresultErrorMessage(res)),
            });
            return Error.ServerError;
        }

        var result = QueryResult{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .fields = &.{},
            .rows = &.{},
        };
        errdefer result.arena.deinit();
        const a = result.arena.allocator();

        // PGRES_COMMAND_OK (DDL/DML with no RETURNING) reports zero fields
        // and zero tuples, which falls out of these loops naturally.
        const field_count: usize = @intCast(c.PQnfields(res));
        const fields = try a.alloc(FieldDescription, field_count);
        for (fields, 0..) |*field, i| {
            field.* = .{
                .name = try a.dupe(u8, std.mem.span(c.PQfname(res, @intCast(i)))),
                .type_oid = @intCast(c.PQftype(res, @intCast(i))),
            };
        }
        result.fields = fields;

        const row_count: usize = @intCast(c.PQntuples(res));
        const rows = try a.alloc(Row, row_count);
        for (rows, 0..) |*row, r| {
            const columns = try a.alloc(?[]const u8, field_count);
            for (columns, 0..) |*column, col| {
                if (c.PQgetisnull(res, @intCast(r), @intCast(col)) == 1) {
                    column.* = null;
                } else {
                    const len: usize = @intCast(c.PQgetlength(res, @intCast(r), @intCast(col)));
                    column.* = try a.dupe(u8, c.PQgetvalue(res, @intCast(r), @intCast(col))[0..len]);
                }
            }
            row.* = .{ .columns = columns };
        }
        result.rows = rows;

        return result;
    }

    /// Begins a transaction. Multi-operation NDC mutation requests run inside
    /// one all-or-nothing transaction -- see
    /// docs/decisions/0011-mutation-transactions.md.
    pub fn begin(self: *Connection) Error!void {
        var result = try self.query("BEGIN", &.{});
        result.deinit();
    }

    pub fn commit(self: *Connection) Error!void {
        var result = try self.query("COMMIT", &.{});
        result.deinit();
    }

    /// Safe to call even when the connection is already in aborted-transaction
    /// state (the common case: this follows a failed operation) -- ROLLBACK is
    /// valid there and is exactly how the aborted state is cleared.
    pub fn rollback(self: *Connection) Error!void {
        var result = try self.query("ROLLBACK", &.{});
        result.deinit();
    }

    fn transportFailure(self: *Connection) Error {
        std.log.warn("postgres connection lost: {s}", .{trimmed(c.PQerrorMessage(self.pg))});
        return Error.ConnectionLost;
    }
};

/// libpq error messages arrive NUL-terminated with a trailing newline.
fn trimmed(message: [*c]const u8) []const u8 {
    if (message == null) return "(no message)";
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(message)));
    return std.mem.trimEnd(u8, span, "\n");
}
