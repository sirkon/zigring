const std = @import("std");
const linux = std.os.linux;
const E = linux.E;
const posix = std.posix;
const BufferPool = @import("provided_buffer.zig").ProvidedBufferPool;

pub const pageSize: usize = 4096;
pub const fireAndForgetTaskIdx: u64 = std.math.maxInt(u64);

pub const BufferSizeClass = enum(u16) {
    tiny, // 128 B
    small, // 512 B
    net, // 2 KiB (Ideal for MTU / Ethernet frames)
    page, // 4 KiB (Standard Linux page size)
    big, // 16 KiB
    huge, // 64 KiB

    /// Returns the exact size of the class in bytes
    pub inline fn size(self: BufferSizeClass) u32 {
        return switch (self) {
            .tiny => 128,
            .small => 512,
            .net => 2 * 1024,
            .page => 4 * 1024,
            .big => 16 * 1024,
            .huge => 64 * 1024,
        };
    }

    /// Returns bgid for the given SizeClass.
    pub inline fn bgid(self: BufferSizeClass) usize {
        return @intFromEnum(self);
    }
};

/// Flags for SQE.
pub const TaskFlags = packed struct(u8) {
    const Self = @This();

    /// IOSQE_FIXED_FILE (1 << 0): Use pre-registered files (registered fds) instead of regular ones
    FixedFile: bool = false,

    /// IOSQE_IODONE_HO_WO (1 << 1): Old internal kernel flag. Not used in user code (can stay false)
    _iosqe_idone_ho_wo: bool = false,

    /// IOSQE_IO_DRAIN (1 << 2): Wait for ALL previous tasks in the ring to complete before starting this one
    Drain: bool = false,

    /// IOSQE_IO_LINK (1 << 3): Link this task with the next one. The very flag you need for a timer!
    Link: bool = false,

    /// IOSQE_IO_HARDLINK (1 << 4): Like io_link, but the chain doesn't break even if the previous task failed with an error
    HardLink: bool = false,

    /// IOSQE_ASYNC (1 << 5): Force the task to run asynchronously in kernel workers (io-wq), even if it's non-blocking
    ForceAsync: bool = false,

    /// IOSQE_BUFFER_SELECT (1 << 6): Use automatic buffer selection from the kernel pool (for IORING_OP.PROVIDE_BUFFERS)
    BufferSelect: bool = false,

    /// IOSQE_CQE_SKIP_SUCCESS (1 << 7): Don't generate a CQE in the completion queue if the task succeeded
    SkipSuccess: bool = false,

    pub inline fn flags(self: Self) u8 {
        return @bitCast(self);
    }

    pub inline fn expectNext() Self {
        return .{
            .Link = true,
        };
    }
};

/// A completion read from the CQ by `popCQE` (or `BatchCQ.popCQE`).
///
/// It mirrors the kernel's `struct io_uring_cqe` byte-for-byte (`user_data`,
/// `res`, `flags`), so it can overlay the CQ ring directly. Everything the
/// kernel encodes inside `flags` is exposed through methods: `taskIdx` returns
/// `user_data`, `hasBuffer`/`hasMore`/`hasNotif` decode the CQE flag bits,
/// `bid` extracts the provided buffer id, and `errno`/`result` interpret `res`.
pub const CQE = extern struct {
    /// User data supplied when the operation was pushed; identifies it.
    user_data: u64,
    /// Raw syscall result: non-negative size/success, or a negative errno.
    res: i32,
    /// Raw kernel `IORING_CQE_F_*` flags, with the provided buffer id in the
    /// upper 16 bits.
    flags: u32,

    /// User data supplied when the operation was pushed; identifies it.
    pub inline fn taskIdx(self: CQE) u64 {
        return self.user_data;
    }

    /// Provided buffer id, valid when `hasBuffer` returns true.
    pub inline fn bid(self: CQE) u16 {
        return @intCast(self.flags >> 16);
    }

    /// True when the kernel selected a provided buffer (buffer-select ops).
    pub inline fn hasBuffer(self: CQE) bool {
        return (self.flags & 1) != 0;
    }

    /// True when a multishot operation is still armed and more CQEs follow.
    pub inline fn hasMore(self: CQE) bool {
        return (self.flags & 2) != 0;
    }

    /// True for the second CQE of a `SEND_ZC`: the buffer may be reused now.
    pub inline fn hasNotif(self: CQE) bool {
        return (self.flags & 8) != 0;
    }

    /// Return errno for given res.
    pub inline fn errno(self: CQE) linux.E {
        const resU: usize = @bitCast(@as(i64, self.res));
        return linux.errno(resU);
    }

    /// Result as usize.
    pub inline fn result(self: CQE) usize {
        return @as(usize, @bitCast(@as(i64, self.res)));
    }
};

