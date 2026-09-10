const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("iouring.zig").Ring;
const BufferSizeClass = @import("iouring.zig").BufferSizeClass;
const CQE = @import("iouring.zig").CQE;
const TaskFlags = @import("iouring.zig").TaskFlags;
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
    ordbuf: *reorderBuffer,

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
        ordbuf: *reorderBuffer,
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

                if (cqe.taskIdx != recvIdx) {
                    // This is a notification about reply.
                    self.respCount += 1;
                    self.state = .needRecv;
                    self.slots.del(cqe.taskIdx);
                    return true;
                }

                // This is a client request.
                const buffer = self.ring.buffer(.tiny, cqe.bid) orelse {
                    try self.setCritical("size class .tiny is not initialized (CQE = {})", .{cqe});
                    return error.CQEBidError;
                };

                if (self.bufRest.len > 0) {
                    std.mem.copyForwards(u8, self.placeholder[0..self.bufRest.len], self.bufRest);
                }

                @memcpy(self.placeholder[self.bufRest.len .. self.bufRest.len + cqe.result()], buffer[0..cqe.result()]);
                self.bufRest = self.placeholder[0 .. self.bufRest.len + cqe.result()];
                self.ring.releaseBuffer(.tiny, cqe.bid);

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

                if (cqe.taskIdx == sendIdx) {
                    // Это ПОЛУЧЕННЫЕ ДАННЫЕ от сервера (CQE от pushRecvZC)
                    const buffer = self.ring.buffer(.tiny, cqe.bid) orelse {
                        try self.setCritical("size class .tiny is not initialized (CQE = {})", .{cqe});
                        return error.CQEBidError;
                    };

                    // Копируем данные из provided buffer в placeholder
                    if (self.bufRest.len > 0) {
                        std.mem.copyForwards(u8, self.placeholder[0..self.bufRest.len], self.bufRest);
                    }
                    @memcpy(self.placeholder[self.bufRest.len .. self.bufRest.len + cqe.result()], buffer[0..cqe.result()]);
                    self.bufRest = self.placeholder[0 .. self.bufRest.len + cqe.result()];

                    self.ring.releaseBuffer(.tiny, cqe.bid);

                    self.recvArmed = false;
                    self.state = .needCheck;
                    return true;
                }

                self.slots.del(cqe.taskIdx);

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
            if (cqe.taskIdx != 2) {
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

const reorderBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    buf: []u8, // данные: mod * itemSize
    nexts: []i32, // nexts[i] = следующий узел в списке
    prevs: []i32, // prevs[i] = предыдущий узел в списке

    size: u64, // окно N
    mod: u64, // 2N
    itemSize: usize,

    wave: u64, // ожидаемый seqIdx
    first: i32, // голова списка
    last: i32, // хвост списка

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

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buf);
        self.allocator.free(self.nexts);
        self.allocator.free(self.prevs);
    }

    /// Вставляет элемент с абсолютным seqIdx.
    /// Возвращает true, если волна сдвинулась (есть готовые к обработке данные).
    pub fn push(self: *Self, idx: u64, data: []const u8) !void {
        const mod: i32 = @truncate(@as(i64, @bitCast(self.mod)));

        // Дубликаты и устаревшие — игнорируем
        if (idx < self.wave) {
            @branchHint(.cold);
            return error.OutdatedFrame;
        }

        // Разрыв больше окна — фатальная ошибка
        const distFromWave = idx - self.wave;

        if (distFromWave >= self.size) {
            @branchHint(.cold);
            return error.FramesAreTooFarAway;
        }

        const relIdx: i32 = @intCast(idx & (self.mod - 1));

        // Записываем данные
        const offset = @as(usize, @intCast(idx & (self.mod - 1))) * self.itemSize;
        @memcpy(self.buf[offset .. offset + self.itemSize], data);

        // Первый элемент в списке
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

        // Быстрый путь: вставка после хвоста
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

        // Медленный путь: ищем место вставки, двигаясь от хвоста назад
        var cur: i32 = self.last;
        while (cur >= 0) {
            const distFromCur = (relIdx - cur) & (mod - 1);
            // Если новый элемент "позади" cur (расстояние >= size) — двигаемся назад
            if (distFromCur >= @as(i32, @intCast(self.size))) {
                @branchHint(.likely);

                cur = self.prevs[@intCast(cur)];
                continue;
            }

            break;
        }

        if (cur < 0) {
            @branchHint(.cold);
            // Вставляем в голову
            self.nexts[@intCast(relIdx)] = self.first;
            self.prevs[@intCast(relIdx)] = -1;
            self.prevs[@intCast(self.first)] = relIdx;
            self.first = relIdx;
            self.advanceWave(idx);
            return;
        }

        // Вставляем после cur
        const nextNode = self.nexts[@intCast(cur)];
        self.nexts[@intCast(cur)] = relIdx;
        self.prevs[@intCast(relIdx)] = cur;
        self.nexts[@intCast(relIdx)] = nextNode;
        self.prevs[@intCast(nextNode)] = relIdx;
        self.advanceWave(idx);
    }

    /// Сдвигает волну, пропуская существующие последовательные, если idx == s.wave.
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

    /// Вынимает первый элемент из списка при условии, что у него нужный idx.
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

    /// Removes the current head element from the list.
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

