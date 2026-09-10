const std = @import("std");
const linux = std.os.linux;
const E = linux.E;
const posix = std.posix;
const BufferPool = @import("provided_buffer.zig").ProvidedBufferPool;

pub const page_size: usize = 4096;
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

/// CQE is a type returned by popCQE method.
pub const CQE = struct {
    taskIdx: u64,
    res: i32,
    bid: u16,
    hasBuffer: bool,
    hasMore: bool,
    hasNotif: bool,

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

/// A wrapper for io_uring ring with kernel poller.
pub const Ring = struct {
    const Self = @This(); // Exact type mapping verified

    fd: posix.fd_t,
    flags: u32,

    sqMmapPtr: []align(page_size) u8,
    cqMmapPtr: []align(4096) u8, // Using literal page_size alignment
    sqesMapPtr: []align(page_size) u8,

    sqHead: *u32,
    sqTail: *u32,
    sqMask: u32,
    sqArray: [*]u32,
    sqEntries: [*]linux.io_uring_sqe,

    cqHead: *u32,
    cqTail: *u32,
    cqMask: u32,
    cqEntries: [*]linux.io_uring_cqe,

    bufPools: [@typeInfo(BufferSizeClass).@"enum".fields.len]BufferPool =
        [_]BufferPool{undefined} ** @typeInfo(BufferSizeClass).@"enum".fields.len,

    /// Creates and initializes a new ring.
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

        const cqLen = params.cq_off.cqes + (params.cq_entries * @sizeOf(linux.io_uring_cqe));
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

    pub fn deinit(self: *Self) void {
        posix.munmap(self.sqMmapPtr);
        posix.munmap(self.sqesMapPtr);
        posix.munmap(self.cqMmapPtr);
        _ = linux.close(self.fd);
        for (&self.bufPools) |*pool| {
            pool.deinit();
        }
    }

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

    /// Allocates an area of `entries` buffers of the given size class on huge
    /// pages (with a regular-page fallback), registers it into io_uring and
    /// returns the backing memory as a flat, page-aligned []u8.
    ///
    /// The returned slice is an mmap mapping, so release it with posix.munmap.
    /// Its length is rounded up to the mmap page size (2 MiB when huge pages
    /// are available), which may exceed sizeClass.size() * entries. Only the
    /// first sizeClass.size() * entries bytes are used as buffers.
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
            const regularSize = std.mem.alignForward(usize, rawSize, page_size);
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
    /// until the matching completion with `CQE.hasNotif` set arrives.
    ///
    /// A successful request produces two completions: the first carries the
    /// number of bytes queued (`CQE.hasMore` is set), the second is the
    /// notification that frees the buffer for reuse (`CQE.hasNotif` is set).
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

    /// Asynchronously opens a directory relative to the base folder (with the O_PATH flag).
    /// A valid folder `fd` will arrive in the `res` field of `popCQE`.
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

    /// Asynchronously opens or creates a session file inside the given directory.
    /// The opened file descriptor will arrive in the `res` field of `popCQE`.
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

    /// Runs an endless non-blocking accept of clients on the listening socket.
    /// For every new connection a new client `fd` will arrive in the `res` field of `popCQE`.
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

    /// Run accept to catch incoming connections.
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

    /// Asynchronously and atomically renames a session file inside the base directory.
    /// Guarantees log integrity across power failures.
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

    /// Generates a CQE event inside another io_uring using its file descriptor (targetRingFd).
    /// Perfect for instantly waking up a sleeping thread-index from a background worker.
    pub inline fn pushMsgRing(
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

    /// Asynchronous timer. The thread will wake up and produce a CQE
    /// when the specified time has elapsed (seconds + nanoseconds).
    /// timespecPtr must remain valid in memory while the timer is ticking!
    /// Beware, you should be really careful with skipSuccess in flags,
    /// since it will lead to timespecPtr leak if it is not static.
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

    /// Attaches a timeout to the previously submitted operation in the chain.
    /// If the previous operation does not complete within timespecPtr, it will be canceled.
    /// timespecPtr must remain valid in memory while the timer is ticking!
    /// Beware, you should be really careful with skipSuccess in flags,
    /// since it will lead to timespecPtr leak if it is not static.
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

        // For linked timeouts, len must always be set to 0
        sqe.len = 0;

        // Timer flags: using ETIME_SUCCESS so that a regular timeout is treated normally.
        // rw_flags maps directly to timeout_flags in the flat SQE structure.
        sqe.rw_flags = linux.IORING_TIMEOUT_ETIME_SUCCESS;
        sqe.flags = flags.flags();

        // Use the global constant for the timer instead of a custom taskIdx
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    pub inline fn popCQE(self: *Self) ?CQE {
        const head = self.cqHead.*;
        const tail = @atomicLoad(u32, self.cqTail, .acquire);

        if (head == tail) return null;

        const cqeIdx = head & self.cqMask;
        const cqe = &self.cqEntries[cqeIdx];

        const taskIdx = cqe.user_data;
        const outRes = cqe.res;
        const flags = cqe.flags;

        // Bit 0 (1 << 0): the kernel selected a provided buffer from our pool
        const hasBuffer = (flags & 1) != 0;

        // Bit 1 (1 << 1): IORING_CQE_F_MORE. Multishot is active, the kernel will keep sending CQEs
        const hasMore = (flags & 2) != 0;

        // Bit 3 (1 << 3): IORING_CQE_F_NOTIF. This is the second CQE of a
        // SEND_ZC request; it signals that the registered buffer may be reused.
        const hasNotif = (flags & 8) != 0;

        // Extract the Buffer ID from the upper 16 bits of the flags field (shift right by 16)
        const bid = @as(u16, @intCast(flags >> 16));

        // Advance the ring head one at a time with .release semantics
        @atomicStore(u32, self.cqHead, head +% 1, .release);

        return CQE{
            .taskIdx = taskIdx,
            .res = outRes,
            .bid = bid,
            .hasBuffer = hasBuffer,
            .hasMore = hasMore,
            .hasNotif = hasNotif,
        };
    }

    /// Opens a batched consumption window over the CQ. It snapshots the current
    /// CQ head and tail and hands back a `BatchedCQ` that reads completions
    /// without publishing the consumed head, so many completions can be drained
    /// and flushed with a single `io_uring_enter` on `commit`. Returns null when
    /// there is nothing to consume, i.e. as soon as the head reaches the tail.
    pub inline fn batchedCQ(self: *Self) ?BatchCQ {
        const head = self.cqHead.*;
        const tail = @atomicLoad(u32, self.cqTail, .acquire);

        if (head == tail) {
            return null;
        }

        return .{ .ring = self, .head = head, .tail = tail };
    }

    /// Puts the current thread-index to sleep until at least one CQE appears.
    /// Called on the "cold" path when both the CQ and the software queue are empty.
    pub fn park(self: *Self) void {
        // If SQPOLL is active in your MyUring, you need to add the IORING_ENTER_SQ_WAKEUP flag (1 << 1),
        // in case the kernel poller also fell asleep due to an idle timeout.
        // enter_flags |= 2;

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

    pub fn releaseBuffer(self: *Self, sizeClass: BufferSizeClass, bid: u16) void {
        self.bufPools[sizeClass.bgid()].releaseBuffer(bid);
    }

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
        const cqe = &ring.cqEntries[cqeIdx];

        const taskIdx = cqe.user_data;
        const outRes = cqe.res;
        const flags = cqe.flags;

        // Bit 0 (1 << 0): the kernel selected a provided buffer from our pool
        const hasBuffer = (flags & 1) != 0;

        // Bit 1 (1 << 1): IORING_CQE_F_MORE. Multishot is active, the kernel will keep sending CQEs
        const hasMore = (flags & 2) != 0;

        // Bit 3 (1 << 3): IORING_CQE_F_NOTIF. This is the second CQE of a
        // SEND_ZC request; it signals that the registered buffer may be reused.
        const hasNotif = (flags & 8) != 0;

        // Extract the Buffer ID from the upper 16 bits of the flags field (shift right by 16)
        const bid = @as(u16, @intCast(flags >> 16));

        // Advance the batch cursor only; the ring head stays put until commit.
        self.head +%= 1;

        return CQE{
            .taskIdx = taskIdx,
            .res = outRes,
            .bid = bid,
            .hasBuffer = hasBuffer,
            .hasMore = hasMore,
            .hasNotif = hasNotif,
        };
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
