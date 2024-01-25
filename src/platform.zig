const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const zgui = @import("zgui");
const emu = @import("emu.zig");

const Window = glfw.Window;
const Key = glfw.Key;
const Mods = glfw.Mods;
const Action = glfw.Action;
const GLuint = gl.GLuint;

const Allocator = std.mem.Allocator;
const BytePusher = @import("BytePusher.zig");
const FrameCounter = @import("util.zig").FrameCounter;

const win_width = 1280;
const win_height = 720;

const bp_width = BytePusher.width;
const bp_height = BytePusher.height;

pub const Gui = struct {
    const log = std.log.scoped(.gui);

    window: Window,
    framebuffer: FrameBuffer,

    pub fn init(allocator: Allocator) !Gui {
        if (!glfw.init(.{})) return error.glfw_init_failed;
        glfw.setErrorCallback(handleError);

        const window = Window.create(win_width, win_height, "BytePusher JIT (?)", null, null, .{}) orelse return error.glfw_window_init_failed;
        glfw.makeContextCurrent(window);
        glfw.swapInterval(1); // enable vsync

        window.setKeyCallback(handleKeyInput);

        const proc_address = struct {
            fn inner(_: void, name: [:0]const u8) ?*const anyopaque {
                return glfw.getProcAddress(name);
            }
        }.inner;

        try gl.load({}, proc_address);

        zgui.init(allocator);
        zgui.backend.initWithGlSlVersion(window.handle, "#version 330 core");

        return .{
            .window = window,
            .framebuffer = try FrameBuffer.init(allocator),
        };
    }

    pub fn deinit(self: Gui, allocator: Allocator) void {
        // Deinit Imgui
        zgui.backend.deinit();
        zgui.deinit();

        self.framebuffer.deinit(allocator);

        self.window.destroy();
        glfw.terminate();
    }

    pub fn run(self: *Gui, bp: *BytePusher) !void {
        self.window.setUserPointer(bp); // expose BytePusher to glfw callbacks

        const vao_id = opengl_impl.vao();
        defer gl.deleteVertexArrays(1, &[_]GLuint{vao_id});

        const emu_tex = opengl_impl.screenTex(self.framebuffer.get(.host));
        const out_tex = opengl_impl.outTex();
        defer gl.deleteTextures(2, &[_]GLuint{ emu_tex, out_tex });

        const fbo_id = try opengl_impl.frameBuffer(out_tex);
        defer gl.deleteFramebuffers(1, &fbo_id);

        const prog_id = try opengl_impl.program(); // Dynamic Shaders?
        defer gl.deleteProgram(prog_id);

        var quit = std.atomic.Value(bool).init(false);
        var counter = try FrameCounter.start();

        const thread = try std.Thread.spawn(.{}, emu.run, .{ bp, &self.framebuffer, &quit, &counter });
        defer thread.join();

        while (!self.window.shouldClose()) {
            glfw.pollEvents();

            // Draw Bytepusher Screen to Texture
            {
                gl.bindFramebuffer(gl.FRAMEBUFFER, fbo_id);
                defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                gl.viewport(0, 0, bp_width, bp_height);
                opengl_impl.drawScreen(emu_tex, prog_id, vao_id, self.framebuffer.get(.host));
            }

            self.draw(out_tex, &counter);

            // Background Color
            const size = zgui.io.getDisplaySize();
            gl.viewport(0, 0, @intFromFloat(size[0]), @intFromFloat(size[1]));
            gl.clearColor(0, 0, 0, 1.0);
            gl.clear(gl.COLOR_BUFFER_BIT);

            zgui.backend.draw();
            self.window.swapBuffers();
        }

        quit.store(true, .SeqCst);
    }

    fn draw(_: *Gui, tex_id: c_uint, counter: *FrameCounter) void {
        zgui.backend.newFrame(win_width, win_height);

        {
            _ = zgui.begin("Screen", .{ .flags = .{ .no_resize = true } });
            defer zgui.end();

            const args = .{
                .w = bp_width * 2,
                .h = bp_height * 2,
            };

            zgui.image(@ptrFromInt(tex_id), args);
        }

        {
            _ = zgui.begin("Statistics", .{});
            defer zgui.end();

            zgui.text("FPS: {:0>3}", .{counter.lap()});
        }
    }

    fn handleKeyInput(window: Window, key: Key, scancode: i32, action: Action, mods: Mods) void {
        _ = scancode;
        _ = mods;

        const bp = window.getUserPointer(BytePusher) orelse {
            log.err("glfw key callback does not have access to BytePusher state", .{});
            return;
        };

        const key_ptr: *u16 = @ptrCast(@alignCast(bp.memory));

        switch (action) {
            .press => key_ptr.* |= emu.key(key),
            .release => key_ptr.* &= ~emu.key(key),
            else => {},
        }
    }

    fn handleError(code: glfw.ErrorCode, description: [:0]const u8) void {
        log.err("glfw: {}: {s}\n", .{ code, description });
    }
};

