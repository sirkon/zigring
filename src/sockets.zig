const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Creates a socket for serving.
pub fn createServerSocket() !posix.fd_t {
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

/// Creates a socket for client connection.
pub fn createClientSocket() !posix.fd_t {
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

    const one: c_int = 1;
    rc = linux.setsockopt(sockFd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(c_int));
    errno = linux.errno(rc);
    if (errno != .SUCCESS) {
        return posix.unexpectedErrno(errno);
    }

    // Примечание: Для клиента вызывать setsockopt (SO_REUSEADDR)
    // обычно не нужно, так как клиент использует случайный порт.

    return sockFd;
}
