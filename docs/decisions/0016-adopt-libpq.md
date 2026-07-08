# 0016 — Adopt libpq for Postgres communication (supersedes 0001)

## Status

Accepted (2026-07-07). Supersedes [0001](0001-native-postgres-wire-protocol.md); makes
[0002](0002-scram-auth-not-md5.md) historical (auth is now libpq's job).

## Context

ADR 0001 chose a from-scratch native wire-protocol implementation, and milestones 1–4.5
vindicated it as a way to ship a working engine with zero dependencies: real SCRAM-SHA-256,
a connection pool, ~200 tests against real Postgres. But the v1.0 roadmap
([roadmap-v1.md](../roadmap-v1.md)) changes what the driver must do:

- **TLS against managed fleets.** RDS and Azure Database for PostgreSQL commonly negotiate
  TLS 1.2 only; Zig's `std.crypto.tls.Client` is TLS 1.3-only. Closing that gap ourselves
  means either implementing TLS 1.2 or absorbing an OpenSSL-class C dependency *anyway* —
  at which point the zero-dependency rationale for a hand-rolled protocol layer is already
  gone.
- **`sslmode=verify-full`** hostname verification, client-certificate auth, query
  cancellation, and years of protocol edge cases (notices, parameter-status changes,
  encoding corners) are table stakes for "point it at a database you didn't design," and
  every one is a mature, security-maintained code path in libpq.
- The wire protocol was never this project's value. The value is the IR, the SQL
  generation, and (ahead) the permission layer. The architecture already isolates the
  driver: `pg_wire` is IR-agnostic ("run this parameterized SQL, hand back rows"), so the
  swap is contained by design.

## Decision

Replace `pg_wire`'s socket/protocol/auth internals with **libpq**, linked through Zig's
native C interop. The `pg_wire` public interface — `Connection`-style "execute parameterized
SQL, iterate rows" plus the `Pool` (ADR 0015) — is preserved, so `sql_gen`, `executor`, the
C ABI, and the HTTP server do not change. The pool now manages `PGconn` handles; parameters
flow through `PQexecParams`/`PQprepare`; cancellation uses `PQcancel`.

The native wire-protocol client and the SCRAM implementation are deleted, not maintained as
a second backend — two drivers means double the lifecycle testing for no user-visible
benefit. Git history preserves them.

## Consequences

- TLS 1.2+1.3, `verify-full`, client certs, all auth methods, cancellation, and pipeline
  mode (PG 14+, relevant to milestone 12's subscription multiplexing) arrive maintained by
  upstream, with security fixes on Postgres's release cadence. Milestone 6's biggest risk
  item disappears.
- **Distribution cost, accepted knowingly:** pg-gql now links libpq and its OpenSSL.
  "Single static binary" requires per-platform static libpq+OpenSSL builds in CI (release
  artifacts); library mode links dynamically; C-ABI consumers inherit the libpq link
  requirement. Zig's trivial cross-compilation no longer applies to the driver — release
  targets are built per platform. This is the standard cost every libpq-based tool pays
  (including ndc-postgres via its Rust equivalents' native-tls path).
- Licensing is a non-issue (PostgreSQL License, permissive).
- The outbound HTTPS client (JWKS/webhook, milestone 10) is *not* covered by this decision
  — identity providers universally support TLS 1.3, so Zig's `std.http.Client` remains the
  plan there (ADR 0021).
- ADR 0015 (pool) survives with its blocking-acquire semantics; only what a pooled
  connection *is* changes.
