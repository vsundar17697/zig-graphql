const std = @import("std");
const connection_mod = @import("connection.zig");

const Connection = connection_mod.Connection;

/// A fixed-size pool of `*Connection`, matching `Connection.connect`'s
/// heap-allocated handle API -- a stable address keeps outstanding leases
/// valid no matter how the idle list reallocates. See
/// docs/decisions/0015-connection-pool.md.
///
/// Staleness policy (milestone 6, narrowing ADR 0015's lazy-invalidation
/// known cost): a connection idle past `validate_after_idle_ms` gets one
/// cheap ping on acquire, and one older than `max_lifetime_ms` is recycled
/// outright -- both failures cost the caller nothing but the fresh dial that
/// replaces the connection. Recently-used connections still skip the ping
/// entirely (the ping-per-checkout tax ADR 0015 declines to pay).
///
/// Locking uses `std.Io.Mutex`/`std.Io.Condition` (Zig 0.16's cooperative-I/O
/// synchronization primitives, not `std.Thread`'s -- that no longer exists)
/// which take an explicit `Io` on every call; `pg-gql-server` runs one OS
/// thread per accepted connection, each with its own `std.Io.Threaded`
/// instance, so every `acquire`/lease-`release` call passes whichever `io`
/// belongs to the calling thread. The underlying futex-based state is shared
/// across all of them regardless of which `Io` instance issued a given call.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    options: Connection.Options,
    max: usize,
    /// Recycle a connection older than this on acquire, regardless of
    /// health -- bounds the blast radius of server-side per-connection state
    /// (and, before milestone 6's TLS work is complete, of anything a
    /// long-lived session accumulates). Overridable after `init`.
    max_lifetime_ms: i64 = 30 * std.time.ms_per_min,
    /// Ping a connection on acquire only if it has sat idle longer than
    /// this; fresher connections are handed out unpinged. Overridable
    /// after `init`.
    validate_after_idle_ms: i64 = 30 * std.time.ms_per_s,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    idle: std.ArrayListUnmanaged(Idle) = .empty,
    open_count: usize = 0,

    const Idle = struct {
        conn: *Connection,
        idle_since_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator, options: Connection.Options, max: usize) Pool {
        return .{ .allocator = allocator, .options = options, .max = max };
    }

    /// Closes every idle connection. Leases still outstanding when this is
    /// called are the caller's bug, not something this guards against --
    /// matches every other resource in this codebase (e.g. `Connection`
    /// itself has no use-after-close protection).
    pub fn deinit(self: *Pool) void {
        for (self.idle.items) |entry| entry.conn.close();
        self.idle.deinit(self.allocator);
    }

    /// A checked-out connection. The caller must call `release` exactly
    /// once, setting `broken = true` first if any operation on `conn`
    /// returned a transport-level error -- see `markBrokenUnless`'s doc
    /// comment for exactly which errors count.
    pub const Lease = struct {
        pool: *Pool,
        conn: *Connection,
        broken: bool = false,

        /// A connection is safe to return to the idle pool after an
        /// `error.ServerError` (a healthy connection correctly reporting a
        /// SQL-level failure -- libpq resyncs after errors, which is exactly
        /// what makes this true) but not after anything else: a
        /// transport-level error means the connection's protocol state is
        /// unknown, so this pool deliberately does not attempt to
        /// distinguish "probably still fine" from "definitely broken"
        /// beyond that one case -- closing and reconnecting is cheap;
        /// silently reusing a corrupted connection for the next request is
        /// not. OR's into `broken` rather than overwriting it -- safe to
        /// call once per operation on a lease shared across several
        /// operations (e.g. one `/graphql` request's several root fields);
        /// once broken, stays broken regardless of what a later, unrelated
        /// operation on the same lease reports.
        pub fn markBrokenUnless(self: *Lease, err: anyerror) void {
            self.broken = self.broken or (err != error.ServerError);
        }

        pub fn release(self: *Lease, io: std.Io) void {
            self.pool.releaseConnection(io, self.conn, self.broken);
        }
    };

    /// Blocks (without holding the pool lock across the blocking I/O) until
    /// a connection is available: an idle one is handed out immediately --
    /// after passing the staleness policy above -- otherwise, if
    /// `open_count < max`, a new one is dialed; otherwise this waits on
    /// `cond` for a release.
    pub fn acquire(self: *Pool, io: std.Io) (std.Io.Cancelable || connection_mod.Error)!Lease {
        try self.mutex.lock(io);
        while (true) {
            if (self.idle.pop()) |entry| {
                self.mutex.unlock(io);
                if (self.validateOutsideLock(entry)) return .{ .pool = self, .conn = entry.conn };
                // Stale or dead: already closed; give back its capacity and
                // go around again (this thread will typically consume that
                // capacity itself by dialing fresh).
                try self.mutex.lock(io);
                self.open_count -= 1;
                continue;
            }
            if (self.open_count < self.max) {
                self.open_count += 1;
                self.mutex.unlock(io);
                const conn = Connection.connect(self.allocator, self.options) catch |err| {
                    try self.mutex.lock(io);
                    self.open_count -= 1;
                    self.mutex.unlock(io);
                    return err;
                };
                return .{ .pool = self, .conn = conn };
            }
            try self.cond.wait(io, &self.mutex);
        }
    }

    /// True if the idle connection may be handed out; closes it and returns
    /// false otherwise. Runs without the pool lock -- the ping is a network
    /// round trip.
    fn validateOutsideLock(self: *Pool, entry: Idle) bool {
        const now = connection_mod.monotonicMs();
        const expired = now - entry.conn.created_ms > self.max_lifetime_ms;
        const needs_ping = now - entry.idle_since_ms > self.validate_after_idle_ms;
        if (!expired and (!needs_ping or entry.conn.ping())) return true;
        entry.conn.close();
        return false;
    }

    fn releaseConnection(self: *Pool, io: std.Io, conn: *Connection, broken: bool) void {
        self.mutex.lock(io) catch return; // canceled -- nothing sensible to do but leak the lease; matches this codebase's no-cancellation-support elsewhere
        defer self.mutex.unlock(io);

        if (broken) {
            conn.close();
            self.open_count -= 1;
        } else {
            self.idle.append(self.allocator, .{
                .conn = conn,
                .idle_since_ms = connection_mod.monotonicMs(),
            }) catch {
                // Can't grow the idle list -- closing rather than leaking
                // the connection is the safe default under OOM.
                conn.close();
                self.open_count -= 1;
            };
        }
        self.cond.signal(io);
    }
};
