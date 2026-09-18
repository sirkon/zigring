const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("iouring.zig").Ring;
const BufferSizeClass = @import("iouring.zig").BufferSizeClass;
const CQE = @import("iouring.zig").CQE;
const TaskFlags = @import("iouring.zig").TaskFlags;
const ReorderBuffer = @import("iouring.zig").ReorderBuffer;
const time = @import("time.zig");

const noOfRequests = 100_000;

var dbgClientCqe: usize = 0;
var dbgServerPush: usize = 0;
var dbgServerFail: usize = 0;

const echoPayload = struct {
    pub fn getSeqIdx(buf: []const u8) u64 {
        return std.mem.readInt(u64, buf[0..8], .native);
    }

    pub fn getGreet(buf: []const u8) []const u8 {
        return buf[8..13];
    }

    pub fn getNowNs(buf: []const u8) u64 {
        return std.mem.readInt(u64, buf[13..21], .native);
    }

    pub fn save(buf: []u8, seqId: u64, greet: []const u8, nowNs: u64) void {
        std.mem.writeInt(u64, buf[0..8], seqId, .native);
        @memcpy(buf[8..13], greet[0..5]);
        std.mem.writeInt(u64, buf[13..21], nowNs, .native);
    }
};

test echoPayload {
    var place: [21]u8 = undefined;
    const buf = place[0..21];

    echoPayload.save(buf, 20220221, "Hello", 333);
    try std.testing.expectEqual(20220221, echoPayload.getSeqIdx(buf));
    try std.testing.expectEqualStrings("Hello", echoPayload.getGreet(buf));
    try std.testing.expectEqual(333, echoPayload.getNowNs(buf));
}

