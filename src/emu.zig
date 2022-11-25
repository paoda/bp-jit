const std = @import("std");
const SDL = @import("sdl2");

const FpsTracker = @import("util.zig").FpsTracker;

const BytePusher = @import("BytePusher.zig");
const FrameBuffer = @import("platform.zig").FrameBuffer;

const cycles_per_frame = 0x10000;

pub fn run(bp: *BytePusher, fb: *FrameBuffer, quit: *std.atomic.Atomic(bool), tracker: *FpsTracker) void {
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

        var cycles: u32 = 0;
        while (cycles < cycles_per_frame) : (cycles += 1) {
            bp.step();
        }

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

        bp.updateFrameBuffer(fb.get(.Guest));
        fb.swap();
    }
};

pub fn key(key_code: SDL.SDL_Keycode) u16 {
    return @byteSwap(switch (key_code) {
        SDL.SDLK_1 => 1 << 0x1,
        SDL.SDLK_2 => 1 << 0x2,
        SDL.SDLK_3 => 1 << 0x3,
        SDL.SDLK_4 => 1 << 0xC,

        SDL.SDLK_q => 1 << 0x4,
        SDL.SDLK_w => 1 << 0x5,
        SDL.SDLK_e => 1 << 0x6,
        SDL.SDLK_r => 1 << 0xD,

        SDL.SDLK_a => 1 << 0x7,
        SDL.SDLK_s => 1 << 0x8,
        SDL.SDLK_d => 1 << 0x9,
        SDL.SDLK_f => 1 << 0xE,

        SDL.SDLK_z => 1 << 0xA,
        SDL.SDLK_x => 1 << 0x0,
        SDL.SDLK_c => 1 << 0xB,
        SDL.SDLK_v => 1 << 0xF,
        else => @as(u16, 0),
    });
}
