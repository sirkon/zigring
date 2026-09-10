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

pub const Mutex = struct {
    raw: c.pthread_mutex_t,

    pub fn init() Mutex {
        var self = Mutex{
            // Properly zero the memory for the C struct
            .raw = std.mem.zeroes(c.pthread_mutex_t),
        };
        // Initialize the mutex with default attributes (null)
        _ = pthread_mutex_init(&self.raw, null);
        return self;
    }

    pub fn deinit(self: *Mutex) void {
        _ = pthread_mutex_destroy(&self.raw);
    }

    pub fn lock(self: *Mutex) void {
        // Regular blocking lock: if busy, the thread sleeps in the OS kernel
        _ = pthread_mutex_lock(&self.raw);
    }

    pub fn unlock(self: *Mutex) void {
        _ = pthread_mutex_unlock(&self.raw);
    }
};

pub const CondVar = struct {
    raw: c.pthread_cond_t,

    pub fn init() CondVar {
        var self = CondVar{
            .raw = std.mem.zeroes(c.pthread_cond_t),
        };
        _ = pthread_cond_init(&self.raw, null);
        return self;
    }

    pub fn deinit(self: *CondVar) void {
        _ = pthread_cond_destroy(&self.raw);
    }

    // Pass your Mutex wrapper. Inside, atomically release the C mutex and wait
    pub fn wait(self: *CondVar, mutex: *Mutex) void {
        _ = pthread_cond_wait(&self.raw, &mutex.raw);
    }

    // Wakes up one thread
    pub fn signal(self: *CondVar) void {
        _ = pthread_cond_signal(&self.raw);
    }

    // Wakes up all threads waiting on this condvar
    pub fn broadcast(self: *CondVar) void {
        _ = pthread_cond_broadcast(&self.raw);
    }
};

pub const Thread = struct {
    raw: c.pthread_t,

    // spawn takes a Zig function and a pointer to any data
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

    pub fn join(self: Thread) void {
        _ = pthread_join(self.raw, null);
    }

    /// Pins this (the current) thread to a specific CPU core
    pub fn setAffinity(self: Thread, core_id: u32) !void {
        var cpuset: cpu_set_t = undefined;
        // Fully clear the CPU mask
        @memset(@as([*]u8, @ptrCast(&cpuset))[0..@sizeOf(cpu_set_t)], 0);

        // Set the bit for the desired core (equivalent of the CPU_SET macro)
        const word_index = core_id / (@sizeOf(c_ulong) * 8);
        const bit_index = core_id % (@sizeOf(c_ulong) * 8);

        if (word_index >= cpuset.__bits.len) return error.CpuIdOutOfRange;
        cpuset.__bits[word_index] |= (@as(c_ulong, 1) << @intCast(bit_index));

        const res = pthread_setaffinity_np(self.raw, @sizeOf(cpu_set_t), &cpuset);
        if (res != 0) return error.SetCpuAffinityFailed;
    }

    /// Lets the calling thread pin itself to a core
    pub fn setSelfAffinity(core_id: u32) !void {
        const self_thread = Thread{ .raw = pthread_self() };
        try self_thread.setAffinity(core_id);
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
