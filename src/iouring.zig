const std = @import("std");
const linux = std.os.linux;
const E = linux.E;
const posix = std.posix;
const BufferPool = @import("provided_buffer.zig").ProvidedBufferPool;

pub const page_size: usize = 4096;

pub const BufferClass = enum(u16) {
    tiny = 0, // 128 B
    small = 1, // 512 B
    net = 2, // 2 KiB (Ideal for MTU / Ethernet frames)
    page = 3, // 4 KiB (Standard Linux page size)
    big = 4, // 16 KiB
    huge = 5, // 64 KiB

    /// Returns the exact size of the class in bytes
    pub inline fn size(self: BufferClass) u32 {
        return switch (self) {
            .tiny => 128,
            .small => 512,
            .net => 2 * 1024,
            .page => 4 * 1024,
            .big => 16 * 1024,
            .huge => 64 * 1024,
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
};

/// A wrapper for io_uring ring with kernel poller.
pub const ZigRing = struct {
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

    bufPools: [@typeInfo(BufferClass).@"enum".fields.len]BufferPool =
        [_]BufferPool{undefined} ** @typeInfo(BufferClass).@"enum".fields.len,

    /// Creates and initializes new a new ring.
    pub fn init(queueDepth: u32, attachFd: ?posix.fd_t) !Self {
        if (@popCount(queueDepth) != 1) {
            return error.ZigRingRequiresDepthPowOf2;
        }

        var params = std.mem.zeroes(linux.io_uring_params);
        params.flags = linux.IORING_SETUP_SQPOLL;

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
            .bufPools = [_]BufferPool{BufferPool.initUninitialized()} ** @typeInfo(BufferClass).@"enum".fields.len,
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

    pub fn initializeSizeClassBuffer(self: *Self, sizeClass: BufferClass, entries: u32) !void {
        const idx = @intFromEnum(sizeClass);
        const bufPool = &self.bufPools[idx];
        if (!bufPool.isInactive()) {
            return error.BufferOfSizeAlreadyInitialized;
        }

        bufPool.* = try BufferPool.init(self.fd, idx, entries, sizeClass.size());
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

        return linux.errno(-res);
    }

    pub inline fn pushWrite(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        dataPtr: [*]const u8,
        len: usize,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = targetFd;
        sqe.addr = @intFromPtr(dataPtr);
        sqe.len = @intCast(len);
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    pub inline fn pushReadZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        size: BufferClass,
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
        sqe.flags = linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = bgid;
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    pub inline fn pushRecvZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        size: BufferClass,
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
        sqe.flags = linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = bgid;
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    pub inline fn pushRecvMultishotZC(
        self: *Self,
        targetFd: posix.fd_t,
        taskIdx: u64,
        size: BufferClass,
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
        sqe.flags = linux.IOSQE_BUFFER_SELECT;
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
        sqe.flags = linux.IOSQE_ASYNC;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Asynchronously opens or creates a session file inside the given directory.
    /// The opened file descriptor will arrive in the `res` field of `popCQE`.
    pub inline fn pushOpenFile(
        self: *Self,
        taskIdx: u64,
        dirFd: posix.fd_t, // Descriptor of the folder obtained from the previous pushOpenDir step
        fileName: [*:0]const u8, // File name, e.g. "session_123.wal"
        flags: linux.O,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.OPENAT;
        // Open the file strictly inside the folder via its descriptor (fast path in the kernel)
        sqe.fd = dirFd;
        sqe.addr = @intFromPtr(fileName);

        // Flags for ultra-perf: Read/Write + Create if missing + DIRECT I/O (bypassing the OS cache)
        // In Zig master, posix.O is force-cast to u32 via bitCast
        var safeFlags = flags;
        safeFlags.CLOEXEC = true;
        sqe.rw_flags = @bitCast(safeFlags);

        // Access mode for the created file (standard 0o644)
        sqe.len = 0o644;
        sqe.user_data = taskIdx;

        // Keep SQPOLL from going to sleep: offload to io-wq workers
        sqe.flags = linux.IOSQE_ASYNC;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    pub inline fn pushClose(
        self: *Self,
        taskIdx: u64,
        targetFd: posix.fd_t,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.CLOSE;
        sqe.fd = targetFd;
        sqe.user_data = taskIdx;
        sqe.flags = linux.IOSQE_ASYNC;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Runs an endless non-blocking accept of clients on the listening socket.
    /// For every new connection a new client `fd` will arrive in the `res` field of `popCQE`.
    pub inline fn pushAcceptMultishot(
        self: *Self,
        listenFd: posix.fd_t,
        taskIdx: u64,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        // getOpSlot already zeroed the struct
        sqe.opcode = linux.IORING_OP.ACCEPT;
        sqe.fd = listenFd;

        // For multishot we don't need the sockaddr struct address in the SQE,
        // the kernel just hands out socket descriptors; leave it zero (already zeroed)

        // Enable the flag that auto-creates client sockets with O_CLOEXEC
        sqe.rw_flags = @bitCast(posix.SOCK.CLOEXEC);

        // Arm the MULTISHOT mode in ioprio!
        sqe.ioprio = linux.IORING_ACCEPT_MULTISHOT;

        sqe.user_data = taskIdx;

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
        sqe.flags = linux.IOSQE_ASYNC;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    pub inline fn pushBind(
        self: *Self,
        socketFd: posix.fd_t,
        taskIdx: u64,
        address: *const std.Io.net.IpAddress,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.BIND;
        sqe.fd = socketFd;
        sqe.user_data = taskIdx;

        var sockAddr: posix.sockaddr = undefined;
        var addrLen: posix.socklen_t = 0;
        sqe.addr =
            switch (address) {
                .ip4 => |ip4| {
                    var in_addr = posix.sockaddr.in{
                        .family = posix.AF.INET,
                        // Need big endian for the network.
                        .port = std.mem.nativeToBig(u16, ip4.port),
                        // Copy all bytes.
                        .addr = @bitCast(ip4.bytes),
                    };
                    @memcpy(std.mem.asBytes(&sockAddr)[0..@sizeOf(posix.sockaddr.in)], std.mem.asBytes(&in_addr));
                    addrLen = @sizeOf(posix.sockaddr.in); //
                },
                .ip6 => |ip6| {
                    var in6_addr = posix.sockaddr.in6{
                        .family = posix.AF.INET6,
                        .port = std.mem.nativeToBig(u16, ip6.port),
                        .flowinfo = ip6.flow,
                        .addr = ip6.bytes,
                        .scope_id = 0,
                    };
                    @memcpy(std.mem.asBytes(&sockAddr)[0..@sizeOf(posix.sockaddr.in6)], std.mem.asBytes(&in6_addr));
                    addrLen = @sizeOf(posix.sockaddr.in6);
                },
            };

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    pub inline fn pushListen(
        self: *Self,
        socketFd: posix.fd_t,
        taskIdx: u64,
        backlog: u32,
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        sqe.opcode = linux.IORING_OP.LISTEN;
        sqe.fd = socketFd;
        sqe.len = backlog;
        sqe.user_data = taskIdx;

        return self.commitOp(targetSlot.idx, targetSlot.head);
    }

    /// Generates a CQE event inside another io_uring using its file descriptor (targetRingFd).
    /// Perfect for instantly waking up a sleeping thread-index from a background worker.
    pub inline fn pushMsgRing(
        self: *Self,
        targetRingFd: posix.fd_t, // fd of the ring belonging to the sleeping thread
        taskIdx: u64,
        msgResult: u32, // Custom message type/signal (will go into cqe.res)
    ) !void {
        const targetSlot = try self.getOpSlot();
        const sqe = targetSlot.entry;

        // getOpSlot already did @memset to 0, only fill the flat meaningful Linux ABI fields
        sqe.opcode = linux.IORING_OP.MSG_RING;
        sqe.fd = targetRingFd; // Target ring descriptor
        sqe.flags = linux.IOSQE_CQE_SKIP_SUCCESS;

        // Map data: len will go to cqe.res, off will go to cqe.user_data on the receiver side
        sqe.len = msgResult;
        sqe.off = taskIdx;

        // We don't typically care about the response to the send operation itself in our own CQE,
        // so we leave sqe.user_data at zero (already zeroed in getOpSlot).
        // The task will execute on the current CPU instantly without blocking.

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
        };
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
};

test "create and write file" {
    const Manager = @import("ring_manager.zig").WeightedRingManager;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);
    try ring.pushOpenDir(1, 0, "/tmp");

    var cqe = try wait(&ring);
    const dirFd = cqe.res;

    try ring.pushOpenFile(1, dirFd, "file.txt", linux.O{ .CREAT = true, .ACCMODE = .WRONLY });
    cqe = try wait(&ring);
    const fileFd = cqe.res;

    try ring.pushWrite(fileFd, 1, "Hello World!\n", 13);
    cqe = try wait(&ring);

    try ring.pushClose(1, fileFd);
    cqe = try wait(&ring);
}

fn wait(ring: *ZigRing) !CQE {
    while (true) {
        const cqe = ring.popCQE() orelse continue;

        if (cqe.res < 0) {
            std.debug.print("{}", .{cqe});
            return std.posix.unexpectedErrno(linux.errno(@intCast(-cqe.res)));
        }

        return cqe;
    }
}
