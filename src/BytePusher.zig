const std = @import("std");
const JitCompiler = @import("JitCompiler.zig");
const AudioQueue = @import("util.zig").AudioQueue;
const Allocator = std.mem.Allocator;

const BytePusher = @This();
const log = std.log.scoped(.byte_pusher);

pub const mem_size = 0x0100_0008; // 16 MiB
pub const width = 256;
pub const height = width;

pc: u24 = 0x000000,
memory: *[mem_size]u8,
jit: JitCompiler,

audio_queue: AudioQueue,

pub fn init(allocator: Allocator, path: []const u8) !BytePusher {
    const memory = try allocator.alignedAlloc(u8, @alignOf(u24), mem_size);
    errdefer allocator.free(memory);

    @memset(memory, 0);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const len = try file.readAll(memory);
    log.info("rom size: {}B", .{len});

    const audio_buf = try allocator.alloc(u8, 1 << 15);
    errdefer allocator.free(audio_buf);

    return .{ .memory = memory[0..mem_size], .jit = try JitCompiler.init(allocator), .audio_queue = AudioQueue.init(audio_buf) };
}

pub fn deinit(self: *BytePusher, allocator: Allocator) void {
    self.jit.deinit(allocator);

    allocator.free(self.audio_queue.inner.buf);
    allocator.destroy(self.memory);
}

pub fn fetch(self: *BytePusher) u24 {
    return self.read(u24, 0x000002);
}

pub fn read(self: *const BytePusher, comptime T: type, addr: u24) T {
    const len = @divExact(@typeInfo(T).Int.bits, 8);

    return switch (T) {
        u24, u16, u8 => std.mem.readInt(T, self.memory[addr..][0..len], .big),
        else => @compileError("bus: unsupported read width"),
    };
}

fn write(self: *BytePusher, comptime T: type, addr: u24, value: T) void {
    const len = @divExact(@typeInfo(T).Int.bits, 8);

    switch (T) {
        u24, u16, u8 => std.mem.writeInt(T, self.memory[addr..][0..len], value, .big),
        else => @compileError("bus: unsupported write width"),
    }
}

const color_lut: [256]u32 = blk: {
    var lut: [256]u32 = undefined;

    for (&lut, 0..) |*color, i| {
        if (i > 216) {
            color.* = 0x0000_00FF;
            continue;
        }

        const b: u32 = i % 6;
        const g: u32 = (i / 6) % 6;
        const r: u32 = (i / 36) % 6;

        color.* = r * 0x33 << 24 | g * 0x33 << 16 | b * 0x33 << 8 | 0xFF;
    }

    break :blk lut;
};

pub fn updateFrameBuffer(self: *const BytePusher, buf: []u8) void {
    const page = @as(u24, self.read(u8, 0x000005)) << 16;

    // const frame_buf: []u32 = @ptrCast(buf); TODO: Compiler doesn't support this yet

    const frame_buf = blk: {
        const ptr: [*]u32 = @ptrCast(@alignCast(buf));
        break :blk ptr[0 .. buf.len / @sizeOf(u32)];
    };

    for (frame_buf, 0..) |*ptr, i| {
        ptr.* = color_lut[self.memory[page | i]];
    }
}

pub fn step(self: *BytePusher) void {
    const src_addr = self.read(u24, self.pc + 0);
    const dst_addr = self.read(u24, self.pc + 3);

    // Write Value
    // log.info("0x{X:0>8} <- {X:0>2}u8@0x{}", .{ dst_addr, self.read(u8, src_addr), src_addr });
    self.write(u8, dst_addr, self.read(u8, src_addr));

    // Update PC
    // log.info("PC <- 0x{X:0>8}", .{self.read(u24, pc + 6)});
    self.pc = self.read(u24, self.pc + 6);
}
