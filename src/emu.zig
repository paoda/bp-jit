const std = @import("std");
const glfw = @import("glfw");

const Key = glfw.Key;

const FrameCounter = @import("util.zig").FrameCounter;
const AudioQueue = @import("util.zig").AudioQueue;

const BytePusher = @import("BytePusher.zig");
const FrameBuffer = @import("platform.zig").FrameBuffer;

const cycles_per_frame = 0x10000;

pub fn run(bp: *BytePusher, fb: *FrameBuffer, quit: *std.atomic.Value(bool), counter: *FrameCounter) void {
    var frame_limiter = std.time.Timer.start() catch unreachable;

    while (!quit.load(.SeqCst)) {

        // jit.runFrame(bp); // 2x faster on my laptop
        interp.runFrame(bp);

        const addr: u24 = bp.read(u16, 0x000006);
        const sample_ptr = bp.memory[addr << 8 ..][0..0x100];

        {
            bp.audio_queue.mutex.lock();
            defer bp.audio_queue.mutex.unlock();

            resample(&bp.audio_queue, sample_ptr, 48000);
        }

        bp.updateFrameBuffer(fb.get(.guest));
        fb.swap();
        counter.tick();

        // TODO: Less bad version of this please
        while (frame_limiter.read() < 16666666) std.atomic.spinLoopHint();
        frame_limiter.reset();
    }
}

fn resample(audio_queue: *AudioQueue, input: *[256]u8, target_freq: usize) void {
    const source_freq = 15360;
    const gcd: usize = std.math.gcd(source_freq, target_freq);

    const M = source_freq / gcd;
    const N = target_freq / gcd;

    // M / N
    const ratio = @as(f32, @floatFromInt(M)) / @as(f32, @floatFromInt(N));
    // N / M
    const inv_ratio = @as(f32, @floatFromInt(N)) / @as(f32, @floatFromInt(M));

    const target_len: usize = @intFromFloat(input.len * inv_ratio);

    // std.debug.print("input  len: {}\n", .{input.len});
    // std.debug.print("target len: {}\n", .{target_len});

    for (0..target_len - 3) |i| {
        const n = @as(f32, @floatFromInt(i)) * ratio;
        const ind: usize = @intFromFloat(std.math.floor(n));
        std.debug.print("i: {} | n: {d} | ind: {}\n", .{ i, n, ind });

        const d = n - @as(f32, @floatFromInt(ind));

        const sample: u8 = @intFromFloat((1 - d) * @as(f32, @floatFromInt(input[ind])) + d * @as(f32, @floatFromInt(input[ind + 1])));

        audio_queue.inner.push(sample) catch @panic("oom");
    }
}

const interp = struct {
    fn runFrame(bp: *BytePusher) void {
        bp.pc = bp.fetch();

        for (0..cycles_per_frame) |_|
            bp.step();
    }
};

const jit = struct {
    fn runFrame(bp: *BytePusher) void {
        bp.pc = bp.fetch();

        var cycles: u32 = 0;
        while (cycles < cycles_per_frame) {
            cycles += bp.jit.execute(bp);
        }
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
