const std = @import("std");

pub const WriteError = std.Io.Writer.Error || std.mem.Allocator.Error;
pub const ReadError = std.Io.Reader.Error || std.mem.Allocator.Error || error{
    ProtocolError,
    UnsupportedAuthMethod,
};

fn appendU16(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: u16) !void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, value, .big);
    try buf.appendSlice(allocator, &tmp);
}

fn appendI32(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: i32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(i32, &tmp, value, .big);
    try buf.appendSlice(allocator, &tmp);
}

fn writeFramed(writer: *std.Io.Writer, msg_type: u8, payload: []const u8) WriteError!void {
    try writer.writeByte(msg_type);
    try writer.writeInt(u32, @intCast(4 + payload.len), .big);
    try writer.writeAll(payload);
}

/// The only message with no leading type byte, and whose length field covers
/// an extra 4 bytes (the protocol version) beyond the usual header.
pub fn writeStartupMessage(allocator: std.mem.Allocator, writer: *std.Io.Writer, user: []const u8, database: []const u8) WriteError!void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, "user\x00");
    try payload.appendSlice(allocator, user);
    try payload.append(allocator, 0);
    try payload.appendSlice(allocator, "database\x00");
    try payload.appendSlice(allocator, database);
    try payload.append(allocator, 0);
    try payload.append(allocator, 0); // parameter list terminator

    try writer.writeInt(u32, @intCast(4 + 4 + payload.items.len), .big);
    try writer.writeInt(u32, 196608, .big); // protocol version 3.0
    try writer.writeAll(payload.items);
}

pub fn writeSASLInitialResponse(allocator: std.mem.Allocator, writer: *std.Io.Writer, mechanism: []const u8, response: []const u8) WriteError!void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, mechanism);
    try payload.append(allocator, 0);
    try appendI32(allocator, &payload, @intCast(response.len));
    try payload.appendSlice(allocator, response);
    try writeFramed(writer, 'p', payload.items);
}

pub fn writeSASLResponse(writer: *std.Io.Writer, response: []const u8) WriteError!void {
    try writeFramed(writer, 'p', response);
}

/// Always declares zero explicit parameter types (legal per the protocol --
/// it means "infer every parameter's type"), so this module never needs an
/// OID-mapping table; Postgres infers types from the query text itself.
pub fn writeParse(allocator: std.mem.Allocator, writer: *std.Io.Writer, query: []const u8) WriteError!void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.append(allocator, 0); // unnamed prepared statement
    try payload.appendSlice(allocator, query);
    try payload.append(allocator, 0);
    try appendU16(allocator, &payload, 0); // zero explicit parameter types
    try writeFramed(writer, 'P', payload.items);
}

pub const QueryParam = union(enum) {
    null_,
    text: []const u8,
};

/// Zero format-code counts for both parameters and results are legal
/// shorthand for "everything is text format" -- avoids needing to repeat a
/// format code per parameter/result column.
pub fn writeBind(allocator: std.mem.Allocator, writer: *std.Io.Writer, params: []const QueryParam) WriteError!void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.append(allocator, 0); // unnamed portal
    try payload.append(allocator, 0); // unnamed prepared statement
    try appendU16(allocator, &payload, 0); // parameter format codes: all text
    try appendU16(allocator, &payload, @intCast(params.len));
    for (params) |param| {
        switch (param) {
            .null_ => try appendI32(allocator, &payload, -1),
            .text => |t| {
                try appendI32(allocator, &payload, @intCast(t.len));
                try payload.appendSlice(allocator, t);
            },
        }
    }
    try appendU16(allocator, &payload, 0); // result format codes: all text
    try writeFramed(writer, 'B', payload.items);
}

pub fn writeDescribePortal(allocator: std.mem.Allocator, writer: *std.Io.Writer) WriteError!void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.append(allocator, 'P');
    try payload.append(allocator, 0); // unnamed portal
    try writeFramed(writer, 'D', payload.items);
}

pub fn writeExecute(allocator: std.mem.Allocator, writer: *std.Io.Writer) WriteError!void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.append(allocator, 0); // unnamed portal
    try appendI32(allocator, &payload, 0); // no row limit
    try writeFramed(writer, 'E', payload.items);
}

pub fn writeSync(writer: *std.Io.Writer) WriteError!void {
    try writeFramed(writer, 'S', &.{});
}

