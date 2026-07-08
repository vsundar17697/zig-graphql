const std = @import("std");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");

pub const QueryParam = protocol.QueryParam;

pub const Error = protocol.WriteError || protocol.ReadError || auth.Error ||
    std.Io.net.IpAddress.ConnectError || error{
        AddressParseError,
        ServerRejectedAuth,
        UnexpectedMessage,
        ServerError,
    };

pub const Row = struct {
    /// Text-format column values, borrowed from the QueryResult's own arena.
    /// null means SQL NULL.
    columns: []?[]const u8,
};

pub const QueryResult = struct {
    arena: std.heap.ArenaAllocator,
    fields: []protocol.FieldDescription,
    rows: []Row,

    pub fn deinit(self: *QueryResult) void {
        self.arena.deinit();
    }
};

const read_buffer_size = 64 * 1024;
const write_buffer_size = 16 * 1024;

/// A single Postgres connection using the native wire protocol (see
/// docs/decisions/0001-native-postgres-wire-protocol.md). Must be heap
/// allocated via `connect` and only ever accessed through a pointer -- its
/// reader/writer capture a pointer back into `self.threaded`, so moving a
/// Connection by value after connecting would leave that pointer dangling.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    stream: std.Io.net.Stream,
    read_buf: [read_buffer_size]u8 = undefined,
    write_buf: [write_buffer_size]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,

    pub const Options = struct {
        host: []const u8,
        port: u16,
        user: []const u8,
        password: []const u8 = "",
        database: []const u8,
    };

    pub fn connect(allocator: std.mem.Allocator, options: Options) Error!*Connection {
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .stream = undefined,
        };
        const io = self.threaded.io();

        const addr = std.Io.net.IpAddress.parse(options.host, options.port) catch return Error.AddressParseError;
        self.stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        errdefer self.stream.close(io);

        self.writer = self.stream.writer(io, &self.write_buf);
        self.reader = self.stream.reader(io, &self.read_buf);

        try protocol.writeStartupMessage(allocator, &self.writer.interface, options.user, options.database);
        try self.writer.interface.flush();

        try self.performAuth(options.user, options.password);
        try self.drainUntilReadyForQuery();

        return self;
    }

    pub fn close(self: *Connection) void {
        self.stream.close(self.threaded.io());
        self.allocator.destroy(self);
    }

    fn performAuth(self: *Connection, user: []const u8, password: []const u8) Error!void {
        var msg = try protocol.readMessage(self.allocator, &self.reader.interface);
        defer msg.deinit(self.allocator);

        if (msg.type == 'E') return errorFromResponse(try protocol.parseErrorResponse(msg.payload));
        if (msg.type != 'R') return Error.UnexpectedMessage;

        switch (try protocol.parseAuthMessage(msg.payload)) {
            .ok => return, // trust/no-password auth (e.g. the Docker test fixture)
            .sasl => try self.performScramAuth(user, password),
            .sasl_continue, .sasl_final => return Error.UnexpectedMessage,
        }
    }

    fn performScramAuth(self: *Connection, user: []const u8, password: []const u8) Error!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Fixed nonce would be a replay vulnerability in production; a real
        // per-connection random nonce is required here (unlike the auth.zig
        // golden-trace tests, which pin a fixed nonce deliberately).
        var nonce_bytes: [18]u8 = undefined;
        self.threaded.io().random(&nonce_bytes);
        const encoder = std.base64.standard.Encoder;
        const nonce = try a.alloc(u8, encoder.calcSize(nonce_bytes.len));
        _ = encoder.encode(nonce, &nonce_bytes);

        const first = try auth.buildClientFirstMessage(a, user, nonce);
        try protocol.writeSASLInitialResponse(self.allocator, &self.writer.interface, "SCRAM-SHA-256", first.message);
        try self.writer.interface.flush();

        var continue_msg = try protocol.readMessage(self.allocator, &self.reader.interface);
        defer continue_msg.deinit(self.allocator);
        if (continue_msg.type == 'E') return errorFromResponse(try protocol.parseErrorResponse(continue_msg.payload));
        if (continue_msg.type != 'R') return Error.UnexpectedMessage;
        const server_first_message = switch (try protocol.parseAuthMessage(continue_msg.payload)) {
            .sasl_continue => |m| m,
            else => return Error.UnexpectedMessage,
        };

        const server_first = try auth.parseServerFirstMessage(a, server_first_message);
        const final = try auth.buildClientFinalMessage(a, password, first.bare, server_first_message, server_first);

        try protocol.writeSASLResponse(&self.writer.interface, final.message);
        try self.writer.interface.flush();

        var final_msg = try protocol.readMessage(self.allocator, &self.reader.interface);
        defer final_msg.deinit(self.allocator);
        if (final_msg.type == 'E') return errorFromResponse(try protocol.parseErrorResponse(final_msg.payload));
        if (final_msg.type != 'R') return Error.UnexpectedMessage;
        const server_final_message = switch (try protocol.parseAuthMessage(final_msg.payload)) {
            .sasl_final => |m| m,
            else => return Error.UnexpectedMessage,
        };
        try auth.verifyServerFinalMessage(server_final_message, final.expected_server_signature);

        var ok_msg = try protocol.readMessage(self.allocator, &self.reader.interface);
        defer ok_msg.deinit(self.allocator);
        if (ok_msg.type == 'E') return errorFromResponse(try protocol.parseErrorResponse(ok_msg.payload));
        if (ok_msg.type != 'R') return Error.UnexpectedMessage;
        switch (try protocol.parseAuthMessage(ok_msg.payload)) {
            .ok => {},
            else => return Error.ServerRejectedAuth,
        }
    }

    /// Drains ParameterStatus/BackendKeyData messages sent right after
    /// authentication succeeds, stopping at ReadyForQuery.
    fn drainUntilReadyForQuery(self: *Connection) Error!void {
        while (true) {
            var msg = try protocol.readMessage(self.allocator, &self.reader.interface);
            defer msg.deinit(self.allocator);
            switch (msg.type) {
                'Z' => return,
                'E' => return errorFromResponse(try protocol.parseErrorResponse(msg.payload)),
                'S', 'K' => continue,
                else => return Error.UnexpectedMessage,
            }
        }
    }

    /// Runs one parameterized query via the extended query protocol (Parse/
    /// Bind/Describe/Execute/Sync -- see docs/decisions/0001). Text-format
    /// params and results only; sql_gen always emits values as text (see
    /// sql_gen's Value union), so no binary codec is needed for milestone 1.
    ///
    /// The returned QueryResult owns an arena sized to this one query; the
    /// caller frees it with `QueryResult.deinit`.
    pub fn query(self: *Connection, sql: []const u8, params: []const QueryParam) Error!QueryResult {
        try protocol.writeParse(self.allocator, &self.writer.interface, sql);
        try protocol.writeBind(self.allocator, &self.writer.interface, params);
        try protocol.writeDescribePortal(self.allocator, &self.writer.interface);
        try protocol.writeExecute(self.allocator, &self.writer.interface);
        try protocol.writeSync(&self.writer.interface);
        try self.writer.interface.flush();

        var result = QueryResult{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .fields = &.{},
            .rows = &.{},
        };
        errdefer result.arena.deinit();
        const a = result.arena.allocator();

        var rows: std.ArrayListUnmanaged(Row) = .empty;

        while (true) {
            var msg = try protocol.readMessage(self.allocator, &self.reader.interface);
            defer msg.deinit(self.allocator);

            switch (msg.type) {
                '1', '2' => {}, // ParseComplete, BindComplete
                'T' => result.fields = try protocol.parseRowDescription(a, msg.payload),
                'n' => {}, // NoData (query returns no rows, e.g. a DDL/DML statement)
                'D' => {
                    const raw_row = try protocol.parseDataRow(a, msg.payload);
                    const columns = try a.alloc(?[]const u8, raw_row.columns.len);
                    for (raw_row.columns, 0..) |col, i| {
                        columns[i] = if (col) |bytes| try a.dupe(u8, bytes) else null;
                    }
                    try rows.append(a, .{ .columns = columns });
                },
                'C' => {}, // CommandComplete: nothing to extract for milestone 1's read-only queries
                'E' => {
                    const err = errorFromResponse(try protocol.parseErrorResponse(msg.payload));
                    // Postgres still sends ReadyForQuery after an error, since
                    // Sync was already part of this round trip -- drain to it
                    // before returning so the connection is protocol-synced
                    // for whatever the caller does next (e.g. ROLLBACK). See
                    // docs/decisions/0011-mutation-transactions.md.
                    self.drainUntilReadyForQuery() catch {};
                    return err;
                },
                'Z' => break,
                else => return Error.UnexpectedMessage,
            }
        }

        result.rows = try rows.toOwnedSlice(a);
        return result;
    }

    /// Begins a transaction. Multi-operation NDC mutation requests run inside
    /// one all-or-nothing transaction -- see
    /// docs/decisions/0011-mutation-transactions.md. Implemented as plain SQL
    /// text over the existing extended-protocol `query` method; no new
    /// wire-protocol work needed.
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
};

fn errorFromResponse(fields: protocol.ErrorFields) Error {
    std.log.err("postgres error [{s}]: {s}", .{ fields.code, fields.message });
    return Error.ServerError;
}
