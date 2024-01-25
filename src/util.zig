const std = @import("std");
const Atomic = std.atomic.Value;
const Timer = std.time.Timer;

pub const FrameCounter = struct {
    elapsed: u32 = 0,
    latch: u32 = 0,
    timer: Timer,

    pub fn start() !FrameCounter {
        return .{ .timer = try std.time.Timer.start() };
    }

    pub fn tick(self: *FrameCounter) void {
        _ = @atomicRmw(u32, &self.elapsed, .Add, 1, .Monotonic);
    }

    /// Will report + reset the frame count if more than a second has passed
    pub fn lap(self: *FrameCounter) u32 {
        if (self.timer.read() >= std.time.ns_per_s) {
            self.timer.reset();
            self.latch = @atomicRmw(u32, &self.elapsed, .Xchg, 0, .Monotonic);
        }

        return self.latch;
    }
};
