const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");

const emu = @import("emu.zig");

const Window = glfw.Window;
const Key = glfw.Key;
const Mods = glfw.Mods;
const Action = glfw.Action;

const Allocator = std.mem.Allocator;
const BytePusher = @import("BytePusher.zig");
const FpsTracker = @import("util.zig").FpsTracker;

// zig fmt: off
const vertices: [32]f32 = [_]f32{
    // Positions        // Colours      // Texture Coords
     1.0, -1.0, 0.0,    1.0, 0.0, 0.0,  1.0, 1.0, // Top Right
     1.0,  1.0, 0.0,    0.0, 1.0, 0.0,  1.0, 0.0, // Bottom Right
    -1.0,  1.0, 0.0,    0.0, 0.0, 1.0,  0.0, 0.0, // Bottom Left
    -1.0, -1.0, 0.0,    1.0, 1.0, 0.0,  0.0, 1.0, // Top Left
};

const indices: [6]u32 = [_]u32{
    0, 1, 3, // First Triangle
    1, 2, 3, // Second Triangle
};
 // zig fmt: on

const width = 256;
const height = width;

pub const Gui = struct {
    const Self = @This();
    const log = std.log.scoped(.Gui);
    const title = "BytePusher JIT";

    window: Window,
    framebuffer: FrameBuffer,

    program_id: c_uint,

    pub fn init(allocator: Allocator) !Self {
        try glfw.init(.{});

        const window = try glfw.Window.create(width * 3, height * 3, title, null, null, .{});
        try glfw.makeContextCurrent(window);
        window.setKeyCallback(keyCallback);

        try gl.load({}, getProcAddress);

        return .{
            .window = window,
            .framebuffer = try FrameBuffer.init(allocator),
            .program_id = compileShaders(),
        };
    }

    fn getProcAddress(_: void, proc_name: [:0]const u8) ?*const anyopaque {
        return glfw.getProcAddress(proc_name);
    }

    pub fn deinit(self: *Self) void {
        self.framebuffer.deinit();

        // TODO: OpenGL Buffer Deallocations
        gl.deleteProgram(self.program_id);

        self.window.destroy();
        glfw.terminate();
        self.* = undefined;
    }

    pub fn run(self: *Self, bp: *BytePusher) !void {
        self.window.setUserPointer(bp); // expose BytePusher to glfw callbacks

        const vao_id = generateBuffers()[0];
        _ = generateTexture(self.framebuffer.get(.Host));

        var quit = std.atomic.Atomic(bool).init(false);
        var tracker = FpsTracker.init();

        const thread = try std.Thread.spawn(.{}, emu.run, .{ bp, &self.framebuffer, &quit, &tracker });
        defer thread.join();

        var title_buf: [0x100]u8 = undefined;

        while (!self.window.shouldClose()) {
            try glfw.pollEvents();

            const buf: []const u8 = self.framebuffer.get(.Host);
            gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

            gl.useProgram(self.program_id);
            gl.bindVertexArray(vao_id);
            gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, null);
            try self.window.swapBuffers();

            const dyn_title = std.fmt.bufPrintZ(&title_buf, "{s} | Emu: {}fps", .{ title, tracker.value() }) catch unreachable;
            try self.window.setTitle(dyn_title);
        }

        quit.store(true, .SeqCst);
    }

    fn keyCallback(window: Window, key: Key, scancode: i32, action: Action, mods: Mods) void {
        _ = scancode;
        _ = mods;

        const bp = window.getUserPointer(BytePusher) orelse {
            log.err("glfw key callback does not have access to BytePusher state", .{});
            return;
        };

        const key_ptr = @ptrCast(*u16, @alignCast(@alignOf(u16), bp.memory));

        switch (action) {
            .press => key_ptr.* |= emu.key(key),
            .release => key_ptr.* &= ~emu.key(key),
            else => {},
        }
    }
};

fn compileShaders() c_uint {
    // TODO: Panic on Shader Compiler Failure + Error Message
    const vert_shader = @embedFile("shader/pixelbuf.vert");
    const frag_shader = @embedFile("shader/pixelbuf.frag");

    const vs = gl.createShader(gl.VERTEX_SHADER);
    defer gl.deleteShader(vs);

    gl.shaderSource(vs, 1, &[_][*c]const u8{vert_shader}, 0);
    gl.compileShader(vs);

    const fs = gl.createShader(gl.FRAGMENT_SHADER);
    defer gl.deleteShader(fs);

    gl.shaderSource(fs, 1, &[_][*c]const u8{frag_shader}, 0);
    gl.compileShader(fs);

    const program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);

    return program;
}

fn generateTexture(buf: []const u8) c_uint {
    var tex_id: c_uint = undefined;
    gl.genTextures(1, &tex_id);
    gl.bindTexture(gl.TEXTURE_2D, tex_id);

    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);
    // gl.generateMipmap(gl.TEXTURE_2D); // TODO: Remove?

    return tex_id;
}

fn generateBuffers() [3]c_uint {
    var vao_id: c_uint = undefined;
    var vbo_id: c_uint = undefined;
    var ebo_id: c_uint = undefined;
    gl.genVertexArrays(1, &vao_id);
    gl.genBuffers(1, &vbo_id);
    gl.genBuffers(1, &ebo_id);

    gl.bindVertexArray(vao_id);

    gl.bindBuffer(gl.ARRAY_BUFFER, vbo_id);
    gl.bufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.STATIC_DRAW);

    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo_id);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, gl.STATIC_DRAW);

    // Position
    gl.vertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 8 * @sizeOf(f32), @intToPtr(?*anyopaque, 0)); // lmao
    gl.enableVertexAttribArray(0);
    // Colour
    gl.vertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, 8 * @sizeOf(f32), @intToPtr(?*anyopaque, (3 * @sizeOf(f32))));
    gl.enableVertexAttribArray(1);
    // Texture Coord
    gl.vertexAttribPointer(2, 2, gl.FLOAT, gl.FALSE, 8 * @sizeOf(f32), @intToPtr(?*anyopaque, (6 * @sizeOf(f32))));
    gl.enableVertexAttribArray(2);

    return .{ vao_id, vbo_id, ebo_id };
}

pub const FrameBuffer = struct {
    const Self = @This();
    const buf_size = width * height * @sizeOf(u32);

    layer: [2]*[buf_size]u8,
    buf: *[buf_size * 2]u8,
    current: u1,

    allocator: Allocator,

    const Destination = enum { Guest, Host };

    pub fn init(allocator: Allocator) !Self {
        const buf = try allocator.create([buf_size * 2]u8);
        std.mem.set(u8, buf, 0);

        return .{
            .layer = [_]*[buf_size]u8{ buf[0..buf_size], buf[buf_size..(buf_size * 2)] },
            .buf = buf,
            .current = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self.buf);
        self.* = undefined;
    }

    pub fn swap(self: *Self) void {
        self.current = ~self.current;
    }

    pub fn get(self: *Self, comptime dst: Destination) *[buf_size]u8 {
        return self.layer[if (dst == .Guest) self.current else ~self.current];
    }
};
