const std = @import("std");
const proc = std.process;
const mem = std.mem;

const config = @import("config.zig");

pub fn openInNvim(allocator: std.mem.Allocator, path: []const u8, pipe: []const u8) !void {
    const vim_command = try std.fmt.allocPrint(allocator, ":e {s}<CR>", .{path});
    const argv = [_][]const u8{ "nvim", "--server", pipe, "--remote-send", vim_command };
    const result = try std.ChildProcess.run(.{ .argv = &argv, .allocator = allocator });
    _ = result;
}
