const std = @import("std");
const BytePusher = @import("BytePusher.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const PROT = std.os.PROT;
const MAP = std.os.MAP;

const Self = @This();
const log = std.log.scoped(.JIT);

code: ArrayList(u8),
exec_mem: ?[]align(std.mem.page_size) u8 = null,
allocator: Allocator,

pub fn init(allocator: Allocator) !Self {
    return .{
        .allocator = allocator,
        .code = ArrayList(u8).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.code.deinit();
    if (self.exec_mem) |memory| std.os.munmap(memory);
    self.* = undefined;
}

pub fn compile(self: *Self, bp: *const BytePusher) !void {
    // Translate BytePusher Instructions to x86 assembly
    var instr_count: usize = 0;
    var current_pc = bp.pc;

    self.code.clearAndFree();

    // SysV CC prelude
    try self.code.append(0x55); // push rbp
    try self.code.appendSlice(&.{ 0x48, 0x89, 0xE5 }); // mov rbp, rsp

    while (true) {
        instr_count += 1;

        // Note: rdi holds the pointer to memory (1st parameter)
        // Note: rsi holds the BytePusher Program Counter (2nd parameter)
        // Note: edx, ecx, and r8 are scratch registers

        // mov edx, DWORD PTR [rdi + rsi] ; load memory[PC + 0] to edx (src addr)
        try self.code.appendSlice(&.{ 0x8B, 0x14, 0x37 });

        // mov ecx, DWORD PTR[rdi + rsi + 3] ; load memory[PC + 3] to ecx (dst addr)
        try self.code.appendSlice(&.{ 0x8B, 0x4C, 0x37, 0x03 });

        // mov r8b, BYTE PTR [rdi + rdx] ; load value at memory[src_addr] to scratch register
        try self.code.appendSlice(&.{ 0x44, 0x8A, 0x04, 0x17 });

        // mov BYTE PTR [rdi + rcx], r8b  ; store value in scratch register to memory[dest_addr]
        try self.code.appendSlice(&.{ 0x44, 0x88, 0x04, 0x0F });

        // If the next program counter doesn't point to the next instruction,
        // return. We know how many instructions there are in this code block
        const next_pc = bp.read(u24, current_pc + 6);
        if (next_pc != current_pc + 9) break;

        // add esi, 9 ; add 9 to PC to prepare for next BytePusher instruction
        try self.code.appendSlice(&.{ 0x83, 0xC6, 0x09 });

        // update our current pc and continue the loop
        current_pc = next_pc;
    }
    log.info("block of {} instructions compiled", .{instr_count});

    // mov eax, DWORD PTR [rdi + rsi + 6] ; load memory[PC + 6] into EAX so it can be returned to the caller
    try self.code.appendSlice(&.{ 0x8B, 0x44, 0x37, 0x06 });

    // SysV CC epilogue
    try self.code.append(0x5D); // pop rbp
    try self.code.append(0xC3); // ret

    // TODO: Windows?

    const memory = try std.os.mmap(null, self.code.items.len, PROT.WRITE | PROT.EXEC, MAP.ANONYMOUS | MAP.PRIVATE, -1, 0);
    std.mem.copy(u8, memory, self.code.items);

    self.exec_mem = memory;
}

pub fn execute(self: *Self, bp: *BytePusher) void {
    const mem_size = BytePusher.mem_size;

    // // move this pointer into r13. the x86 JIT assumes this register
    // // holds the pointer to the byte pussher assembly
    // asm volatile (
    //     \\mov %[memory] %%r13
    //     \\mov %[pc] %%r12
    //     :
    //     : [memory] "{r11}" (memory),
    //       [pc] "{r10}" (bp.pc),
    //     : "r13", "r12" // I clobber r13 and r12
    // );

    const memory = self.exec_mem orelse @panic("no compiled code to run");
    defer {
        std.os.munmap(memory);
        self.exec_mem = null;
    }

    const fn_ptr = @ptrCast(*const fn (*[mem_size]u8, u32) callconv(.SysV) u32, memory);
    bp.pc = @intCast(u24, fn_ptr(bp.memory, bp.pc));
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
