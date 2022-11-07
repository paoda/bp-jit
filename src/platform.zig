const std = @import("std");
const SDL = @import("sdl2");
const gl = @import("gl");

const emu = @import("emu.zig");

const Allocator = std.mem.Allocator;
const BytePusher = @import("BytePusher.zig");

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
    const SDL_GLContext = *anyopaque;
    const log = std.log.scoped(.Gui);
    const title: []const u8 = "BytePusher JIT";

    window: *SDL.SDL_Window,
    ctx: SDL_GLContext,
    framebuffer: FrameBuffer,

    program_id: c_uint,

    pub fn init(allocator: Allocator) !Self {
        if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0) panic();
        if (SDL.SDL_GL_SetAttribute(SDL.SDL_GL_CONTEXT_PROFILE_MASK, SDL.SDL_GL_CONTEXT_PROFILE_CORE) < 0) panic();
        if (SDL.SDL_GL_SetAttribute(SDL.SDL_GL_CONTEXT_MAJOR_VERSION, 3) < 0) panic();
        if (SDL.SDL_GL_SetAttribute(SDL.SDL_GL_CONTEXT_MAJOR_VERSION, 3) < 0) panic();

        const window = SDL.SDL_CreateWindow(
            title.ptr,
            SDL.SDL_WINDOWPOS_CENTERED,
            SDL.SDL_WINDOWPOS_CENTERED,
            width * 3,
            height * 3,
            SDL.SDL_WINDOW_OPENGL | SDL.SDL_WINDOW_SHOWN,
        ) orelse panic();

        const ctx = SDL.SDL_GL_CreateContext(window) orelse panic();
        if (SDL.SDL_GL_MakeCurrent(window, ctx) < 0) panic();

        gl.load(ctx, Self.procAddress) catch @panic("gl.load failed");
        if (SDL.SDL_GL_SetSwapInterval(1) < 0) panic();

        const program_id = compileShaders();

        const framebuffer = try FrameBuffer.init(allocator);

        return .{ .window = window, .ctx = ctx, .framebuffer = framebuffer, .program_id = program_id };
    }

    pub fn deinit(self: *Self) void {
        self.framebuffer.deinit();

        // TODO: OpenGL Buffer Deallocations
        gl.deleteProgram(self.program_id);
        SDL.SDL_GL_DeleteContext(self.ctx);
        SDL.SDL_DestroyWindow(self.window);
        SDL.SDL_Quit();
        self.* = undefined;
    }

    fn procAddress(ctx: SDL.SDL_GLContext, proc: [:0]const u8) ?*anyopaque {
        _ = ctx;
        return SDL.SDL_GL_GetProcAddress(proc.ptr);
    }

    pub fn run(self: *Self, bp: *BytePusher) void {
        const vao_id = generateBuffers()[0];
        _ = generateTexture(self.framebuffer.get(.Host));

        emu_loop: while (true) {
            emu.jit.runFrame(bp, &self.framebuffer);
            // emu.interpreter.runFrame(bp, &self.framebuffer);

            var event: SDL.SDL_Event = undefined;
            while (SDL.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    SDL.SDL_QUIT => break :emu_loop,
                    else => {}, // TODO: Add Input
                }
            }

            const buf: []const u8 = self.framebuffer.get(.Host);
            gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

            gl.useProgram(self.program_id);
            gl.bindVertexArray(vao_id);
            gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, null);
            SDL.SDL_GL_SwapWindow(self.window);
        }
    }
};

fn panic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}

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
