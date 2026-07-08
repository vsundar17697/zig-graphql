# 0015 — Connection pool: fixed-size, blocking acquire, lazy invalidation

## Status

Accepted. Written retroactively in milestone 5 — the pool shipped during
milestone 3/4 work citing this number before the document existed. The design
predates [0016](0016-adopt-libpq.md) (libpq) and survived it unchanged: only
what a pooled connection *is* changed, not how the pool manages one.

## Context

The HTTP server handles connections concurrently (one OS thread per accepted
connection), so database connections need sharing without cross-talk: a
connection mid-transaction cannot serve two requests. Requirements at the
time: bounded connection count against the fixture database, safe reuse after
SQL-level errors (the ROLLBACK path of
[0011](0011-mutation-transactions.md) depends on it), and no correctness
dependence on health guesswork.

## Decision

A fixed-size pool (`pg_wire/pool.zig`) of heap-allocated `*Connection`
handles with three properties:

- **Blocking `acquire`**: an idle connection is handed out immediately; below
  `max`, a new one is dialed; at `max`, the caller waits on a condition
  variable for a release. No queue-depth limit and no acquire timeout —
  deferred to milestone 11's backpressure work (pool-acquire timeout, 503).
- **Lazy invalidation instead of ping-per-checkout**: no health round-trip on
  acquire. The `Lease` carries a `broken` flag; `markBrokenUnless` marks the
  connection poisoned on any error *except* `error.ServerError` — a healthy
  connection correctly reporting a SQL-level failure, safe to reuse precisely
  because the driver resyncs after errors (originally the
  drain-to-ReadyForQuery fix in 0011; now libpq's own behavior). Anything
  else (transport failure, unknown state) closes the connection on release
  rather than risking a corrupted reuse. A per-checkout ping taxes every
  request to defend against a rare failure that lazy invalidation already
  converts into one failed request followed by a fresh dial.
- **Synchronization via `std.Io.Mutex`/`std.Io.Condition`** (Zig 0.16's
  cooperative-I/O primitives), taking the calling thread's own `Io` instance
  per call; the underlying futex state is shared across threads regardless of
  which `Io` issued a given call.

## Consequences

- A connection killed mid-lease costs exactly one failed request; the pool
  replaces it on the next acquire (integration-tested).
- The first request after a database restart can fail once per pooled
  connection (lazy invalidation's known cost); milestone 6's remaining
  lifecycle work (validate-on-acquire after idle, max-lifetime recycling)
  narrows this without changing the model.
- Leases are manual (`release` exactly once, `markBrokenUnless` on error) —
  acceptable while call sites are few; revisit if lease handling spreads.
