//! Postgres connection over libpq (see docs/decisions/0016-adopt-libpq.md,
//! which supersedes the native wire-protocol client of ADRs 0001/0002).

const std = @import("std");

const c = @cImport({
    @cInclude("libpq-fe.h");
    @cInclude("time.h");
});

/// Milliseconds on the system monotonic clock, via libc (this module links
/// libc for libpq already). Zig 0.16 put clocks behind `std.Io`, which this
/// module deliberately doesn't hold -- and a monotonic span is the right
/// tool for idle/lifetime measurement anyway (immune to wall-clock jumps).
pub fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const ns_part: i64 = @intCast(@divTrunc(ts.tv_nsec, 1_000_000));
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + ns_part;
}

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
    /// credentials, connect timeout, ...).
    ConnectionFailed,
    /// The connection dropped mid-use; its state is unknown and the pool
    /// treats it as poison (see pool.zig's markBrokenUnless).
    ConnectionLost,
    /// A healthy connection reporting a SQL-level failure -- including a
    /// statement timeout or a `cancel` request landing (both SQLSTATE 57014).
    /// libpq resyncs the connection automatically after an error, so it
    /// stays safe to reuse -- the invariant pool.zig's markBrokenUnless and
    /// ADR 0011's ROLLBACK-after-failure path rely on.
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
/// safe for concurrent use (`cancel` being the deliberate exception); one
/// connection serves one request at a time, which the pool enforces by
/// construction.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    pg: *c.PGconn,
    /// Created once at connect so `cancel` never has to touch live
    /// connection state from another thread.
    cancel_handle: ?*c.PGcancel,
    /// When this connection was dialed; the pool's max-lifetime recycling
    /// reads it (pool.zig). Milliseconds on the `monotonicMs` clock.
    created_ms: i64,

    pub const Options = struct {
        host: []const u8,
        port: u16,
        user: []const u8,
        password: []const u8 = "",
        database: []const u8,
        /// Fail `connect` after this many seconds rather than blocking
        /// indefinitely on an unresponsive host (libpq `connect_timeout`).
        connect_timeout_s: u32 = 10,
        /// Server-side cap on any single statement's execution time, set for
        /// the connection's whole lifetime. A statement exceeding it fails
        /// with SQLSTATE 57014 -> `error.ServerError`, and the connection
        /// stays reusable. Null means no cap.
        statement_timeout_ms: ?u32 = null,
    };

    pub fn connect(allocator: std.mem.Allocator, options: Options) Error!*Connection {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        var keywords: std.ArrayListUnmanaged([*c]const u8) = .empty;
        var values: std.ArrayListUnmanaged([*c]const u8) = .empty;
        // libpq wants NUL-terminated C strings; everything lands in scratch.
        try keywords.append(a, "host");
        try values.append(a, (try a.dupeZ(u8, options.host)).ptr);
        try keywords.append(a, "port");
        try values.append(a, (try std.fmt.allocPrintSentinel(a, "{d}", .{options.port}, 0)).ptr);
        try keywords.append(a, "user");
        try values.append(a, (try a.dupeZ(u8, options.user)).ptr);
        try keywords.append(a, "password");
        try values.append(a, (try a.dupeZ(u8, options.password)).ptr);
        try keywords.append(a, "dbname");
        try values.append(a, (try a.dupeZ(u8, options.database)).ptr);
        try keywords.append(a, "connect_timeout");
        try values.append(a, (try std.fmt.allocPrintSentinel(a, "{d}", .{options.connect_timeout_s}, 0)).ptr);
        if (options.statement_timeout_ms) |ms| {
            try keywords.append(a, "options");
            try values.append(a, (try std.fmt.allocPrintSentinel(a, "-c statement_timeout={d}", .{ms}, 0)).ptr);
        }
        try keywords.append(a, null);
        try values.append(a, null);

        // Null return means libpq itself couldn't allocate; every other
        // failure (auth, unreachable, timeout, ...) comes back as a PGconn
        // in CONNECTION_BAD state.
        const maybe_pg: ?*c.PGconn = c.PQconnectdbParams(keywords.items.ptr, values.items.ptr, 0);
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
        self.* = .{
            .allocator = allocator,
            .pg = pg,
            .cancel_handle = c.PQgetCancel(pg),
            .created_ms = monotonicMs(),
        };
        return self;
    }

    pub fn close(self: *Connection) void {
        if (self.cancel_handle) |handle| c.PQfreeCancel(handle);
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

        const sql_z = try sa.dupeZ(u8, sql);
        const values = try encodeParams(sa, params);

        return self.collectResult(c.PQexecParams(
            self.pg,
            sql_z.ptr,
            @intCast(params.len),
            null, // param types: let the server infer
            if (params.len == 0) null else values.ptr,
            null, // param lengths: ignored for text-format params
            null, // param formats: all text
            0, // result format: text
        ));
    }

    /// Parses `sql` as this connection's *unnamed* server-side prepared
    /// statement and returns a handle for executing it repeatedly with
    /// different parameter bindings -- exactly NDC variable batching's shape
    /// (render once, execute N times; see executor.runWithVariables). The
    /// unnamed statement slot is overwritten by the next `prepare` or `query`
    /// call on this connection, so the handle is only valid until then --
    /// a documented contract, chosen over named statements because it needs
    /// no cache keying, no DEALLOCATE cleanup, and no invalidation policy.
    pub fn prepare(self: *Connection, sql: []const u8) Error!Prepared {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        const maybe_res: ?*c.PGresult = c.PQprepare(self.pg, "", sql_z.ptr, 0, null);
        const res = maybe_res orelse return self.transportFailure();
        defer c.PQclear(res);
        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) return self.resultFailure(res);
        return .{ .conn = self };
    }

    pub const Prepared = struct {
        conn: *Connection,

        /// Executes the prepared statement with these parameter bindings.
        /// Same result contract as `Connection.query`.
        pub fn query(self: Prepared, params: []const QueryParam) Error!QueryResult {
            var scratch = std.heap.ArenaAllocator.init(self.conn.allocator);
            defer scratch.deinit();
            const sa = scratch.allocator();

            const values = try encodeParams(sa, params);
            return self.conn.collectResult(c.PQexecPrepared(
                self.conn.pg,
                "", // the unnamed statement `prepare` parsed
                @intCast(params.len),
                if (params.len == 0) null else values.ptr,
                null,
                null,
                0,
            ));
        }
    };

    /// Cheap liveness probe for the pool's validate-on-acquire (pool.zig):
    /// an empty-query round trip, the smallest thing that actually exercises
    /// the socket (PQstatus alone only reflects already-observed failures).
    pub fn ping(self: *Connection) bool {
        if (c.PQstatus(self.pg) != c.CONNECTION_OK) return false;
        const maybe_res: ?*c.PGresult = c.PQexec(self.pg, "");
        const res = maybe_res orelse return false;
        defer c.PQclear(res);
        return c.PQresultStatus(res) == c.PGRES_EMPTY_QUERY;
    }

    /// Asks the server to abort whatever this connection is currently
    /// executing. Deliberately safe to call from another thread while
    /// `query` blocks -- that is its whole purpose (the PGcancel handle is
    /// created at connect and immutable; libpq documents PQcancel as
    /// thread-safe). The in-flight call then fails as SQLSTATE 57014 ->
    /// `error.ServerError`; the connection itself stays healthy and
    /// reusable. Best-effort: a cancel that arrives after the statement
    /// finished does nothing, which is inherent to cancellation. Wiring
    /// this to HTTP client disconnects is milestone 11's concurrency work;
    /// the primitive lives here so those layers can build on it.
    pub fn cancel(self: *Connection) void {
        const handle = self.cancel_handle orelse return;
        var err_buf: [256]u8 = undefined;
        if (c.PQcancel(handle, &err_buf, err_buf.len) == 0) {
            std.log.warn("postgres cancel request failed: {s}", .{trimmed(@ptrCast(&err_buf))});
        }
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

    /// Owns the PGresult (clears it on every path) and turns it into either
    /// an arena-backed QueryResult or the right Error. Shared by `query` and
    /// `Prepared.query` so the two can never diverge.
    fn collectResult(self: *Connection, maybe_res: ?*c.PGresult) Error!QueryResult {
        const res = maybe_res orelse return self.transportFailure();
        defer c.PQclear(res);

        const status = c.PQresultStatus(res);
        if (status != c.PGRES_TUPLES_OK and status != c.PGRES_COMMAND_OK) {
            return self.resultFailure(res);
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

    /// Classifies a failed PGresult: a dropped connection also surfaces as a
    /// failed result, so only a failure on a still-healthy connection is a
    /// SQL-level error. Does not clear `res` (the caller's defer does).
    fn resultFailure(self: *Connection, res: *c.PGresult) Error {
        if (c.PQstatus(self.pg) != c.CONNECTION_OK) return self.transportFailure();
        const sqlstate = c.PQresultErrorField(res, c.PG_DIAG_SQLSTATE);
        std.log.warn("postgres error [{s}]: {s}", .{
            if (sqlstate != null) std.mem.span(@as([*:0]const u8, @ptrCast(sqlstate))) else "-----",
            trimmed(c.PQresultErrorMessage(res)),
        });
        return Error.ServerError;
    }

    fn transportFailure(self: *Connection) Error {
        std.log.warn("postgres connection lost: {s}", .{trimmed(c.PQerrorMessage(self.pg))});
        return Error.ConnectionLost;
    }
};

/// libpq wants each text param as a NUL-terminated C string, which
/// []const u8 slices don't carry; everything lands in `scratch`.
fn encodeParams(scratch: std.mem.Allocator, params: []const QueryParam) std.mem.Allocator.Error![]const [*c]const u8 {
    const values = try scratch.alloc([*c]const u8, params.len);
    for (params, 0..) |param, i| {
        values[i] = switch (param) {
            .null_ => null,
            .text => |text| (try scratch.dupeZ(u8, text)).ptr,
        };
    }
    return values;
}

/// libpq error messages arrive NUL-terminated with a trailing newline.
fn trimmed(message: [*c]const u8) []const u8 {
    if (message == null) return "(no message)";
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(message)));
    return std.mem.trimEnd(u8, span, "\n");
}