const echoServerFSM = struct {
    const Self = @This();
    const recvIdx = std.math.maxInt(u64);
    const slotter = @import("slotter.zig");

    allocator: std.mem.Allocator,
    ring: *Ring,
    slots: *slotter.BufferSlots,
    placeholder: []u8,
    bufRest: []u8,
    critical: []u8,
    ordbuf: *ReorderBuffer,

    reqCount: u64,
    respCount: u64,
    state: enum {
        // We need to receive data.
        needRecv,
        // We need to send reply to the client.
        // We must retry an attempt to reply if it failed.
        needReply,
        // We need to check incoming data.
        needCheck,
    },
    limit: u64,

    clientFd: posix.fd_t,
    recvArmed: bool,

    fn init(
        allocator: std.mem.Allocator,
        ring: *Ring,
        slots: *slotter.BufferSlots,
        clientFd: posix.fd_t,
        ordbuf: *ReorderBuffer,
        limit: u64,
    ) !Self {
        return Self{
            .allocator = allocator,
            .ring = ring,
            .slots = slots,
            .placeholder = try allocator.alloc(u8, 1024),
            .bufRest = &[0]u8{},
            .critical = "",
            .ordbuf = ordbuf,
            .reqCount = 0,
            .respCount = 0,
            .state = .needRecv,
            .limit = limit,
            .clientFd = clientFd,
            .recvArmed = false,
        };
    }

    fn deinit(self: *Self) void {
        if (self.critical.len > 0) {
            self.allocator.free(self.critical);
        }
        self.allocator.free(self.placeholder);
    }

    fn do(self: *Self) !bool {
        if (self.reqCount == self.limit and self.state == .needRecv) {
            self.state = .needCheck;
        }

        switch (self.state) {
            .needRecv => {
                if (!self.recvArmed) {
                    self.ring.pushRecvZC(self.clientFd, recvIdx, .tiny, .{}) catch |err| {
                        if (err != error.RingFull) {
                            try self.setCritical("critical push error", .{});
                            return err;
                        }
                        self.state = .needCheck;
                        return false;
                    };
                    self.recvArmed = true;
                }

                self.state = .needCheck;
                return false;
            },

            .needReply => {
                const chunk = self.ordbuf.peekHeadCond(self.reqCount) orelse {
                    self.state = .needRecv;
                    return false;
                };

                const greet = echoPayload.getGreet(chunk);
                if (!std.mem.eql(u8, greet, "Hello")) {
                    try self.setCritical("invalid greet \"{s}\" != \"Hello\"", .{greet});
                    return error.InvalidGreet;
                }

                const now = time.nowNs();
                if (now < echoPayload.getNowNs(chunk)) {
                    try self.setCritical("client time is in the future", .{});
                    return error.InvalidClientTime;
                }

                const bufferIdx = self.slots.alloc() catch |err| {
                    try self.setCritical("failed to allocate a slot", .{});
                    return err;
                };

                var buffer = self.slots.get(bufferIdx) orelse {
                    try self.setCritical("invariant violation: buffer must exist as for now", .{});
                    return error.ReplyErrorMissingBuffer;
                };

                echoPayload.save(buffer, self.reqCount, "World", now);
                self.ring.pushSend(self.clientFd, bufferIdx, buffer[0..21], 21, .{}) catch |err| {
                    if (err == error.RingFull) {
                        self.slots.del(bufferIdx);
                        std.atomic.spinLoopHint();
                        return false;
                    }

                    try self.setCritical("unexpected push error", .{});
                    return err;
                };

                self.ordbuf.dropHead();
                self.reqCount += 1;
                self.state = .needCheck;
                return true;
            },

            .needCheck => {
                if (self.bufRest.len >= 21) {
                    const seqIdx = echoPayload.getSeqIdx(self.bufRest[0..21]);
                    self.ordbuf.push(seqIdx, self.bufRest[0..21]) catch |err| {
                        std.debug.panic("push data into the reorder buffer (wave={}, idx={}): {any}", .{ self.ordbuf.wave, seqIdx, err });
                    };
                    self.state = .needReply;
                    self.bufRest = self.bufRest[21..];
                    return true;
                }

                const cqe = self.ring.popCQE() orelse {
                    self.state = .needRecv;
                    return false;
                };

                if (cqe.res < 0) {
                    try self.setCritical("invalid CQE={} from {any}", .{ linux.errno(cqe.result()), cqe });
                    return error.CQEError;
                }

                if (cqe.taskIdx() != recvIdx) {
                    // This is a notification about reply.
                    self.respCount += 1;
                    self.state = .needRecv;
                    self.slots.del(cqe.taskIdx());
                    return true;
                }

                // This is a client request.
                const buffer = self.ring.buffer(.tiny, cqe.bid()) orelse {
                    try self.setCritical("size class .tiny is not initialized (CQE = {})", .{cqe});
                    return error.CQEBidError;
                };

                if (self.bufRest.len > 0) {
                    std.mem.copyForwards(u8, self.placeholder[0..self.bufRest.len], self.bufRest);
                }

                @memcpy(self.placeholder[self.bufRest.len .. self.bufRest.len + cqe.result()], buffer[0..cqe.result()]);
                self.bufRest = self.placeholder[0 .. self.bufRest.len + cqe.result()];
                self.ring.releaseBuffer(.tiny, cqe.bid());

                self.recvArmed = false;
                self.state = .needRecv;
                return true;
            },
        }
    }

    fn setCritical(self: *Self, comptime format: []const u8, args: anytype) !void {
        std.debug.print(
            \\ Server context:
            \\   current sequence idx: {}
            \\   responses commited: {}
            \\   state: {}
            \\ ---
            \\
        , .{ self.reqCount, self.respCount, self.state });
        self.critical = try std.fmt.allocPrint(self.allocator, format, args);
    }

    pub fn errMsg(self: *Self) []const u8 {
        return self.critical;
    }

    pub fn done(self: *Self) bool {
        return self.reqCount >= self.limit and self.respCount >= self.limit;
    }

    inline fn reqBody(self: *Self) []u8 {
        return self.bufRest[0..21];
    }
};

