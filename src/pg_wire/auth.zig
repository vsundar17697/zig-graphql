const std = @import("std");

pub const Error = error{
    MissingNonce,
    MissingSalt,
    MissingIterations,
    InvalidServerFinalMessage,
    ServerSignatureMismatch,
} || std.mem.Allocator.Error || std.fmt.ParseIntError || std.base64.Error ||
    std.crypto.errors.WeakParametersError || std.crypto.errors.OutputTooLongError;

/// The GS2 header this client always sends ("n,,": no channel binding, no
/// authzid) base64-encoded once, as a compile-time constant rather than
/// re-encoding it on every connection.
const gs2_header_b64 = "biws";

pub const ClientFirst = struct {
    /// The full message sent as the SASLInitialResponse body: gs2-header + bare.
    message: []const u8,
    /// The part after the gs2-header, reused verbatim inside AuthMessage later.
    bare: []const u8,
};

pub fn buildClientFirstMessage(allocator: std.mem.Allocator, user: []const u8, client_nonce: []const u8) Error!ClientFirst {
    const bare = try std.fmt.allocPrint(allocator, "n={s},r={s}", .{ user, client_nonce });
    const message = try std.fmt.allocPrint(allocator, "n,,{s}", .{bare});
    return .{ .message = message, .bare = bare };
}

pub const ServerFirst = struct {
    nonce: []const u8,
    salt: []const u8,
    iterations: u32,
};

pub fn parseServerFirstMessage(allocator: std.mem.Allocator, message: []const u8) Error!ServerFirst {
    var nonce: ?[]const u8 = null;
    var salt_b64: ?[]const u8 = null;
    var iterations: ?u32 = null;

    var it = std.mem.splitScalar(u8, message, ',');
    while (it.next()) |part| {
        if (std.mem.startsWith(u8, part, "r=")) {
            nonce = part[2..];
        } else if (std.mem.startsWith(u8, part, "s=")) {
            salt_b64 = part[2..];
        } else if (std.mem.startsWith(u8, part, "i=")) {
            iterations = try std.fmt.parseInt(u32, part[2..], 10);
        }
    }

    const decoder = std.base64.standard.Decoder;
    const salt_b64_value = salt_b64 orelse return Error.MissingSalt;
    const salt = try allocator.alloc(u8, try decoder.calcSizeForSlice(salt_b64_value));
    try decoder.decode(salt, salt_b64_value);

    return .{
        .nonce = nonce orelse return Error.MissingNonce,
        .salt = salt,
        .iterations = iterations orelse return Error.MissingIterations,
    };
}

pub const ClientFinal = struct {
    /// The full message sent as the SASLResponse (client final) body.
    message: []const u8,
    /// The server signature we expect back in AuthenticationSASLFinal,
    /// base64-encoded, ready for a direct string comparison.
    expected_server_signature: []const u8,
};

/// Implements RFC 5802's SCRAM key derivation. See docs/decisions/0002-scram-auth-not-md5.md
/// for why this is implemented at all rather than falling back to MD5/cleartext.
pub fn buildClientFinalMessage(
    allocator: std.mem.Allocator,
    password: []const u8,
    client_first_bare: []const u8,
    server_first_message: []const u8,
    server_first: ServerFirst,
) Error!ClientFinal {
    const client_final_no_proof = try std.fmt.allocPrint(allocator, "c={s},r={s}", .{ gs2_header_b64, server_first.nonce });
    const auth_message = try std.fmt.allocPrint(allocator, "{s},{s},{s}", .{ client_first_bare, server_first_message, client_final_no_proof });

    var salted_password: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted_password, password, server_first.salt, server_first.iterations, std.crypto.auth.hmac.sha2.HmacSha256);

    var client_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_key, "Client Key", &salted_password);

    var stored_key: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&client_key, &stored_key, .{});

    var client_signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_signature, auth_message, &stored_key);

    var client_proof: [32]u8 = undefined;
    for (client_proof[0..], client_key, client_signature) |*out, ck, cs| out.* = ck ^ cs;

    var server_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&server_key, "Server Key", &salted_password);

    var server_signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&server_signature, auth_message, &server_key);

    const encoder = std.base64.standard.Encoder;
    const proof_b64 = try allocator.alloc(u8, encoder.calcSize(client_proof.len));
    _ = encoder.encode(proof_b64, &client_proof);

    const signature_b64 = try allocator.alloc(u8, encoder.calcSize(server_signature.len));
    _ = encoder.encode(signature_b64, &server_signature);

    const message = try std.fmt.allocPrint(allocator, "{s},p={s}", .{ client_final_no_proof, proof_b64 });

    return .{ .message = message, .expected_server_signature = signature_b64 };
}

