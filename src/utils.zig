const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const test_allocator = std.testing.allocator;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const debug = std.debug;

const LinkPathError = error{FileDoesNotExist};

pub fn fileExists(rel_path: []const u8) bool {
    const file = try fs.cwd().openFile(rel_path, .{}) catch |err| {
        _ = err;
        return false;
    };
    _ = file;
    return true;
}

pub fn dirExists(rel_path: []const u8) bool {
    const file = try fs.cwd().openFile(rel_path, .{}) catch |err| {
        _ = err;
        return false;
    };
    _ = file;
    return true;
}

//returns a full path from files, if link_file_name is found in their
pub fn expandLink(link_file_name: []const u8, files: std.ArrayList([]const u8)) anyerror![]const u8 {
    for (files.items) |f| {
        // debug.print("{s}\n", .{f});
        if (std.mem.eql(u8, fs.path.basename(f), link_file_name)) {
            return f;
        }

        var split = std.mem.split(u8, fs.path.basename(f), ".");
        if (std.mem.eql(u8, split.next() orelse "", link_file_name)) {
            return f;
        }
    }
    return LinkPathError.FileDoesNotExist;
}

/// Returns list of file paths recursively collected from root of type specified in type
/// Caller must deinit result
pub fn traverseRoot(allocator: std.mem.Allocator, root: []const u8, file_types: *std.ArrayList([]const u8)) !std.ArrayList([]const u8) {
    // TODO Change file_types to std.HashMap as a Set

    var file_paths = std.ArrayList([]const u8).init(allocator);
    _ = file_types;
    var sub_dirs = std.ArrayList([]const u8).init(allocator);
    defer sub_dirs.deinit();
    try sub_dirs.append(try allocator.dupe(u8, root));

    var root_dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer root_dir.close();

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        //TODO filter file types
        if (entry.kind != fs.File.Kind.file) {
            continue;
        }
        const path = try entry.dir.realpathAlloc(allocator, entry.basename);
        try file_paths.append(path);
    }

    return file_paths;
}

/// Returns a list of files linked to file. Caller must free results
/// TODO Make tokens that denote a link configurable. Rn we use the obsidian syntax:
/// [[link|displayed name]]
pub fn getLinks(allocator: std.mem.Allocator, file_path: []const u8, files: std.ArrayList([]const u8)) !std.ArrayList([]const u8) {
    var linked_files = std.ArrayList([]const u8).init(allocator);

    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const size = (try file.stat()).size;

    const read_buf = try file.readToEndAlloc(allocator, size);
    defer allocator.free(read_buf);
    // debug.print("{s}\n", .{read_buf});

    if (read_buf.len == 0) return linked_files;

    // parse read buff and collect links
    // try linked_files.append(read_buf);

    var link_start: i32 = -1;
    var link_end: i32 = -1; // exclusive
    var i: i32 = -1;
    while (i + 1 < read_buf.len - 1) {
        i += 1;
        const c = read_buf[@intCast(i)];
        // debug.print("{d}, {d} {d} {c}\n", .{i, link_start, link_end, c});
        if (link_start == -1 and c == '[' and read_buf[@intCast(i + 1)] == '[') {
            link_start = i + 2;
            i += 1;
            continue;
        }

        if (c == '|' and link_start != -1) {
            link_end = i;
        }

        if (c == ']' and link_start != -1 and read_buf[@intCast(i)] == ']') {
            link_end = i;
        }

        if (link_end != -1 and link_start != -1) {
            const link = try allocator.dupe(u8, read_buf[@intCast(link_start)..@intCast(link_end)]);
            // debug.print("{s}\n", .{link});
            if (expandLink(link, files)) |linked_file| {
                try linked_files.append(linked_file);
            } else |_| {
                try stderr.print("{s} does not exsist\n", .{link});
            }
            link_start = -1;
            link_end = -1;
        }
    }

    return linked_files;
}

/// Returns a list of Hashtags.
/// TODO Implement. Hashtags must occur in form #tag_. Hashtags may not be taken in code listings
pub fn getHashtags(allocator: std.mem.Allocator, file: []const u8) !std.ArrayList([]const u8) {
    _ = file;

    const hashtags = std.ArrayList([]const u8).init(allocator);

    return hashtags;
}

test "traverse test directory" {
    std.debug.print("\n", .{}); // new line from Test [] line
    //
    var file_types = std.ArrayList([]const u8).init(test_allocator);
    defer file_types.deinit();
    try file_types.append("txt");
    try file_types.append("md");

    const root = fs.cwd().realpathAlloc(test_allocator, "./test") catch |err| {
        try stderr.print("test is not a valid dir\n", .{});
        return err;
    };
    defer test_allocator.free(root);

    // std.debug.print("{s}\n", .{root});
    var file_paths = try traverseRoot(test_allocator, root, &file_types);
    for (file_paths.items) |el| {
        test_allocator.free(el);
    }

    defer file_paths.deinit();
}

test "link in file" {
    std.debug.print("\n", .{}); // new line from Test [] line
    var tmp_dir = std.testing.tmpDir(.{}); // This creates a directory under ./zig-cache/tmp/{hash}/test_file
    defer tmp_dir.cleanup();

    var file1 = try tmp_dir.dir.createFile("file1.txt", .{ .read = true });
    defer file1.close();

    var file2 = try tmp_dir.dir.createFile("file2.txt", .{ .read = true });
    defer file2.close();

    const write_buf: []const u8 = "[[file2.txt]]";
    try file1.writeAll(write_buf);

    const path = try tmp_dir.dir.realpathAlloc(test_allocator, "./file1.txt");
    defer test_allocator.free(path);

    const path2 = try tmp_dir.dir.realpathAlloc(test_allocator, "./file2.txt");
    defer test_allocator.free(path2);

    var files = std.ArrayList([]const u8).init(test_allocator);
    defer files.deinit();
    try files.append(path);
    try files.append(path2);

    var links = try getLinks(test_allocator, path, files);

    debug.assert(std.mem.eql(u8, links.items[0], "file2.txt"));

    //free links
    for (links.items) |link| {
        test_allocator.free(link);
    }
    links.deinit();
}
