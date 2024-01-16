const std = @import("std");
const clap = @import("clap");

const Gui = @import("platform.zig").Gui;
const BytePusher = @import("BytePusher.zig");

const params = clap.parseParamsComptime(
    \\-h, --help    Display this help and exit.
    \\<str>...     Path to BytePusher ROM  
    \\
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();
    const stderr = std.io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    for (res.positionals) |pos| std.debug.print("{s}", .{pos});

    switch (res.positionals.len) {
        0 => return error.no_file_provided,
        else => {
            if (res.positionals.len > 1) return error.more_than_one_file_provided;
            const path = res.positionals[0];

            var gui = try Gui.init(allocator);
            defer gui.deinit(allocator);

            var bp = try BytePusher.init(allocator, path);
            defer bp.deinit(allocator);

            try gui.run(&bp);
        },
    }
}
