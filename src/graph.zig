const std = @import("std");
const Allocator = std.mem.Allocator;
const test_allocator = std.testing.allocator;
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const utils = @import("utils.zig");
const Node = struct {
    id: u32,
    file: []const u8,
    path: []const u8,
    edges: std.ArrayList(u32),
    file_links: std.ArrayList([]const u8),
    hashtags: std.ArrayList([]const u8),
    created: i64, //time stamp
    position: Point
};

const Edge = struct {
    x: u32,
    y: u32,
};

const Point = struct {
    x: i32,
    y: i32,
};


pub const Graph = struct {
    allocator: Allocator,
    nodes: std.AutoArrayHashMap(u32, Node),
    edges: std.AutoArrayHashMap(Edge, void),
    id_lookup: std.StringArrayHashMap(u32),

    pub fn init(allocator: Allocator, files: std.ArrayList([]const u8)) !Graph {

        var nodes = std.AutoArrayHashMap(u32, Node).init(allocator);
        var edges = std.AutoArrayHashMap(Edge, void).init(allocator);
        var id_lookup = std.StringArrayHashMap(u32).init(allocator);

        var graph = Graph {
            .allocator=allocator,
            .nodes=nodes,
            .edges=edges,
            .id_lookup=id_lookup
        };

        try graph.update(files);

        return graph;
    }

    ///Updates the graph with new file list
    pub fn update(self: *Graph, files: std.ArrayList([]const u8)) !void {
        
        for(files.items) |file| {
            if(self.id_lookup.contains(file)){
                // receive id and then a Node
                // update node
                // update edges
            
            } else {
                // create new entry in id_lookup
                var id = std.hash.CityHash32.hash(file);
                //TODO What to do when hash collision
                var file_cpy = try self.allocator.dupe(u8, file);
                try self.id_lookup.put(file_cpy, id);
                //get links
                var links = try utils.getLinks(self.allocator, file, files);

                //get hashtags
                var hashtags = try utils.getHashtags(self.allocator, file);

                // create new Node
                var node: Node = Node {
                    .id = id,
                    .file = std.fs.path.basename(file_cpy),
                    .path = file_cpy,
                    .edges = std.ArrayList(u32).init(self.allocator),
                    .file_links = links,
                    .hashtags = hashtags,
                    .created = std.time.milliTimestamp(),
                    .position = Point {.x=0, .y=0}
                };
                // update nodes
                try self.nodes.put(id, node);
                // TODO update edges
            }
        }
    }

    ///Call this if a file was deleted and needs to be removed from the graph
    pub fn remove(self: *Graph, id: u32) !void {
        //TODO Implement
        _ = id;
        _ = self;
    }

    pub fn deinit(self: *Graph) void {
        //TODO deinit all nodes
        var iter = self.id_lookup.iterator();
        while(iter.next()) |entry| {
            var file: []const u8 = entry.key_ptr.*;
            self.allocator.free(file);

            var node: Node = self.nodes.get(entry.value_ptr.*) orelse continue;
            var file_links = node.file_links;

            for(file_links.items) |link| {
                self.allocator.free(link);
            }

            node.file_links.deinit();
            node.edges.deinit();
            node.hashtags.deinit();
        }


        self.nodes.deinit();
        self.edges.deinit();
        self.id_lookup.deinit();
    }
};

test "Simple Graph" {
    std.debug.print("\n", .{}); // new line from Test [] line

    var file_types = std.ArrayList([]const u8).init(test_allocator);
    defer file_types.deinit();

    try file_types.append("md");
    try file_types.append("txt");

    var root = std.fs.cwd().realpathAlloc(test_allocator, "./test") catch |err| {
        try stderr.print("test is not a valid dir\n", .{});
        return err;
    };
    defer test_allocator.free(root);

    var files = try utils.traverseRoot(test_allocator, root, &file_types);

    var graph: Graph = try Graph.init(test_allocator, files);

    for(files.items) |el| {
        test_allocator.free(el);
    }
    files.deinit();

    defer graph.deinit();
}
