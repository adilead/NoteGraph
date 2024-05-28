//will contain layout algorithms like Kamada/Kawai or Fruchterman/Reingold

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;
const random = std.crypto.random;

const graph_lib = @import("graph.zig");
const Graph = graph_lib.Graph;
const Point = graph_lib.Point;
const Edge = graph_lib.Edge;
const sugiyama = @import("sugiyama_layout.zig");

pub const LayoutMethod = enum {
    fruchterman,
    sugiyama,

    pub fn toString(self: LayoutMethod) [:0]const u8 {
        return switch (self) {
            // .kamada => "Kamada",
            .fruchterman => "Fruchterman",
            .sugiyama => "Sugiyama",
        };
    }
};

pub const LayoutData = union(LayoutMethod) {
    fruchterman: FruchtermanLayoutData,
    sugiyama: sugiyama.SugiyamaLayoutData,

    pub fn getPos(self: LayoutData) graph_lib.Point {
        switch (self) {
            .sugiyama => |sugiyama_data| return sugiyama_data.getPos(),
            .fruchterman => |fd| return fd.getPos(),
            // inline else => |impl| return impl.getPos(),
        }
    }

    pub fn getEdges(self: LayoutData) ![][2]Point {
        switch (self) {
            .sugiyama => |sugiyama_data| return sugiyama_data.getEdges(),
            .fruchterman => |fd| return fd.getEdges(),
            // inline else => |impl| return impl.getPos(),
        }
    }
    pub fn deinit(self: LayoutData) void {
        switch (self) {
            .sugiyama => |sugiyama_data| return sugiyama_data.deinit(),
            .fruchterman => |fd| return fd.deinit(),
        }
    }
};

pub const FruchtermanLayoutData = struct {
    alloc: Allocator, //will be gpa
    pos: Point,
    d: Point,
    edges: [][2]Point,

    pub fn getPos(self: FruchtermanLayoutData) graph_lib.Point {
        return self.pos;
    }

    pub fn getEdges(self: FruchtermanLayoutData) ![][2]Point {
        return self.edges;
    }

    pub fn deinit(self: FruchtermanLayoutData) void {
        self.alloc.free(self.edges);
    }
};

const K: f32 = 0.1; // force factor
const C: f32 = 0.9; // Coupling factor
const EPSILON: f32 = 0.000001;

pub fn resetLayout(graph: *Graph) void {
    //TODO  Remove me sometime
    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node: *graph_lib.Node = entry.value_ptr;
        node.position = graph_lib.Point{ .x = random.float(f32) * graph.window_width, .y = random.float(f32) * graph.window_height };
    }
    graph.changed = true;
}

//TODO remove width and height from function interface because width and height are now in the graph
pub fn layout(allocator: std.mem.Allocator, graph: *Graph, method: LayoutMethod, width: i32, height: i32) !void {
    // if (!graph.changed) return;
    // var arena = std.heap.ArenaAllocator.init(allocator);
    // defer arena.deinit();

    // remove all LayoutData if they are different to the requested one
    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node: *graph_lib.Node = entry.value_ptr;
        if (node.layout_data) |ld| {
            if (ld != method) {
                node.layout_data.?.deinit();
                node.layout_data = null;
            }
        }
    }

    const result = switch (method) {
        // .kamada => kamada(graph),
        .fruchterman => try generateFruchtermanLayout(allocator, graph, width, height),
        .sugiyama => sugiyama.generateSugiyamaLayout(allocator, graph, width, height),
    };
    _ = try result;
}

fn kamada(graph: *Graph) !void {
    _ = graph;
}

fn generateFruchtermanLayout(allocator: Allocator, graph: *Graph, width: i32, height: i32) !void {
    const size: i32 = width * height;
    const initial_temperature: f32 = math.sqrt(@as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(graph.nodes.keys().len)));
    var temperature = initial_temperature;

    var i: usize = 0;
    while (i < 5) {
        defer i += 1;
        try fruchtermanLayout(allocator, graph, width, height, temperature);
        temperature *= C; // Reduce the temperature with each iteration
    }
}

