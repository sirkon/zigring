const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Creates a socket for serving.
pub fn createServerSocket() !posix.fd_t {
    // 1. Создаем сокет. Вызов возвращает usize.
    const rc = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        linux.IPPROTO.TCP,
    );

    // Проверяем, не вернуло ли ядро ошибку (значение выше возвращаемого лимита)
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) {
        // Возвращаем честную ошибку Zig, автоматически преобразованную из errno Linux
        return posix.unexpectedErrno(errno);
    }

    // Теперь, когда мы точно знаем, что это валидный дескриптор, кастим его в i32
    const sockFd: posix.fd_t = @intCast(rc);

    // 2. Включаем SO_REUSEADDR
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
