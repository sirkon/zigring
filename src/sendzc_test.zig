const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("iouring.zig").Ring;
const BufferSizeClass = @import("iouring.zig").BufferSizeClass;
const CQE = @import("iouring.zig").CQE;
const sockets = @import("sockets.zig");

fn wait(ring: *Ring) !CQE {
    while (true) {
        if (ring.popCQE()) |cqe| return cqe;
        ring.park();
    }
}

test "SendZC sends a slice of a registered buffer" {
    var ring = try Ring.init(64, null);
    defer ring.deinit();

    // Set up a connected TCP loopback pair on the same ring.
    const listenFd = try sockets.createServerSocket();
    defer _ = linux.close(listenFd);

    try ring.pushBindIp4(listenFd, 1, "127.0.0.1", 60011, .{});
    _ = try wait(&ring);
    try ring.pushListen(listenFd, 1, 1, .{});
    _ = try wait(&ring);

    try ring.pushAccept(listenFd, 2, .{});

    const clientFd = try sockets.createClientSocket();
    defer _ = linux.close(clientFd);

    try ring.pushConnectIp4(clientFd, 3, "127.0.0.1", 60011, .{});

    var serverFd: posix.fd_t = -1;
    var connected = false;
    while (serverFd < 0 or !connected) {
        const cqe = try wait(&ring);
        switch (cqe.taskIdx) {
            2 => if (cqe.res >= 0) {
                serverFd = cqe.res;
            },
            3 => {
                if (cqe.res < 0) return error.ConnectFailed;
                connected = true;
            },
            else => {},
        }
    }
    defer _ = linux.close(serverFd);

    // Register a pool of fixed buffers on this very ring.
    const bufSize = BufferSizeClass.tiny.size();
    const entries = 4;
    const mem = try ring.registerBuffers(.tiny, entries);
    defer posix.munmap(mem);

    // Send only a part of the second registered buffer (offset 16, bufIndex 1),
    // which is exactly what the zero-copy fixed-buffer path exists for.
    const bufIndex: u16 = 1;
    const offset = 16;
    const payload = "zero-copy SEND_ZC from a registered buffer";
    const start = @as(usize, bufIndex) * bufSize + offset;
    @memcpy(mem[start .. start + payload.len], payload);

    const sendTaskIdx: u64 = 10;
    try ring.pushSendZC(serverFd, sendTaskIdx, mem.ptr + start, payload.len, bufIndex, 0, .{});

    // Receive the payload on the client with a kernel-provided buffer.
    try ring.regiterSizeClassReceiveBuffer(.tiny, 128);
    const recvTaskIdx: u64 = 11;
    try ring.pushRecvZC(clientFd, recvTaskIdx, .tiny, .{});

    var gotSendFirst = false;
    var gotNotif = false;
    var gotRecv = false;

    while (!(gotSendFirst and gotNotif and gotRecv)) {
        const cqe = try wait(&ring);
        if (cqe.taskIdx == sendTaskIdx) {
            if (cqe.hasNotif) {
                gotNotif = true;
            } else {
                try std.testing.expect(cqe.res >= 0);
                try std.testing.expectEqual(@as(i32, @intCast(payload.len)), cqe.res);
                try std.testing.expect(cqe.hasMore);
                gotSendFirst = true;
            }
        } else if (cqe.taskIdx == recvTaskIdx) {
            try std.testing.expect(!cqe.hasNotif);
            const recvBuf = ring.buffer(.tiny, cqe.bid) orelse return error.MissingRecvBuffer;
            try std.testing.expectEqualStrings(payload, recvBuf[0..cqe.result()]);
            gotRecv = true;
        }
    }
}