const echoClientFSM = struct {
    const Self = @This();
    const sendIdx = std.math.maxInt(u64);
    const slotter = @import("slotter.zig");

    allocator: std.mem.Allocator,
    ring: *Ring,
    slots: *slotter.BufferSlots,
    placeholder: []u8,
    bufRest: []u8,
    critical: []u8,
    reply: [21]u8,

    reqCount: u64,
    respCount: u64,
    state: enum {
        needSend,
        needCheck,
        needRecv,
    },
    limit: u64,

    serverFd: posix.fd_t,
    iterationCounter: usize = 0,
    lastRespCount: u64 = 0,
    recvArmed: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        ring: *Ring,
        slots: *slotter.BufferSlots,
        serverFd: posix.fd_t,
        limit: u64,
    ) !Self {
        return Self{
            .allocator = allocator,
            .ring = ring,
            .slots = slots,
            .placeholder = try allocator.alloc(u8, 1024),
            .bufRest = &[0]u8{},
            .critical = "",
            .reply = undefined,
            .reqCount = 0,
            .respCount = 0,
            .state = .needSend,
            .limit = limit,
            .serverFd = serverFd,
            .recvArmed = false,
        };
    }

    fn deinit(self: *Self) void {
        if (self.critical.len > 0) {
            self.allocator.free(self.critical);
        }
        self.allocator.free(self.placeholder);
    }

    fn do(self: *Self) !bool {
        if (self.respCount == self.limit and self.state == .needRecv) {
            self.state = .needCheck;
        }

        if (self.reqCount >= self.limit) {
            // Detect a genuine stall: only count iterations that make no
            // progress on received responses.
            if (self.respCount == self.lastRespCount) {
                self.iterationCounter += 1;
                if (self.iterationCounter >= 50_000_000) {
                    return error.LoopTooMuch;
                }
            } else {
                self.iterationCounter = 0;
                self.lastRespCount = self.respCount;
            }
        }

        switch (self.state) {
            .needSend => {
                if (self.reqCount >= self.limit) {
                    self.state = .needCheck;
                    return false;
                }

                const bufferIdx = self.slots.alloc() catch |err| {
                    try self.setCritical("failed to allocate a slot", .{});
                    return err;
                };

                var buffer = self.slots.get(bufferIdx) orelse {
                    try self.setCritical("invariant violation: buffer must exist as for now", .{});
                    return error.SendErrorMissingBuffer;
                };

                echoPayload.save(buffer[0..21], self.reqCount, "Hello", time.nowNs());

                self.ring.pushSend(self.serverFd, bufferIdx, buffer[0..21], 21, .{}) catch |err| {
                    if (err == error.RingFull) {
                        self.slots.del(bufferIdx);
                        std.atomic.spinLoopHint();
                        return false;
                    }

                    try self.setCritical("unexpected push error", .{});
                    return err;
                };

                self.reqCount += 1;
                self.state = .needRecv;
                return true;
            },

            .needCheck => {
                if (self.bufRest.len >= 21) {
                    const seqIdx = echoPayload.getSeqIdx(self.respBody());
                    if (seqIdx != self.respCount) {
                        try self.setCritical("got seqId = {}, wanted {} from {any}", .{ seqIdx, self.respCount, self.respBody() });
                        return error.ErrorUnexpectedSeqIdx;
                    }

                    const greet = echoPayload.getGreet(self.respBody());
                    if (!std.mem.eql(u8, greet, "World")) {
                        try self.setCritical("invalid greeting \"{s}\" from {any}", .{ greet, self.respBody() });
                        return error.ErrorInvalidGreet;
                    }

                    const now = time.nowNs();
                    const respNow = echoPayload.getNowNs(self.respBody());
                    if (respNow > now) {
                        try self.setCritical("server time is from the future ({} > {}) from {any}", .{ respNow, now, self.respBody() });
                        return error.ErrorInvalidTime;
                    }

                    self.bufRest = self.bufRest[21..];
                    self.respCount += 1;

                    self.state = .needSend;
                    return true;
                }

                const cqe = self.ring.popCQE() orelse {
                    // Do not send ahead: blasting requests without waiting for the
                    // previous send's completion floods the SQ and exhausts slots.
                    // Only make sure a receive is armed while we wait.
                    if (!self.recvArmed) {
                        self.state = .needRecv;
                    }
                    return false;
                };

                if (cqe.res < 0) {
                    try self.setCritical("invalid CQE={} from {any}", .{ linux.errno(cqe.result()), cqe });
                    return error.CQEError;
                }

                if (cqe.taskIdx() == sendIdx) {
                    // These are RECEIVED DATA from the server (CQE from pushRecvZC)
                    const buffer = self.ring.buffer(.tiny, cqe.bid()) orelse {
                        try self.setCritical("size class .tiny is not initialized (CQE = {})", .{cqe});
                        return error.CQEBidError;
                    };

                    // Copy the data from the provided buffer into the placeholder
                    if (self.bufRest.len > 0) {
                        std.mem.copyForwards(u8, self.placeholder[0..self.bufRest.len], self.bufRest);
                    }
                    @memcpy(self.placeholder[self.bufRest.len .. self.bufRest.len + cqe.result()], buffer[0..cqe.result()]);
                    self.bufRest = self.placeholder[0 .. self.bufRest.len + cqe.result()];

                    self.ring.releaseBuffer(.tiny, cqe.bid());

                    self.recvArmed = false;
                    self.state = .needCheck;
                    return true;
                }

                self.slots.del(cqe.taskIdx());

                if (self.reqCount < self.limit) {
                    self.state = .needSend;
                } else {
                    self.state = .needRecv;
                }
                return true;
            },

            .needRecv => {
                if (!self.recvArmed) {
                    self.ring.pushRecvZC(self.serverFd, sendIdx, .tiny, .{}) catch |err| {
                        if (err != error.RingFull) {
                            try self.setCritical("critical push error", .{});
                            return err;
                        }
                        self.state = .needCheck;
                        return false;
                    };
                    self.recvArmed = true;
                }

                self.state = .needCheck;
                return false;
            },
        }
    }

    fn setCritical(self: *Self, comptime format: []const u8, args: anytype) !void {
        std.debug.print(
            \\ Client context:
            \\   current sequence idx: {}
            \\   responses commited: {}
            \\   state: {}
            \\ ---
            \\
        , .{ self.reqCount, self.respCount, self.state });
        self.critical = try std.fmt.allocPrint(self.allocator, format, args);
    }

    pub fn errMsg(self: *Self) []const u8 {
        return self.critical;
    }

    pub fn done(self: *Self) bool {
        return self.reqCount >= self.limit and self.respCount >= self.limit;
    }

    inline fn respBody(self: *Self) []u8 {
        return self.bufRest[0..21];
    }
};

