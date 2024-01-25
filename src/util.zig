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

pub const AudioQueue = struct {
    inner: RingBuffer(u8),
    mutex: std.Thread.Mutex = .{},

    pub fn init(buf: []u8) AudioQueue {
        return .{ .inner = RingBuffer(u8).init(buf) };
    }

    pub fn push(self: *AudioQueue, value: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.inner.push(value);
    }

    pub fn pop(self: *AudioQueue) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.inner.pop();
    }

    pub fn len(self: *AudioQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.inner.len();
    }
};

fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const Index = usize;
        const max_capacity = (@as(Index, 1) << @typeInfo(Index).Int.bits - 1) - 1; // half the range of index type

        const log = std.log.scoped(.RingBuffer);

        read: Index,
        write: Index,
        buf: []T,

        const Error = error{buffer_full};

        pub fn init(buf: []T) Self {
            std.debug.assert(std.math.isPowerOfTwo(buf.len)); // capacity must be a power of two
            std.debug.assert(buf.len <= max_capacity);

            return .{ .read = 0, .write = 0, .buf = buf };
        }

        pub fn push(self: *Self, value: T) Error!void {
            if (self.isFull()) return error.buffer_full;
            defer self.write += 1;

            self.buf[self.mask(self.write)] = value;
        }

        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) return null;
            defer self.read += 1;

            return self.buf[self.mask(self.read)];
        }

        /// Returns the number of entries read
        pub fn copy(self: *const Self, cpy: []T) Index {
            const count = @min(self.len(), cpy.len);
            var start: Index = self.read;

            for (cpy, 0..) |*v, i| {
                if (i >= count) break;

                v.* = self.buf[self.mask(start)];
                start += 1;
            }

            return count;
        }

        fn len(self: *const Self) Index {
            return self.write - self.read;
        }

        fn isFull(self: *const Self) bool {
            return self.len() == self.buf.len;
        }

        fn isEmpty(self: *const Self) bool {
            return self.read == self.write;
        }

        fn mask(self: *const Self, idx: Index) Index {
            return idx & (self.buf.len - 1);
        }
    };
}