test "reorder buffer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    {
        // Пишем-удаляем-пишем-удаляем.
        var ordbuf = try reorderBuffer.init(arena.allocator(), 128, 1);
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
        // Пишем 1-2, добавляем 0, пишем 4-5, добавляем 3. И так скока-то.
        var ordbuf = try reorderBuffer.init(arena.allocator(), 128, 1);
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

/// Принимает любое ошибочное выражение (Inferred Error Union).
/// Если там ошибка — паникует с выводом имени ошибки. Иначе возвращает чистое значение.
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

    const Manager = @import("ring_manager.zig").WeightedRingManager;
    const slotter = @import("slotter.zig");
    const pthread = @import("pthread.zig");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
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
            var ordbuf = must("create reorder buffer", reorderBuffer.init(serverArena.allocator(), 128, 21));

            // Create socket, bind it and start listening.
            const sockets = @import("sockets.zig");
            const sockFd = must("create socket server", sockets.createServerSocket());
            defer _ = linux.close(sockFd);

            must("bind server socket to the address", ring.pushBindIp4(sockFd, 1, "0.0.0.0", 60006, .{}));
            _ = must("wait for the bind approval", wait(&ring));

            must("start listening", ring.pushListen(sockFd, 1, 1, .{}));
            _ = must("wait for the listening approval", wait(&ring));
            state.barrier.unlock();

            // Push accepts until there's a client.
            const clientFd = must("wait and accept the client", getAcceptedConn(&ring, sockFd));

            var one: c_int = 1;
            const rc = linux.setsockopt(clientFd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(c_int));
            const errno = linux.errno(rc);
            if (errno != .SUCCESS) {
                std.debug.panic("forbid socket to split send frames: {}", .{errno});
            }

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

            // Получаем кольцо и инициализируем HugePage буферы
            var ring: Ring = must("create client ring", state.mgr.acquireRing(4096, 1));
            defer ring.deinit();
            must("initialize client buffer class", ring.regiterSizeClassReceiveBuffer(.tiny, 16384));

            var clientArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer clientArena.deinit();

            // Слоттер для отслеживания отправляемых тасок
            var slots: slotter.BufferSlots = must("create client buffer slots", slotter.BufferSlots.init(clientArena.allocator(), 16384, 128, 4));

            // Коннектимся к серверу (через сокет-хелперы)
            const sockets = @import("sockets.zig");
            const clientFd = must("create client socket", sockets.createClientSocket());
            defer _ = linux.close(clientFd);

            state.barrier.lock();
            state.barrier.unlock();

            const serverIp = "127.0.0.1";
            const serverPort = 60006;

            std.debug.print("connect to the server {s}:{}\n", .{ serverIp, serverPort });
            must("connect to the server", ring.pushConnectIp4(clientFd, 1, serverIp, serverPort, .{}));
            const cqe = must("wait for the connection approval", wait(&ring));
            if (cqe.res < 0) {
                std.debug.panic("failed to connect to the server: {}", .{linux.errno(cqe.result())});
            }
            std.debug.print("connected\n", .{});
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
            std.debug.print("it took {} seconds to finish the job\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000_000});
        }
    }.run;

    sharedState.barrier.lock();
    const serverThread = try pthread.Thread.spawn(&sharedState, serverWorker);
    const clientThread = try pthread.Thread.spawn(&sharedState, clientWorker);

    serverThread.join();
    clientThread.join();
}

test "create and write file" {
    const Manager = @import("ring_manager.zig").WeightedRingManager;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);
    try ring.pushOpenDir(1, 0, "/tmp", .{});

    try ring.initializeSizeClassBuffer(.page, 1024);

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
    const buffer = ring.buffer(.page, cqe.bid) orelse {
        std.debug.panic("missing buffer for the cqe {}", .{cqe});
    };

    try std.testing.expectEqualStrings(helloWorld, buffer[0..cqe.result()]);
    try ring.pushClose(1, fileFd, .{});
    cqe = try wait(&ring);
}

test "create a server and wait for 1 second for incoming connections what will never happen" {
    const Manager = @import("ring_manager.zig").WeightedRingManager;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var mgr = try Manager.init(arena.allocator(), 1);
    defer mgr.deinit();

    var ring = try mgr.acquireRing(128, 1);

    const sockets = @import("sockets.zig");
    const sockFd = try sockets.createServerSocket();
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
        try ring.pushAccept(sockFd, 2, TaskFlags.expectNext());
        try ring.pushTimeoutForOp(&timerSpec, 3, .{});

        var needReroll = false;
        for (0..2) |_| {
            std.debug.print("waiting\n", .{});

            cqe = waitPeacefully(&ring);
            std.debug.print("got {} for {any}\n", .{ linux.errno(cqe.result()), cqe });

            if (cqe.taskIdx != 2) {
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
                    std.debug.print("unexpected error {any} in {} \n", .{ cqe.errno(), cqe });
                    try std.testing.expect(false);
                },
            }
        }

        if (!needReroll) {
            break;
        }
    }
}