fn fruchtermanLayout(allocator: Allocator, graph: *Graph, width: i32, height: i32, temperature: f32) !void {
    const area = width * height;
    const num_vertices = graph.nodes.keys().len;
    const k = K * math.sqrt(@as(f32, @floatFromInt(area)) / @as(f32, @floatFromInt(num_vertices)));
    const nodes = graph.nodes.values();

    for (nodes) |*node| {
        node.layout_data = node.layout_data orelse LayoutData{ .fruchterman = FruchtermanLayoutData{ .alloc = allocator, .pos = Point{ .x = random.float(f32) * graph.window_width, .y = random.float(f32) * graph.window_height }, .d = Point{ .x = 0.0, .y = 0.0 }, .edges = undefined } };
    }

    // repulsive forces
    for (0..num_vertices) |i| {
        for (0..num_vertices) |j| {
            const pos1 = nodes[i].layout_data.?.fruchterman.getPos();
            const pos2 = nodes[j].layout_data.?.fruchterman.getPos();
            const dx = pos1.x - pos2.x;
            const dy = pos1.y - pos2.y;
            const d = @max(EPSILON, math.sqrt(dx * dx + dy * dy));

            const fx: f32 = (k * k) / d * dx / d;
            const fy: f32 = (k * k) / d * dy / d;

            nodes[i].layout_data.?.fruchterman.d.x += fx;
            nodes[i].layout_data.?.fruchterman.d.y += fy;
        }
    }

    //attracting forces
    for (graph.edges.keys()) |*edge| {
        const u = graph.nodes.getIndex(edge.u).?;
        const v = graph.nodes.getIndex(edge.v).?;

        const pos_u = nodes[u].layout_data.?.fruchterman.getPos();
        const pos_v = nodes[v].layout_data.?.fruchterman.getPos();

        const dx = pos_u.x - pos_v.x;
        const dy = pos_u.y - pos_v.y;
        const d = @max(EPSILON, math.sqrt(dx * dx + dy * dy));

        const fx = (d * d) / k * dx / d;
        const fy = (d * d) / k * dy / d;

        // FIXME find the ID instead of index into the field
        nodes[u].layout_data.?.fruchterman.d.x -= fx;
        nodes[u].layout_data.?.fruchterman.d.y -= fy;
        nodes[v].layout_data.?.fruchterman.d.x -= fx;
        nodes[v].layout_data.?.fruchterman.d.y -= fy;
    }

    for (nodes) |*node| {
        // defer i += 1;
        const d = node.layout_data.?.fruchterman.d;
        const disp_norm: f32 = math.sqrt(d.x * d.x + d.y * d.y);
        const xratio: f32 = @min(@abs(d.x), temperature);
        const yratio: f32 = @min(@abs(d.y), temperature);

        node.layout_data.?.fruchterman.pos.x += d.x / disp_norm * xratio;
        node.layout_data.?.fruchterman.pos.y += d.y / disp_norm * yratio;

        // Limit the positions within the canvas boundaries
        node.layout_data.?.fruchterman.pos.x = @max(0.0, @min(node.layout_data.?.fruchterman.pos.x, @as(f32, @floatFromInt(width))));
        node.layout_data.?.fruchterman.pos.y = @max(0.0, @min(node.layout_data.?.fruchterman.pos.y, @as(f32, @floatFromInt(height))));
    }

    //compute edges
    for (nodes) |*node| {
        node.layout_data.?.fruchterman.edges = try allocator.alloc([2]Point, node.edges.items.len);
        for (node.edges.items, 0..node.edges.items.len) |e, i| {
            node.layout_data.?.fruchterman.edges[i][0] = node.layout_data.?.fruchterman.pos;
            node.layout_data.?.fruchterman.edges[i][1] = graph.nodes.get(e).?.layout_data.?.fruchterman.pos;
        }
    }
}
