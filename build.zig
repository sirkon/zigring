const std = @import("std");

/// Builds the `zigring` package.
///
/// The interesting output is the public `zigring` module: other projects add
/// this package as a dependency and `@import("zigring")` in their own sources.
/// The module is also the root of the unit tests and of the two integration
/// test roots shipped in `src/`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module. Exposing it through `addModule` is what makes it visible
    // to downstream packages; `link_libc` is mandatory because the threading
    // wrappers call pthread symbols from libc.
    const zigring = b.addModule("zigring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // `zig build test` runs the unit tests plus the two integration suites.
    const test_step = b.step("test", "Run unit and integration tests");

    // Unit tests: all `test` blocks reachable from the module root, which
    // covers the slot allocators, the pthread wrappers and the time helpers.
    const unit_tests = b.addTest(.{ .root_module = zigring });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The integration suites are standalone roots that drive a real ring over
    // loopback sockets, so each needs its own test artifact.
    const integration_roots = [_][]const u8{
        "src/iouringtest.zig",
        "src/sendzc_test.zig",
    };
    for (integration_roots) |root| {
        const module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
