# 0001 — Native Postgres wire protocol instead of libpq

## Status

Accepted (milestone 1).

## Context

`pg-gql` needs to talk to Postgres. The two realistic options are (a) bind to `libpq` via
Zig's C interop (`@cImport`), or (b) implement the Postgres frontend/backend wire protocol
natively in Zig.

The project's stated goal is to ship primarily as a library — a pure Zig package plus a C ABI
export for embedding from other languages — with an emphasis on being dependency-light and
efficient. The development machine itself has no `libpq`/`psql`/`pg_config` installed, which
is a live signal that requiring libpq is friction even before considering downstream
consumers.

## Decision

Implement the Postgres wire protocol natively in Zig. No libpq dependency for milestone 1.

Scope for milestone 1: startup message, SCRAM-SHA-256 authentication (see
[0002](0002-scram-auth-not-md5.md)), the **extended** query protocol only
(Parse/Bind/Describe/Execute/Sync — every generated query is parameterized, so the simple
query protocol adds nothing), the `ReadyForQuery` state machine, and mid-stream
`ErrorResponse`/`NoticeResponse` handling. `pg.zig` (karlseguin), a mature native-Zig Postgres
client, is used as a reference for message framing, SCRAM, and OID decoding while writing this
module — consulted, not vendored.

## Consequences

- A C-ABI consumer embedding `pg-gql` from another language does not need libpq present on
  the target system at link time or runtime, preserving Zig's static-linking value
  proposition.
- More upfront implementation work than binding libpq, and initially narrower
  auth-mechanism/Postgres-version coverage than libpq provides for free. `pg_wire` is budgeted
  as the largest single module in milestone 1 for this reason, and is built and
  integration-tested against the Docker Postgres fixture earliest to de-risk the rest of the
  plan.
- `pg_wire` is deliberately IR-agnostic (it only knows "run this parameterized SQL, hand back
  rows"), which keeps `@cImport`/libpq available later for narrow needs (e.g. the `COPY`
  protocol for bulk loads) without this being a one-way door — starting on libpq and later
  removing it would have been the harder direction to reverse.
- Protocol bugs of the form "matches my reading of the docs but not the real server" are a
  known risk with a hand-rolled implementation; mitigated by capturing golden wire traces from
  the Docker Postgres fixture and checking them in as fixtures for encode/decode unit tests,
  rather than relying solely on live-connection integration tests to catch protocol-level bugs.
