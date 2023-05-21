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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const stderr = std.io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    for (res.positionals) |pos| std.debug.print("{s}", .{pos});

    switch (res.positionals.len) {
        0 => try stderr.print("user did not provide a file path as an argument", .{}),
        else => {
            if (res.positionals.len > 1) try stderr.print("did not expect more than 1 argument (note: saw {})", .{res.positionals.len});
            const path = res.positionals[0];

            var gui = try Gui.init(allocator);
            defer gui.deinit();

            var bp = try BytePusher.init(allocator, path);
            defer bp.deinit();

            try gui.run(&bp);
        },
    }
}
