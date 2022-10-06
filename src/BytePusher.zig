const std = @import("std");

const Allocator = std.mem.Allocator;

const Self = @This();
const log = std.log.scoped(.BytePusher);
const mem_size = 0x0100_0008; // 16 MiB

pc: u24,
memory: *[mem_size]u8,
allocator: Allocator,

pub fn init(allocator: Allocator, path: []const u8) !Self {
    const memory = try allocator.create([mem_size]u8);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const len = try file.readAll(memory);
    log.info("rom size: {}B", .{len});

    return .{
        .pc = 0x000000,
        .allocator = allocator,
        .memory = memory,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self.memory);
}

pub fn fetch(self: *Self) u24 {
    return self.read(u24, 0x000002);
}

fn read(self: *const Self, comptime T: type, addr: u24) T {
    return switch (T) {
        u24, u16, u8 => std.mem.readIntSliceBig(T, self.memory[addr..][0..@sizeOf(T)]),
        else => @compileError("bus: unsupported read width"),
    };
}

fn write(self: *Self, comptime T: type, addr: u24, value: T) void {
    switch (T) {
        u24, u16, u8 => std.mem.writeIntSliceBig(T, self.memory[addr..][0..@sizeOf(T)], value),
        else => @compileError("bus: unsupported write width"),
    }
}

const color_lut: [256]u32 = blk: {
    var lut: [256]u32 = undefined;

    for (lut) |*color, i| {
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

pub fn updateFrameBuffer(self: *const Self, buf: []u8) void {
    const page = @as(u24, self.read(u8, 0x000005)) << 16;

    var i: u16 = 0;
    while (i < std.math.maxInt(u16)) : (i += 1) {
        const rgba8888 = color_lut[self.read(u8, page | i)];
        std.mem.writeIntSliceNative(u32, buf[@as(u32, i) * @sizeOf(u32) ..][0..@sizeOf(u32)], rgba8888);
    }
}

pub fn step(self: *Self) void {
    const src_addr = self.read(u24, self.pc + 0);
    const dst_addr = self.read(u24, self.pc + 3);

    // Write Value
    // log.info("0x{X:0>8} <- {X:0>2}u8@0x{}", .{ dst_addr, self.read(u8, src_addr), src_addr });
    self.write(u8, dst_addr, self.read(u8, src_addr));

    // Update PC
    // log.info("PC <- 0x{X:0>8}", .{self.read(u24, pc + 6)});
    self.pc = self.read(u24, self.pc + 6);
}
