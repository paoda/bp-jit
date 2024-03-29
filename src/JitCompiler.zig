const std = @import("std");
const builtin = @import("builtin");
const BytePusher = @import("BytePusher.zig");

const Allocator = std.mem.Allocator;
const HashMap = std.HashMap(u24, Block, Context, 80);
const ArrayList = std.ArrayList;
const log = std.log.scoped(.Jit);

const JitCompiler = @This();
const JitFnPtr = *const fn (*[BytePusher.mem_size]u8, u32) callconv(.SysV) u32;

code: ArrayList(u8),
map: HashMap,

const Block = struct {
    mem: []align(std.mem.page_size) u8,
    cycle_count: u32 = 0,
    vacant: bool = true,
};

pub fn init(allocator: Allocator) !JitCompiler {
    return .{
        .map = HashMap.initContext(allocator, .{}),
        .code = try ArrayList(u8).initCapacity(allocator, 64), // smallest block is 40 instructions
    };
}

pub fn deinit(self: *JitCompiler, _: Allocator) void {
    self.code.deinit();

    var it = self.map.iterator();
    while (it.next()) |entry| {
        const block = entry.value_ptr;
        if (block.vacant) continue;

        log.debug("block of {} instructions found at PC: 0x{X:0>8}", .{ block.cycle_count, entry.key_ptr.* });

        if (builtin.os.tag != .windows) {
            std.os.munmap(block.mem);
        } else {
            const MEM_RELEASE = std.os.windows.MEM_RELEASE;
            std.os.windows.VirtualFree(block.mem.ptr, 0, MEM_RELEASE);
        }
    }

    self.map.deinit();
}

fn compile(self: *JitCompiler, bp: *const BytePusher) !Block {
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

        const ret: [*]align(alignment) u8 = @ptrCast(@alignCast(ptr));
        break :blk ret[0..self.code.items.len];
    };

    @memcpy(mem, self.code.items);

    return .{
        .mem = mem,
        .cycle_count = instr_count,
        .vacant = false,
    };
}

pub fn execute(self: *JitCompiler, bp: *BytePusher) u32 {
    const pc = bp.pc;

    const entry = self.map.getOrPut(pc) catch |e| panic("failed to access HashMap: {}", .{e});
    if (!entry.found_existing) {
        log.warn("cache miss. recompiling...", .{});
        entry.value_ptr.* = self.compile(bp) catch |e| panic("failed to compile block: {}", .{e});
    }
    const block = entry.value_ptr;

    const fn_ptr: JitFnPtr = @ptrCast(block.mem);
    bp.pc = @as(u24, @intCast(fn_ptr(bp.memory, pc)));

    return block.cycle_count;
}

fn panic(comptime format: []const u8, args: anytype) noreturn {
    @setCold(true);
    std.debug.panic(format, args);
}

const Context = struct {
    pub fn hash(self: @This(), value: u24) u64 {
        _ = self;
        return value;
    }

    pub fn eql(self: @This(), left: u24, right: u24) bool {
        _ = self;

        return left == right;
    }
};
