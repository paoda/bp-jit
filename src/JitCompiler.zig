const std = @import("std");
const BytePusher = @import("BytePusher.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const PROT = std.os.PROT;
const MAP = std.os.MAP;

const Self = @This();
const log = std.log.scoped(.JIT);

const code_buf_len = std.mem.page_size * 64; // 256KiB

code: ArrayList(u8),
exec_mem: []align(std.mem.page_size) u8,
allocator: Allocator,

pub fn init(allocator: Allocator) !Self {
    return .{
        // TODO: Windows?
        .exec_mem = try std.os.mmap(null, code_buf_len, PROT.WRITE | PROT.EXEC, MAP.ANONYMOUS | MAP.PRIVATE, -1, 0),
        .allocator = allocator,
        .code = try ArrayList(u8).initCapacity(allocator, code_buf_len),
    };
}

pub fn deinit(self: *Self) void {
    self.code.deinit();
    std.os.munmap(self.exec_mem);
    self.* = undefined;
}

pub fn compile(self: *Self, bp: *const BytePusher) !u32 {
    // Translate BytePusher Instructions to x86 assembly
    var instr_count: u32 = 0;
    var current_pc = bp.pc;

    var writer = self.code.writer();
    defer self.code.clearRetainingCapacity();

    // SysV CC prelude
    // zig fmt: off
    try writer.writeAll(&.{
        0x55, // push rbp
        0x48, 0x89, 0xE5, // mov rbp, rsp
        // 0xCC, // INT3
    });
    // zig fmt: on

    while (true) {
        instr_count += 1;

        // Note: rdi holds the pointer to memory (1st parameter)
        // Note: rsi holds the BytePusher Program Counter (2nd parameter)
        // Note: edx, ecx, and r8 are scratch registers

        // 1. load memory[PC + 0] (this is the src addr)
        // 2. shift src addr to the right twice (24-bit integer)
        // 3. mask the 24 bits
        // zig fmt: off
        try writer.writeAll(&.{
            0x0F, 0x38, 0xF0, 0x14, 0x37,       // movbe edx, DWORD PTR [rdi + rsi]
            0xC1, 0xEA, 0x08,                   // shr edx, 8
            // 0x81, 0xE2, 0xFF, 0xFF, 0xFF, 0x00  // and edx, 0x00FF_FFFF
        });
        // zig fmt: on

        // 4. load memory[PC + 3] (this is the dest addr)
        // 5. shift dest addr to the right twice (24-bit integer)
        // 6. mask the 24 bits
        // zig fmt: off
        try writer.writeAll(&.{
            0x0F, 0x38, 0xF0, 0x4C, 0x37, 0x03, // movbe ecx, DWORD PTR[rdi + rsi + 3]
            0xC1, 0xE9, 0x08,                   // shr ecx, 8
            // 0x81, 0xE1, 0xFF, 0xFF, 0xFF, 0x0   // and ecx, 0x00FF_FFFF
        });
        // zig fmt: on

        // load value at memory[src_addr] into memory[dest_addr]
        // zig fmt: off
        try writer.writeAll(&.{
            0x44, 0x8A, 0x04, 0x17, // mov r8b, BYTE PTR [rdi + rdx]
            0x44, 0x88, 0x04, 0x0F  // mov BYTE PTR [rdi + rcx], r8b
        });
        // zig fmt: on

        // If next program counter isn't sequential, break. We have accounted for every
        // instruction we can compile at once
        const next_pc = bp.read(u24, current_pc + 6);
        if (next_pc != current_pc + 9) break;

        // add 9 to PC to prepare for next sequential instruction
        try writer.writeAll(&.{ 0x83, 0xC6, 0x09 }); // add esi, 9

        // update our current pc and continue the loop
        current_pc = next_pc;
    }

    // // mov eax, DWORD PTR [rdi + rsi + 6] ; load memory[PC + 6] into EAX so it can be returned to the caller
    // try writer.writeAll(&.{ 0x8B, 0x44, 0x37, 0x06 });

    // load memory[PC +6] into EAX so Zig can assign it to the BytePusher struct's pc variable
    // zig fmt: off
    try writer.writeAll(&.{
        0x0F, 0x38, 0xF0, 0x44, 0x37, 0x06, // movbe eax, DWORD PTR [rdi + rsi + 6] 
        0xC1, 0xE8, 0x08,                   // shr eax, 8

        // SysV CC epilogue
        0x5D,                               // pop rpb
        0xC3                                // ret
    });
    // zig fmt: on

    // log.info("block of {} instructions compiled", .{instr_count});
    // log.info("buf len: {}", .{self.code.items.len});
    std.mem.copy(u8, self.exec_mem, self.code.items);

    return instr_count;
}

pub fn execute(self: *Self, bp: *BytePusher) void {
    const mem_size = BytePusher.mem_size;

    const fn_ptr = @ptrCast(*const fn (*[mem_size]u8, u32) callconv(.SysV) u32, self.exec_mem);
    bp.pc = @intCast(u24, fn_ptr(&bp.memory[0], bp.pc));
}

/// Code Block
const Block = struct {
    code: ArrayList(u8),

    start_addr: u24,
    len: usize = 0,
    dirty: bool = false,

    pub fn init(allocator: Allocator, start_addr: u24) !Self {
        return .{
            .code = ArrayList(u8).init(allocator),
            .start_addr = start_addr,
        };
    }
};
