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

    not_initalized: bool,

    ring_fd: posix.fd_t,
    bgid: u16,

    // Memory of the buffer control ring.
    buf_ring: *io_uring_buf_ring,
    buf_ring_entries: u32,

    // A big chunk of memory carved into buffers.
    memory_backing: []u8,
    buffer_size: u32,

    // Raw mmap slices, saved for cleanup in deinit. The ring slice
    // covers the rounded-up mapping, so munmap can release it whole.
    buf_ring_mmap: []align(std.heap.page_size_min) u8,
    memory_backing_mmap: []align(std.heap.page_size_min) u8,

    /// Marks `self` as not yet initialized, so `deinit`, `releaseBuffer`,
    /// `buffer` and `replenishAll` all become harmless no-ops. Used to fill
    /// the ring's pool slots before any pool is registered.
    pub fn initUninitialized(self: *Self) void {
        self.not_initalized = true;
    }

    /// Registers a kernel-provided buffer ring for `entries` buffers of
    /// `buffer_size` bytes in place, on ring fd `ring_fd` under group id `bgid`.
    ///
    /// `entries` must be a power of two and the element array must be at least
    /// 32 bytes, else `error.EntriesMustBePowerOf2` or
    /// `error.BufferRingTooSmall`. On any failure `self` is left untouched.
    pub fn init(
        self: *Self,
        ring_fd: posix.fd_t,
        bgid: u16,
        entries: u32,
        buffer_size: u32,
    ) !void {
        // Protect indices against non power-of-two rings.
        if (@popCount(entries) != 1) return error.EntriesMustBePowerOf2;

        const rawEntriesSize = entries * @sizeOf(linux.io_uring_buf);
        // Kernel rejects rings whose element array is under 32 bytes.
        if (rawEntriesSize < 32) return error.BufferRingTooSmall;

        const ringSize = try mmapRing(entries);
        errdefer posix.munmap(ringSize);

        const backingSize = try mmapBacking(entries, buffer_size);
        errdefer posix.munmap(backingSize);

        const buf_ring: *io_uring_buf_ring = @ptrCast(ringSize.ptr);

        // Register the ring in the kernel by explicit opcode 22
        // (IORING_REGISTER_PBUF_RING). The IORING_REGISTER enum ordering
        // is not stable, so it is deliberately not used.
        var reg = std.mem.zeroes(linux.io_uring_buf_reg);
        reg.ring_addr = @intFromPtr(buf_ring);
        reg.ring_entries = entries;
        reg.bgid = bgid;

        const IORING_REGISTER_PBUF_RING = 22;
        const res = linux.syscall4(
            .io_uring_register,
            @intCast(ring_fd),
            IORING_REGISTER_PBUF_RING,
            @intFromPtr(&reg),
            1,
        );
        if (linux.errno(res) != .SUCCESS) {
            return error.RegisterBufRingFailed;
        }

        self.* = .{
            .not_initalized = false,
            .ring_fd = ring_fd,
            .bgid = bgid,
            .buf_ring = buf_ring,
            .buf_ring_entries = entries,
            .memory_backing = backingSize[0 .. @as(usize, entries) * buffer_size],
            .buffer_size = buffer_size,
            .buf_ring_mmap = ringSize,
            .memory_backing_mmap = backingSize,
        };

        // Publish every buffer to the kernel before the ring is handed back,
        // so buffer-select operations never start from an empty pool.
        self.replenishAll();
    }

    pub fn deinit(self: *Self) void {
        if (self.not_initalized) {
            return;
        }

        posix.munmap(self.buf_ring_mmap);
        posix.munmap(self.memory_backing_mmap);
        self.* = undefined;
    }

    /// Map the buffer ring, preferring 2 MiB huge pages and falling
    /// back to regular 4096-byte pages.
    fn mmapRing(entries: u32) MMapError![]align(std.heap.pageSize()) u8 {
        const rawRingSize = bufsOffset + (entries * @sizeOf(linux.io_uring_buf));
        return mmapPool(rawRingSize);
    }

    /// Map the data backing of all buffers.
    fn mmapBacking(entries: u32, buffer_size: u32) MMapError![]align(std.heap.pageSize()) u8 {
        const rawDataSize = @as(usize, entries) * buffer_size;
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

    /// Cut `memory_backing` into buffers and map them all into the ring.
    fn replenishAll(self: *Self) void {
        if (self.not_initalized) {
            return;
        }

        const mask = self.buf_ring_entries - 1;
        const tail = @atomicLoad(u16, &self.buf_ring.tail, .acquire);

        // The element array sits strictly after the io_uring_buf_ring header.
        const basePtr = @intFromPtr(self.buf_ring) + bufsOffset;
        const bufsPtr: [*]linux.io_uring_buf = @ptrFromInt(basePtr);

        var i: u32 = 0;
        while (i < self.buf_ring_entries) : (i += 1) {
            const slotIdx = (tail + i) & mask;
            const offset = @as(usize, i) * self.buffer_size;

            bufsPtr[slotIdx] = .{
                .addr = @intFromPtr(self.memory_backing.ptr + offset),
                .len = self.buffer_size,
                .bid = @intCast(i),
                .resv = 0,
            };
        }

        // Publish the new tail so the SQPOLL kernel thread can consume
        // the freshly added buffers. .release ordering guarantees the
        // element writes are visible before the tail update.
        const newTail = tail +% @as(u16, @intCast(self.buf_ring_entries));
        @atomicStore(u16, &self.buf_ring.tail, newTail, .release);
    }

    /// Return a single processed buffer (identified by its id) back to
    /// the ring at the current tail index.
    pub fn releaseBuffer(self: *Self, bid: u16) void {
        if (self.not_initalized) {
            @branchHint(.cold);
            return;
        }
        const idx = @as(usize, bid);
        if (idx >= self.buf_ring_entries) {
            @branchHint(.cold);
            return;
        }

        const mask = self.buf_ring_entries - 1;

        // The tail is only written by our userspace thread.
        const tail = @atomicLoad(u16, &self.buf_ring.tail, .acquire);

        const basePtr = @intFromPtr(self.buf_ring) + bufsOffset;
        const bufsPtr: [*]linux.io_uring_buf = @ptrFromInt(basePtr);

        const slotIdx = tail & mask;
        const offset = idx * self.buffer_size;

        bufsPtr[slotIdx] = .{
            .addr = @intFromPtr(self.memory_backing.ptr + offset),
            .len = self.buffer_size,
            .bid = bid,
            .resv = 0,
        };

        @atomicStore(u16, &self.buf_ring.tail, tail +% 1, .release);
    }

    /// Return buffer slice for the given idx.
    pub fn buffer(self: *Self, bid: u16) ![]u8 {
        if (self.not_initalized) {
            @branchHint(.cold);
            return error.SizeClassNotInitialized;
        }
        const idx = @as(usize, bid);
        if (idx >= self.buf_ring_entries) {
            @branchHint(.cold);
            return error.InvalidBufferIndex;
        }

        const offset = idx * self.buffer_size;
        return self.memory_backing[offset .. offset + self.buffer_size];
    }

    /// Checks if this buffer pool is initialized.
    pub fn isInactive(self: *Self) bool {
        return self.not_initalized;
    }
};