/// Parses "v=<base64 signature>" and verifies it matches what we computed in
/// `buildClientFinalMessage` -- this is what protects the client against a
/// man-in-the-middle impersonating the server (RFC 5802 section 3).
pub fn verifyServerFinalMessage(message: []const u8, expected_server_signature: []const u8) Error!void {
    if (!std.mem.startsWith(u8, message, "v=")) return Error.InvalidServerFinalMessage;
    if (!std.mem.eql(u8, message[2..], expected_server_signature)) return Error.ServerSignatureMismatch;
}

// Golden-trace test vectors captured from a real Postgres 16 SCRAM-SHA-256
// handshake (role `scram_user`/`scram_pw`, fixed client nonce) -- see the
// capture scripts used during development. These pin the exact RFC 5802 key
// derivation against real server output, not just internal self-consistency.
const test_user = "scram_user";
const test_password = "scram_pw";
const test_client_nonce = "fixedTestNonceValue1234567890==";
const test_server_first_message = "r=fixedTestNonceValue1234567890==CVFQeHLASMWqthxYhULu6Iam,s=PmUFw4M4h/EMQewwMxJWNg==,i=4096";
const test_expected_client_final_message = "c=biws,r=fixedTestNonceValue1234567890==CVFQeHLASMWqthxYhULu6Iam,p=So1AEPLb1tfZu7LI9Ez/Ubm4LGaimIsM9QCK/qSYW+w=";
const test_expected_server_final_message = "v=YtVBv/VoyAkGPQvs1WRfOWsYYELKN8FBmEpx6Xpun5s=";

test "buildClientFirstMessage matches the captured wire format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first = try buildClientFirstMessage(arena.allocator(), test_user, test_client_nonce);
    try std.testing.expectEqualStrings("n,,n=scram_user,r=fixedTestNonceValue1234567890==", first.message);
}

test "parseServerFirstMessage extracts nonce, salt and iterations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try parseServerFirstMessage(arena.allocator(), test_server_first_message);
    try std.testing.expectEqualStrings("fixedTestNonceValue1234567890==CVFQeHLASMWqthxYhULu6Iam", parsed.nonce);
    try std.testing.expectEqual(@as(u32, 4096), parsed.iterations);
    try std.testing.expectEqual(@as(usize, 16), parsed.salt.len);
}

test "full SCRAM handshake reproduces the real Postgres-verified byte sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try buildClientFirstMessage(allocator, test_user, test_client_nonce);
    const server_first = try parseServerFirstMessage(allocator, test_server_first_message);
    const final = try buildClientFinalMessage(allocator, test_password, first.bare, test_server_first_message, server_first);

    try std.testing.expectEqualStrings(test_expected_client_final_message, final.message);
    try verifyServerFinalMessage(test_expected_server_final_message, final.expected_server_signature);
}

test "verifyServerFinalMessage rejects a tampered signature" {
    const result = verifyServerFinalMessage("v=not-the-right-signature", "YtVBv/VoyAkGPQvs1WRfOWsYYELKN8FBmEpx6Xpun5s=");
    try std.testing.expectError(Error.ServerSignatureMismatch, result);
}
