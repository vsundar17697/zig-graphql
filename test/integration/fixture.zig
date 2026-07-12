//! Single source of truth for how integration tests reach the fixture
//! Postgres. Defaults match docker-compose.yml (127.0.0.1:55432, pggql/pggql,
//! trust auth); every knob is overridable through the environment so the same
//! suite runs unchanged against CI's TLS-required and TLS-1.2-pinned servers:
//!
//!   PGGQL_TEST_HOST          default 127.0.0.1
//!   PGGQL_TEST_PORT          default 55432
//!   PGGQL_TEST_USER          default pggql
//!   PGGQL_TEST_PASSWORD      default "" (compose uses trust auth)
//!   PGGQL_TEST_DATABASE      default pggql
//!   PGGQL_TEST_SSLMODE       disable|allow|prefer|require|verify-ca|verify-full
//!   PGGQL_TEST_SSLROOTCERT   path to the CA bundle for verify-* modes
//!   PGGQL_TEST_EXPECT_TLS_VERSION  makes tls_test.zig assert the exact
//!                            negotiated protocol (e.g. "TLSv1.2"); unset
//!                            means "whatever the fixture speaks is fine".
//!
//! Values are read once, at first use, and leak intentionally: they live for
//! the whole test process and std.testing.allocator would report them.

const std = @import("std");
const pg_gql = @import("pg_gql");

const Options = pg_gql.pg_wire.Connection.Options;

var cached: ?Options = null;

/// Connection options for the fixture database, environment applied. Lazy,
/// not thread-safe: tests call it (directly or via `connect`) from the test
/// runner's thread before handing the returned value to worker threads.
pub fn options() Options {
    if (cached == null) populate();
    return cached.?;
}

fn populate() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator(); // never freed; see file doc comment

    const ssl_mode: Options.SslMode = if (env(a, "PGGQL_TEST_SSLMODE")) |raw| mode: {
        inline for (@typeInfo(Options.SslMode).@"enum".fields) |field| {
            // Env spelling uses libpq's hyphens ("verify-full"); field names
            // use underscores.
            var buf: [16]u8 = undefined;
            const libpq_name = buf[0..field.name.len];
            _ = std.mem.replace(u8, field.name, "_", "-", libpq_name);
            if (std.mem.eql(u8, raw, libpq_name))
                break :mode @field(Options.SslMode, field.name);
        }
        std.debug.panic("PGGQL_TEST_SSLMODE has unknown value '{s}'", .{raw});
    } else .prefer;

    cached = .{
        .host = env(a, "PGGQL_TEST_HOST") orelse "127.0.0.1",
        .port = if (env(a, "PGGQL_TEST_PORT")) |raw|
            std.fmt.parseInt(u16, raw, 10) catch
                std.debug.panic("PGGQL_TEST_PORT is not a port number: '{s}'", .{raw})
        else
            55432,
        .user = env(a, "PGGQL_TEST_USER") orelse "pggql",
        .password = env(a, "PGGQL_TEST_PASSWORD") orelse "",
        .database = env(a, "PGGQL_TEST_DATABASE") orelse "pggql",
        .ssl_mode = ssl_mode,
        .ssl_root_cert = env(a, "PGGQL_TEST_SSLROOTCERT"),
    };
}

// libc getenv, because these tests always link libc (libpq requires it) and
// Zig 0.16's std.process.Environ plumbing is overkill for six variables.
fn env(a: std.mem.Allocator, name: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr) orelse return null;
    const copy = a.dupe(u8, std.mem.span(raw)) catch @panic("OOM");
    return if (copy.len == 0) null else copy;
}

/// The exact TLS protocol the fixture is expected to negotiate
/// (PGGQL_TEST_EXPECT_TLS_VERSION, e.g. "TLSv1.2"), or null when the
/// environment makes no demand. tls_test.zig asserts against this.
pub fn expectedTlsVersion() ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return env(arena.allocator(), "PGGQL_TEST_EXPECT_TLS_VERSION");
}

/// Connect to the fixture database, with the diagnostic every test used to
/// hand-roll: a connect failure here nearly always means the compose fixture
/// (or CI service) isn't up, so say that instead of a bare error code.
pub fn connect(allocator: std.mem.Allocator) !*pg_gql.pg_wire.Connection {
    const opts = options();
    return pg_gql.pg_wire.Connection.connect(allocator, opts) catch |err| {
        std.debug.print(
            "\nfailed to connect to the test fixture Postgres at {s}:{d} -- is `docker compose up -d --wait` running? ({t})\n",
            .{ opts.host, opts.port, err },
        );
        return err;
    };
}
