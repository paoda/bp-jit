const std = @import("std");

const BytePusher = @import("BytePusher.zig");
const FrameBuffer = @import("platform.zig").FrameBuffer;

const cycles_per_frame = 0x10000;

pub fn runFrame(bp: *BytePusher, fb: *FrameBuffer) void {
    var cycles: u32 = 0;

    // TODO: Poll Keys, Write to Key Register

    bp.pc = bp.fetch();
    while (cycles < cycles_per_frame) : (cycles += 1) {
        bp.step();
    }

    bp.updateFrameBuffer(fb.get(.Guest));
    fb.swap();
}
