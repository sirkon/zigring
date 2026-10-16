const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("iouring.zig").Ring;
const pthread = @import("pthread.zig");

pub const Factory = struct {
    const Self = @This();

    // Maximal amount of poller threads available.
    maxPollerThreads: u32,
    allocator: std.mem.Allocator,

    mutex: pthread.Mutex,

    // Active pollers.
    groups: std.ArrayList(PollerGroup),

    // Represents a kernel poller.
    const PollerGroup = struct {
        masterFd: posix.fd_t,
        // Weight of rings of the current poller.
        currentWeight: u32,
        // Amount of rings of this poller.
        ringCount: u32,
    };

    /// Initializes the factory in place.
    ///
    /// The factory embeds a `pthread.Mutex`, which pthreads forbids copying
    /// once initialized, so it is initialized at its final address rather than
    /// returned by value.
    pub fn init(self: *Self, allocator: std.mem.Allocator, maxPollerThreads: u32) !void {
        const groups = try std.ArrayList(PollerGroup).initCapacity(allocator, maxPollerThreads);
        self.maxPollerThreads = maxPollerThreads;
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
            if (group.currentWeight < minWeightFound) {
                minWeightFound = group.currentWeight;
                bestGroupIdx = i;
            }
        }

        // Step 2. Decide, whether to create a new poller thread or reuse one.
        // We create if:
        // 1. We haven't created anything yet.
        // 2. We haven't reached the maxPollerThreads.
        if (self.groups.items.len == 0 or
            (self.groups.items.len < self.maxPollerThreads and minWeightFound > 0))
        {
            // Create a new master thread.
            try ring.init(queueDepth, null);

            // Register new group of rings for the master thread.
            self.groups.append(self.allocator, .{
                .masterFd = ring.fd,
                .currentWeight = weight,
                .ringCount = 1,
            }) catch |err| {
                ring.deinit();
                return err;
            };

            return;
        }

        // Step 3: We are here because the limit of kernel polling threads is reached,
        // and we must attach a new ring to the existing kernel thread.
        const targetGroup = &self.groups.items[bestGroupIdx.?];

        try ring.init(queueDepth, targetGroup.masterFd);

        // Update group metrics.
        targetGroup.currentWeight += weight;
        targetGroup.ringCount += 1;
    }
};
