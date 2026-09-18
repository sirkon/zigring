//! zigring: a small, libc-backed Zig wrapper around Linux io_uring.
//!
//! This file is the public entry point of the library. Downstream projects
//! depend on the `zigring` module and reach everything through here, so every
//! type, value and routine a consumer may need is re-exported below and the
//! private source files are considered implementation details.
//!
//! The wrapper deliberately avoids the standard library's io_uring, socket and
//! time helpers: the ring is driven through raw SQE fields for predictable,
//! syscall-free submissions, sockets are created with `SOCK_CLOEXEC` directly,
//! and time is read through the vDSO. Link against libc, since the threading
//! primitives are the real `pthread_*` symbols.

const ring = @import("iouring.zig");
const factory = @import("ring_factory.zig");
const pthread = @import("pthread.zig");
const slotter = @import("slotter.zig");
const time = @import("time.zig");
const sockets = @import("sockets.zig");

/// An io_uring ring configured with kernel-side (SQPOLL) polling.
///
/// Submissions are written directly into the SQ and results read back from the
/// CQ with `popCQE`, so the hot path usually runs without a syscall.
pub const Ring = ring.Ring;

/// A thread-safe factory that hands out rings.
///
/// It spreads rings across at most `maxPollerThreads` kernel pollers, attaching
/// new rings to an existing poller with `IORING_SETUP_ATTACH_WQ` to cap the
/// number of polling threads.
pub const Factory = factory.Factory;

/// The fixed buffer sizes the kernel-provided buffer pools can serve.
pub const BufferSizeClass = ring.BufferSizeClass;

/// The SQE flag word accepted by every `Ring.push*` operation.
pub const TaskFlags = ring.TaskFlags;

/// A completion read back from the completion queue.
///
/// Exposes the operation id (`taskIdx`), the raw result and the decoded
/// `IORING_CQE_F_*` bits (provided buffer id, multishot continuation, send-zc
/// notification).
pub const CQE = ring.CQE;

/// A batched view over the submission queue, opened with `Ring.batchedSQ`.
///
/// Several operations can be reserved through it and published with a single
/// `commit`, collapsing many submissions into one kernel wakeup.
pub const BatchSQ = ring.BatchSQ;

/// A streaming view over the submission queue, opened with `Ring.streamedSQ`.
///
/// It offers the same push surface as `BatchSQ`, but its `commit` re-reads the
/// ring's cursors so the handle can drive one submission round after another.
pub const StreamSQ = ring.StreamSQ;

/// A batched view over the completion queue, opened with `Ring.batchedCQ`.
///
/// Several completions can be drained through it and acknowledged with a
/// single `commit`. The window can be capped with the `maxEntries` argument.
pub const BatchCQ = ring.BatchCQ;

/// A sliding-window buffer that restores order to out-of-order completions.
///
/// Items are tagged with a sequence index and handed back only once every
/// earlier index has arrived, which is what turns a completion queue into a
/// reliable in-order stream.
pub const ReorderBuffer = ring.ReorderBuffer;

/// The page size, in bytes, assumed when mmapping pools.
pub const pageSize = ring.pageSize;

/// The task index reserved for operations whose completion is not awaited.
pub const fireAndForgetTaskIdx = ring.fireAndForgetTaskIdx;

/// A dense, growable index allocator for trivially copyable values.
///
/// `add` returns a `u64` slot index and `del` returns it to the free pool.
pub const Slots = slotter.Slots;

/// A dense, growable index allocator over fixed-size byte buffers.
///
/// Each index maps to an `elementSize`-byte slice of one backing allocation,
/// handed out without copying so callers can write in place.
pub const BufferSlots = slotter.BufferSlots;

/// A thin wrapper around a libc `pthread_mutex_t`.
pub const Mutex = pthread.Mutex;

/// A thin wrapper around a libc `pthread_cond_t`.
pub const CondVar = pthread.CondVar;

/// A joinable libc thread (`pthread_t`).
pub const Thread = pthread.Thread;

/// Current wall-clock time as Unix nanoseconds, via the vDSO fast path.
pub const nowNs = time.nowNs;

/// Monotonic time in nanoseconds, suitable for measuring elapsed time.
pub const monotonicNs = time.monotonicNs;

/// Creates an IPv4 TCP listening socket, ready for `bind`/`listen`.
///
/// The returned fd is `SOCK_CLOEXEC` with `SO_REUSEADDR` already enabled, so it
/// can be rebound while a previous instance is still in `TIME_WAIT`.
pub const createTCPServerSocket = sockets.createTCPServerSocket;

/// Creates an IPv4 TCP client socket, optionally enabling one TCP option.
///
/// `opts` is a TCP-level socket option name (for example
/// `std.os.linux.TCP.NODELAY`), or null to leave the socket untouched.
pub const createTCPClientSocket = sockets.createTCPClientSocket;

// Pull the unit tests of every private module into the module's own test
// binary, so `zig build test` exercises them through the public root.
test {
    _ = ring;
    _ = factory;
    _ = pthread;
    _ = slotter;
    _ = time;
    _ = sockets;
}
