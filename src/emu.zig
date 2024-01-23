const std = @import("std");
const glfw = @import("glfw");

const Key = glfw.Key;

const FpsTracker = @import("util.zig").FpsTracker;

const BytePusher = @import("BytePusher.zig");
const FrameBuffer = @import("platform.zig").FrameBuffer;

const cycles_per_frame = 0x10000;

pub fn run(bp: *BytePusher, fb: *FrameBuffer, quit: *std.atomic.Value(bool), tracker: *FpsTracker) void {
    while (!quit.load(.SeqCst)) {
        // TODO: Time to 60Fps

        jit.runFrame(bp, fb); // 2x faster on my laptop
        // interp.runFrame(bp, fb);

        tracker.tick();
    }
}

const interp = struct {
    fn runFrame(bp: *BytePusher, fb: *FrameBuffer) void {
        // TODO: Poll Keys, Write to Key Register
        bp.pc = bp.fetch();

        for (0..cycles_per_frame) |_|
            bp.step();

        bp.updateFrameBuffer(fb.get(.Guest));
        fb.swap();
    }
};

const jit = struct {
    fn runFrame(bp: *BytePusher, fb: *FrameBuffer) void {
        // TODO: Poll Keys, Write to Key Register
        bp.pc = bp.fetch();

        var cycles: u32 = 0;
        while (cycles < cycles_per_frame) {
            cycles += bp.jit.execute(bp);
        }

        bp.updateFrameBuffer(fb.get(.guest));
        fb.swap();
    }
};

pub fn key(code: Key) u16 {
    return @byteSwap(switch (code) {
        .one => 1 << 0x1,
        .two => 1 << 0x2,
        .three => 1 << 0x3,
        .four => 1 << 0xC,

        .q => 1 << 0x4,
        .w => 1 << 0x5,
        .e => 1 << 0x6,
        .r => 1 << 0xD,

        .a => 1 << 0x7,
        .s => 1 << 0x8,
        .d => 1 << 0x9,
        .f => 1 << 0xE,

        .z => 1 << 0xA,
        .x => 1 << 0x0,
        .c => 1 << 0xB,
        .v => 1 << 0xF,
        else => @as(u16, 0),
    });
}