fn wait(ring: *Ring) !CQE {
    while (true) {
        const cqe = ring.popCQE() orelse continue;
        if (cqe.res < 0) {
            std.debug.print("got cqe with error: {}\n", .{cqe});
            return posix.UnexpectedError.Unexpected;
        }

        return cqe;
    }
}

fn waitNoMatterWhat(ring: *Ring) CQE {
    while (true) {
        const cqe = ring.popCQE() orelse continue;
        return cqe;
    }
}

fn waitPeacefully(ring: *Ring) CQE {
    var attempts: usize = 0;
    const attemptsLimit = 100_000;
    while (true) {
        const res = ring.popCQE() orelse {
            attempts += 1;
            if (attempts == attemptsLimit) {
                attempts = 0;
                ring.park();
                continue;
            }

            std.atomic.spinLoopHint();
            continue;
        };

        return res;
    }
}

fn getAcceptedConn(ring: *Ring, sock: posix.fd_t) !posix.fd_t {
    mainLoop: while (true) {
        try ring.pushAccept(sock, 2, TaskFlags.expectNext());
        while (true) {
            const cqe = waitNoMatterWhat(ring);
            if (cqe.taskIdx() != 2) {
                return error.UnexpectedIOUringTask;
            }

            if (cqe.res > 0) {
                return @as(posix.fd_t, cqe.res);
            }
            if (cqe.res == 0) {
                return error.UnexpectedZeroRes;
            }

            const res: usize = @bitCast(@as(i64, cqe.res));
            if (linux.errno(res) == linux.E.AGAIN) {
                std.atomic.spinLoopHint();
                continue :mainLoop;
            }

            return posix.unexpectedErrno(linux.errno(res));
        }
    }
}

test "reorder buffer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    {
        // Write-delete-write-delete.
        var ordbuf = try ReorderBuffer.init(arena.allocator(), 128, 1);
        defer ordbuf.deinit();
        for (0..1000) |i| {
            const buf = [1]u8{@truncate(i)};
            try ordbuf.push(i, buf[0..1]);

            const res = ordbuf.popHeadCond(i) orelse {
                std.debug.panic("expected buffer, got null", .{});
            };

            try std.testing.expectEqualSlices(u8, buf[0..1], res);
        }
    }

    {
        // Write 1-2, add 0, write 4-5, add 3. And so on for a while.
        var ordbuf = try ReorderBuffer.init(arena.allocator(), 128, 1);
        defer ordbuf.deinit();
        for (0..15) |i| {
            const tasks = [3]u64{
                i * 3 + 1,
                i * 3 + 2,
                i * 3,
            };
            for (tasks) |value| {
                const buf = [1]u8{@truncate(value)};
                try ordbuf.push(value, buf[0..1]);
            }
        }

        for (0..15 * 3) |index| {
            if (ordbuf.popHeadCond(index + 1) != null) {
                std.debug.panic("unexpected element from the head", .{});
            }

            const res = ordbuf.popHeadCond(index) orelse {
                std.debug.panic("missing expected element {} in the head", .{index});
            };

            if (ordbuf.popHeadCond(index) != null) {
                std.debug.panic("unexpected element from the head", .{});
            }

            const ref = [1]u8{@truncate(index)};
            try std.testing.expectEqualSlices(u8, ref[0..1], res[0..1]);
        }

        if (ordbuf.popHeadCond(15 * 3) != null) {
            std.debug.panic("unexpected element from the head", .{});
        }
    }
}

