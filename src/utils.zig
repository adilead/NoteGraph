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

//use this if .md is missing
pub fn expandLinkWithFileType(allocator: std.mem.Allocator, link: []u8, file_type: []const u8) ![]const u8 {
    debug.assert(std.fs.path.extension(link).len == 0);

    const new_link: []u8 = try allocator.alloc(u8, link.len + file_type.len + 1);
    new_link[link.len] = '.';
    @memcpy(new_link[0..link.len], link);
    @memcpy(new_link[link.len + 1 .. new_link.len], file_type);
    return new_link;
}

///Checks if function is a valid file in the repository
pub fn linkIsValid(link_file_name: []const u8, files: std.ArrayList([]const u8)) bool {
    debug.assert(std.fs.path.isAbsolute(link_file_name));
    for (files.items) |f| {
        if (std.mem.eql(u8, f, link_file_name)) {
            return true;
        }
    }
    return false;
}

/// Returns list of file paths recursively collected from root of type specified in type
/// Caller must deinit result
pub fn traverseRoot(allocator: std.mem.Allocator, root: []const u8, file_types: *std.ArrayList([]const u8)) !std.ArrayList([]const u8) {
    // TODO Change file_types to std.HashMap as a Set

    var file_paths = std.ArrayList([]const u8).init(allocator);

    var root_dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer root_dir.close();

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        //TODO filter file types
        if (entry.kind != fs.File.Kind.file) {
            continue;
        }
        for (file_types.items) |ft| {
            if (std.mem.eql(u8, ft, std.fs.path.extension(entry.path))) {
                try file_paths.append(try entry.dir.realpathAlloc(allocator, entry.basename));
                break;
            }
        }
    }

    return file_paths;
}

/// Returns a list of files linked to file. Caller must free results
/// TODO Make tokens that denote a link configurable. Rn we use the obsidian syntax:
/// [[link|displayed name]]
pub fn getLinks(allocator: std.mem.Allocator, file_path: []const u8, root: []const u8, files: std.ArrayList([]const u8), ignore_invalid_links: bool) !std.ArrayList([]const u8) {
    var linked_files = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (linked_files.items) |link| {
            allocator.free(link);
        }
        linked_files.deinit();
    }

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
            var link = read_buf[@intCast(link_start)..@intCast(link_end)];
            if (link.len == 0) {
                continue;
            }

            if (!std.fs.path.isAbsolute(link)) {
                link = try std.fs.path.join(allocator, &[_][]const u8{ root, link });
            } else {
                link = try allocator.dupe(u8, link);
            }

            var expanded_link: []const u8 = undefined;
            if (std.fs.path.extension(link).len == 0) {
                expanded_link = try expandLinkWithFileType(allocator, link, "md");
                allocator.free(link);
            } else {
                expanded_link = link;
            }
            std.debug.print("Expanded link: {s}\n", .{expanded_link});
            // debug.print("{s}\n", .{link});
            if (linkIsValid(expanded_link, files) or !ignore_invalid_links) {
                try linked_files.append(expanded_link);
            } else {
                allocator.free(expanded_link);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // ----- setup test dir
    var tmp_dir = std.testing.tmpDir(.{}); // This creates a directory under ./zig-cache/tmp/{hash}/test_file
    const root = try tmp_dir.dir.realpathAlloc(test_allocator, ".");
    defer test_allocator.free(root);
    defer tmp_dir.cleanup();

    var file1 = try tmp_dir.dir.createFile("file1.md", .{ .read = true });
    defer file1.close();

    var file2 = try tmp_dir.dir.createFile("file2.md", .{ .read = true });
    defer file2.close();

    try tmp_dir.dir.makeDir("subdir1");
    var file3 = try tmp_dir.dir.createFile("subdir1/file3.txt", .{ .read = true });

    defer file3.close();

    var file_types = std.ArrayList([]const u8).init(alloc);
    defer file_types.deinit();
    // try file_types.append("txt");
    try file_types.append(".md");

    var file_paths = try traverseRoot(alloc, root, &file_types);
    defer file_paths.deinit();

    std.testing.expectEqual(2, file_paths.items.len) catch |err| {
        for (file_paths.items) |fp| {
            debug.print("{s}\n", .{fp});
        }
        return err;
    };
}

test "link in file" {
    std.debug.print("\n", .{}); // new line from Test [] line
    var tmp_dir = std.testing.tmpDir(.{}); // This creates a directory under ./zig-cache/tmp/{hash}/test_file
    const root = try tmp_dir.dir.realpathAlloc(test_allocator, ".");
    defer test_allocator.free(root);
    defer tmp_dir.cleanup();

    var file1 = try tmp_dir.dir.createFile("file1.txt", .{ .read = true });
    defer file1.close();

    var file2 = try tmp_dir.dir.createFile("file2.txt", .{ .read = true });
    defer file2.close();

    try tmp_dir.dir.makeDir("subdir1");
    var file3 = try tmp_dir.dir.createFile("subdir1/file3.txt", .{ .read = true });
    defer file3.close();

    const wrong_path = "subdir1/bar.txt";
    const write_buf: []const u8 = "lsjdflkj[[file2.txt|bla]]sdlfjlsdkf\n[[subdir1/file3.txt]]\nsldfjklsdjflksjdf[[" ++ wrong_path ++ "]]\n";
    try file1.writeAll(write_buf);

    const path1 = try tmp_dir.dir.realpathAlloc(test_allocator, "file1.txt");
    defer test_allocator.free(path1);

    const path2 = try tmp_dir.dir.realpathAlloc(test_allocator, "file2.txt");
    defer test_allocator.free(path2);

    const path3 = try tmp_dir.dir.realpathAlloc(test_allocator, "subdir1/file3.txt");
    defer test_allocator.free(path3);

    var files = std.ArrayList([]const u8).init(test_allocator);
    defer files.deinit();
    try files.append(path1);
    try files.append(path2);
    try files.append(path3);

    {
        var links_checked = try getLinks(test_allocator, path1, root, files, true);

        defer {
            for (links_checked.items) |link| {
                test_allocator.free(link);
            }
            links_checked.deinit();
        }

        try std.testing.expectEqual(2, links_checked.items.len);
        try std.testing.expectEqualStrings(path2, links_checked.items[0]);
        try std.testing.expectEqualStrings(path3, links_checked.items[1]);
    }
    {
        var links_unchecked = try getLinks(test_allocator, path1, root, files, false);
        defer {
            for (links_unchecked.items) |link| {
                test_allocator.free(link);
            }
            links_unchecked.deinit();
        }
        try std.testing.expectEqual(3, links_unchecked.items.len);
        try std.testing.expectEqualStrings(path2, links_unchecked.items[0]);
        try std.testing.expectEqualStrings(path3, links_unchecked.items[1]);
        const p = try std.fs.path.join(test_allocator, &[_][]const u8{ root, wrong_path });
        defer test_allocator.free(p);
        try std.testing.expectEqualStrings(p, links_unchecked.items[2]);
    }
}
