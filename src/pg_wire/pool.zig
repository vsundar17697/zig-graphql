const std = @import("std");
const connection_mod = @import("connection.zig");

const Connection = connection_mod.Connection;

/// A fixed-size pool of `*Connection`, matching `Connection.connect`'s
/// heap-allocated handle API -- a stable address keeps outstanding leases
/// valid no matter how the idle list reallocates. See
/// docs/decisions/0015-connection-pool.md.
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
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    idle: std.ArrayListUnmanaged(*Connection) = .empty,
    open_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, options: Connection.Options, max: usize) Pool {
        return .{ .allocator = allocator, .options = options, .max = max };
    }

    /// Closes every idle connection. Leases still outstanding when this is
    /// called are the caller's bug, not something this guards against --
    /// matches every other resource in this codebase (e.g. `Connection`
    /// itself has no use-after-close protection).
    pub fn deinit(self: *Pool) void {
        for (self.idle.items) |conn| conn.close();
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
        /// SQL-level failure -- see docs/decisions/0011-mutation-transactions.md's
        /// drain-to-ReadyForQuery fix, which is exactly what makes this
        /// true) but not after anything else: a transport-level error means
        /// the connection's protocol state is unknown, so this pool
        /// deliberately does not attempt to distinguish "probably still
        /// fine" from "definitely broken" beyond that one case -- closing
        /// and reconnecting is cheap; silently reusing a corrupted
        /// connection for the next request is not. OR's into `broken`
        /// rather than overwriting it -- safe to call once per operation on
        /// a lease shared across several operations (e.g. one `/graphql`
        /// request's several root fields); once broken, stays broken
        /// regardless of what a later, unrelated operation on the same
        /// lease reports.
        pub fn markBrokenUnless(self: *Lease, err: anyerror) void {
            self.broken = self.broken or (err != error.ServerError);
        }

        pub fn release(self: *Lease, io: std.Io) void {
            self.pool.releaseConnection(io, self.conn, self.broken);
        }
    };

    /// Blocks (without holding the pool lock across the blocking I/O) until
    /// a connection is available: an idle one is handed out immediately;
    /// otherwise, if `open_count < max`, a new one is dialed; otherwise this
    /// waits on `cond` for a release. No per-checkout health ping is sent --
    /// see docs/decisions/0015-connection-pool.md for why a ping-per-checkout
    /// tax on every request isn't worth defending against a rare failure
    /// mode `markBrokenUnless`'s lazy invalidation already handles.
    pub fn acquire(self: *Pool, io: std.Io) (std.Io.Cancelable || connection_mod.Error)!Lease {
        try self.mutex.lock(io);
        while (true) {
            if (self.idle.pop()) |conn| {
                self.mutex.unlock(io);
                return .{ .pool = self, .conn = conn };
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

    fn releaseConnection(self: *Pool, io: std.Io, conn: *Connection, broken: bool) void {
        self.mutex.lock(io) catch return; // canceled -- nothing sensible to do but leak the lease; matches this codebase's no-cancellation-support elsewhere
        defer self.mutex.unlock(io);

        if (broken) {
            conn.close();
            self.open_count -= 1;
        } else {
            self.idle.append(self.allocator, conn) catch {
                // Can't grow the idle list -- closing rather than leaking
                // the connection is the safe default under OOM.
                conn.close();
                self.open_count -= 1;
            };
        }
        self.cond.signal(io);
    }
};
