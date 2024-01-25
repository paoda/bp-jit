const std = @import("std");
const sysaudio = @import("sysaudio");

const Allocator = std.mem.Allocator;
const Context = sysaudio.Context;
const Player = sysaudio.Player;

const AudioQueue = @import("util.zig").AudioQueue;
const Audio = @This();
const log = std.log.scoped(.audio);

var player: Player = undefined; // yuck

ctx: Context,

pub fn init(allocator: Allocator, audio_queue: *AudioQueue) !Audio {
    var ctx = try Context.init(null, allocator, .{});
    try ctx.refresh();

    const default_device = ctx.defaultDevice(.playback) orelse return error.no_device;
    log.info("default device: {s}", .{default_device.name});

    player = try ctx.createPlayer(default_device, writeFn, .{ .user_data = audio_queue });

    log.info("Player Format: {s}", .{@tagName(player.format())});
    log.info("Player Sample Rate: {}Hz", .{player.sampleRate()});
    log.info("# of Channels: {}", .{player.channels().len});

    return .{ .ctx = ctx };
}

pub fn start(_: Audio) !void {
    try player.start();
}

pub fn deinit(self: Audio, _: Allocator) void {
    player.deinit();
    self.ctx.deinit();
}

fn writeFn(queue_ptr: ?*anyopaque, output: []u8) void {
    const queue: *AudioQueue = @ptrCast(@alignCast(queue_ptr));
    const frame_size = player.format().frameSize(@intCast(player.channels().len));

    log.debug("{} frames in queue", .{queue.len()});
    log.debug("seeking {} frames\n", .{output.len / frame_size});

    {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        var i: u24 = 0;
        var sample: u8 = 0;

        while (i < output.len) : (i += frame_size) {
            sample = queue.inner.pop() orelse sample;

            sysaudio.convertTo(u8, &.{ sample, sample }, player.format(), output[i..][0..frame_size]);
        }
    }
}
