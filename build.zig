// build.zig - cmdbox
//   zig build                       (host, ReleaseSmall by default)
//   zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7
//   zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Dstrip=false
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .musl } });
    // default to ReleaseSmall: this project's whole point is binary size
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;
    const strip = b.option(bool, "strip", "Strip symbols (default: true)") orelse true;

    const exe = b.addExecutable(.{
        .name = "cmdbox",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .link_libc = true,
            .strip = strip,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run cmdbox");
    run_step.dependOn(&run_cmd.step);
}
