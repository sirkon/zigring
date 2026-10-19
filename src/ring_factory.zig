const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("iouring.zig").Ring;
const pthread = @import("pthread.zig");

pub const Factory = struct {
    const Self = @This();

    // Maximal amount of poller threads available.
    max_poller_threads: u32,
    allocator: std.mem.Allocator,

    mutex: pthread.Mutex,

    // Active pollers.
    groups: std.ArrayList(PollerGroup),

    // Represents a kernel poller.
    const PollerGroup = struct {
        master_fd: posix.fd_t,
        // Weight of rings of the current poller.
        current_weight: u32,
        // Amount of rings of this poller.
        ring_count: u32,
    };

    /// Initializes the factory in place.
    ///
    /// The factory embeds a `pthread.Mutex`, which pthreads forbids copying
    /// once initialized, so it is initialized at its final address rather than
    /// returned by value.
    pub fn init(self: *Self, allocator: std.mem.Allocator, max_poller_threads: u32) !void {
        const groups = try std.ArrayList(PollerGroup).initCapacity(allocator, max_poller_threads);
        self.max_poller_threads = max_poller_threads;
        self.allocator = allocator;
        self.groups = groups;
        self.mutex.init();
    }

    pub fn deinit(self: *Self) void {
        self.mutex.deinit();
        self.groups.deinit(self.allocator);
    }

    /// Thread-safe method to acquire a new ring with the given "weight",
    /// initialized in place at `ring`.
    ///
    /// `ring` must point at storage that outlives the ring. On failure it is
    /// left untouched and nothing is registered with the factory.
    pub fn acquireRing(self: *Self, ring: *Ring, queueDepth: u32, weight: u32) !void {
        // Lock the mutex on entry. Released automatically when leaving the function (scope-based)
        self.mutex.lock();
        defer self.mutex.unlock();

        var bestGroupIdx: ?usize = null;
        var minWeightFound: u32 = std.math.maxInt(u32);

        // Step 1. Look for the poller with the minimal weight.
        for (self.groups.items, 0..) |group, i| {
            if (group.current_weight < minWeightFound) {
                minWeightFound = group.current_weight;
                bestGroupIdx = i;
            }
        }

        // Step 2. Decide, whether to create a new poller thread or reuse one.
        // We create if:
        // 1. We haven't created anything yet.
        // 2. We haven't reached the max_poller_threads.
        if (self.groups.items.len == 0 or
            (self.groups.items.len < self.max_poller_threads and minWeightFound > 0))
        {
            // Create a new master thread.
            try ring.init(queueDepth, null);

            // Register new group of rings for the master thread.
            self.groups.append(self.allocator, .{
                .master_fd = ring.fd,
                .current_weight = weight,
                .ring_count = 1,
            }) catch |err| {
                ring.deinit();
                return err;
            };

            return;
        }

        // Step 3: We are here because the limit of kernel polling threads is reached,
        // and we must attach a new ring to the existing kernel thread.
        const targetGroup = &self.groups.items[bestGroupIdx.?];

        try ring.init(queueDepth, targetGroup.master_fd);

        // Update group metrics.
        targetGroup.current_weight += weight;
        targetGroup.ring_count += 1;
    }
};
