//! TLS exit tests (roadmap-v1.md milestone 6): prove the connection actually
//! negotiated what the environment demanded, from the server's point of view
//! (pg_stat_ssl), not the client's. CI runs this suite three ways:
//!
//!   - plain compose fixture: no env demands, the test only checks that
//!     pg_stat_ssl is readable and consistent with the sslmode used;
//!   - TLS-required server + PGGQL_TEST_SSLMODE=verify-full +
//!     PGGQL_TEST_EXPECT_TLS_VERSION=TLSv1.3;
//!   - the same server pinned to ssl_max_protocol_version=TLSv1.2 +
//!     PGGQL_TEST_EXPECT_TLS_VERSION=TLSv1.2 -- the "managed Postgres stuck
//!     on TLS 1.2" scenario (RDS/Azure) that motivated adopting libpq
//!     (docs/decisions/0016-adopt-libpq.md).

const std = @import("std");
const fixture = @import("fixture.zig");

test "negotiated TLS matches what the environment demands" {
    const allocator = std.testing.allocator;
    const conn = try fixture.connect(allocator);
    defer conn.close();

    // ssl::text renders as 'true'/'false'; version is e.g. 'TLSv1.3', null
    // for plaintext connections.
    var result = try conn.query(
        "SELECT coalesce(ssl::text, 'false'), coalesce(version, '') FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
        &.{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    const tls_on = std.mem.eql(u8, result.rows[0].columns[0].?, "true");
    const tls_version = result.rows[0].columns[1].?;

    if (fixture.expectedTlsVersion()) |expected| {
        try std.testing.expect(tls_on);
        try std.testing.expectEqualStrings(expected, tls_version);
        return;
    }

    // No explicit demand: still assert internal consistency with the
    // sslmode the fixture connected with. require/verify-* must be TLS;
    // disable must not be.
    switch (fixture.options().ssl_mode) {
        .require, .verify_ca, .verify_full => try std.testing.expect(tls_on),
        .disable => try std.testing.expect(!tls_on),
        .allow, .prefer => {}, // either outcome is legitimate
    }
}