/// Accepts any fallible expression (Inferred Error Union).
/// If there is an error, panics with the error name. Otherwise returns the clean value.
inline fn must(what: []const u8, result: anytype) @TypeOf(if (@typeInfo(@TypeOf(result)) == .error_union) (result catch unreachable) else result) {
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        return result catch |err| {
            @branchHint(.cold);
            std.debug.panic("{s}: MUST violation - unexpected error.{any}", .{ what, err });
        };
    }
    return result;
}

test "echo server and client" {
    // In this test we send
    //   || sequence_idx: u64 | "Hello" | client_now_ns: i64 ||
    // to the server in multiplex in a string sequence, i.e. each request must wait until the CQ of the
    // previous is successfully completed. There should be 100k such requests.
    //
    // Meanwhile, the server must read each and reply with
    //   || copied_sequence_idx: u64 | "World" | server_now_ns: i64 ||
    // in a string sequence again.
    //
    // The server must check client_now_ns is not greater than its own now_ns.
    // Similarly, client must check the responses against its time again.
    // Both should check the payload's sequence_idx grows as 0, 1, 2, ..., 99999.

    const Manager = @import("ring_factory.zig").Factory;
    const slotter = @import("slotter.zig");
    const pthread = @import("pthread.zig");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // Two independent SQPOLL threads: one for the server ring, one for the
    // client ring. Sharing a single poller serializes both ends of the
    // connection on one CPU-bound kernel thread and roughly doubles the
    // round-trip time.
    var mgr = try Manager.init(arena.allocator(), 2);
    var barrier = pthread.Mutex.init();

    const SharedState = struct {
        mgr: *Manager,
        barrier: *pthread.Mutex,
    };

    var sharedState = SharedState{
        .mgr = &mgr,
        .barrier = &barrier,
    };
    const serverWorker = struct {
        fn run(state: *SharedState) void {
            // pthread.Thread.setSelfAffinity(2) catch |err| {
            //     std.debug.panic("failed to bind server thread to P-core 2: {any}\n", .{err});
            // };

            var ring: Ring = must("create server ring", state.mgr.acquireRing(4096, 1));
            defer ring.deinit();
            must("create proved buffer", ring.regiterSizeClassReceiveBuffer(.tiny, 16384));
            var serverArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            var slots: slotter.BufferSlots = must("create buffer slots", slotter.BufferSlots.init(serverArena.allocator(), 16384, 32, 4));
            var ordbuf = must("create reorder buffer", ReorderBuffer.init(serverArena.allocator(), 128, 21));

            // Create socket, bind it and start listening.
            const sockets = @import("sockets.zig");
            const sockFd = must("create socket server", sockets.createTCPServerSocket());
            defer _ = linux.close(sockFd);

            must("bind server socket to the address", ring.pushBindIp4(sockFd, 1, "0.0.0.0", 60006, .{}));
            _ = must("wait for the bind approval", wait(&ring));

            must("start listening", ring.pushListen(sockFd, 1, 1, .{}));
            _ = must("wait for the listening approval", wait(&ring));
            state.barrier.unlock();

            // Push accepts until there's a client.
            const clientFd = must("wait and accept the client", getAcceptedConn(&ring, sockFd));

            var fsm = must("create server fsm", echoServerFSM.init(serverArena.allocator(), &ring, &slots, clientFd, &ordbuf, noOfRequests));
            defer fsm.deinit();

            while (!fsm.done()) {
                const didWork = fsm.do() catch |err| {
                    std.debug.panic("server critical error={any}: {s}", .{ err, fsm.errMsg() });
                };
                if (!didWork) {
                    ring.park();
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;

    const clientWorker = struct {
        fn run(state: *SharedState) void {
            // pthread.Thread.setSelfAffinity(4) catch |err| {
            //     std.debug.panic("failed to bind server thread to P-core 4: {any}\n", .{err});
            // };

            // Acquire the ring and initialize the HugePage buffers
            var ring: Ring = must("create client ring", state.mgr.acquireRing(4096, 1));
            defer ring.deinit();
            must("initialize client buffer class", ring.regiterSizeClassReceiveBuffer(.tiny, 16384));

            var clientArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer clientArena.deinit();

            // Slotter for tracking the tasks being sent
            var slots: slotter.BufferSlots = must("create client buffer slots", slotter.BufferSlots.init(clientArena.allocator(), 16384, 128, 4));

            // Connect to the server (via the socket helpers)
            const sockets = @import("sockets.zig");
            const clientFd = must("create client socket", sockets.createTCPClientSocket(null));
            defer _ = linux.close(clientFd);

            state.barrier.lock();
            state.barrier.unlock();

            const serverIp = "127.0.0.1";
            const serverPort = 60006;

            must("connect to the server", ring.pushConnectIp4(clientFd, 1, serverIp, serverPort, .{}));
            const cqe = must("wait for the connection approval", wait(&ring));
            if (cqe.res < 0) {
                std.debug.panic("failed to connect to the server: {}", .{linux.errno(cqe.result())});
            }
            var fsm = must("create client fsm", echoClientFSM.init(clientArena.allocator(), &ring, &slots, clientFd, noOfRequests));

            const start = time.nowNs();
            while (!fsm.done()) {
                const didWork = fsm.do() catch |err| {
                    std.debug.panic("client critical error={any}: {s}", .{ err, fsm.errMsg() });
                };
                if (!didWork) {
                    std.atomic.spinLoopHint();
                }
            }
            const elapsed = time.nowNs() - start;
            // // Uncomment for manual testing.
            // std.debug.print("it took {} seconds to finish the job\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000_000});
            _ = elapsed;
        }
    }.run;

    sharedState.barrier.lock();
    const serverThread = try pthread.Thread.spawn(&sharedState, serverWorker);
    const clientThread = try pthread.Thread.spawn(&sharedState, clientWorker);

    serverThread.join();
    clientThread.join();
}

test "create and write file" {
    const Manager = @import("ring_factory.zig").Factory;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);
    try ring.pushOpenDir(1, 0, "/tmp", .{});

    try ring.regiterSizeClassReceiveBuffer(.page, 1024);

    var cqe = try wait(&ring);
    const dirFd = cqe.res;

    try ring.pushOpenFile(1, dirFd, "file.txt", linux.O{ .CREAT = true, .ACCMODE = .WRONLY }, .{});
    cqe = try wait(&ring);
    var fileFd = cqe.res;

    const helloWorld = "Hello World!\n";
    try ring.pushWrite(fileFd, 1, helloWorld, helloWorld.len, .{});
    cqe = try wait(&ring);

    try ring.pushClose(1, fileFd, .{});
    cqe = try wait(&ring);

    // Now, need to check if the file was successfully written.
    try ring.pushOpenFile(1, dirFd, "file.txt", linux.O{ .ACCMODE = .RDONLY }, .{});
    cqe = try wait(&ring);
    fileFd = cqe.res;

    try ring.pushReadZC(fileFd, 1, .page, .{});
    cqe = try wait(&ring);
    const buffer = ring.buffer(.page, cqe.bid()) orelse {
        std.debug.panic("missing buffer for the cqe {}", .{cqe});
    };

    try std.testing.expectEqualStrings(helloWorld, buffer[0..cqe.result()]);
    try ring.pushClose(1, fileFd, .{});
    cqe = try wait(&ring);
}

test "write and read file at an explicit offset" {
    const Manager = @import("ring_factory.zig").Factory;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);
    try ring.pushOpenDir(1, 0, "/tmp", .{});
    var cqe = try wait(&ring);
    const dirFd = cqe.res;

    try ring.pushOpenFile(1, dirFd, "offsetfile.txt", linux.O{ .CREAT = true, .TRUNC = true, .ACCMODE = .WRONLY }, .{});
    cqe = try wait(&ring);
    const fileFd = cqe.res;

    // Write past the start of the file; the kernel must land the bytes at the
    // requested offset (leaving a hole) and leave the file position untouched.
    const helloWorld = "Hello World!\n";
    const hole = 8;
    try ring.pushWriteOffset(fileFd, 1, hole, helloWorld, helloWorld.len, .{});
    cqe = try wait(&ring);
    try std.testing.expectEqual(helloWorld.len, cqe.result());

    try ring.pushClose(1, fileFd, .{});
    cqe = try wait(&ring);

    try ring.pushOpenFile(1, dirFd, "offsetfile.txt", linux.O{ .ACCMODE = .RDONLY }, .{});
    cqe = try wait(&ring);
    const readFd = cqe.res;

    var dst: [hole + helloWorld.len]u8 = @splat(0);
    try ring.pushReadOffset(readFd, 1, 0, &dst, .{});
    cqe = try wait(&ring);
    try std.testing.expectEqual(dst.len, cqe.result());

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, dst[0..hole]);
    try std.testing.expectEqualStrings(helloWorld, dst[hole..]);

    // A read starting inside the payload must see only the bytes from there on.
    var tail: [4]u8 = undefined;
    try ring.pushReadOffset(readFd, 2, hole + 8, &tail, .{});
    cqe = try wait(&ring);
    try std.testing.expectEqual(tail.len, cqe.result());
    try std.testing.expectEqualStrings("rld!", &tail);

    try ring.pushClose(1, readFd, .{});
    cqe = try wait(&ring);
}

test "writev and readv file" {
    const Manager = @import("ring_factory.zig").Factory;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);

    try ring.pushOpenDir(1, 0, "/tmp", .{});
    var cqe = try wait(&ring);
    const dirFd = cqe.res;

    try ring.pushOpenFile(1, dirFd, "filev.txt", linux.O{ .CREAT = true, .ACCMODE = .WRONLY }, .{});
    cqe = try wait(&ring);
    const writeFd = cqe.res;

    const seg1 = "Hello, ";
    const seg2 = "vectored ";
    const seg3 = "world!\n";
    const total = seg1.len + seg2.len + seg3.len;

    var writeIovecs = [_]posix.iovec_const{
        .{ .base = seg1.ptr, .len = seg1.len },
        .{ .base = seg2.ptr, .len = seg2.len },
        .{ .base = seg3.ptr, .len = seg3.len },
    };

    try ring.pushWritev(writeFd, 1, &writeIovecs, .{});
    cqe = try wait(&ring);
    try std.testing.expectEqual(total, cqe.result());

    try ring.pushClose(1, writeFd, .{});
    cqe = try wait(&ring);

    try ring.pushOpenFile(1, dirFd, "filev.txt", linux.O{ .ACCMODE = .RDONLY }, .{});
    cqe = try wait(&ring);
    const readFd = cqe.res;

    var dst1: [seg1.len]u8 = undefined;
    var dst2: [seg2.len]u8 = undefined;
    var dst3: [seg3.len]u8 = undefined;

    var readIovecs = [_]posix.iovec{
        .{ .base = &dst1, .len = dst1.len },
        .{ .base = &dst2, .len = dst2.len },
        .{ .base = &dst3, .len = dst3.len },
    };

    try ring.pushReadv(readFd, 1, &readIovecs, .{});
    cqe = try wait(&ring);
    try std.testing.expectEqual(total, cqe.result());
    try std.testing.expectEqualStrings(seg1, &dst1);
    try std.testing.expectEqualStrings(seg2, &dst2);
    try std.testing.expectEqualStrings(seg3, &dst3);

    try ring.pushClose(1, readFd, .{});
    cqe = try wait(&ring);
}

