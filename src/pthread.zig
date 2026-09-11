const std = @import("std");
const c = std.c;

// Import C functions directly from libc by hand
extern "c" fn pthread_mutex_init(mutex: *c.pthread_mutex_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_mutex_destroy(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_lock(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(mutex: *c.pthread_mutex_t) c_int;

extern "c" fn pthread_cond_init(cond: *c.pthread_cond_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_cond_destroy(cond: *c.pthread_cond_t) c_int;
extern "c" fn pthread_cond_wait(cond: *c.pthread_cond_t, mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_cond_signal(cond: *c.pthread_cond_t) c_int;
extern "c" fn pthread_cond_broadcast(cond: *c.pthread_cond_t) c_int;

// Type for the CPU mask. On Linux this is a struct, but its size is 128 bytes (enough for 1024 cores)
const cpu_set_t = extern struct {
    __bits: [128 / @sizeOf(c_ulong)]c_ulong,
};

extern "c" fn pthread_create(thread: *c.pthread_t, attr: ?*const anyopaque, start_routine: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) c_int;
extern "c" fn pthread_join(thread: c.pthread_t, retval: ?*?*anyopaque) c_int;
extern "c" fn pthread_setaffinity_np(thread: c.pthread_t, cpusetsize: usize, cpuset: *const cpu_set_t) c_int;
extern "c" fn pthread_self() c.pthread_t;

/// A thin, libc-backed mutex (`pthread_mutex_t`).
///
/// The raw object is stored inline, so the `Mutex` must live at a stable
/// address for its whole lifetime; do not copy or move it once it may be
/// contended. There is no reentrancy and no timeout: a blocked `lock` parks
/// the calling thread inside the kernel.
pub const Mutex = struct {
    raw: c.pthread_mutex_t,

    /// Initializes the mutex with default (process-private) attributes.
    ///
    /// Must be paired with `deinit` on the same instance. Pthreads requires the
    /// same memory to be used for init, lock, unlock and destroy, so keep the
    /// returned value where it is.
    pub fn init() Mutex {
        var self = Mutex{
            // Properly zero the memory for the C struct
            .raw = std.mem.zeroes(c.pthread_mutex_t),
        };
        // Initialize the mutex with default attributes (null)
        _ = pthread_mutex_init(&self.raw, null);
        return self;
    }

    /// Destroys the mutex and releases any resources libc attached to it.
    ///
    /// The mutex must be unlocked and have no waiters, and must not be used
    /// afterwards. The memory holding the `Mutex` itself is not freed.
    pub fn deinit(self: *Mutex) void {
        _ = pthread_mutex_destroy(&self.raw);
    }

    /// Acquires the mutex, blocking the calling thread (inside the kernel)
    /// while another thread holds it. There is no timeout, no priority
    /// inheritance and no fairness guarantee.
    pub fn lock(self: *Mutex) void {
        // Regular blocking lock: if busy, the thread sleeps in the OS kernel
        _ = pthread_mutex_lock(&self.raw);
    }

    /// Releases the mutex. Must be called by the thread that locked it.
    pub fn unlock(self: *Mutex) void {
        _ = pthread_mutex_unlock(&self.raw);
    }
};

/// A condition variable (`pthread_cond_t`), used together with a `Mutex`.
///
/// Like `Mutex` it embeds the raw object inline, so it must stay at a stable
/// address and every `init` must be matched by a `deinit` on the same memory.
pub const CondVar = struct {
    raw: c.pthread_cond_t,

    /// Initializes the condition variable with default attributes.
    ///
    /// Must be paired with `deinit` on the same instance; see the address
    /// stability note on `Mutex`.
    pub fn init() CondVar {
        var self = CondVar{
            .raw = std.mem.zeroes(c.pthread_cond_t),
        };
        _ = pthread_cond_init(&self.raw, null);
        return self;
    }

    /// Destroys the condition variable.
    ///
    /// Only valid once no thread is blocked in `wait` on it. The memory holding
    /// the `CondVar` itself is not freed.
    pub fn deinit(self: *CondVar) void {
        _ = pthread_cond_destroy(&self.raw);
    }

    /// Atomically releases `mutex` and blocks the calling thread until the
    /// condition is signaled, then re-acquires `mutex` before returning.
    ///
    /// The caller must hold `mutex` on entry. Wakeups may be spurious and
    /// `signal`/`broadcast` do not wait for the woken thread, so always wait in
    /// a loop that re-checks the predicate while holding the mutex.
    pub fn wait(self: *CondVar, mutex: *Mutex) void {
        _ = pthread_cond_wait(&self.raw, &mutex.raw);
    }

    /// Wakes one thread currently blocked in `wait`.
    ///
    /// Waking does not transfer the mutex: the woken thread only becomes
    /// runnable and re-contends for it. Usually called while holding the
    /// associated mutex.
    pub fn signal(self: *CondVar) void {
        _ = pthread_cond_signal(&self.raw);
    }

    /// Wakes every thread currently blocked in `wait`. Same locking caveats as
    /// `signal`.
    pub fn broadcast(self: *CondVar) void {
        _ = pthread_cond_broadcast(&self.raw);
    }
};

/// A joinable libc thread (`pthread_t`).
///
/// This module declares the pthread entry points itself, so the program must be
/// linked against libc. Every successful `spawn` must be matched by exactly one
/// `join`; otherwise the thread's stack and kernel task leak even after it
/// exits.
pub const Thread = struct {
    raw: c.pthread_t,

    /// Spawns a new thread that runs `f`.
    ///
    /// `context` must be a pointer (or `void`/`null` for a context-free
    /// function); the thread invokes `f(context)`. Only the pointer value is
    /// copied into the thread, not the pointed-to data, so the pointee must
    /// stay alive until the thread is joined. Returns
    /// `error.ThreadSpawnFailed` on failure, in which case nothing was created.
    pub fn spawn(context: anytype, comptime f: anytype) !Thread {
        const ContextType = @TypeOf(context);

        const wrapper = struct {
            fn run(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
                if (ContextType == void or ContextType == @TypeOf(null)) {
                    f();
                } else {
                    const ptr: ContextType = @ptrCast(@alignCast(arg));
                    f(ptr);
                }
                return null;
            }
        }.run;

        // Create the struct with uninitialized (garbage) state
        var self = Thread{
            .raw = undefined,
        };

        // Zero the thread handle's raw memory directly, byte by byte
        // This bypasses Zig's type checks and works on any OS/libc
        const bytes = @as([*]u8, @ptrCast(&self.raw))[0..@sizeOf(c.pthread_t)];
        @memset(bytes, 0);

        const raw_arg = if (ContextType == void or ContextType == @TypeOf(null)) null else @as(?*anyopaque, @ptrCast(context));

        const res = pthread_create(&self.raw, null, @ptrCast(&wrapper), raw_arg);
        if (res != 0) return error.ThreadSpawnFailed;

        return self;
    }

    /// Waits for the thread to finish and releases its resources.
    ///
    /// Must be called exactly once per successfully spawned thread, and never
    /// from the thread itself. Blocks in the kernel until the target exits. The
    /// thread's return value is discarded.
    pub fn join(self: Thread) void {
        _ = pthread_join(self.raw, null);
    }

    /// Pins the thread referred to by this handle to the single CPU `core_id`.
    ///
    /// The change is requested from the calling thread and applies to
    /// `self.raw`, which must already have been started. `core_id` outside the
    /// mask returns `error.CpuIdOutOfRange`; a rejected request (for example an
    /// offline core) returns `error.SetCpuAffinityFailed`.
    pub fn setAffinity(self: Thread, coreId: u32) !void {
        var cpuset: cpu_set_t = undefined;
        // Fully clear the CPU mask
        @memset(@as([*]u8, @ptrCast(&cpuset))[0..@sizeOf(cpu_set_t)], 0);

        // Set the bit for the desired core (equivalent of the CPU_SET macro)
        const wordIdx = coreId / (@sizeOf(c_ulong) * 8);
        const bitIdx = coreId % (@sizeOf(c_ulong) * 8);

        if (wordIdx >= cpuset.__bits.len) return error.CpuIdOutOfRange;
        cpuset.__bits[wordIdx] |= (@as(c_ulong, 1) << @intCast(bitIdx));

        const res = pthread_setaffinity_np(self.raw, @sizeOf(cpu_set_t), &cpuset);
        if (res != 0) return error.SetCpuAffinityFailed;
    }

    /// Pins the calling thread to `core_id`, without needing a `Thread` handle.
    ///
    /// Handy from inside a freshly started thread; the constraints of
    /// `setAffinity` apply.
    pub fn setSelfAffinity(coreId: u32) !void {
        const self_thread = Thread{ .raw = pthread_self() };
        try self_thread.setAffinity(coreId);
    }
};

test "pthread wrappers: mutex, condvar, and thread workflow" {
    // Struct for shared state between threads
    const SharedState = struct {
        mutex: Mutex,
        cond: CondVar,
        ready: bool,
        counter: i32,
    };

    // Initialize our state
    var state = SharedState{
        .mutex = Mutex.init(),
        .cond = CondVar.init(),
        .ready = false,
        .counter = 0,
    };
    defer state.mutex.deinit();
    defer state.cond.deinit();

    // Local function for the background thread
    const worker = struct {
        fn run(s: *SharedState) void {
            s.mutex.lock();
            defer s.mutex.unlock();

            // Wait until the main thread sets ready to true
            while (!s.ready) {
                s.cond.wait(&s.mutex);
            }

            // Modify data under the mutex
            s.counter += 42;
        }
    }.run;

    // 1. Spawn the thread
    const thread = try Thread.spawn(&state, worker);

    // Give the background thread time to start and block in cond.wait()
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .awake);

    // Check that the counter is still 0 (the thread is waiting)
    try std.testing.expectEqual(@as(i32, 0), state.counter);

    // 2. Lock the mutex and set ready to true
    state.mutex.lock();
    state.ready = true;
    state.mutex.unlock();

    // Send the signal to wake up the thread
    state.cond.signal();

    // 3. Wait for the thread to finish
    thread.join();

    // Check that the background thread woke up and updated the counter
    try std.testing.expectEqual(@as(i32, 42), state.counter);
}