/// A single io_uring instance configured with SQPOLL, so a dedicated kernel
/// thread polls the submission queue.
///
/// The ring owns three mmaps (the SQ ring, the SQE array and the CQ ring) plus
/// the ring fd; `deinit` releases them all. Work is submitted with the `push*`
/// family, which writes an SQE and only wakes the kernel when needed, and
/// results are read back with `popCQE` or `batchedCQ`.
///
/// The kernel reads operation arguments (buffers, paths, timespecs) from the
/// SQE asynchronously, so every pointer handed to a `push*` must stay valid
/// until the matching completion has been consumed.
///
/// A ring is not synchronized: do not call the `push*` methods or `popCQE`
/// concurrently on the same instance from several threads unless you add your
/// own locking. Use one ring per submitting thread.
pub const Ring = struct {
    const Self = @This(); // Exact type mapping verified

    fd: posix.fd_t,
    flags: u32,

    sqMmapPtr: []align(pageSize) u8,
    cqMmapPtr: []align(4096) u8, // Using literal page_size alignment
    sqesMapPtr: []align(pageSize) u8,

    sqHead: *u32,
    sqTail: *u32,
    sqMask: u32,
    sqArray: [*]u32,
    sqEntries: [*]linux.io_uring_sqe,

    cqHead: *u32,
    cqTail: *u32,
    cqMask: u32,
    cqEntries: [*]CQE,

    bufPools: [@typeInfo(BufferSizeClass).@"enum".fields.len]BufferPool =
        [_]BufferPool{undefined} ** @typeInfo(BufferSizeClass).@"enum".fields.len,

    /// Creates a ring by calling `io_uring_setup` and mmapping the SQ ring, the
    /// SQE array and the CQ ring.
    ///
    /// `queueDepth` is the number of SQ entries and must be a power of two,
    /// otherwise `error.ZigRingRequiresDepthPowOf2` is returned. The ring runs
    /// with SQPOLL, so its kernel thread polls the SQ and parks itself after one
    /// second idle; submissions normally cost no syscall.
    ///
    /// When `attachFd` is non-null, this ring shares the kernel polling thread
    /// of the ring with that fd (`IORING_SETUP_ATTACH_WQ`) instead of starting
    /// its own. That is how several rings can be served by one poller; the
    /// referenced ring must outlive this one.
    ///
    /// The caller owns the returned value and must call `deinit` to unmap the
    /// regions and close the fd.
    pub fn init(queueDepth: u32, attachFd: ?posix.fd_t) !Self {
        if (@popCount(queueDepth) != 1) {
            return error.ZigRingRequiresDepthPowOf2;
        }

        var params = std.mem.zeroes(linux.io_uring_params);
        params.flags = linux.IORING_SETUP_SQPOLL;
        params.sq_thread_idle = 1000;

        if (attachFd) |masterFd| {
            params.flags |= linux.IORING_SETUP_ATTACH_WQ;
            params.wq_fd = @intCast(masterFd);
        }

        const setupRes = linux.io_uring_setup(queueDepth, &params);
        if (linux.errno(setupRes) != .SUCCESS) {
            return error.ZigRingSetupFailed;
        }

        const ringFd: posix.fd_t = @intCast(setupRes);

        const sqLen = params.sq_off.array + (params.sq_entries * @sizeOf(u32));
        const sqMmap = try posix.mmap(
            null,
            sqLen,
            linux.PROT{ .READ = true, .WRITE = true },
            linux.MAP{ .TYPE = .SHARED },
            ringFd,
            linux.IORING_OFF_SQ_RING,
        );

        const sqesLen = params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqesMmap = try posix.mmap(
            null,
            sqesLen,
            linux.PROT{ .READ = true, .WRITE = true },
            linux.MAP{ .TYPE = .SHARED },
            ringFd,
            linux.IORING_OFF_SQES,
        );

        const cqLen = params.cq_off.cqes + (params.cq_entries * @sizeOf(CQE));
        const cqMmap = try posix.mmap(
            null,
            cqLen,
            linux.PROT{ .READ = true, .WRITE = true },
            linux.MAP{ .TYPE = .SHARED },
            ringFd,
            linux.IORING_OFF_CQ_RING,
        );

        const sqBase = sqMmap.ptr;
        const cqBase = cqMmap.ptr;

        const sqMaskPtr: *u32 = @ptrCast(@alignCast(sqBase + params.sq_off.ring_mask));
        const cqMaskPtr: *u32 = @ptrCast(@alignCast(cqBase + params.cq_off.ring_mask));

        return Self{
            .fd = ringFd,
            .flags = params.flags,
            .sqMmapPtr = sqMmap,
            .cqMmapPtr = cqMmap,
            .sqesMapPtr = sqesMmap,

            .sqHead = @ptrCast(@alignCast(sqBase + params.sq_off.head)),
            .sqTail = @ptrCast(@alignCast(sqBase + params.sq_off.tail)),
            .sqMask = sqMaskPtr.*,
            .sqArray = @ptrCast(@alignCast(sqBase + params.sq_off.array)),
            .sqEntries = @ptrCast(@alignCast(sqesMmap.ptr)),

            .cqHead = @ptrCast(@alignCast(cqBase + params.cq_off.head)),
            .cqTail = @ptrCast(@alignCast(cqBase + params.cq_off.tail)),
            .cqMask = cqMaskPtr.*,
            .cqEntries = @ptrCast(@alignCast(cqBase + params.cq_off.cqes)),
            .bufPools = [_]BufferPool{BufferPool.initUninitialized()} ** @typeInfo(BufferSizeClass).@"enum".fields.len,
        };
    }

    /// Releases everything the ring owns: unmaps the SQ ring, the SQE array and
    /// the CQ ring, closes the ring fd, and tears down every provided buffer
    /// pool registered with `regiterSizeClassReceiveBuffer`.
    ///
    /// After this the ring is invalid and must not be used again. This does not
    /// free the memory returned by `registerBuffers`: that mapping is owned by
    /// the caller and must be released with `posix.munmap`.
    pub fn deinit(self: *Self) void {
        posix.munmap(self.sqMmapPtr);
        posix.munmap(self.sqesMapPtr);
        posix.munmap(self.cqMmapPtr);
        _ = linux.close(self.fd);
        for (&self.bufPools) |*pool| {
            pool.deinit();
        }
    }

    /// Registers a kernel-provided buffer ring (a "buffer pool") for one size
    /// class, so the kernel can pick buffers for buffer-select operations on
    /// this ring.
    ///
    /// `entries` buffers of `sizeClass.size()` bytes are mmapped (preferring
    /// 2 MiB huge pages) and published to the kernel; `entries` must be a power
    /// of two. At most one pool per size class may exist: a second call for the
    /// same class returns `error.BufferOfSizeAlreadyInitialized`.
    ///
    /// The pool backs `pushReadZC`/`pushRecvZC`/`pushRecvMultishotZC` for that
    /// class and is owned and freed by the ring itself, not by the caller.
    pub fn regiterSizeClassReceiveBuffer(self: *Self, sizeClass: BufferSizeClass, entries: u32) !void {
        const idx = @intFromEnum(sizeClass);
        const bufPool = &self.bufPools[idx];
        if (!bufPool.isInactive()) {
            return error.BufferOfSizeAlreadyInitialized;
        }

        bufPool.* = try BufferPool.init(self.fd, idx, entries, sizeClass.size());
    }

    // 2 MiB huge page size.
    const hugePageSize: usize = 1 << 21;
    const hugePageMask: u32 = 21 << 26;

    const MMapError = posix.MMapError;

    /// Allocates and registers a flat region of `entries` buffers of
    /// `sizeClass` as io_uring fixed buffers, then returns the mapping.
    ///
    /// These are the buffers referenced by index in `pushSendZC`: buffer `i`
    /// starts at offset `i * sizeClass.size()`. The region is allocated on huge
    /// pages with a regular-page fallback, so its length is rounded up to the
    /// mapping page size (2 MiB when huge pages are available) and may exceed
    /// `sizeClass.size() * entries`; only the first `sizeClass.size() * entries`
    /// bytes are registered.
    ///
    /// Ownership: the returned slice is a raw mmap owned by the caller and must
    /// be released with `posix.munmap`. The kernel pins these pages while the
    /// registration is live, so do not unmap them until every in-flight
    /// `pushSendZC` using them has completed. Closing the ring fd in `deinit`
    /// releases the registration itself.
    pub fn registerBuffers(self: *Self, sizeClass: BufferSizeClass, entries: u32) ![]align(std.heap.pageSize()) u8 {
        const buf_size = sizeClass.size();
        const total = @as(usize, buf_size) * entries;

        const backing_mem = try mmapPool(total);
        errdefer posix.munmap(backing_mem);

        // Standard Linux ABI requires an array of iovec structures:
        // struct iovec { void *iov_base; size_t iov_len; };
        const allocator = std.heap.page_allocator;
        const iovecs = try allocator.alloc(posix.iovec, entries);
        defer allocator.free(iovecs);

        var i: u32 = 0;
        while (i < entries) : (i += 1) {
            const offset = @as(usize, i) * buf_size;
            iovecs[i] = .{
                .base = @ptrCast(backing_mem.ptr + offset),
                .len = buf_size,
            };
        }

        const res = std.os.linux.syscall4(
            .io_uring_register,
            @intCast(self.fd),
            @intFromEnum(linux.IORING_REGISTER.REGISTER_BUFFERS),
            @intFromPtr(iovecs.ptr),
            entries,
        );

        if (std.os.linux.errno(res) != .SUCCESS) {
            return error.RegisterBuffersFailed;
        }

        return backing_mem;
    }

    /// mmap a pool of at least `rawSize` bytes, preferring 2 MiB huge pages
    /// and falling back to regular 4096-byte pages when the OS has none.
    fn mmapPool(rawSize: usize) MMapError![]align(std.heap.pageSize()) u8 {
        const prot = linux.PROT{ .READ = true, .WRITE = true };

        // First try huge pages: SHARED | ANONYMOUS | HUGETLB with the 2 MiB
        // page size bitmask in the map flags. The Zig MAP packed struct has
        // no slot for the page mask, so it must be OR-ed into the raw flags
        // (bits 26-31 are padding). The kernel rounds the length up to the
        // huge page size, so the mapping is 2 MiB aligned in both address
        // and length.
        const hugeSize = std.mem.alignForward(usize, rawSize, hugePageSize);
        var hugeFlags: u32 = @bitCast(linux.MAP{
            .TYPE = .SHARED,
            .ANONYMOUS = true,
            .HUGETLB = true,
        });
        hugeFlags |= hugePageMask;

        return posix.mmap(null, hugeSize, prot, @bitCast(hugeFlags), -1, 0) catch blk: {
            // No huge pages configured in the OS: transparently fall back
            // to a plain anonymous mapping.
            const regularSize = std.mem.alignForward(usize, rawSize, pageSize);
            break :blk try posix.mmap(
                null,
                regularSize,
                prot,
                linux.MAP{ .TYPE = .SHARED, .ANONYMOUS = true },
                -1,
                0,
            );
        };
    }

    // try to retrieve a room for a new op.
    inline fn getOpSlot(self: *Self) !struct { idx: u32, entry: *linux.io_uring_sqe, head: u32 } {
        const tail = self.sqTail.*;
        const head = @atomicLoad(u32, self.sqHead, .acquire);

        if (tail - head >= self.sqMask + 1) {
            return error.RingFull;
        }

        const sqeIdx = tail & self.sqMask;
        const sqe = &self.sqEntries[sqeIdx];

        @memset(std.mem.asBytes(sqe), 0);

        return .{ .idx = sqeIdx, .entry = sqe, .head = head };
    }

    // push a task.
    fn commitOp(self: *Self, idx: u32, cachedHead: u32) !void {
        self.sqArray[idx] = idx;

        const currentTail = self.sqTail.*;
        const nextTail = currentTail + 1;

        @atomicStore(u32, self.sqTail, nextTail, .release);

        if (currentTail != cachedHead) {
            return;
        }

        const freshHead = @atomicLoad(u32, self.sqHead, .acquire);
        if (currentTail != freshHead) {
            return;
        }

        var sig: linux.sigset_t = undefined;
        const res = linux.io_uring_enter(
            self.fd,
            1,
            0,
            linux.IORING_ENTER_SQ_WAKEUP,
            &sig,
        );
        if (res >= 0) {
            return;
        }

        return posix.unexpectedErrno(linux.errno(-res));
    }

    /// Opens a batched submission window over the SQ. It snapshots the current
    /// SQ head and tail and hands back a `BatchSQ` that reserves SQEs without
    /// publishing them, so many operations can be flushed with a single
    /// `io_uring_enter`. Returns null when the ring is already full.
    pub inline fn batchedSQ(self: *Self) ?BatchSQ {
        const tail = self.sqTail.*;
        const head = @atomicLoad(u32, self.sqHead, .acquire);

        if (tail -% head >= self.sqMask + 1) {
            return null;
        }

        return .{ .ring = self, .head = head, .tail = tail };
    }

    /// Opens a streaming submission window over the SQ, the long-lived
    /// counterpart of `batchedSQ`.
    ///
    /// It starts from the same head/tail snapshot, but every `commit` rebuilds
    /// the window from the ring's live cursors, so the same handle keeps
    /// accepting operations across many submission rounds instead of being a
    /// one-shot batch. Returns null when the ring is already full at open time.
    pub inline fn streamedSQ(self: *Self) ?StreamSQ {
        const tail = self.sqTail.*;
        const head = @atomicLoad(u32, self.sqHead, .acquire);

        if (tail -% head >= self.sqMask + 1) {
            return null;
        }

        return .{ .ring = self, .head = head, .tail = tail };
    }

    /// Submits a plain file write (`IORING_OP.WRITE`) of `len` bytes from
    /// `dataPtr` to `targetFd`, at the file's current offset.
    ///
    /// The kernel reads `dataPtr` asynchronously, so that buffer must stay
    /// valid and unchanged until the matching completion arrives. `taskIdx` is
    /// opaque user data echoed back in the resulting `CQE` to identify the
    /// operation. A short write is possible, so check `CQE.result()`.
    pub inline fn pushWrite(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a plain file write (`IORING_OP.WRITE`) of `len` bytes from
    /// `dataPtr` to `targetFd`, starting at `fileOffset`.
    ///
    /// Unlike `pushWrite`, which writes at the file's current offset and lets
    /// the kernel advance it, this variant passes an explicit offset in
    /// `sqe.off`, so the file position is left untouched. It is safe to queue
    /// several writes to distinct offsets on the same fd. The kernel reads
    /// `dataPtr` asynchronously, so that buffer must stay valid and unchanged
    /// until the matching completion arrives. A short write is possible, so
    /// check `CQE.result()`.
    pub inline fn pushWriteOffset(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        fileOffset: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = targetFd;
        // An explicit offset in `off` leaves the file position untouched,
        // unlike an offset of -1 which makes the kernel use it.
        sqe.off = fileOffset;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a vectored write (`IORING_OP.WRITEV`) that gathers the
    /// `iovecs.len` segments it points to and writes their concatenation to
    /// `targetFd`, at the file's current offset.
    ///
    /// The kernel reads the iovec array and every segment it references
    /// asynchronously, so all of them must stay valid and unchanged until the
    /// matching completion arrives. A short write is possible, so check
    /// `CQE.result()`. `taskIdx` is opaque user data echoed back in the
    /// resulting `CQE` to identify the operation.
    pub inline fn pushWritev(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        iovecs: []const posix.iovec_const,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.WRITEV;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(iovecs.ptr);
        // Vectored reads/writes take the segment count in `len`.
        sqe.len = @intCast(iovecs.len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a socket send (`IORING_OP.SEND`) of `len` bytes from `dataPtr` to
    /// `targetFd`.
    ///
    /// `dataPtr` must stay valid until the matching completion, exactly like
    /// `pushWrite`. For zero-copy sending use `pushSendZC`. `taskIdx` is echoed
    /// in the resulting `CQE`.
    pub inline fn pushSend(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.SEND;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Zero-copy send (`IORING_OP.SEND_ZC`) straight out of a buffer that was
    /// registered with `registerBuffers` on this same ring.
    ///
    /// `bufIndex` is the index (0..entries-1) of the registered buffer that
    /// backs `dataPtr`, and `dataPtr`/`len` may select any part of it: the
    /// kernel pins the pages once and hands them to the network stack instead
    /// of copying the payload, so the buffer must not be modified or reused
    /// until the matching completion with `CQE.hasNotif()` set arrives.
    ///
    /// A successful request produces two completions: the first carries the
    /// number of bytes queued (`CQE.hasMore()` is set), the second is the
    /// notification that frees the buffer for reuse (`CQE.hasNotif()` is set).
    ///
    /// `msgFlags` are the regular `MSG_*` flags (e.g. `MSG_NOSIGNAL`).
    pub inline fn pushSendZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        bufIndex: u16,
        msgFlags: u32,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.SEND_ZC;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        // MSG_* flags live in rw_flags, while the zerocopy selectors
        // (IORING_RECVSEND_*) live in ioprio.
        sqe.rw_flags = msgFlags;
        sqe.ioprio = linux.IORING_RECVSEND_FIXED_BUF;
        sqe.buf_index = bufIndex;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a read (`IORING_OP.READ`) that lets the kernel pick a buffer from
    /// the provided pool registered for `size`, instead of using a caller
    /// buffer.
    ///
    /// The size class must already be registered with
    /// `regiterSizeClassReceiveBuffer`, otherwise
    /// `error.BufferPoolNotInitialized` is returned.
    ///
    /// The chosen buffer is reported in the completion: `CQE.hasBuffer()` is set
    /// and `CQE.bid()` identifies it. The kernel does not reclaim it
    /// automatically, so call `releaseBuffer` once done, otherwise the pool
    /// drains. Fetch its bytes with `buffer(size, bid)`.
    pub inline fn pushReadZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        size: BufferSizeClass,
        flags: TaskFlags,
    ) !void {
        const bgid = @intFromEnum(size);
        if (self.bufPools[bgid].isInactive()) {
            @branchHint(.cold);
            return error.BufferPoolNotInitialized;
        }

        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.READ;
        sqe.fd = targetFd;
        sqe.len = size.size();
        sqe.flags = linux.IOSQE_BUFFER_SELECT | flags.flags();
        sqe.buf_index = bgid;
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a read (`IORING_OP.READ`) of up to `dst.len` bytes from
    /// `targetFd` into the caller-owned `dst`, at the file's current offset.
    ///
    /// `dst` must stay valid until the matching completion. A short read is
    /// possible, so check `CQE.result()`. `taskIdx` is echoed in the `CQE`.
    pub inline fn pushRead(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dst: []u8,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.READ;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dst.ptr);
        sqe.len = @intCast(dst.len);
        sqe.flags = flags.flags();
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a read (`IORING_OP.READ`) of up to `dst.len` bytes from
    /// `targetFd` into the caller-owned `dst`, starting at `fileOffset`.
    ///
    /// Unlike `pushRead`, which reads at the file's current offset and lets
    /// the kernel advance it, this variant passes an explicit offset in
    /// `sqe.off`, so the file position is left untouched. It is safe to queue
    /// several reads from distinct offsets on the same fd. `dst` must stay
    /// valid until the matching completion and a short read is possible, so
    /// check `CQE.result()`.
    pub inline fn pushReadOffset(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        fileOffset: u64,
        dst: []u8,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.READ;
        sqe.fd = targetFd;
        // An explicit offset in `off` leaves the file position untouched,
        // unlike an offset of -1 which makes the kernel use it.
        sqe.off = fileOffset;
        sqe.addr = @intFromPtr(dst.ptr);
        sqe.len = @intCast(dst.len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a vectored read (`IORING_OP.READV`) that scatters up to the
    /// total length of `iovecs` into the `iovecs.len` segments it points to,
    /// from `targetFd` at the file's current offset.
    ///
    /// The kernel reads the iovec array and writes into every segment
    /// asynchronously, so all of them must stay valid and unchanged until the
    /// matching completion arrives. A short read is possible, so check
    /// `CQE.result()`. `taskIdx` is echoed back in the resulting `CQE`.
    pub inline fn pushReadv(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        iovecs: []const posix.iovec,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.READV;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(iovecs.ptr);
        // Vectored reads/writes take the segment count in `len`.
        sqe.len = @intCast(iovecs.len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a single socket receive (`IORING_OP.RECV`) that fills a buffer
    /// the kernel picks from the provided pool registered for `size`.
    ///
    /// The size class must be registered first
    /// (`regiterSizeClassReceiveBuffer`), otherwise
    /// `error.BufferPoolNotInitialized` is returned. The borrowed buffer is
    /// reported through `CQE.hasBuffer()`/`CQE.bid()` and must be returned to the
    /// pool with `releaseBuffer` after use. Use `pushRecvMultishotZC` when one
    /// submission should keep receiving.
    pub inline fn pushRecvZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        size: BufferSizeClass,
        flags: TaskFlags,
    ) !void {
        const bgid = @intFromEnum(size);
        if (self.bufPools[bgid].isInactive()) {
            @branchHint(.cold);
            return error.BufferPoolNotInitialized;
        }

        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.RECV;
        sqe.fd = targetFd;
        sqe.len = size.size();
        sqe.flags = linux.IOSQE_BUFFER_SELECT | flags.flags();
        sqe.buf_index = bgid;
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a single socket receive (`IORING_OP.RECV`) of up to `buf.len`
    /// bytes into the caller-owned `buf`.
    ///
    /// `buf` must stay valid until the matching completion; the number of bytes
    /// received is in `CQE.result()`. `taskIdx` is echoed in the `CQE`.
    pub inline fn pushRecv(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        buf: []u8,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.RECV;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @intCast(buf.len);
        sqe.flags = flags.flags();
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Arms a multishot receive (`IORING_OP.RECV` with `IORING_RECV_MULTISHOT`)
    /// that keeps producing completions without being re-submitted.
    ///
    /// Each completion with `CQE.hasMore()` set means the receive is still armed,
    /// and every one of them carries a borrowed provided buffer via
    /// `CQE.hasBuffer()`/`CQE.bid()` that the caller must `releaseBuffer` once
    /// processed. The multishot ends on an error (for example `-ENOBUFS` once
    /// the pool is drained) or when the operation is canceled; the final `CQE`
    /// then clears `hasMore`. Only one multishot receive may be armed per fd at
    /// a time, a second attempt fails with `-EBUSY`.
    pub inline fn pushRecvMultishotZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        size: BufferSizeClass,
        flags: TaskFlags,
    ) !void {
        const bgid = @intFromEnum(size);
        if (self.bufPools[bgid].isInactive()) {
            @branchHint(.cold);
            return error.BufferPoolNotInitialized;
        }

        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.RECV;
        sqe.fd = targetFd;
        sqe.flags = linux.IOSQE_BUFFER_SELECT | flags.flags();
        sqe.buf_index = bgid;
        sqe.user_data = taskIdx;
        sqe.ioprio = linux.IORING_RECV_MULTISHOT;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Asynchronously opens a subdirectory relative to `baseDirFd`
    /// (`IORING_OP.OPENAT` with `O_PATH`).
    ///
    /// `subPath` is a NUL-terminated path relative to `baseDirFd`; both it and
    /// `baseDirFd` must be valid until the operation completes, because the
    /// kernel reads them asynchronously. The request is forced to the io-wq
    /// workers, since opening can block on the VFS.
    ///
    /// On success the completion's `res` is a new `O_PATH` fd for the
    /// directory, owned by the caller and to be closed later with `pushClose`.
    pub inline fn pushOpenDir(
        self: *Self,
        taskIdx: u64,
        baseDirFd: posix.fd_t, // Descriptor of the root logs folder, e.g. opened at startup with AT_FDCWD
        subPath: [*:0]const u8, // Name of the shard/session subfolder, e.g. "shard_42"
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.OPENAT;
        // Base reference point in the VFS for the Linux kernel
        sqe.fd = baseDirFd;
        sqe.addr = @intFromPtr(subPath);

        // In the Linux ABI: O_PATH (0x02000000) | O_CLOEXEC (0x00080000).
        // Zig master packed this into linux.O.
        // Cast directly into the rw_flags of our flat SQE struct.
        sqe.rw_flags = @bitCast(linux.O{ .PATH = true, .CLOEXEC = true });

        // For directories opened with O_PATH, the access mode is irrelevant
        sqe.len = 0;
        sqe.user_data = taskIdx;

        // Force the operation into the background io-wq pool
        sqe.flags = linux.IOSQE_ASYNC | flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Asynchronously opens or creates a file inside `dirFd`
    /// (`IORING_OP.OPENAT`).
    ///
    /// `dirFd` is a directory fd (for example one returned by `pushOpenDir`) and
    /// `fileName` is a NUL-terminated name relative to it; the name must stay
    /// valid until the operation completes. `opts` are the `open(2)` flags,
    /// with `O_CLOEXEC` always forced on. The request is offloaded to the io-wq
    /// workers because opening can block.
    ///
    /// On success the completion's `res` is the new fd, owned by the caller and
    /// to be closed later with `pushClose`.
    pub inline fn pushOpenFile(
        self: *Self,
        taskIdx: u64,
        dirFd: posix.fd_t, // Descriptor of the folder obtained from the previous pushOpenDir step
        fileName: [*:0]const u8, // File name, e.g. "session_123.wal"
        opts: linux.O,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.OPENAT;
        // Open the file strictly inside the folder via its descriptor (fast path in the kernel)
        sqe.fd = dirFd;
        sqe.addr = @intFromPtr(fileName);

        // Flags for ultra-perf: Read/Write + Create if missing + DIRECT I/O (bypassing the OS cache)
        // In Zig master, posix.O is force-cast to u32 via bitCast
        var safeOpts = opts;
        safeOpts.CLOEXEC = true;
        sqe.rw_flags = @bitCast(safeOpts);

        // Access mode for the created file (standard 0o644)
        sqe.len = 0o644;
        sqe.user_data = taskIdx;

        // Keep SQPOLL from going to sleep: offload to io-wq workers
        sqe.flags = linux.IOSQE_ASYNC | flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Asynchronously closes `targetFd` (`IORING_OP.CLOSE`).
    ///
    /// `targetFd` must still be valid when the kernel processes the SQE. On
    /// success the completion's `res` is 0, and the fd must not be used after
    /// pushing the close. The request is offloaded to the io-wq workers because
    /// closing can block.
    pub inline fn pushClose(
        self: *Self,
        taskIdx: u64,
        targetFd: posix.fd_t,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.CLOSE;
        sqe.fd = targetFd;
        sqe.user_data = taskIdx;
        sqe.flags = linux.IOSQE_ASYNC | flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Arms a multishot accept (`IORING_OP.ACCEPT` with
    /// `IORING_ACCEPT_MULTISHOT`) on `listenFd`, which keeps delivering incoming
    /// connections without being re-submitted.
    ///
    /// Every completion whose `res` is a valid fd is a freshly accepted client
    /// socket (created with `O_CLOEXEC`); the caller owns it and must close it
    /// with `pushClose`. As long as `CQE.hasMore()` is set the accept is still
    /// armed; it stops on an error or when the operation is canceled, and the
    /// final `CQE` clears `hasMore`.
    pub inline fn pushAcceptMultishot(
        self: *Self,
        listenFd: posix.fd_t,
        taskIdx: u64,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        // getOpSlot already zeroed the struct
        sqe.opcode = linux.IORING_OP.ACCEPT;
        sqe.fd = listenFd;

        // For multishot we don't need the sockaddr struct address in the SQE,
        // the kernel just hands out socket descriptors; leave it zero (already zeroed)

        // Enable the flag that auto-creates client sockets with O_CLOEXEC
        sqe.rw_flags = posix.SOCK.CLOEXEC;

        // Arm the MULTISHOT mode in ioprio!
        sqe.ioprio = linux.IORING_ACCEPT_MULTISHOT;

        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Submits a one-shot accept (`IORING_OP.ACCEPT`) on `listenFd`.
    ///
    /// `listenFd` must already be bound and listening. On success the
    /// completion's `res` is a new client socket fd (created with `O_CLOEXEC`),
    /// owned by the caller and to be closed with `pushClose`. To keep accepting
    /// without resubmitting use `pushAcceptMultishot`.
    pub inline fn pushAccept(
        self: *Self,
        listenFd: posix.fd_t,
        taskIdx: u64,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.ACCEPT;
        sqe.fd = listenFd;
        sqe.rw_flags = posix.SOCK.CLOEXEC;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Asynchronously renames a file within the directory `baseDirFd`
    /// (`IORING_OP.RENAMEAT`).
    ///
    /// Both names are resolved relative to the same `baseDirFd` and the rename
    /// is atomic in the VFS, which lets callers publish a fully written
    /// temporary file under its final name.
    ///
    /// `oldName` and `newName` are NUL-terminated and must stay valid until the
    /// operation completes. The request is forced to the io-wq workers because
    /// renaming locks VFS metadata.
    pub inline fn pushRename(
        self: *Self,
        taskIdx: u64,
        baseDirFd: posix.fd_t, // Our saved descriptor of the single logs folder
        oldName: [*:0]const u8, // E.g. "session_42.wal.tmp"
        newName: [*:0]const u8, // E.g. "session_42.wal"
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.RENAMEAT;

        // Map the same folder descriptor for both the source and target paths
        sqe.fd = baseDirFd; // oldDirFd in the Linux ABI
        sqe.len = @intCast(baseDirFd); // newDirFd in the Linux ABI

        // Write the pointers to the path strings
        sqe.addr = @intFromPtr(oldName);
        sqe.addr3 = @intFromPtr(newName);

        // The flags of renameat2 itself. To avoid overwriting an existing file,
        // set linux.RENAME_NOREPLACE. Otherwise leave 0 (already zeroed)
        // sqe.rw_flags = 0; // Already done in getOpSlot.

        sqe.user_data = taskIdx;

        // Force the operation into kernel io-wq workers, since RENAME locks VFS metadata
        sqe.flags = linux.IOSQE_ASYNC | flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Low-level bind primitive: submits `IORING_OP.BIND` for `socketFd`
    /// against a raw POSIX socket address.
    ///
    /// `sockAddr`/`sockLen` describe the local address and must stay valid
    /// until the operation completes, because the kernel reads them from the
    /// SQE asynchronously. Callers normally do not need this directly: prefer
    /// `pushBindIp4`/`pushBindIp6`, which build the address from a string.
    inline fn pushBind(
        self: *Self,
        socketFd: posix.fd_t,
        taskIdx: u64,
        sockAddr: *const posix.sockaddr,
        sockLen: u32,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.BIND;
        sqe.fd = socketFd;
        // io_uring takes the address pointer in `addr` and its length in `off`
        // (which aliases `addr2` in the kernel ABI).
        sqe.addr = @intFromPtr(sockAddr);
        sqe.off = sockLen;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Low-level connect primitive: submits `IORING_OP.CONNECT` for `socketFd`
    /// against a raw POSIX peer address.
    ///
    /// `sockAddr`/`sockLen` describe the peer address and must stay valid until
    /// the operation completes, because the kernel reads them from the SQE
    /// asynchronously. Callers normally do not need this directly: prefer
    /// `pushConnectIp4`/`pushConnectIp6`, which build the address from a string.
    inline fn pushConnect(
        self: *Self,
        socketFd: posix.fd_t,
        taskIdx: u64,
        sockAddr: *const posix.sockaddr,
        sockLen: u32,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.CONNECT;
        sqe.fd = socketFd;
        sqe.addr = @intFromPtr(sockAddr);
        sqe.off = sockLen;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Binds `fd` to the IPv4 endpoint `ip_str`:`port`.
    ///
    /// `ip_str` is dotted-decimal, for example "127.0.0.1", or "0.0.0.0" to
    /// listen on every interface. The text is parsed and packed into a
    /// `sockaddr.in` for you, so callers never declare POSIX address structs or
    /// cast pointers by hand. `flags` carries the usual `TaskFlags`.
    pub inline fn pushBindIp4(
        self: *Self,
        fd: posix.fd_t,
        user_data: u64,
        ip_str: []const u8,
        port: u16,
        flags: TaskFlags,
    ) !void {
        const ip = try std.Io.net.Ip4Address.parse(ip_str, port);
        const sock_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, ip.port),
            .addr = @bitCast(ip.bytes),
        };
        try self.pushBind(fd, user_data, @ptrCast(&sock_addr), @sizeOf(posix.sockaddr.in), flags);
    }

    /// Connects `fd` to the IPv4 endpoint `ip_str`:`port`.
    ///
    /// `ip_str` is dotted-decimal, for example "127.0.0.1". The text is parsed
    /// and packed into a `sockaddr.in` for you, so callers never declare POSIX
    /// address structs or cast pointers by hand. `flags` carries the usual
    /// `TaskFlags`.
    pub inline fn pushConnectIp4(
        self: *Self,
        fd: posix.fd_t,
        user_data: u64,
        ip_str: []const u8,
        port: u16,
        flags: TaskFlags,
    ) !void {
        const ip = try std.Io.net.Ip4Address.parse(ip_str, port);
        const sock_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, ip.port),
            .addr = @bitCast(ip.bytes),
        };
        try self.pushConnect(fd, user_data, @ptrCast(&sock_addr), @sizeOf(posix.sockaddr.in), flags);
    }

    /// Binds `fd` to the IPv6 endpoint `ip_str`:`port`.
    ///
    /// `ip_str` is the textual IPv6 form, for example "::1", or "::" to listen
    /// on every interface. The text is parsed and packed into a `sockaddr.in6`
    /// for you, so callers never declare POSIX address structs or cast pointers
    /// by hand. `flags` carries the usual `TaskFlags`.
    pub inline fn pushBindIp6(
        self: *Self,
        fd: posix.fd_t,
        user_data: u64,
        ip_str: []const u8,
        port: u16,
        flags: TaskFlags,
    ) !void {
        const ip = try std.Io.net.Ip6Address.parse(ip_str, port);
        const sock_addr = posix.sockaddr.in6{
            .family = posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, ip.port),
            .flowinfo = ip.flow,
            .addr = ip.bytes,
            .scope_id = 0,
        };
        try self.pushBind(fd, user_data, @ptrCast(&sock_addr), @sizeOf(posix.sockaddr.in6), flags);
    }

    /// Connects `fd` to the IPv6 endpoint `ip_str`:`port`.
    ///
    /// `ip_str` is the textual IPv6 form, for example "::1". The text is parsed
    /// and packed into a `sockaddr.in6` for you, so callers never declare POSIX
    /// address structs or cast pointers by hand. `flags` carries the usual
    /// `TaskFlags`.
    pub inline fn pushConnectIp6(
        self: *Self,
        fd: posix.fd_t,
        user_data: u64,
        ip_str: []const u8,
        port: u16,
        flags: TaskFlags,
    ) !void {
        const ip = try std.Io.net.Ip6Address.parse(ip_str, port);
        const sock_addr = posix.sockaddr.in6{
            .family = posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, ip.port),
            .flowinfo = ip.flow,
            .addr = ip.bytes,
            .scope_id = 0,
        };
        try self.pushConnect(fd, user_data, @ptrCast(&sock_addr), @sizeOf(posix.sockaddr.in6), flags);
    }

    /// Submits `listen(2)` (`IORING_OP.LISTEN`) on `socketFd`, marking it ready
    /// to accept connections with `backlog` as the pending-connection hint.
    ///
    /// The socket must already be bound. The kernel clamps the usable backlog
    /// to `net.core.somaxconn`, so the effective value may be lower than
    /// requested; a successful completion has `res == 0`.
    pub inline fn pushListen(
        self: *Self,
        socketFd: posix.fd_t,
        taskIdx: u64,
        backlog: u32,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.LISTEN;
        sqe.fd = socketFd;
        sqe.len = backlog;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Sends a wakeup to another io_uring (`IORING_OP.MSG_RING`) identified by
    /// `targetRingFd`, useful for waking a thread parked on that ring.
    ///
    /// The target ring receives a `CQE` whose `res` is `msgResult` and whose
    /// `taskIdx` is this call's `taskIdx`, so the receiver can tell senders
    /// apart. The operation is non-blocking and no completion is generated on
    /// the sending ring (`SkipSuccess`), so nothing needs to be awaited here.
    pub inline fn pushMsgRingFd(
        self: *Self,
        targetRingFd: posix.fd_t, // fd of the ring belonging to the sleeping thread
        taskIdx: u64,
        msgResult: u32, // Custom message type/signal (will go into cqe.res)
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        // getOpSlot already did @memset to 0, only fill the flat meaningful Linux ABI fields
        sqe.opcode = linux.IORING_OP.MSG_RING;
        sqe.fd = targetRingFd; // Target ring descriptor
        sqe.flags = linux.IOSQE_CQE_SKIP_SUCCESS | flags.flags();

        // Map data: len will go to cqe.res, off will go to cqe.user_data on the receiver side
        sqe.len = msgResult;
        sqe.off = taskIdx;

        // We don't typically care about the response to the send operation itself in our own CQE,
        // so we leave sqe.user_data at zero (already zeroed in getOpSlot).
        // The task will execute on the current CPU instantly without blocking.

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Sends a wakeup to another io_uring (`IORING_OP.MSG_RING`) identified by
    /// `targetRing`, useful for waking a thread parked on that ring.
    ///
    /// This is a convenience wrapper over `pushMsgRingFd` that uses the target
    /// ring's own descriptor. The target ring receives a `CQE` whose `res` is
    /// `msgResult` and whose `taskIdx` is this call's `taskIdx`. The operation
    /// is non-blocking and no completion is generated on the sending ring
    /// (`SkipSuccess`), so nothing needs to be awaited here.
    pub inline fn pushMsgRing(
        self: *Self,
        targetRing: *Ring, // ring belonging to the sleeping thread
        taskIdx: u64,
        msgResult: u32, // Custom message type/signal (will go into cqe.res)
        flags: TaskFlags,
    ) !void {
        return self.pushMsgRingFd(targetRing.fd, taskIdx, msgResult, flags);
    }

    /// Arms a standalone timer (`IORING_OP.TIMEOUT`) that produces a `CQE`
    /// after the duration in `timespecPtr` elapses.
    ///
    /// The time is relative to submission unless the operation is flagged as
    /// absolute, and the timeout is reported as success
    /// (`IORING_TIMEOUT_ETIME_SUCCESS`), so an expired timer yields `res == 0`
    /// rather than `-ETIME`.
    ///
    /// `timespecPtr` is read by the kernel while the timer runs, so it must
    /// remain valid and unchanged until the completion is consumed. Take care
    /// with `SkipSuccess`: suppressing the completion also hides the only
    /// signal that the pointer is no longer needed, leaking it unless the
    /// timespec is static.
    pub inline fn pushTimeout(
        self: *Self,
        taskIdx: u64,
        timespecPtr: *const linux.kernel_timespec,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.TIMEOUT;
        sqe.fd = -1; // No file descriptor needed for timers, write -1

        // Pass the pointer to the time structure
        sqe.addr = @intFromPtr(timespecPtr);

        // Timer task will really wait for the timer to stop.
        sqe.len = 0;

        // Timer flags: 0 means relative time (countdown starts from the moment of push).
        // If absolute time is needed, set linux.IORING_TIMEOUT_ABS.
        sqe.rw_flags = linux.IORING_TIMEOUT_ETIME_SUCCESS;
        sqe.flags = flags.flags();

        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Attaches a timeout (`IORING_OP.LINK_TIMEOUT`) that cancels the operation
    /// immediately preceding it if that operation does not finish in time.
    ///
    /// The link is established only between SQEs submitted together, so for a
    /// reliable guard push the guarded operation and this timeout in the same
    /// `batchedSQ` batch; a bare ring push may lose the association and the
    /// kernel then rejects the SQE with `-EINVAL`. On expiry the timeout is
    /// reported as success (`IORING_TIMEOUT_ETIME_SUCCESS`), and the guard
    /// counts exactly one operation.
    ///
    /// `timespecPtr` must remain valid and unchanged until the completion is
    /// consumed. As with `pushTimeout`, be careful with `SkipSuccess`: hiding
    /// the completion keeps the pointer live until it is known to be freeable.
    pub inline fn pushTimeoutForOp(
        self: *Self,
        timespecPtr: *const linux.kernel_timespec,
        taskIdx: u64,
        flags: TaskFlags,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        // Use LINK_TIMEOUT to bind to the previous SQE in the queue
        sqe.opcode = linux.IORING_OP.LINK_TIMEOUT;
        sqe.fd = -1; // No file descriptor needed for timers, write -1

        // Pass the pointer to the time structure
        sqe.addr = @intFromPtr(timespecPtr);

        // For linked timeouts the kernel requires the event count in len to
        // be exactly 1, otherwise it rejects the SQE with -EINVAL.
        sqe.len = 1;

        // Timer flags: using ETIME_SUCCESS so that a regular timeout is treated normally.
        // rw_flags maps directly to timeout_flags in the flat SQE structure.
        sqe.rw_flags = linux.IORING_TIMEOUT_ETIME_SUCCESS;
        sqe.flags = flags.flags();

        // Use the global constant for the timer instead of a custom taskIdx
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Removes and returns the next completion, or null if the CQ is empty.
    ///
    /// `CQE.taskIdx()` identifies the operation and `CQE.res` is its result. When
    /// `CQE.hasBuffer()` is set, `bid` is a borrowed provided buffer that must be
    /// returned with `releaseBuffer` exactly once; for `pushSendZC` the buffer
    /// is freed by the completion with `hasNotif` set. Consuming a completion
    /// advances the CQ head and frees its slot for the kernel, so leaving
    /// completions unread will eventually stall the CQ. Call this on the hot
    /// path and fall back to `park` only when it returns null.
    pub inline fn popCQE(self: *Self) ?CQE {
        const head = self.cqHead.*;
        const tail = @atomicLoad(u32, self.cqTail, .acquire);

        if (head == tail) return null;

        const cqeIdx = head & self.cqMask;

        // Advance the ring head one at a time with .release semantics
        @atomicStore(u32, self.cqHead, head +% 1, .release);

        return self.cqEntries[cqeIdx];
    }

    /// Returns true when at least one completion is waiting in the CQ, false
    /// otherwise. Unlike `popCQE` it does not consume anything, so it is a cheap
    /// way to poll for readiness without advancing the CQ head. It observes the
    /// same acquire load of the CQ tail as `popCQE`, so a true result guarantees
    /// a following `popCQE`/`batchedCQ` sees at least one completion.
    pub inline fn checkCQNotEmpty(self: *Self) bool {
        const head = self.cqHead.*;
        const tail = @atomicLoad(u32, self.cqTail, .acquire);

        return head != tail;
    }

    /// Opens a batched consumption window over the CQ. It snapshots the current
    /// CQ head and tail and hands back a `BatchedCQ` that reads completions
    /// without publishing the consumed head, so many completions can be drained
    /// and flushed with a single `io_uring_enter` on `commit`. Returns null when
    /// there is nothing to consume, i.e. as soon as the head reaches the tail.
    ///
    /// `maxEntries` caps how many completions the window exposes: the instance
    /// returns null after that many pops, even if the ring holds more, so a
    /// single batch can be kept bounded. Pass `null` to drain everything
    /// currently visible.
    pub inline fn batchedCQ(self: *Self, maxEntries: ?u32) ?BatchCQ {
        const head = self.cqHead.*;
        const tail = @atomicLoad(u32, self.cqTail, .acquire);

        if (head == tail) {
            return null;
        }

        const available = tail -% head;
        const limit = if (maxEntries) |max| @min(available, max) else available;

        if (limit == 0) {
            return null;
        }

        return .{ .ring = self, .head = head, .tail = head +% limit };
    }

    /// Blocks the calling thread until at least one completion is available.
    ///
    /// This enters the kernel with `io_uring_enter`, requesting
    /// `IORING_ENTER_GETEVENTS` with a minimum of one event and also passing
    /// `IORING_ENTER_SQ_WAKEUP` so a parked SQPOLL thread resumes. No operation
    /// is submitted, so it is safe to call when the SQ is empty.
    ///
    /// It is the cold-path companion to `popCQE`/`batchedCQ`: call it only after
    /// they returned null, to avoid an unnecessary syscall in the hot path.
    /// `EINTR` (for example from a profiler or debugger) is retried internally;
    /// any other error is treated as fatal and panics.
    pub fn park(self: *Self) void {
        // IORING_ENTER_SQ_WAKEUP (1 << 1) is always passed below: the SQPOLL
        // thread parks itself after its idle timeout, so without the wakeup a
        // sleep here could outlive the poller and never be interrupted.

        while (true) {
            // Direct system call to io_uring_enter without stdlib intermediaries
            const res = linux.syscall6(
                .io_uring_enter,
                @intCast(self.fd), // fd of our ring
                0, // to_submit = 0 (we're not submitting anything, just waiting)
                1, // min_complete = 1 (wake up when at least one task appears in the CQ)
                linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_SQ_WAKEUP, // sleep/wait flags
                0, // sig = null
                0, // size = 0
            );

            // Handle interruptions from Linux OS system signals
            const err = linux.errno(res);
            if (err == .SUCCESS) break;

            // If the syscall was interrupted by a system signal (e.g., profiler or debugger),
            // we must continue sleeping rather than panicking
            if (err == .INTR) {
                @branchHint(.likely);
                continue;
            }

            // Any other error here is a fatal ring crash
            @panic("Fatal: io_uring_enter failed during park state!");
        }
    }

    /// Returns a provided buffer that the kernel handed out (a `CQE.bid()` with
    /// `CQE.hasBuffer()` set) to the pool for `sizeClass`, making it reusable by
    /// later buffer-select operations.
    ///
    /// Each borrowed buffer must be released exactly once. Forgetting to
    /// release drains the pool, after which multishot receives fail with
    /// `-ENOBUFS`; the pool is per size class and is not refilled
    /// automatically. Out-of-range ids, or a pool that is not initialized, are
    /// ignored.
    pub fn releaseBuffer(self: *Self, sizeClass: BufferSizeClass, bid: u16) void {
        self.bufPools[sizeClass.bgid()].releaseBuffer(bid);
    }

    /// Returns the bytes of provided buffer `bid` from the pool for
    /// `sizeClass`, or null if the pool is not initialized or `bid` is out of
    /// range.
    ///
    /// The slice is a borrowed view into the pool's mmapped backing memory: it
    /// stays valid until the buffer is released with `releaseBuffer` (and, more
    /// generally, until the ring is deinitialized). Do not free it. For a given
    /// completion only the first `CQE.result()` bytes hold data.
    pub fn buffer(self: *Self, sizeClass: BufferSizeClass, bid: u16) ?[]const u8 {
        var bufpool: BufferPool = self.bufPools[sizeClass.bgid()];
        return bufpool.buffer(bid) catch {
            return null;
        };
    }
};

/// A batched view over the submission queue, created by `Ring.batchedSQ`.
///
/// Operations pushed through it are written into the ring but stay invisible
/// to the kernel until `commit` advances the ring's tail. This lets callers
/// queue many operations and flush them with a single wakeup. Each push
/// returns null once the window is exhausted, i.e. as soon as it would
/// overwrite an SQE the kernel has not consumed yet.
pub const BatchSQ = struct {
    const Self = @This();

    /// The ring this batch belongs to.
    ring: *Ring,
    /// SQ head captured when the batch was opened.
    head: u32,
    /// SQ producer cursor. It starts at the tail captured when the batch was
    /// opened and advances with every pushed operation.
    tail: u32,

    /// Reserves the next SQE, zeroes it and records it in the SQ array.
    /// Returns null once the window reaches the captured head plus one full
    /// ring length.
    inline fn reserve(self: *Self) ?*linux.io_uring_sqe {
        const ring = self.ring;

        if (self.tail -% self.head >= ring.sqMask + 1) {
            return null;
        }

        const idx = self.tail & ring.sqMask;
        const sqe = &ring.sqEntries[idx];

        @memset(std.mem.asBytes(sqe), 0);
        ring.sqArray[idx] = idx;

        self.tail +%= 1;

        return sqe;
    }

    /// Reserves and fills a plain file write in the batch, mirroring
    /// `Ring.pushWrite` (including the buffer lifetime requirement). Returns
    /// null when the batch is full, in which case nothing was reserved.
    pub inline fn pushWrite(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves and fills a plain file write at an explicit offset in the
    /// batch, mirroring `Ring.pushWriteOffset` (including the buffer lifetime
    /// requirement). Returns null when the batch is full.
    pub inline fn pushWriteOffset(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        fileOffset: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = targetFd;
        sqe.off = fileOffset;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves and fills a read at an explicit offset in the batch, mirroring
    /// `Ring.pushReadOffset` (including the buffer lifetime requirement).
    /// Returns null when the batch is full.
    pub inline fn pushReadOffset(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        fileOffset: u64,
        dst: []u8,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.READ;
        sqe.fd = targetFd;
        sqe.off = fileOffset;
        sqe.addr = @intFromPtr(dst.ptr);
        sqe.len = @intCast(dst.len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves and fills a socket send in the batch, mirroring
    /// `Ring.pushSend` (including the buffer lifetime requirement). Returns null
    /// when the batch is full.
    pub inline fn pushSend(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.SEND;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Zero-copy send, mirroring `Ring.pushSendZC`. See that method for the
    /// buffer lifetime and dual-completion semantics.
    pub inline fn pushSendZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        bufIndex: u16,
        msgFlags: u32,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.SEND_ZC;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.rw_flags = msgFlags;
        sqe.ioprio = linux.IORING_RECVSEND_FIXED_BUF;
        sqe.buf_index = bufIndex;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves an accept of one incoming connection, mirroring `Ring.pushAccept`.
    pub inline fn pushAccept(
        self: *Self,
        listenFd: posix.fd_t,
        taskIdx: u64,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.ACCEPT;
        sqe.fd = listenFd;
        sqe.rw_flags = posix.SOCK.CLOEXEC;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves a linked timeout guarding the operation reserved right before
    /// it, mirroring `Ring.pushTimeoutForOp`. It must be pushed in the same
    /// batch as the operation it guards: the kernel only establishes the link
    /// while assembling a single submission, otherwise it fails with `-EINVAL`.
    pub inline fn pushTimeoutForOp(
        self: *Self,
        timespecPtr: *const linux.kernel_timespec,
        taskIdx: u64,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.LINK_TIMEOUT;
        sqe.fd = -1;
        sqe.addr = @intFromPtr(timespecPtr);
        sqe.len = 1;
        sqe.rw_flags = linux.IORING_TIMEOUT_ETIME_SUCCESS;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Publishes every SQE pushed so far by atomically moving the ring's tail,
    /// then nudges the kernel poller so it observes the new entries.
    pub fn commit(self: *Self) !void {
        const ring = self.ring;

        @atomicStore(u32, ring.sqTail, self.tail, .release);

        var sig: linux.sigset_t = undefined;
        const res = linux.io_uring_enter(
            ring.fd,
            1,
            0,
            linux.IORING_ENTER_SQ_WAKEUP,
            &sig,
        );

        const err = linux.errno(res);
        if (err == .SUCCESS) {
            return;
        }

        return posix.unexpectedErrno(err);
    }
};

/// A streaming view over the submission queue, created by `Ring.streamedSQ`.
///
/// It mirrors `BatchSQ` (same `push*` surface and single-wakeup `commit`) but
/// is meant to be kept alive: every `commit` re-reads the ring's live SQ head
/// and tail, so the window slides forward as the kernel consumes the entries
/// and the same handle can drive one submission round after another. Each push
/// still returns null once the window is exhausted, i.e. as soon as it would
/// overwrite an SQE the kernel has not consumed yet.
pub const StreamSQ = struct {
    const Self = @This();

    /// The ring this stream belongs to.
    ring: *Ring,
    /// SQ head captured at open time and re-read by every `commit`.
    head: u32,
    /// SQ producer cursor, advanced by every pushed operation and re-synced
    /// with the ring tail by every `commit`.
    tail: u32,

    /// Reserves the next SQE, zeroes it and records it in the SQ array.
    /// Returns null once the window reaches the captured head plus one full
    /// ring length.
    inline fn reserve(self: *Self) ?*linux.io_uring_sqe {
        const ring = self.ring;

        if (self.tail -% self.head >= ring.sqMask + 1) {
            return null;
        }

        const idx = self.tail & ring.sqMask;
        const sqe = &ring.sqEntries[idx];

        @memset(std.mem.asBytes(sqe), 0);
        ring.sqArray[idx] = idx;

        self.tail +%= 1;

        return sqe;
    }

    /// Reserves and fills a plain file write in the stream, mirroring
    /// `Ring.pushWrite` (including the buffer lifetime requirement). Returns
    /// null when the window is full, in which case nothing was reserved.
    pub inline fn pushWrite(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves and fills a plain file write at an explicit offset in the
    /// stream, mirroring `Ring.pushWriteOffset` (including the buffer lifetime
    /// requirement). Returns null when the window is full.
    pub inline fn pushWriteOffset(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        fileOffset: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = targetFd;
        sqe.off = fileOffset;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves and fills a read at an explicit offset in the stream, mirroring
    /// `Ring.pushReadOffset` (including the buffer lifetime requirement).
    /// Returns null when the window is full.
    pub inline fn pushReadOffset(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        fileOffset: u64,
        dst: []u8,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.READ;
        sqe.fd = targetFd;
        sqe.off = fileOffset;
        sqe.addr = @intFromPtr(dst.ptr);
        sqe.len = @intCast(dst.len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves and fills a socket send in the stream, mirroring
    /// `Ring.pushSend` (including the buffer lifetime requirement). Returns null
    /// when the window is full.
    pub inline fn pushSend(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.SEND;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Zero-copy send, mirroring `Ring.pushSendZC`. See that method for the
    /// buffer lifetime and dual-completion semantics.
    pub inline fn pushSendZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
        bufIndex: u16,
        msgFlags: u32,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.SEND_ZC;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.rw_flags = msgFlags;
        sqe.ioprio = linux.IORING_RECVSEND_FIXED_BUF;
        sqe.buf_index = bufIndex;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves an accept of one incoming connection, mirroring `Ring.pushAccept`.
    pub inline fn pushAccept(
        self: *Self,
        listenFd: posix.fd_t,
        taskIdx: u64,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.ACCEPT;
        sqe.fd = listenFd;
        sqe.rw_flags = posix.SOCK.CLOEXEC;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Reserves a linked timeout guarding the operation reserved right before
    /// it, mirroring `Ring.pushTimeoutForOp`. It must be pushed in the same
    /// window as the operation it guards: the kernel only establishes the link
    /// while assembling a single submission, otherwise it fails with `-EINVAL`.
    pub inline fn pushTimeoutForOp(
        self: *Self,
        timespecPtr: *const linux.kernel_timespec,
        taskIdx: u64,
        flags: TaskFlags,
    ) ?void {
        const sqe = self.reserve() orelse return null;

        sqe.opcode = linux.IORING_OP.LINK_TIMEOUT;
        sqe.fd = -1;
        sqe.addr = @intFromPtr(timespecPtr);
        sqe.len = 1;
        sqe.rw_flags = linux.IORING_TIMEOUT_ETIME_SUCCESS;
        sqe.user_data = taskIdx;
        sqe.flags = flags.flags();
    }

    /// Publishes every SQE pushed so far by atomically moving the ring's tail,
    /// nudges the kernel poller so it observes the new entries, and then
    /// re-reads the ring's live head and tail so the window slides forward for
    /// the next round. The handle stays valid and reusable across commits.
    pub fn commit(self: *Self) !void {
        const ring = self.ring;

        @atomicStore(u32, ring.sqTail, self.tail, .release);

        var sig: linux.sigset_t = undefined;
        const res = linux.io_uring_enter(
            ring.fd,
            1,
            0,
            linux.IORING_ENTER_SQ_WAKEUP,
            &sig,
        );

        const err = linux.errno(res);
        if (err != .SUCCESS) {
            return posix.unexpectedErrno(err);
        }

        self.head = @atomicLoad(u32, ring.sqHead, .acquire);
        self.tail = ring.sqTail.*;
    }
};

/// A batched view over the completion queue, created by `Ring.batchedCQ`.
///
/// Completions are read through it into a local cursor without moving the
/// ring's consumed head, so the kernel keeps treating them as unconsumed until
/// `commit` publishes the advanced head with a single wakeup. Each `popCQE`
/// returns null once the window is exhausted, i.e. as soon as it reaches the
/// tail captured when the batch was opened.
pub const BatchCQ = struct {
    const Self = @This();

    /// The ring this batch belongs to.
    ring: *Ring,
    /// CQ consumer cursor. It starts at the head captured when the batch was
    /// opened and advances with every popped completion.
    head: u32,
    /// CQ tail captured when the batch was opened: the upper bound of the
    /// completions visible to this batch.
    tail: u32,

    /// Reads the next completion visible to this batch and advances the local
    /// consumer cursor. The ring's head is left untouched until `commit`.
    /// Returns null once the captured tail is reached.
    pub inline fn popCQE(self: *Self) ?CQE {
        if (self.head == self.tail) {
            return null;
        }

        const ring = self.ring;
        const cqeIdx = self.head & ring.cqMask;

        // Advance the batch cursor only; the ring head stays put until commit.
        self.head +%= 1;

        return ring.cqEntries[cqeIdx];
    }

    /// Publishes every popped completion by atomically moving the ring's
    /// consumed head to the batch cursor, then nudges the kernel poller so it
    /// notices the freed completion slots.
    pub fn commit(self: *Self) !void {
        const ring = self.ring;

        @atomicStore(u32, ring.cqHead, self.head, .release);

        var sig: linux.sigset_t = undefined;
        const res = linux.io_uring_enter(
            ring.fd,
            0,
            0,
            linux.IORING_ENTER_SQ_WAKEUP,
            &sig,
        );

        const err = linux.errno(res);
        if (err == .SUCCESS) {
            return;
        }

        return posix.unexpectedErrno(err);
    }
};

pub const ReorderBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    buf: []u8, // data: mod * itemSize
    nexts: []i32, // nexts[i] = next node in the list
    prevs: []i32, // prevs[i] = previous node in the list

    size: u64, // window N
    mod: u64, // 2N
    itemSize: usize,

    wave: u64, // expected seqIdx
    first: i32, // head of the list
    last: i32, // tail of the list

    /// Creates a reorder buffer that holds up to `size` in-flight items of
    /// `itemSize` bytes each.
    ///
    /// `size` is the reorder window: an item may arrive at most `size - 1`
    /// positions ahead of the next expected sequence index, otherwise `push`
    /// returns `error.FramesAreTooFarAway`. It must be a power of two and no
    /// more than 0xFFFF, else `error.ReorderBufferSizeMustBeAPowOf2` or
    /// `error.ReorderBufferNoMoreThan32KibItems` is returned. The backing
    /// storage is `2 * size` slots, one ring length of headroom.
    ///
    /// The caller owns the returned value and must call `deinit` to release the
    /// item buffer and the two link arrays.
    pub fn init(allocator: std.mem.Allocator, size: usize, itemSize: usize) !Self {
        if (@popCount(size) != 1) {
            return error.ReorderBufferSizeMustBeAPowOf2;
        }
        if (size > 0xFFFF) {
            return error.ReorderBufferNoMoreThan32KibItems;
        }

        const mod = 2 * size;
        const buf = try allocator.alloc(u8, mod * itemSize);
        errdefer allocator.free(buf);

        const nexts = try allocator.alloc(i32, mod);
        errdefer allocator.free(nexts);

        const prevs = try allocator.alloc(i32, mod);
        errdefer allocator.free(prevs);

        @memset(nexts, -1);
        @memset(prevs, -1);

        return Self{
            .allocator = allocator,
            .buf = buf,
            .nexts = nexts,
            .prevs = prevs,
            .size = size,
            .mod = mod,
            .itemSize = itemSize,
            .wave = 0,
            .first = -1,
            .last = -1,
        };
    }

    /// Releases the item buffer and the two link arrays allocated by `init`,
    /// using the same allocator.
    ///
    /// After this the buffer is invalid and must not be used again. Every slice
    /// previously returned by `popHeadCond`/`peekHeadCond` dangles.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buf);
        self.allocator.free(self.nexts);
        self.allocator.free(self.prevs);
    }

    /// Inserts the item in `data`, tagged with the absolute sequence index
    /// `idx`, into the buffer while keeping pending items ordered by index.
    ///
    /// `data.len` must equal the `itemSize` given to `init`. An index below the
    /// current wave is rejected with `error.OutdatedFrame`, and one `size` or
    /// more ahead with `error.FramesAreTooFarAway`. The bytes are copied in, so
    /// `data` remains owned by the caller.
    ///
    /// When `idx` equals the wave the wave advances across every consecutive
    /// item already buffered, so those items become available to
    /// `popHeadCond`/`peekHeadCond` without further pushes.
    pub fn push(self: *Self, idx: u64, data: []const u8) !void {
        const mod: i32 = @truncate(@as(i64, @bitCast(self.mod)));

        // Ignore duplicates and outdated frames
        if (idx < self.wave) {
            @branchHint(.cold);
            return error.OutdatedFrame;
        }

        // A gap larger than the window is a fatal error
        const distFromWave = idx - self.wave;

        if (distFromWave >= self.size) {
            @branchHint(.cold);
            return error.FramesAreTooFarAway;
        }

        const relIdx: i32 = @intCast(idx & (self.mod - 1));

        // Write the data
        const offset = @as(usize, @intCast(idx & (self.mod - 1))) * self.itemSize;
        @memcpy(self.buf[offset .. offset + self.itemSize], data);

        // First element in the list
        if (self.last < 0) {
            @branchHint(.cold);
            self.first = relIdx;
            self.last = relIdx;
            self.nexts[@intCast(relIdx)] = -1;
            self.prevs[@intCast(relIdx)] = -1;

            if (self.wave == idx) {
                @branchHint(.likely);
                self.wave += 1;
            }

            return;
        }

        // Fast path: insert after the tail
        const distFromLast = (relIdx - self.last) & (mod - 1);
        if (distFromLast < @as(i32, @intCast(self.size))) {
            @branchHint(.likely);

            self.nexts[@intCast(self.last)] = relIdx;
            self.prevs[@intCast(relIdx)] = self.last;
            self.nexts[@intCast(relIdx)] = -1;
            self.last = relIdx;

            if (self.wave == idx) {
                @branchHint(.likely);
                self.wave += 1;
            }

            return;
        }

        // Slow path: find the insertion point by moving backward from the tail
        var cur: i32 = self.last;
        while (cur >= 0) {
            const distFromCur = (relIdx - cur) & (mod - 1);
            // If the new element is "behind" cur (distance >= size), move backward
            if (distFromCur >= @as(i32, @intCast(self.size))) {
                @branchHint(.likely);

                cur = self.prevs[@intCast(cur)];
                continue;
            }

            break;
        }

        if (cur < 0) {
            @branchHint(.cold);
            // Insert at the head
            self.nexts[@intCast(relIdx)] = self.first;
            self.prevs[@intCast(relIdx)] = -1;
            self.prevs[@intCast(self.first)] = relIdx;
            self.first = relIdx;
            self.advanceWave(idx);
            return;
        }

        // Insert after cur
        const nextNode = self.nexts[@intCast(cur)];
        self.nexts[@intCast(cur)] = relIdx;
        self.prevs[@intCast(relIdx)] = cur;
        self.nexts[@intCast(relIdx)] = nextNode;
        self.prevs[@intCast(nextNode)] = relIdx;
        self.advanceWave(idx);
    }

    /// Advances the wave, skipping existing consecutive frames, when idx == s.wave.
    inline fn advanceWave(self: *Self, idx: u64) void {
        var frontIdx: i32 = @intCast(idx & (self.mod - 1));

        if (self.wave != idx) {
            return;
        }

        while (true) {
            const nextIdx = self.nexts[@as(usize, @bitCast(@as(i64, frontIdx)))];
            if (nextIdx -% frontIdx != 1) {
                return;
            }

            self.wave += 1;
            frontIdx = nextIdx;
        }
    }

    /// Removes and returns the head item only if its sequence index equals
    /// `idx`, otherwise returns null and leaves the buffer untouched.
    ///
    /// The returned slice is a borrowed view into the buffer: it stays valid
    /// until a later `push` reuses its slot, and is not owned by the caller.
    /// Use `peekHeadCond` plus `dropHead` instead when a failed operation should
    /// be retried without consuming the frame.
    pub fn popHeadCond(self: *Self, idx: u64) ?[]u8 {
        const relIdx: i32 = @intCast(idx & (self.mod - 1));

        if (self.first != relIdx) {
            return null;
        }

        const offset = @as(usize, @intCast(idx & (self.mod - 1))) * self.itemSize;
        const res = self.buf[offset .. offset + self.itemSize];

        const second = self.nexts[@bitCast(@as(i64, relIdx))];
        if (second < 0) {
            self.first = -1;
            self.last = -1;
            return res;
        }

        self.prevs[@bitCast(@as(i64, second))] = -1;
        self.first = second;
        return res;
    }

    /// Returns the head element only if its idx matches, WITHOUT removing it.
    /// The element stays in the buffer until `dropHead` is called, so callers
    /// can safely retry a failed operation without losing the frame.
    pub fn peekHeadCond(self: *Self, idx: u64) ?[]u8 {
        const relIdx: i32 = @intCast(idx & (self.mod - 1));

        if (self.first != relIdx) {
            return null;
        }

        const offset = @as(usize, @intCast(idx & (self.mod - 1))) * self.itemSize;
        return self.buf[offset .. offset + self.itemSize];
    }

    /// Removes the current head item without returning it, advancing the head
    /// to the next buffered item.
    ///
    /// Meant to be paired with `peekHeadCond` once the peeked item has been
    /// processed successfully; it is a no-op when the buffer is empty.
    pub fn dropHead(self: *Self) void {
        if (self.first < 0) {
            return;
        }

        const second = self.nexts[@bitCast(@as(i64, self.first))];
        if (second < 0) {
            self.first = -1;
            self.last = -1;
            return;
        }

        self.prevs[@bitCast(@as(i64, second))] = -1;
        self.first = second;
    }
};