test "create a server and wait for 1 second for incoming connections what will never happen" {
    const Manager = @import("ring_factory.zig").Factory;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);

    const sockets = @import("sockets.zig");
    const sockFd = try sockets.createTCPServerSocket();
    defer _ = linux.close(sockFd);

    try ring.pushBindIp4(sockFd, 1, "0.0.0.0", 60006, .{});
    var cqe = try wait(&ring);

    try ring.pushListen(sockFd, 1, 1, .{});
    _ = try wait(&ring);

    const timerSpec = linux.kernel_timespec{
        .sec = 1,
        .nsec = 0,
    };

    while (true) {
        // The accept and the timeout guarding it must travel in the same
        // submission batch: the kernel only establishes the link while
        // assembling a single batch, otherwise LINK_TIMEOUT is rejected with
        // -EINVAL. Waking the poller after the accept alone would split them.
        var batch = ring.batchedSQ() orelse {
            std.debug.panic("no room in the SQ for accept + timeout", .{});
        };
        if (batch.pushAccept(sockFd, 2, TaskFlags.expectNext()) == null) {
            std.debug.panic("failed to reserve the accept SQE", .{});
        }
        if (batch.pushTimeoutForOp(&timerSpec, 3, .{}) == null) {
            std.debug.panic("failed to reserve the link timeout SQE", .{});
        }
        try batch.commit();

        var needReroll = false;
        for (0..2) |_| {
            cqe = waitPeacefully(&ring);

            if (cqe.taskIdx() != 2) {
                continue;
            }

            if (cqe.res >= 0) {
                std.debug.print("unexpected success: {}\n", .{cqe});
                return error.UnexpectedSuccess;
            }

            const resU: usize = @bitCast(@as(i64, cqe.res));
            switch (linux.errno(resU)) {
                linux.E.CANCELED => return,
                linux.E.AGAIN => {
                    needReroll = true;
                },
                else => {
                    std.debug.panic("unexpected error {any} in {} \n", .{ cqe.errno(), cqe });
                },
            }
        }

        if (!needReroll) {
            break;
        }
    }
}