pub const FrameBuffer = struct {
    const buf_size = (bp_width * @sizeOf(u32)) * bp_height;

    buf: *[buf_size * 2]u8,
    current: u1,

    // TODO: rename
    const Destination = enum { guest, host };

    pub fn init(allocator: Allocator) !FrameBuffer {
        const buf = try allocator.alignedAlloc(u8, @alignOf(u24), buf_size * 2);
        @memset(buf, 0);

        return .{
            .buf = buf[0 .. buf_size * 2],
            .current = 0,
        };
    }

    pub fn deinit(self: FrameBuffer, allocator: Allocator) void {
        allocator.destroy(self.buf);
    }

    pub fn swap(self: *FrameBuffer) void {
        self.current = ~self.current;
    }

    pub fn get(self: *const FrameBuffer, comptime dst: Destination) *[buf_size]u8 {
        const multiplicand: usize = if (dst == .guest) self.current else ~self.current;
        return self.buf[buf_size * multiplicand ..][0..buf_size];
    }
};

fn exitln(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

const opengl_impl = struct {
    fn drawScreen(tex_id: GLuint, prog_id: GLuint, vao_id: GLuint, buf: []const u8) void {
        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, bp_width, bp_height, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

        // Bind VAO
        gl.bindVertexArray(vao_id);
        defer gl.bindVertexArray(0);

        // Use compiled frag + vertex shader
        gl.useProgram(prog_id);
        defer gl.useProgram(0);

        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 3);
    }

    fn program() !GLuint {
        const vert_shader = @embedFile("shader/pixelbuf.vert");
        const frag_shader = @embedFile("shader/pixelbuf.frag");

        const vs = gl.createShader(gl.VERTEX_SHADER);
        defer gl.deleteShader(vs);

        gl.shaderSource(vs, 1, &[_][*c]const u8{vert_shader}, 0);
        gl.compileShader(vs);

        if (!shader.didCompile(vs)) return error.VertexCompileError;

        const fs = gl.createShader(gl.FRAGMENT_SHADER);
        defer gl.deleteShader(fs);

        gl.shaderSource(fs, 1, &[_][*c]const u8{frag_shader}, 0);
        gl.compileShader(fs);

        if (!shader.didCompile(fs)) return error.FragmentCompileError;

        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);

        return prog;
    }

    fn vao() GLuint {
        var vao_id: GLuint = undefined;
        gl.genVertexArrays(1, &vao_id);

        return vao_id;
    }

    fn screenTex(buf: []const u8) GLuint {
        var tex_id: GLuint = undefined;
        gl.genTextures(1, &tex_id);

        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, bp_width, bp_height, 0, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

        return tex_id;
    }

    fn outTex() GLuint {
        var tex_id: GLuint = undefined;
        gl.genTextures(1, &tex_id);

        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, bp_width, bp_height, 0, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, null);

        return tex_id;
    }

    fn frameBuffer(tex_id: GLuint) !GLuint {
        var fbo_id: GLuint = undefined;
        gl.genFramebuffers(1, &fbo_id);

        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo_id);
        defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        gl.framebufferTexture(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, tex_id, 0);
        gl.drawBuffers(1, &@as(GLuint, gl.COLOR_ATTACHMENT0));

        if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)
            return error.FrameBufferObejctInitFailed;

        return fbo_id;
    }

    const shader = struct {
        const log = std.log.scoped(.shader);

        fn didCompile(id: gl.GLuint) bool {
            var success: gl.GLint = undefined;
            gl.getShaderiv(id, gl.COMPILE_STATUS, &success);

            if (success == 0) err(id);

            return success == 1;
        }

        fn err(id: gl.GLuint) void {
            const buf_len = 512;
            var error_msg: [buf_len]u8 = undefined;

            gl.getShaderInfoLog(id, buf_len, 0, &error_msg);
            log.err("{s}", .{std.mem.sliceTo(&error_msg, 0)});
        }
    };
};
