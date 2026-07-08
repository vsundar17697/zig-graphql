# 0002 — SCRAM-SHA-256 auth, not MD5

## Status

Accepted (milestone 1).

## Context

The initial draft of the `pg_wire` design deferred SCRAM-SHA-256 authentication in favor of
implementing cleartext/MD5 auth first, on the reasoning that it was the smaller amount of
protocol code to get connectivity working.

This was reviewed and found to be backwards: since Postgres 14, `password_encryption` defaults
to `scram-sha-256`, and the stock Docker `postgres` image stores SCRAM verifiers and will
negotiate SCRAM even when `pg_hba.conf` says `md5`. A client that only implements
cleartext/MD5 auth cannot authenticate against a realistically-configured Postgres instance at
all — only against one deliberately configured with `POSTGRES_HOST_AUTH_METHOD=trust` or an
explicitly downgraded `password_encryption` setting. MD5 auth is also on a deprecation track
in upstream Postgres.

## Decision

Implement SCRAM-SHA-256 authentication in milestone 1, using `std.crypto`'s HMAC-SHA256 and
PBKDF2. Do not implement MD5 or cleartext password auth as a supported path — `trust` (no
password) is used for the Docker test fixture itself, since the fixture is entirely
under our control and doesn't need to exercise password auth to be useful.

## Consequences

- `pg-gql` can authenticate against a default-configured modern Postgres, which a
  cleartext/MD5-only client could not — this is a precondition for "shippable library" being
  true rather than aspirational.
- SCRAM is more code than MD5 (roughly 150–250 lines, dominated by nonce/proof/signature
  bookkeeping across the multi-message exchange) and a correspondingly larger source of
  possible bugs. This is mitigated by testing at the byte level against golden wire traces
  (see [0001](0001-native-postgres-wire-protocol.md)) rather than relying only on
  live-connection tests, since SCRAM bugs are exactly the kind that are easy to get "almost
  right."
- If a narrower embedding target genuinely requires MD5/cleartext support later (e.g. against
  an old Postgres or an intentionally downgraded one), it can be added as an additional case
  in `pg_wire/auth.zig` without affecting any other module — auth mechanism selection is
  isolated to `pg_wire`.