test "batchedCQ caps the drained entries" {
    const Manager = @import("ring_factory.zig").Factory;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);

    try ring.pushOpenDir(1, 0, "/tmp", .{});
    const dirCqe = try wait(&ring);
    const dirFd = dirCqe.res;
    defer _ = linux.close(dirFd);

    // Push the whole burst without draining, so the CQ holds all of them.
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        try ring.pushOpenFile(100 + i, dirFd, "batchcq.txt", linux.O{ .CREAT = true, .ACCMODE = .WRONLY }, .{});
    }

    // Each park returns once at least one more completion is available, so
    // four of them guarantee the whole burst is visible to the batch.
    var spins: usize = 0;
    while (true) : (spins += 1) {
        const head = ring.cqHead.*;
        const tail = @atomicLoad(u32, ring.cqTail, .acquire);
        if (tail -% head >= 4) break;

        if (spins % 1000 == 999) {
            ring.park();
        } else {
            std.atomic.spinLoopHint();
        }
    }

    var fds: [4]posix.fd_t = undefined;
    var seen: u32 = 0;

    var capped = ring.batchedCQ(1) orelse return error.MissingBatch;
    while (capped.popCQE()) |cqe| {
        fds[seen] = @intCast(cqe.res);
        seen += 1;
    }
    try capped.commit();
    try std.testing.expectEqual(@as(u32, 1), seen);

    // The remaining three completions must still be visible afterwards.
    var rest = ring.batchedCQ(null) orelse return error.MissingBatch;
    while (rest.popCQE()) |cqe| {
        fds[seen] = @intCast(cqe.res);
        seen += 1;
    }
    try rest.commit();
    try std.testing.expectEqual(@as(u32, 4), seen);

    for (fds) |fd| {
        _ = linux.close(fd);
    }
}

test "streamedSQ survives many commit rounds" {
    const Manager = @import("ring_factory.zig").Factory;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(8, 1);

    try ring.pushOpenDir(1, 0, "/tmp", .{});
    var cqe = try wait(&ring);
    const dirFd = cqe.res;

    try ring.pushOpenFile(1, dirFd, "streamsq.txt", linux.O{ .CREAT = true, .ACCMODE = .WRONLY }, .{});
    cqe = try wait(&ring);
    const fileFd = cqe.res;
    defer _ = linux.close(fileFd);

    var stream = ring.streamedSQ() orelse return error.MissingStream;

    // More rounds than the ring has entries: if the window did not slide after
    // each commit the stream would wedge once the SQ filled up.
    var round: u32 = 0;
    while (round < 16) : (round += 1) {
        while (stream.pushWrite(fileFd, round, "x", 1, .{}) == null) {
            try stream.commit();
        }
        try stream.commit();
    }

    // Drain every completion the stream produced.
    var drained: u32 = 0;
    while (drained < 16) : (drained += 1) {
        cqe = try wait(&ring);
        try std.testing.expect(cqe.res > 0);
    }
}
