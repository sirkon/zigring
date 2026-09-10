const std = @import("std");
const linux = std.os.linux;

/// Возвращает текущее время Unix в наносекундах (u64) напрямую через сисколл.
/// Никаких аллокаторов, никаких контекстов Io, чистый vDSO-Fastpath ядра.
pub inline fn nowNs() u64 {
    // Явно объявляем структуру timespec из ABI Linux (секунды + наносекунды)
    var ts: linux.timespec = undefined;

    // В Linux ABI: CLOCK_REALTIME = 0
    // Вызываем сисколл напрямую через встроенный ассемблерный шлюз Zig
    const res = linux.syscall2(.clock_gettime, 0, @intFromPtr(&ts));

    // Если сисколл отработал успешно (вернул 0)
    if (res == 0) {
        @branchHint(.likely);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    // Холодная ветка на случай, если вселенная сломалась
    return 0;
}

/// Монотонное время для внутренних замеров дельты Latency.
/// В Linux ABI: CLOCK_MONOTONIC = 1
pub inline fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    const res = linux.syscall2(.clock_gettime, 1, @intFromPtr(&ts));
    if (res == 0) {
        @branchHint(.likely);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    return 0;
}

test "times" {
    const start = nowNs();

    // Спим 1 миллисекунду (1_000_000 нс)
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);

    const elapsed = nowNs() - start;
    std.debug.print("Real elapsed ns: {}\n", .{elapsed});

    // Проверяем, что мы поспали около 1 мс с допуском ±200_000 наносекунд (на погрешность ОС)
    const expected_ns: i64 = 1_000_000;
    var diff = @as(i64, @intCast(elapsed)) - expected_ns;
    if (diff < 0) {
        diff = -diff;
    }

    // Абсолютная дельта должна быть меньше 200 микросекунд
    try std.testing.expect(diff < 200_000);
}
