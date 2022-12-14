const std = @import("std");
const glfw = @import("lib/mach-glfw/build.zig");
const zgui = @import("lib/zgui/build.zig");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("bp-jit", "src/main.zig");
    exe.setTarget(target);

    // Argument Parsing
    exe.addPackagePath("clap", "lib/zig-clap/clap.zig");

    // OpenGL 3.3. Bindings
    exe.addPackagePath("gl", "lib/gl.zig");

    // GLFW Bindings
    exe.addPackage(glfw.pkg);
    try glfw.link(b, exe, .{});

    // Dear ImGui Bindings
    const zgui_options = zgui.BuildOptionsStep.init(b, .{ .backend = .glfw_opengl3 });
    const zgui_pkg = zgui.getPkg(&.{zgui_options.getPkg()});
    exe.addPackage(zgui_pkg);
    zgui.link(exe, zgui_options);

    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
