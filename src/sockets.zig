const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Creates a TCP listening socket on IPv4, ready to be bound and listened on.
///
/// Returns a `SOCK_STREAM`/`IPPROTO.TCP` socket in `AF_INET` created with
/// `SOCK_CLOEXEC`, so it is closed automatically if the process execs. Because
/// the socket only becomes usable after `bind` and `listen`, the usual next
/// steps are `Ring.pushBindIp4`/`pushBindIp6` followed by `Ring.pushListen`.
///
/// `SO_REUSEADDR` is enabled to allow rebinding an address that is still in
/// `TIME_WAIT`, which would otherwise fail with `-EADDRINUSE` after a restart.
///
/// Ownership: the returned fd belongs to the caller and must eventually be
/// closed (`Ring.pushClose` or `close(2)`). If enabling `SO_REUSEADDR` fails,
/// the fd is closed before the error is returned, so no descriptor leaks on
/// that path.
pub fn createTCPServerSocket() !posix.fd_t {
    // 1. Create the socket. The call returns a usize.
    const rc = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        linux.IPPROTO.TCP,
    );

    // Check whether the kernel returned an error (value above the returnable limit)
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) {
        // Return an honest Zig error, automatically converted from the Linux errno
        return posix.unexpectedErrno(errno);
    }

    // Now that we know it's a valid descriptor, cast it to i32
    const sockFd: posix.fd_t = @intCast(rc);

    // 2. Enable SO_REUSEADDR
    const optVal: i32 = 1;
    const sOptRc = linux.setsockopt(
        sockFd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        @ptrCast(&optVal),
        @sizeOf(i32),
    );

    const sOptErrno = linux.errno(sOptRc);
    if (sOptErrno != .SUCCESS) {
        _ = linux.close(sockFd);
        return posix.unexpectedErrno(sOptErrno);
    }

    return sockFd;
}

/// Creates an IPv4 TCP client socket, optionally with one TCP-level option set.
///
/// Returns a `SOCK_STREAM`/`IPPROTO.TCP` socket in `AF_INET` created with
/// `SOCK_CLOEXEC`, so it is closed automatically if the process execs.
///
/// When `opts` is non-null it is treated as a TCP socket option name (for
/// example `linux.TCP.NODELAY`) and enabled with an `int` value of 1 via
/// `setsockopt` at the `IPPROTO_TCP` level; pass null when no option is needed.
/// `SO_REUSEADDR` is deliberately not set here: a client uses an ephemeral
/// port, so reuse is pointless. Use `Ring.pushConnectIp4`/`pushConnectIp6` to
/// connect, or `Ring.pushSend`/`pushRecv` once connected.
///
/// Ownership: the returned fd belongs to the caller and must eventually be
/// closed (`Ring.pushClose` or `close(2)`). If the `setsockopt` fails, the
/// error is returned without closing the socket, so the descriptor leaks on
/// that path.
pub fn createTCPClientSocket(opts: ?u32) !posix.fd_t {
    // 1. Create the socket. The call returns a usize.
    var rc = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        linux.IPPROTO.TCP,
    );

    // Check whether the kernel returned an error
    var errno = linux.errno(rc);
    if (errno != .SUCCESS) {
        return posix.unexpectedErrno(errno);
    }

    // Now that we know it's a valid descriptor, cast it to i32
    const sockFd: posix.fd_t = @intCast(rc);

    const refOpts = opts orelse {
        return sockFd;
    };

    const one: c_int = 1;
    rc = linux.setsockopt(sockFd, linux.IPPROTO.TCP, refOpts, std.mem.asBytes(&one), @sizeOf(c_int));
    errno = linux.errno(rc);
    if (errno != .SUCCESS) {
        return posix.unexpectedErrno(errno);
    }

    // Note: for a client, calling setsockopt (SO_REUSEADDR)
    // is usually unnecessary, since the client uses an ephemeral port.

    return sockFd;
}
