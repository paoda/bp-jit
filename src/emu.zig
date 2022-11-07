const std = @import("std");

const BytePusher = @import("BytePusher.zig");
const FrameBuffer = @import("platform.zig").FrameBuffer;

const cycles_per_frame = 0x10000;

pub const interpreter = struct {
    pub fn runFrame(bp: *BytePusher, fb: *FrameBuffer) void {
        // TODO: Poll Keys, Write to Key Register
        bp.pc = bp.fetch();

        var cycles: u32 = 0;
        while (cycles < cycles_per_frame) : (cycles += 1) {
            bp.step();
        }

        bp.updateFrameBuffer(fb.get(.Guest));
        fb.swap();
    }
};

pub const jit = struct {
    pub fn runFrame(bp: *BytePusher, fb: *FrameBuffer) void {
        // TODO: Poll Keys, Write to Key Register
        bp.pc = bp.fetch();

        var cycles: u32 = 0;
        while (cycles < cycles_per_frame) {
            cycles += bp.jit.compile(bp) catch |e| std.debug.panic("JIT compilation failed: {}", .{e});
            bp.jit.execute(bp);
        }

        bp.updateFrameBuffer(fb.get(.Guest));
        fb.swap();
    }
};
