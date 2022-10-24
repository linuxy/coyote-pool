const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const poolPkg = std.build.Pkg{ .name = "coyote-pool", .source = std.build.FileSource{ .path = "src/coyote-pool.zig" }};

    const exe = b.addExecutable("triangle", "examples/triangle.zig");
    exe.setBuildMode(mode);
    exe.addPackage(poolPkg);
    exe.use_stage1 = true;
    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}