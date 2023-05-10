const std = @import("std");
const utils = @import("utils.zig");
const fs = std.fs;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub const NGConfig = struct {
    root: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, map: std.StringHashMap([]const u8)) !NGConfig {
        // TODO Make root mandatory
        var root = try allocator.dupe(u8, map.get("root") orelse "./");
        root = fs.cwd().realpathAlloc(allocator, root) catch |err| {
            try stderr.print("{s} is no valid dir\n", .{root});
            return err;
        };
        
        return NGConfig {
            .root = root,
            .allocator = allocator
        };
    }

    pub fn initJSON(allocator: std.mem.Allocator, jsonPath: []const u8) NGConfig {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        _ = jsonPath;

        return NGConfig {
            .root = undefined,
            .allocator = allocator
        };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.root);
    }
};
