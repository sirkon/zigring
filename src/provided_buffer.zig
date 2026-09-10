const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// io_uring buffer ring control structure.
///
/// The kernel requires the ring to be exactly this layout: a 16-byte
/// header followed immediately by `entries` consecutive
/// `linux.io_uring_buf` elements. The `tail` field is the producers
/// index into that element array (we are the producer, the SQPOLL
/// kernel thread is the consumer).
pub const io_uring_buf_ring = extern struct {
    resv1: u64,
    resv2: u32,
    resv3: u16,
    tail: u16,
};

comptime {
    // The element array is placed right after this header by the
    // kernel, so the ABI size must never drift.
    if (@sizeOf(linux.io_uring_buf) != 16) {
        @compileError("linux.io_uring_buf must be 16 bytes to match the kernel ABI");
    }
}

/// Kernel provided buffers for zero-copy reads.
pub const ProvidedBufferPool = struct {
    const Self = @This();

    // Kernel io_uring_buf_ring is a union: the io_uring_buf element
    // array overlays the 16-byte header, so bufs[0] starts at offset 0
    // and its fields alias resv1/resv2/resv3/tail. The tail (u16 at
    // offset 14) is shared with bufs[0].resv, which the kernel never
    // reads, so writing the tail is harmless. The ring mapping is
    // entries * sizeof(io_uring_buf) bytes, no separate header.
    const bufsOffset = 0;
    // 2 MiB huge page size.
    const hugePageSize: usize = 1 << 21;
    const hugePageMask: u32 = 21 << 26;
    // Fallback to regular 4096-byte pages when the OS has no huge pages.
    const regularPageSize: usize = 4096;

    const MMapError = posix.MMapError;

    notInitalized: bool,

    ringFd: posix.fd_t,
    bgid: u16,

    // Memory of the buffer control ring.
    bufRing: *io_uring_buf_ring,
    bufRingEntries: u32,

    // A big chunk of memory carved into buffers.
    memoryBacking: []u8,
    bufferSize: u32,

    // Raw mmap slices, saved for cleanup in deinit. The ring slice
    // covers the rounded-up mapping, so munmap can release it whole.
    bufRingMmap: []align(std.heap.page_size_min) u8,
    memoryBackingMmap: []align(std.heap.page_size_min) u8,

    pub fn initUninitialized() Self {
        var s: Self = undefined;
        s.notInitalized = true;
        return s;
    }

    pub fn init(
        ringFd: posix.fd_t,
        bgid: u16,
        entries: u32,
        bufferSize: u32,
    ) !Self {
        // Protect indices against non power-of-two rings.
        if (@popCount(entries) != 1) return error.EntriesMustBePowerOf2;

        const rawEntriesSize = entries * @sizeOf(linux.io_uring_buf);
        // Kernel rejects rings whose element array is under 32 bytes.
        if (rawEntriesSize < 32) return error.BufferRingTooSmall;

        const ringSize = try mmapRing(entries);
        errdefer posix.munmap(ringSize);

        const backingSize = try mmapBacking(entries, bufferSize);
        errdefer posix.munmap(backingSize);

        const bufRing: *io_uring_buf_ring = @ptrCast(ringSize.ptr);

        // Register the ring in the kernel by explicit opcode 22
        // (IORING_REGISTER_PBUF_RING). The IORING_REGISTER enum ordering
        // is not stable, so it is deliberately not used.
        var reg = std.mem.zeroes(linux.io_uring_buf_reg);
        reg.ring_addr = @intFromPtr(bufRing);
        reg.ring_entries = entries;
        reg.bgid = bgid;

        const IORING_REGISTER_PBUF_RING = 22;
        const res = linux.syscall4(
            .io_uring_register,
            @intCast(ringFd),
            IORING_REGISTER_PBUF_RING,
            @intFromPtr(&reg),
            1,
        );
        if (linux.errno(res) != .SUCCESS) {
            return error.RegisterBufRingFailed;
        }

        var self = Self{
            .notInitalized = false,
            .ringFd = ringFd,
            .bgid = bgid,
            .bufRing = bufRing,
            .bufRingEntries = entries,
            .memoryBacking = backingSize[0 .. @as(usize, entries) * bufferSize],
            .bufferSize = bufferSize,
            .bufRingMmap = ringSize,
            .memoryBackingMmap = backingSize,
        };

        // Initially fill the ring with buffers.
        self.replenishAll();

        // Cr

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.notInitalized) {
            return;
        }

        posix.munmap(self.bufRingMmap);
        posix.munmap(self.memoryBackingMmap);
        self.* = undefined;
    }

    /// Map the buffer ring, preferring 2 MiB huge pages and falling
    /// back to regular 4096-byte pages.
    fn mmapRing(entries: u32) MMapError![]align(std.heap.pageSize()) u8 {
        const rawRingSize = bufsOffset + (entries * @sizeOf(linux.io_uring_buf));
        return mmapPool(rawRingSize);
    }

    /// Map the data backing of all buffers.
    fn mmapBacking(entries: u32, bufferSize: u32) MMapError![]align(std.heap.pageSize()) u8 {
        const rawDataSize = @as(usize, entries) * bufferSize;
        return mmapPool(rawDataSize);
    }

    fn mmapPool(rawSize: usize) MMapError![]align(std.heap.pageSize()) u8 {
        const prot = linux.PROT{ .READ = true, .WRITE = true };

        // First try huge pages: SHARED | ANONYMOUS | HUGETLB with the
        // 2 MiB page size bitmask in the map flags. The Zigs MAP packed
        // struct has no slot for the page mask, so it must be OR-ed
        // into the raw flags (bits 26-31 are padding).
        const hugeSize = std.mem.alignForward(usize, rawSize, hugePageSize);
        var hugeFlags: u32 = @bitCast(linux.MAP{
            .TYPE = .SHARED,
            .ANONYMOUS = true,
            .HUGETLB = true,
        });
        hugeFlags |= hugePageMask;

        const hugeMap = posix.mmap(null, hugeSize, prot, @bitCast(hugeFlags), -1, 0) catch |err| switch (err) {
            // No huge pages configured in the OS: transparently fall
            // back to a plain anonymous mapping.
            else => blk: {
                const regularSize = std.mem.alignForward(usize, rawSize, regularPageSize);
                const regularMap = try posix.mmap(
                    null,
                    regularSize,
                    prot,
                    linux.MAP{ .TYPE = .SHARED, .ANONYMOUS = true },
                    -1,
                    0,
                );
                break :blk regularMap;
            },
        };
        errdefer posix.munmap(hugeMap);

        return hugeMap;
    }

    /// Cut `memoryBacking` into buffers and map them all into the ring.
    fn replenishAll(self: *Self) void {
        if (self.notInitalized) {
            return;
        }

        const mask = self.bufRingEntries - 1;
        const tail = @atomicLoad(u16, &self.bufRing.tail, .acquire);

        // The element array sits strictly after the io_uring_buf_ring header.
        const basePtr = @intFromPtr(self.bufRing) + bufsOffset;
        const bufsPtr: [*]linux.io_uring_buf = @ptrFromInt(basePtr);

        var i: u32 = 0;
        while (i < self.bufRingEntries) : (i += 1) {
            const slotIdx = (tail + i) & mask;
            const offset = @as(usize, i) * self.bufferSize;

            bufsPtr[slotIdx] = .{
                .addr = @intFromPtr(self.memoryBacking.ptr + offset),
                .len = self.bufferSize,
                .bid = @intCast(i),
                .resv = 0,
            };
        }

        // Publish the new tail so the SQPOLL kernel thread can consume
        // the freshly added buffers. .release ordering guarantees the
        // element writes are visible before the tail update.
        const newTail = tail +% @as(u16, @intCast(self.bufRingEntries));
        @atomicStore(u16, &self.bufRing.tail, newTail, .release);
    }

    /// Return a single processed buffer (identified by its id) back to
    /// the ring at the current tail index.
    pub fn releaseBuffer(self: *Self, bid: u16) void {
        if (self.notInitalized) {
            @branchHint(.cold);
            return;
        }
        const idx = @as(usize, bid);
        if (idx >= self.bufRingEntries) {
            @branchHint(.cold);
            return;
        }

        const mask = self.bufRingEntries - 1;

        // The tail is only written by our userspace thread.
        const tail = @atomicLoad(u16, &self.bufRing.tail, .acquire);

        const basePtr = @intFromPtr(self.bufRing) + bufsOffset;
        const bufsPtr: [*]linux.io_uring_buf = @ptrFromInt(basePtr);

        const slotIdx = tail & mask;
        const offset = idx * self.bufferSize;

        bufsPtr[slotIdx] = .{
            .addr = @intFromPtr(self.memoryBacking.ptr + offset),
            .len = self.bufferSize,
            .bid = bid,
            .resv = 0,
        };

        @atomicStore(u16, &self.bufRing.tail, tail +% 1, .release);
    }

    /// Return buffer slice for the given idx.
    pub fn buffer(self: *Self, bid: u16) ![]u8 {
        if (self.notInitalized) {
            @branchHint(.cold);
            return error.SizeClassNotInitialized;
        }
        const idx = @as(usize, bid);
        if (idx >= self.bufRingEntries) {
            @branchHint(.cold);
            return error.InvalidBufferIndex;
        }

        const offset = idx * self.bufferSize;
        return self.memoryBacking[offset .. offset + self.bufferSize];
    }

    /// Checks if this buffer pool is initialized.
    pub fn isInactive(self: *Self) bool {
        return self.notInitalized;
    }
};
