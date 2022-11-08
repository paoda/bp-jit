const std = @import("std");
const builtin = @import("builtin");
const BytePusher = @import("BytePusher.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const log = std.log.scoped(.Jit);

const JitFn = *const fn (*[BytePusher.mem_size]u8, u32) callconv(.SysV) u32;
const Self = @This();

code: ArrayList(u8),

table: []?Block,
allocator: Allocator,

const Block = struct {
    mem: []align(std.mem.page_size) u8,
    cycle_count: u32,
};

pub fn init(allocator: Allocator) !Self {
    const table = try allocator.alloc(?Block, BytePusher.mem_size);
    std.mem.set(?Block, table, null);

    return .{
        .table = table,
        .code = try ArrayList(u8).initCapacity(allocator, 64), // smallest block is 40 instructions
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.code.deinit();

    for (self.table) |maybe_block, i| {
        if (maybe_block == null) continue;

        log.debug("block of {} instructions found at PC: 0x{X:0>8}", .{ maybe_block.?.cycle_count, i });

        if (builtin.os.tag != .windows) {
            std.os.munmap(maybe_block.?.mem);
        } else {
            const MEM_RELEASE = std.os.windows.MEM_RELEASE;
            std.os.windows.VirtualFree(maybe_block.?.mem.ptr, 0, MEM_RELEASE);
        }
    }

    self.allocator.free(self.table);
    self.* = undefined;
}

fn compile(self: *Self, bp: *const BytePusher) !Block {
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
        // zig fmt: off
        try writer.writeAll(&.{
            0x0F, 0x38, 0xF0, 0x14, 0x37,   // movbe edx, DWORD PTR [rdi + rsi]
            0xC1, 0xEA, 0x08,               // shr edx, 8
        });
        // zig fmt: on

        // 3. load memory[PC + 3] (this is the dest addr)
        // 4. shift dest addr to the right twice (24-bit integer)
        // zig fmt: off
        try writer.writeAll(&.{
            0x0F, 0x38, 0xF0, 0x4C, 0x37, 0x03, // movbe ecx, DWORD PTR[rdi + rsi + 3]
            0xC1, 0xE9, 0x08,                   // shr ecx, 8
        });
        // zig fmt: on

        // 5. load value at memory[src_addr] into memory[dest_addr]
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

        // 6. add 9 to PC to prepare for next sequential instruction
        try writer.writeAll(&.{ 0x83, 0xC6, 0x09 }); // add esi, 9

        // update our current pc and continue the loop
        current_pc = next_pc;
    }

    // load memory[PC +6] into EAX as the return value
    // zig fmt: off
    try writer.writeAll(&.{
        0x0F, 0x38, 0xF0, 0x44, 0x37, 0x06, // movbe eax, DWORD PTR [rdi + rsi + 6] 
        0xC1, 0xE8, 0x08,                   // shr eax, 8

        // SysV CC epilogue
        0x5D,                               // pop rpb
        0xC3                                // ret
    });
    // zig fmt: on
    log.info("compiled a block of {} instructions", .{instr_count});

    const mem = if (builtin.os.tag != .windows) blk: {
        const PROT = std.os.PROT;
        const MAP = std.os.MAP;

        break :blk try std.os.mmap(null, self.code.items.len, PROT.WRITE | PROT.EXEC, MAP.ANONYMOUS | MAP.PRIVATE, -1, 0);
    } else blk: {
        const MEM_COMMIT = std.os.windows.MEM_COMMIT;
        const PAGE_EXECUTE_READWRITE = std.os.windows.PAGE_EXECUTE_READWRITE;
        const alignment = std.mem.page_size;

        const ptr = try std.os.windows.VirtualAlloc(null, self.code.items.len, MEM_COMMIT, PAGE_EXECUTE_READWRITE);
        break :blk @ptrCast([*]align(alignment) u8, @alignCast(alignment, ptr))[0..self.code.items.len];
    };
    std.mem.copy(u8, mem, self.code.items);

    return .{
        .mem = mem,
        .cycle_count = instr_count,
    };
}

pub fn execute(self: *Self, bp: *BytePusher) u32 {
    const pc = bp.pc;

    if (self.table[pc] == null) {
        log.warn("cache miss. recompiling...", .{});
        self.table[pc] = self.compile(bp) catch |e| std.debug.panic("failed to compile block: {}", .{e});
    }

    const fn_ptr = @ptrCast(JitFn, self.table[pc].?.mem);
    bp.pc = @intCast(u24, fn_ptr(bp.memory, pc));

    return self.table[pc].?.cycle_count;
}