pub const RawMessage = struct {
    type: u8,
    payload: []u8,

    pub fn deinit(self: *RawMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

/// Reads one backend message. The payload is copied out of the reader's
/// internal buffer (via `allocator`) since that buffer is reused on the next
/// read -- callers must free it (`RawMessage.deinit`).
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError!RawMessage {
    const msg_type = try reader.takeByte();
    const len = try reader.takeInt(u32, .big);
    if (len < 4) return error.ProtocolError;
    const body = try reader.take(len - 4);
    return .{ .type = msg_type, .payload = try allocator.dupe(u8, body) };
}

pub const AuthMessage = union(enum) {
    ok,
    /// Mechanism list itself is not surfaced; milestone 1 requires the server
    /// to offer SCRAM-SHA-256 and errors out otherwise (see connection.zig).
    sasl,
    sasl_continue: []const u8,
    sasl_final: []const u8,
};

pub fn parseAuthMessage(payload: []const u8) ReadError!AuthMessage {
    if (payload.len < 4) return error.ProtocolError;
    const code = std.mem.readInt(u32, payload[0..4], .big);
    return switch (code) {
        0 => .ok,
        10 => .sasl,
        11 => .{ .sasl_continue = payload[4..] },
        12 => .{ .sasl_final = payload[4..] },
        else => error.UnsupportedAuthMethod,
    };
}

pub const FieldDescription = struct {
    name: []const u8,
    type_oid: u32,
};

/// Field names are copied via `allocator` rather than borrowed from `payload`
/// -- callers (see connection.zig) free the raw message payload right after
/// each message is processed, so a borrowed slice would dangle.
pub fn parseRowDescription(allocator: std.mem.Allocator, payload: []const u8) ReadError![]FieldDescription {
    if (payload.len < 2) return error.ProtocolError;
    const count = std.mem.readInt(u16, payload[0..2], .big);
    var pos: usize = 2;
    const fields = try allocator.alloc(FieldDescription, count);
    for (0..count) |i| {
        const name_end = std.mem.indexOfScalarPos(u8, payload, pos, 0) orelse return error.ProtocolError;
        const name = try allocator.dupe(u8, payload[pos..name_end]);
        pos = name_end + 1;
        pos += 4; // table OID
        pos += 2; // column attribute number
        if (pos + 4 > payload.len) return error.ProtocolError;
        const type_oid = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        pos += 2; // type size
        pos += 4; // type modifier
        pos += 2; // format code
        fields[i] = .{ .name = name, .type_oid = type_oid };
    }
    return fields;
}

pub const DataRow = struct {
    /// Borrowed from the RawMessage payload; null entries are SQL NULL.
    columns: []?[]const u8,
};

pub fn parseDataRow(allocator: std.mem.Allocator, payload: []const u8) ReadError!DataRow {
    if (payload.len < 2) return error.ProtocolError;
    const count = std.mem.readInt(u16, payload[0..2], .big);
    var pos: usize = 2;
    const columns = try allocator.alloc(?[]const u8, count);
    for (0..count) |i| {
        if (pos + 4 > payload.len) return error.ProtocolError;
        const len_i32: i32 = @bitCast(std.mem.readInt(u32, payload[pos..][0..4], .big));
        pos += 4;
        if (len_i32 < 0) {
            columns[i] = null;
        } else {
            const len: usize = @intCast(len_i32);
            if (pos + len > payload.len) return error.ProtocolError;
            columns[i] = payload[pos .. pos + len];
            pos += len;
        }
    }
    return .{ .columns = columns };
}

pub fn parseCommandComplete(payload: []const u8) ReadError![]const u8 {
    const end = std.mem.indexOfScalar(u8, payload, 0) orelse return error.ProtocolError;
    return payload[0..end];
}

pub const ErrorFields = struct {
    message: []const u8 = "",
    code: []const u8 = "",
};

pub fn parseErrorResponse(payload: []const u8) ReadError!ErrorFields {
    var result = ErrorFields{};
    var pos: usize = 0;
    while (pos < payload.len and payload[pos] != 0) {
        const field_type = payload[pos];
        pos += 1;
        const end = std.mem.indexOfScalarPos(u8, payload, pos, 0) orelse return error.ProtocolError;
        const value = payload[pos..end];
        pos = end + 1;
        switch (field_type) {
            'M' => result.message = value,
            'C' => result.code = value,
            else => {},
        }
    }
    return result;
}

// Golden-trace fixtures captured from a real Postgres 16 connection (see the
// capture scripts used during development) -- these pin the decoder against
// bytes an actual server sent, not just bytes this codebase produced itself.

test "writeStartupMessage matches the captured wire bytes" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeStartupMessage(allocator, &writer, "scram_user", "pggql");

    const expected_hex = "00000028000300007573657200736372616d5f7573657200646174616261736500706767716c0000";
    var expected: [40]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
}

/// Decodes a hex fixture into `scratch` and returns the exactly-sized slice,
/// so tests never have to hand-count hex string lengths (a real source of
/// off-by-one bugs when transcribing captured wire traces).
fn decodeHex(scratch: []u8, hex: []const u8) []u8 {
    return std.fmt.hexToBytes(scratch, hex) catch unreachable;
}

test "parseAuthMessage decodes a real AuthenticationSASL response" {
    const hex = "0000000a534352414d2d5348412d3235360000"; // payload only (type+len stripped)
    var scratch: [256]u8 = undefined;
    const msg = try parseAuthMessage(decodeHex(&scratch, hex));
    try std.testing.expectEqual(AuthMessage.sasl, std.meta.activeTag(msg));
}

test "parseAuthMessage decodes a real AuthenticationSASLContinue response" {
    const hex = "0000000b723d6669786564546573744e6f6e636556616c7565313233343536373839303d3d4356465165484c41534d57717468785968554c753649616d2c733d506d554677344d34682f454d516577774d784a574e673d3d2c693d34303936";
    var scratch: [256]u8 = undefined;
    const msg = try parseAuthMessage(decodeHex(&scratch, hex));
    try std.testing.expectEqualStrings(
        "r=fixedTestNonceValue1234567890==CVFQeHLASMWqthxYhULu6Iam,s=PmUFw4M4h/EMQewwMxJWNg==,i=4096",
        msg.sasl_continue,
    );
}

test "parseAuthMessage decodes a real AuthenticationSASLFinal response" {
    const hex = "0000000c763d59745642762f566f79416b4750517673315752664f57735959454c4b4e3846426d457078365870756e35733d";
    var scratch: [256]u8 = undefined;
    const msg = try parseAuthMessage(decodeHex(&scratch, hex));
    try std.testing.expectEqualStrings("v=YtVBv/VoyAkGPQvs1WRfOWsYYELKN8FBmEpx6Xpun5s=", msg.sasl_final);
}

test "parseAuthMessage decodes a real AuthenticationOk response" {
    const hex = "00000000";
    var scratch: [256]u8 = undefined;
    const msg = try parseAuthMessage(decodeHex(&scratch, hex));
    try std.testing.expectEqual(AuthMessage.ok, msg);
}

test "parseRowDescription decodes a real single-column RowDescription" {
    // Captured for `SELECT $1::int4 + 1 AS result` (type+len header stripped).
    const hex = "0001726573756c7400000000000000000000170004ffffffff0000";
    var scratch: [256]u8 = undefined;
    const decoded = decodeHex(&scratch, hex);

    const fields = try parseRowDescription(std.testing.allocator, decoded);
    defer {
        for (fields) |field| std.testing.allocator.free(field.name);
        std.testing.allocator.free(fields);
    }

    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("result", fields[0].name);
    try std.testing.expectEqual(@as(u32, 23), fields[0].type_oid); // int4
}

test "parseDataRow decodes a real single-column DataRow" {
    // Captured DataRow for the same query, value "42" as text.
    const hex = "000100000002" ++ "3432";
    var scratch: [256]u8 = undefined;
    const decoded = decodeHex(&scratch, hex);

    const row = try parseDataRow(std.testing.allocator, decoded);
    defer std.testing.allocator.free(row.columns);

    try std.testing.expectEqual(@as(usize, 1), row.columns.len);
    try std.testing.expectEqualStrings("42", row.columns[0].?);
}

test "parseDataRow decodes a NULL column" {
    const payload = [_]u8{ 0, 1, 0xff, 0xff, 0xff, 0xff }; // count=1, length=-1
    const row = try parseDataRow(std.testing.allocator, &payload);
    defer std.testing.allocator.free(row.columns);

    try std.testing.expectEqual(@as(usize, 1), row.columns.len);
    try std.testing.expect(row.columns[0] == null);
}

test "parseCommandComplete decodes a real CommandComplete tag" {
    const payload = "SELECT 1\x00";
    const tag = try parseCommandComplete(payload);
    try std.testing.expectEqualStrings("SELECT 1", tag);
}

test "readMessage frames a message off a fixed reader" {
    const allocator = std.testing.allocator;
    // ParseComplete: '1' + length(4)
    const bytes = [_]u8{ '1', 0, 0, 0, 4 };
    var reader = std.Io.Reader.fixed(&bytes);

    var msg = try readMessage(allocator, &reader);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(@as(u8, '1'), msg.type);
    try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
}

test "writeBind encodes params as length-prefixed text with NULL support" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeBind(allocator, &writer, &.{ .{ .text = "42" }, .null_ });

    const written = writer.buffered();
    try std.testing.expectEqual(@as(u8, 'B'), written[0]);
    // portal\0 statement\0 paramFormatCodes(0) numParams(2) len(2) "42" len(-1)
    const expected_tail = [_]u8{
        0, 0, // portal, statement (empty cstrings)
        0, 0, // 0 parameter format codes
        0, 2, // 2 parameters
        0, 0, 0, 2, '4', '2', // param 1: length 2, "42"
        0xff, 0xff, 0xff, 0xff, // param 2: length -1 (NULL)
        0, 0, // 0 result format codes
    };
    try std.testing.expectEqualSlices(u8, &expected_tail, written[5..]);
}
