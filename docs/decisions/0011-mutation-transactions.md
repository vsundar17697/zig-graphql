# 0011 — Mutation SQL shape, missing-row semantics, and transaction handling

## Status

Accepted.

## Context

Two correctness issues were flagged while designing milestone 3, both easy to get wrong and
expensive to discover late:

1. The obvious way to write a data-modifying-CTE mutation statement —
   `SELECT json_build_object(...) FROM (SELECT ... FROM mutated) AS t` — returns **zero rows**,
   not `{"affected_rows": 0}`, when the CTE itself affects zero rows (e.g. `update_<t>_by_pk`
   targeting a primary key that doesn't exist). `executor` expects exactly one JSON-column row
   per statement (see [0003](0003-json-shaping-sql-in-generator.md)); a statement that
   sometimes returns zero rows breaks that contract silently.
2. A mid-transaction Postgres error leaves the wire connection in aborted-transaction state.
   `pg_wire.Connection.query`'s error path (`'E'` case) returned immediately without draining
   the `ReadyForQuery` message Postgres still sends after an error (since `Sync` was already
   part of the same extended-protocol round trip) — the next call on that connection would
   then read that stale `ReadyForQuery` as if it were the *next* query's response, permanently
   desynchronizing the protocol. This was latent since milestone 1 but never triggered because
   every milestone 1/2 query was well-formed; mutations are the first place a caller-triggerable
   Postgres error (a constraint violation) becomes an expected, tested code path.

## Decision

**Always-one-row shape**: every mutation statement is `WITH mutated AS (<insert|update|delete>
... RETURNING *) SELECT json_build_object('affected_rows', (SELECT count(*) FROM mutated),
'returning', (SELECT coalesce(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT ... FROM
mutated) AS t))` — both `affected_rows` and `returning` are **scalar subqueries** against the
CTE, composed directly into one `json_build_object(...)` call with **no outer `FROM` clause of
its own**. A bare `SELECT expr, expr2` with no `FROM` always returns exactly one row in
Postgres, regardless of how many rows `mutated` produced — 0, 1, or many. See
[render.zig's `renderMutation`](../../src/sql_gen/render.zig) and
[0010](0010-mutation-procedure-naming.md) for the argument surface this renders from.

**Missing-row-on-`*_by_pk` is a normal response, not an error**: `update_<t>_by_pk`/
`delete_<t>_by_pk` against a nonexistent key returns `{"affected_rows": 0, "returning": []}`
(if `returning` was requested) — no special-casing needed, since the always-one-row shape
above already produces exactly this by construction. This was a deliberate choice over making
it an error: a caller doing a conditional update ("update if it exists") shouldn't need to
catch an error for the common "doesn't exist" case, and it composes better inside a
multi-operation transaction (one operation quietly affecting zero rows doesn't need to abort
operations after it, whereas a thrown error would).

**Transaction semantics**: a `MutationRequest` with N operations runs as one all-or-nothing
transaction — `BEGIN`, then each operation's generated SQL in order, then `COMMIT`; any
operation failing (a real Postgres error, e.g. an FK violation) triggers `ROLLBACK` and the
whole request fails, with no operations' writes surviving. `pg_wire.Connection.begin`/`commit`/
`rollback` are thin wrappers over the existing `query` method (`BEGIN`/`COMMIT`/`ROLLBACK` are
just SQL text with no params) — no new wire-protocol work needed.

**pg_wire protocol-resync fix**: `Connection.query`'s `'E'` (ErrorResponse) case now drains
messages until `'Z'` (ReadyForQuery) before returning the error, instead of returning
immediately. This is what makes the `ROLLBACK` call after a failed operation land on a
synchronized connection — without it, `ROLLBACK`'s own response would be misread against the
stale `ReadyForQuery` left over from the failed operation, corrupting every subsequent query on
that connection. This fix has no observable effect on the milestone 1/2 read-only paths (they
never trigger a Postgres-level error today) but is a load-bearing correctness fix for
mutations, where a constraint violation is an expected, tested case.

## Consequences

- No column in the generated SQL statement is allowed to depend on `mutated`'s row count via a
  `FROM mutated` at the top level — any future mutation feature (e.g. bulk operations) must
  preserve the "scalar subqueries composed into one `json_build_object`" shape or reintroduce
  the zero-row bug this ADR fixes.
- Clients that want "fail if the row doesn't exist" semantics for `*_by_pk` operations must
  check `affected_rows == 0` themselves; the connector does not synthesize an error for them.
- The connection pooling milestone (M4) inherits a connection-handling invariant it must
  preserve: every code path that can receive `'E'` must fully drain to `'Z'` before the
  connection is considered usable again (or returned to a pool).
