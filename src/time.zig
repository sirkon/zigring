const std = @import("std");
const linux = std.os.linux;

inline fn toUnixNs(ts: linux.timespec) u64 {
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Returns the current Unix time in nanoseconds (u64).
/// Uses the vDSO implementation of clock_gettime: on the fast path the kernel is not
/// crossed; if vDSO is unavailable, Zig falls back to a regular syscall.
pub inline fn nowNs() u64 {
    var ts: linux.timespec = undefined;

    const res = linux.clock_gettime(.REALTIME, &ts);

    if (res == 0) {
        @branchHint(.likely);
        return toUnixNs(ts);
    }

    // Cold branch in case the universe broke
    return 0;
}

/// Monotonic time for internal Latency delta measurements.
pub inline fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;

    const res = linux.clock_gettime(.MONOTONIC, &ts);

    if (res == 0) {
        @branchHint(.likely);
        return toUnixNs(ts);
    }

    return 0;
}

test "times" {
    const start = nowNs();

    // Sleep for 1 millisecond (1_000_000 ns)
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);

    const elapsed = nowNs() - start;

    // Check that we slept about 1 ms with a ±200_000 nanosecond tolerance (for OS jitter)
    const expected_ns: i64 = 1_000_000;
    var diff = @as(i64, @intCast(elapsed)) - expected_ns;
    if (diff < 0) {
        diff = -diff;
    }

    // The absolute delta must be less than 200 microseconds
    try std.testing.expect(diff < 200_000);
}
