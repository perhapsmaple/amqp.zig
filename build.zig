const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const amqp_module = b.addModule("amqp", .{
        .root_source_file = b.path("src/amqp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    const amqp_tests = b.addTest(.{ .root_module = amqp_module });
    test_step.dependOn(&b.addRunArtifact(amqp_tests).step);

    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src") },
        .check = true,
    }).step);
}
