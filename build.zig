const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libpq = detectLibpq(b);

    // --- Leaf / core modules, wired per docs/architecture.md's dependency graph ---

    const ndc_ir = b.addModule("ndc_ir", .{
        .root_source_file = b.path("src/ndc_ir/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const schema = b.addModule("schema", .{
        .root_source_file = b.path("src/schema/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
        },
    });

    const sql_gen = b.addModule("sql_gen", .{
        .root_source_file = b.path("src/sql_gen/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
        },
    });

    const pg_wire = b.addModule("pg_wire", .{
        .root_source_file = b.path("src/pg_wire/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (libpq) |paths| {
        pg_wire.addIncludePath(.{ .cwd_relative = paths.include });
        pg_wire.addLibraryPath(.{ .cwd_relative = paths.lib });
    }
    pg_wire.linkSystemLibrary("pq", .{});

    const graphql_parser = b.addModule("graphql_parser", .{
        .root_source_file = b.path("src/graphql_parser/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
        },
    });

    const query_builder = b.addModule("query_builder", .{
        .root_source_file = b.path("src/query_builder/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
        },
    });

    const graphql_schema = b.addModule("graphql_schema", .{
        .root_source_file = b.path("src/graphql_schema/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
            .{ .name = "graphql_parser", .module = graphql_parser },
        },
    });

    const executor = b.addModule("executor", .{
        .root_source_file = b.path("src/executor/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
            .{ .name = "sql_gen", .module = sql_gen },
            .{ .name = "pg_wire", .module = pg_wire },
        },
    });

    // --- Public library: the package other Zig code depends on directly ---

    const pg_gql = b.addModule("pg_gql", .{
        .root_source_file = b.path("src/pg_gql.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
            .{ .name = "sql_gen", .module = sql_gen },
            .{ .name = "pg_wire", .module = pg_wire },
            .{ .name = "graphql_parser", .module = graphql_parser },
            .{ .name = "query_builder", .module = query_builder },
            .{ .name = "executor", .module = executor },
            .{ .name = "graphql_schema", .module = graphql_schema },
        },
    });

    // --- C ABI shared library ---

    const c_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/c_abi/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
            .{ .name = "pg_wire", .module = pg_wire },
            .{ .name = "graphql_parser", .module = graphql_parser },
            .{ .name = "query_builder", .module = query_builder },
            .{ .name = "executor", .module = executor },
        },
    });

    const c_abi_lib = b.addLibrary(.{
        .name = "pg_gql",
        .linkage = .dynamic,
        .root_module = c_abi_mod,
    });
    b.installArtifact(c_abi_lib);

    // --- HTTP server binary ---

    const http_server_mod = b.createModule(.{
        .root_source_file = b.path("src/http_server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg_gql", .module = pg_gql },
            .{ .name = "ndc_ir", .module = ndc_ir },
            .{ .name = "schema", .module = schema },
        },
    });

    const server_exe = b.addExecutable(.{
        .name = "pg-gql-server",
        .root_module = http_server_mod,
    });
    b.installArtifact(server_exe);

    // --- Unit tests: pure logic only, no Docker/network. This is `zig build test`. ---

    const test_step = b.step("test", "Run pure unit tests (no DB required)");
    const unit_test_modules = [_]*std.Build.Module{
        ndc_ir, schema, sql_gen, pg_wire, graphql_parser, query_builder, executor, graphql_schema, pg_gql, c_abi_mod, http_server_mod,
    };
    // Vendored test runner: identical to the compiler's default except for a
    // one-line fix that unbreaks `zig build test --fuzz` on Zig 0.16.0 (see
    // build_support/test_runner.zig for the details and removal condition).
    const test_runner: std.Build.Step.Compile.TestRunner = .{
        .path = b.path("build_support/test_runner.zig"),
        .mode = .server,
    };

    for (unit_test_modules) |mod| {
        const t = b.addTest(.{ .root_module = mod, .test_runner = test_runner });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // --- Integration tests: require `docker compose up -d --wait` first. Separate step
    //     so the default `test` step never touches Docker or the network. ---

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg_gql", .module = pg_gql },
        },
    });

    const integration_test_step = b.step(
        "test-integration",
        "Run Postgres-backed integration tests (requires `docker compose up -d --wait` first)",
    );
    const integration_test = b.addTest(.{ .root_module = integration_mod });
    integration_test_step.dependOn(&b.addRunArtifact(integration_test).step);
}

const LibpqPaths = struct {
    include: []const u8,
    lib: []const u8,
};

/// Locates libpq's headers and library (docs/decisions/0016-adopt-libpq.md),
/// in order: an explicit -Dlibpq-prefix, the well-known keg-only Homebrew
/// prefixes (never on the default search path), then `pg_config` (the
/// Debian/Ubuntu libpq-dev layout puts libpq-fe.h at /usr/include/postgresql,
/// also not on the compiler's default include path). Null means "trust the
/// system default search paths".
fn detectLibpq(b: *std.Build) ?LibpqPaths {
    if (b.option([]const u8, "libpq-prefix", "libpq install prefix containing include/ and lib/")) |prefix| {
        return .{
            .include = b.pathJoin(&.{ prefix, "include" }),
            .lib = b.pathJoin(&.{ prefix, "lib" }),
        };
    }

    for ([_][]const u8{ "/opt/homebrew/opt/libpq", "/usr/local/opt/libpq" }) |prefix| {
        std.Io.Dir.accessAbsolute(b.graph.io, prefix, .{}) catch continue;
        return .{
            .include = b.pathJoin(&.{ prefix, "include" }),
            .lib = b.pathJoin(&.{ prefix, "lib" }),
        };
    }

    var code: u8 = undefined;
    const include_dir = b.runAllowFail(&.{ "pg_config", "--includedir" }, &code, .ignore) catch return null;
    const lib_dir = b.runAllowFail(&.{ "pg_config", "--libdir" }, &code, .ignore) catch return null;
    return .{
        .include = std.mem.trimEnd(u8, include_dir, "\n"),
        .lib = std.mem.trimEnd(u8, lib_dir, "\n"),
    };
}
