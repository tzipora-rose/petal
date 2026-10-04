const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows, .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(b.addExecutable(.{ .name = "petal", .root_module = module }));

    const unit_tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run petal's unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
