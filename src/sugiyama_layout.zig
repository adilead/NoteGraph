const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;
const debug = std.debug;
const random = std.crypto.random;

const graph_lib = @import("graph.zig");
const utils = @import("utils.zig");
const LayoutData = @import("layout.zig").LayoutData;
const Graph = graph_lib.Graph;
const Point = graph_lib.Point;

pub const SugiyamaLayoutError = error{
    IterationsExceeded,
};

pub const OSCM = enum { barycenter, median, ilp };

const MaxIter = 100_000;

pub const SugiyamaLayoutData = struct {
    alloc: Allocator, //will be gpa
    pos: graph_lib.Point,
    edges: [][2]Point,
    layer: usize,
    order: f32,

    pub fn getPos(self: SugiyamaLayoutData) graph_lib.Point {
        return self.pos;
    }

    pub fn getEdges(self: SugiyamaLayoutData) ![][2]Point {
        return self.edges;
    }

    pub fn deinit(self: SugiyamaLayoutData) void {
        self.alloc.free(self.edges);
    }
};

pub const SugiyamaLayout = struct {
    allocator: Allocator,
    graph: *graph_lib.Graph,
    matrix: [][]bool, //has dim (n_nodes * n_dummies) x (n_nodes * n_dummies)
    id_to_idx: std.AutoArrayHashMap(u32, usize),
    n_nodes: usize, //number of real nodes
    n_dummies: usize, //number of dummy nodes, default: 0
    b: usize, //max number of nodes per layer
    layers: []?usize,
    n_layers: ?usize,
    layout_data: ?std.ArrayList(*SugiyamaLayoutData),
    dummy_layout_data: ?[]SugiyamaLayoutData,
    layer_lookup: ?[]std.ArrayList(usize),

    pub fn init(allocator: Allocator, graph: *Graph, b: usize) !SugiyamaLayout {
        const n_nodes = graph.nodes.keys().len;

        var id_to_idx = std.AutoArrayHashMap(u32, usize).init(allocator);
        for (graph.nodes.keys(), 0..n_nodes) |id, i| {
            try id_to_idx.put(id, i);
        }

        const matrix = try allocator.alloc([]bool, n_nodes);
        for (0..n_nodes) |i| {
            matrix[i] = try allocator.alloc(bool, n_nodes);
            const node = graph.nodes.values()[i];
            for (node.edges.items) |edge| {
                const j = id_to_idx.get(edge).?;
                matrix[i][j] = true;
            }
        }
        for (matrix) |row| {
            for (row) |val| {
                std.debug.print("{d}", .{@intFromBool(val)});
            }
            std.debug.print("\n", .{});
        }

        const layers = try allocator.alloc(?usize, n_nodes);
        for (0..n_nodes) |i| {
            layers[i] = null;
        }

        return SugiyamaLayout{
            .allocator = allocator,
            .graph = graph,
            .matrix = matrix,
            .n_nodes = n_nodes,
            .n_dummies = 0,
            .id_to_idx = id_to_idx,
            .b = b,
            .layers = layers,
            .n_layers = null,
            .layout_data = null,
            .dummy_layout_data = null,
            .layer_lookup = null,
        };
    }

    pub fn deinit(self: *SugiyamaLayout) void {
        for (self.matrix) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.matrix);
        self.allocator.free(self.layers);
        if (self.layout_data) |*ld| {
            ld.deinit();
        }
        if (self.dummy_layout_data) |dld| {
            self.allocator.free(dld);
        }
        if (self.layer_lookup) |lk| {
            self.allocator.free(lk);
        }
    }

    fn fasHeur(self: *SugiyamaLayout) !void {
        //remove two-cycles by removing one edge if there's such a cycle
        for (0..self.n_nodes) |i| {
            for (0..self.n_nodes) |j| {
                if (self.matrix[i][j] and self.matrix[j][i]) self.matrix[j][i] = false;
            }
        }

        //current vertices
        var v = std.AutoArrayHashMap(usize, void).init(self.allocator);
        defer v.deinit();
        for (0..self.n_nodes) |i| try v.put(i, {});

        //detected edges set
        var A = std.AutoHashMap(graph_lib.Edge, void).init(self.allocator);
        defer A.deinit();

        //backup matrix
        var matrix_backup = try self.allocator.dupe([]bool, self.matrix);
        for (self.matrix, 0..self.n_nodes) |row, i| {
            matrix_backup[i] = try self.allocator.dupe(bool, row);
        }

        //cycle removal
        while (v.keys().len != 0) {
            //remove sinks
            while (self.getSink(&v)) |idx| {
                _ = v.swapRemove(idx);
                for (0..self.n_nodes) |i| {
                    if (self.matrix[i][idx]) {
                        try A.put(graph_lib.Edge{ .u = @intCast(i), .v = @intCast(idx) }, {});
                        self.matrix[i][idx] = false;
                    }
                }
            }
            std.debug.print("{d}\n", .{v.keys().len});
            //remove isolated nodes
            try self.removeIsolatedNodes(&v);
            //remove sources
            while (self.getSink(&v)) |idx| {
                _ = v.swapRemove(idx);
                for (0..self.n_nodes) |i| {
                    if (self.matrix[idx][i]) {
                        try A.put(graph_lib.Edge{ .u = @intCast(idx), .v = @intCast(i) }, {});
                        self.matrix[idx][i] = false;
                    }
                }
            }

            //remove node with highes incoming / outgoing diff
            if (v.keys().len == 0) continue;
            var max_diff: usize = 0;
            var max_idx: ?usize = 0;
            for (v.keys()) |i| {
                var incoming: usize = 0;
                var outgoing: usize = 0;

                for (v.keys()) |j| {
                    if (self.matrix[i][j]) outgoing += 1;
                    if (self.matrix[j][i]) incoming += 1;
                }

                if (outgoing - incoming > max_diff) {
                    max_diff = outgoing - incoming;
                    max_idx = i;
                }
            }
            if (max_idx) |idx| {
                _ = v.swapRemove(idx);
                for (0..self.n_nodes) |i| {
                    if (self.matrix[idx][i]) {
                        try A.put(graph_lib.Edge{ .u = @intCast(idx), .v = @intCast(i) }, {});
                        self.matrix[idx][i] = false;
                    }
                }
            }
        }

        //the remaining edges in matrix must be flipped
        for (0..self.n_nodes) |i| {
            for (0..self.n_nodes) |j| {
                if (self.matrix[i][j]) {
                    matrix_backup[i][j] = false;
                    matrix_backup[j][i] = true;
                }
            }
        }
        //free old matrix
        for (0..self.n_nodes) |i| {
            self.allocator.free(self.matrix[i]);
        }
        self.allocator.free(self.matrix);
        self.matrix = matrix_backup;
    }

    fn getSink(self: *SugiyamaLayout, v: *std.AutoArrayHashMap(usize, void)) ?usize {
        const idxs = v.keys();
        for (idxs) |i| {
            var stopped = false;
            for (idxs) |j| {
                if (self.matrix[j][i]) {
                    stopped = true;
                    break;
                }
            }
            if (!stopped) continue;
            stopped = false;
            for (idxs) |j| {
                if (self.matrix[i][j]) {
                    stopped = true;
                    break;
                }
            }
            if (!stopped) return i;
        }
        return null;
    }

    fn removeIsolatedNodes(self: *SugiyamaLayout, v: *std.AutoArrayHashMap(usize, void)) !void {
        const idxs = v.keys();
        var i: usize = 0;
        var idxs_len: usize = idxs.len;
        while (i < idxs_len) {
            var stop = false;
            for (idxs[0..idxs_len]) |j| {
                if (self.matrix[j][i] or self.matrix[i][j]) {
                    stop = true;
                    break;
                }
            }
            if (!stop) {
                _ = v.swapRemoveAt(i);
                idxs_len -= 1; //deleted items are swapped with the last one; so we simply reduce the length of the slice
            } else {
                i += 1; // and only go to the next element, when not a new one swapped in
            }
        }
    }

    fn getSource(self: *SugiyamaLayout, v: *std.AutoArrayHashMap(usize, void)) ?usize {
        const idxs = v.keys();
        for (idxs) |i| {
            var stopped = false;
            for (idxs) |j| {
                if (self.matrix[i][j]) {
                    stopped = true;
                    break;
                }
            }
            if (!stopped) continue;
            stopped = false;
            for (idxs) |j| {
                if (self.matrix[j][i]) {
                    stopped = true;
                    break;
                }
            }
            if (!stopped) return i;
        }
        return null;
    }

    fn layerScheduling(self: *SugiyamaLayout) !void {
        var scheduled = std.AutoArrayHashMap(usize, usize).init(self.allocator);
        defer scheduled.deinit();
        var curr_layer: usize = 0;
        var b_counter: usize = 0;
        var it: usize = 0;
        while (scheduled.keys().len < self.n_nodes) {
            if (it >= MaxIter) return SugiyamaLayoutError.IterationsExceeded;
            defer it += 1;
            var found = false;
            var candidate: ?usize = null;
            var count_u: usize = 0;
            var count_v: usize = 0;
            l: for (0..self.n_nodes) |i| {
                if (scheduled.contains(i)) continue;
                // var min_length: usize = 0;
                // var min_i: ?usize = null;
                var curr_count_u: usize = 0;
                var curr_count_v: usize = 0;
                for (0..self.n_nodes) |j| {
                    if (self.matrix[i][j]) curr_count_v += 1;
                    if (self.matrix[j][i]) {
                        curr_count_u += 1;
                        if (scheduled.get(j)) |layer| {
                            if (layer == curr_layer) continue :l; // the edge to node i has a source j on the same layer
                        } else {
                            continue :l; // incoming edge has unregistered source
                        }
                    }
                }
                // std.debug.print("Here {d} {d} {d}\n", .{ i, curr_count_u, curr_count_v });
                if (candidate) |_| {
                    if (curr_count_u > count_u) {
                        candidate = i;
                        count_u = curr_count_u;
                        count_v = curr_count_v;
                    }
                    if (curr_count_v > count_v and curr_count_u >= count_u) {
                        candidate = i;
                        count_u = curr_count_u;
                        count_v = curr_count_v;
                    }
                } else {
                    candidate = i;
                    count_u = curr_count_u;
                    count_v = curr_count_v;
                }
            }
            if (candidate) |cand| {
                try scheduled.put(cand, curr_layer);
                // std.debug.print("{d}: {d}\n", .{ cand, curr_layer });
                b_counter += 1;
                found = true;
            }
            if (b_counter == self.b or !found) {
                b_counter = 0;
                curr_layer += 1;
            }
        }

        for (scheduled.keys()) |n| {
            self.layers[n] = scheduled.get(n).?;
        }
        self.n_layers = curr_layer + 1;

        // for (self.layers, 0..self.n_nodes) |l, i| {
        //     std.debug.print("{d}: {d}\n", .{ i, l.? });
        // }
    }

    fn insertDummies(self: *SugiyamaLayout) !void {
        //find total number of dummy nodes needed
        var dummies: usize = 0;
        for (0..self.n_nodes) |i| {
            for (0..self.n_nodes) |j| {
                if (!self.matrix[i][j]) continue;
                dummies += self.layout_data.?.items[j].layer - self.layout_data.?.items[i].layer - 1;
            }
        }
        self.n_dummies = dummies;

        self.dummy_layout_data = try self.allocator.alloc(SugiyamaLayoutData, self.n_dummies);

        //copy old matrix into new one
        const total = self.n_dummies + self.n_nodes;
        const new_matrix = try self.allocator.alloc([]bool, total);
        for (0..total) |i| {
            new_matrix[i] = try self.allocator.alloc(bool, total);
            for (0..total) |j| {
                if (i < self.n_nodes and j < self.n_nodes and self.matrix[i][j]) {
                    new_matrix[i][j] = true;
                } else {
                    new_matrix[i][j] = false;
                }
            }
        }

        //Insert dummy nodes, where idx >= n_nodes are dummy nodes
        var k: usize = 0;
        for (0..self.n_nodes) |i| {
            for (0..self.n_nodes) |j| {
                if (!new_matrix[i][j]) continue;
                const n: usize = self.layout_data.?.items[j].layer - self.layout_data.?.items[i].layer - 1;
                if (n == 0) continue;
                new_matrix[i][j] = false;
                var u: usize = i;
                var v: usize = self.n_nodes + k;
                const target = j;
                for (0..n) |l| {
                    new_matrix[u][v] = true;
                    self.dummy_layout_data.?[k] = SugiyamaLayoutData{ .pos = self.layout_data.?.items[i].pos, .alloc = self.allocator, .edges = undefined, .layer = self.layout_data.?.items[i].layer + l + 1, .order = 0 };
                    u = v;
                    k += 1;
                    v = self.n_nodes + k;
                }
                new_matrix[u][target] = true;
            }
        }
        for (self.matrix) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.matrix);
        self.matrix = new_matrix;
        for (0..self.dummy_layout_data.?.len) |i| {
            try self.layout_data.?.append(&self.dummy_layout_data.?[i]);
        }
    }

    fn minimizeCrossings(self: *SugiyamaLayout) !void {
        std.debug.assert(self.layout_data != null);
        std.debug.assert(self.layout_data.?.items.len == self.matrix.len);

        var layer_lookup = try self.allocator.alloc(std.ArrayList(usize), self.n_layers.?);
        self.layer_lookup = layer_lookup;

        for (layer_lookup) |*ll| {
            ll.* = std.ArrayList(usize).init(self.allocator);
        }
        defer {
            for (layer_lookup) |*ll| {
                ll.deinit();
            }
        }

        for (0..self.layout_data.?.items.len) |i| {
            try layer_lookup[self.layout_data.?.items[i].layer].append(i);
            self.layout_data.?.items[i].order = @floatFromInt(layer_lookup[self.layout_data.?.items[i].layer].items.len - 1);
        }

        var changed = true;
        var it: usize = 0;
        while (changed) {
            defer it += 1;
            // if (it >= MaxIter) return SugiyamaLayoutError.IterationsExceeded;
            if (it >= 500) break;
            changed = false;
            for (0..self.n_layers.? - 1) |i| {
                changed = changed or self.oscm(OSCM.barycenter, &layer_lookup[i], &layer_lookup[i + 1], false);
            }
            for (0..self.n_layers.? - 1) |i| {
                changed = changed or self.oscm(OSCM.barycenter, &layer_lookup[self.n_layers.? - i - 2], &layer_lookup[self.n_layers.? - i - 1], true);
            }
            //normalize order values
            for (0..self.n_layers.? - 1) |i| {
                for (self.layer_lookup.?[i].items, 0..) |j, l| {
                    self.layout_data.?.items[j].order = @floatFromInt(l);
                }
            }
        }

        //test print
        for (layer_lookup, 0..) |l, i| {
            std.debug.print("{d}: ", .{i});
            for (l.items) |j| {
                std.debug.print("{d}-{d} ", .{ j, self.layout_data.?.items[j].layer });
            }
            std.debug.print("\n", .{});
        }
    }

    fn oscm(self: *SugiyamaLayout, oscm_type: OSCM, x1: *std.ArrayList(usize), x2: *std.ArrayList(usize), reversed: bool) bool {
        switch (oscm_type) {
            .barycenter => return self.barycenter_oscm(x1, x2, reversed),
            else => return false,
        }
    }

    fn barycenter_oscm(self: *SugiyamaLayout, x1: *std.ArrayList(usize), x2: *std.ArrayList(usize), reversed: bool) bool {
        std.debug.assert(self.layout_data.?.items[x1.items[0]].layer == self.layout_data.?.items[x2.items[0]].layer - 1);
        var a: *std.ArrayList(usize) = undefined; //order will be changed
        var b: *std.ArrayList(usize) = undefined; //order constant

        if (reversed) {
            a = x1;
            b = x2;
        } else {
            a = x2;
            b = x1;
        }
        for (a.items) |y| {
            var deg: usize = 0;
            var sum: f32 = 0;
            for (b.items) |x| {
                if (!reversed and self.matrix[x][y] or reversed and self.matrix[y][x]) {
                    deg += 1;
                    sum += self.layout_data.?.items[x].order;
                }
            }
            self.layout_data.?.items[y].order = sum / @as(f32, @floatFromInt(deg));
        }
        //check if the order has changed
        var order_changed = false;
        for (0..a.items.len - 1) |i| {
            if (self.layout_data.?.items[i].order > self.layout_data.?.items[i + 1].order) {
                order_changed = true;
                break;
            }
        }
        if (!order_changed) return false;
        //sort the array
        std.sort.heap(usize, a.items, self.layout_data.?, sortOrder);
        return true;
    }

    fn computePositions(self: *SugiyamaLayout, width: f32, height: f32) !void {
        //First compute vertices:

        //compute coordinates
        const y_margin: f32 = 50.0;
        const dy: f32 = (height - 2.0 * y_margin) / @as(f32, @floatFromInt(self.n_layers.?));

        const x_margin: f32 = 50.0;
        for (self.layout_data.?.items) |ld| {
            const dx: f32 = (width - 2.0 * x_margin) / @as(f32, @floatFromInt(self.layer_lookup.?[ld.layer].items.len));
            ld.pos = graph_lib.Point{ .y = dy * @as(f32, @floatFromInt(ld.layer)) + y_margin, .x = dx * ld.order + x_margin };
        }

        //Then edges:
        for (0..self.n_nodes) |i| {
            const ld = self.layout_data.?.items[i];
            var edge_list = std.ArrayList([2]Point).init(ld.alloc);
            for (0..self.n_nodes + self.n_dummies) |j| {
                if (!self.matrix[i][j]) continue;
                if (j >= self.n_nodes) {
                    var u: usize = i;
                    var v: usize = j;
                    while (v >= self.n_nodes) {
                        try edge_list.append([_]Point{ self.layout_data.?.items[u].pos, self.layout_data.?.items[v].pos });
                        for (0..self.n_nodes + self.n_dummies) |l| {
                            if (self.matrix[v][l]) {
                                u = v;
                                v = l;
                                break; //dummy nodes have exactly one next
                            }
                        }
                    }
                    try edge_list.append([_]Point{ self.layout_data.?.items[u].pos, self.layout_data.?.items[v].pos });
                } else {
                    try edge_list.append([_]Point{ ld.pos, self.layout_data.?.items[j].pos });
                }
            }
            ld.edges = try edge_list.toOwnedSlice();
            edge_list.deinit();
        }
    }
};

pub fn generateSugiyamaLayout(allocator: Allocator, graph: *Graph, width: i32, height: i32) !void {
    _ = height; // autofix
    _ = width; // autofix
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var slayout = try SugiyamaLayout.init(arena.allocator(), graph, 10);
    defer slayout.deinit();

    // resolve cycles by flipping directed edges
    //  find maximum DAG
    //  reverse the remaining edges
    try slayout.fasHeur();
    std.debug.assert(try utils.graphIsCyclic(allocator, slayout.matrix) == false);
    // layer assignment
    slayout.layerScheduling() catch |err| {
        _ = switch (err) {
            SugiyamaLayoutError.IterationsExceeded => {
                std.debug.print("Iteration error at\n", .{});
                return;
            },
            else => return err,
        };
    };

    var n_per_layer = try allocator.alloc(usize, slayout.n_layers.?);
    defer allocator.free(n_per_layer);
    for (0..slayout.n_layers.?) |i| {
        n_per_layer[i] = 0;
    }

    slayout.layout_data = std.ArrayList(*SugiyamaLayoutData).init(slayout.allocator);

    var nodes_layout_data = try slayout.layout_data.?.addManyAt(0, slayout.n_nodes);

    for (slayout.graph.nodes.keys()) |id| {
        const idx = slayout.id_to_idx.get(id).?;
        var node = slayout.graph.nodes.getPtr(id).?;
        const layer = slayout.layers[idx].?;

        const p = graph_lib.Point{ .y = random.float(f32) * graph.window_height, .x = random.float(f32) * graph.window_width };

        node.layout_data = LayoutData{ .sugiyama = SugiyamaLayoutData{ .alloc = allocator, .pos = p, .edges = undefined, .layer = layer, .order = 0 } };
        nodes_layout_data[idx] = &node.layout_data.?.sugiyama;
        node.layout_data.?.sugiyama.edges = try allocator.alloc([2]Point, node.edges.items.len);
        n_per_layer[layer] += 1;
    }

    try slayout.insertDummies();

    try slayout.minimizeCrossings();

    try slayout.computePositions(graph.window_width, graph.window_height);
}

fn sortOrder(sld: std.ArrayList(*SugiyamaLayoutData), l: usize, r: usize) bool {
    return sld.items[l].order < sld.items[r].order;
}

// crossing minimization
// node positioning
// edge drawing (may be omitted)

test "find sinks" {
    const alloc = std.testing.allocator;
    const dummy = std.ArrayList([]const u8).init(alloc);
    defer dummy.deinit();
    var graph = try graph_lib.Graph.init(alloc, "", dummy, 0.0, 0.0); // just a dummy
    //we don't initialize with the graph with init(), we initialize the field manually
    const n_nodes: usize = 5;

    var matrix = try alloc.alloc([]bool, n_nodes);
    defer alloc.free(matrix);
    for (0..n_nodes) |i| {
        matrix[i] = try alloc.alloc(bool, n_nodes);
        for (0..n_nodes) |j| {
            matrix[i][j] = false;
        }
    }
    defer {
        for (0..n_nodes) |i| {
            alloc.free(matrix[i]);
        }
    }

    //Edges: 0-2, 1-2, 3-2, 4-1, 1-3
    //Vertices: 0,1,2,3,4
    var v = std.AutoArrayHashMap(usize, void).init(alloc);
    defer v.deinit();
    for (0..n_nodes) |i| {
        try v.put(i, {});
    }
    matrix[0][2] = true;
    matrix[1][2] = true;
    matrix[3][2] = true;
    matrix[4][1] = true;
    matrix[0][4] = true;

    var layout = SugiyamaLayout{ .allocator = alloc, .graph = &graph, .matrix = matrix, .n_nodes = n_nodes, .id_to_idx = undefined, .b = 0, .layers = undefined, .n_layers = null, .n_dummies = 0, .layout_data = null, .dummy_layout_data = null, .layer_lookup = null };

    const idx = layout.getSink(&v).?;
    try std.testing.expectEqual(2, idx);

    matrix[0][2] = false;
    matrix[1][2] = false;
    matrix[3][2] = false;
    matrix[4][1] = true;
    matrix[1][2] = true;
    matrix[2][4] = true;

    try std.testing.expectEqual(null, layout.getSink(&v));
}

test "find sources" {
    const alloc = std.testing.allocator;
    const dummy = std.ArrayList([]const u8).init(alloc);
    defer dummy.deinit();
    var graph = try graph_lib.Graph.init(alloc, "", dummy, 0.0, 0.0); // just a dummy
    //we don't initialize with the graph with init(), we initialize the field manually
    const n_nodes: usize = 5;

    var matrix = try alloc.alloc([]bool, n_nodes);
    defer alloc.free(matrix);
    for (0..n_nodes) |i| {
        matrix[i] = try alloc.alloc(bool, n_nodes);
        for (0..n_nodes) |j| {
            matrix[i][j] = false;
        }
    }
    defer {
        for (0..n_nodes) |i| {
            alloc.free(matrix[i]);
        }
    }

    //Vertices: 0,1,2,3,4
    var v = std.AutoArrayHashMap(usize, void).init(alloc);
    defer v.deinit();
    for (0..n_nodes) |i| {
        try v.put(i, {});
    }
    matrix[2][0] = true;
    matrix[2][1] = true;
    matrix[2][3] = true;
    matrix[1][4] = true;
    matrix[4][3] = true;

    var layout = SugiyamaLayout{ .allocator = alloc, .graph = &graph, .matrix = matrix, .n_nodes = n_nodes, .id_to_idx = undefined, .b = 0, .layers = undefined, .n_layers = null, .n_dummies = 0, .layout_data = null, .dummy_layout_data = null, .layer_lookup = null };

    const idx = layout.getSource(&v).?;
    try std.testing.expectEqual(2, idx);

    matrix[2][0] = false;
    matrix[2][1] = false;
    matrix[2][3] = false;
    matrix[1][4] = true;
    matrix[4][3] = true;
    matrix[3][1] = true;

    try std.testing.expectEqual(null, layout.getSource(&v));
}

test "remove isolated" {
    const alloc = std.testing.allocator;
    const dummy = std.ArrayList([]const u8).init(alloc);
    defer dummy.deinit();
    var graph = try graph_lib.Graph.init(alloc, "", dummy, 0.0, 0.0); // just a dummy
    //we don't initialize with the graph with init(), we initialize the field manually
    const n_nodes: usize = 5;

    var matrix = try alloc.alloc([]bool, n_nodes);
    defer alloc.free(matrix);
    for (0..n_nodes) |i| {
        matrix[i] = try alloc.alloc(bool, n_nodes);
        for (0..n_nodes) |j| {
            matrix[i][j] = false;
        }
    }
    defer {
        for (0..n_nodes) |i| {
            alloc.free(matrix[i]);
        }
    }

    var v = std.AutoArrayHashMap(usize, void).init(alloc);
    defer v.deinit();
    for (0..n_nodes) |i| {
        try v.put(i, {});
    }
    matrix[2][0] = true;
    matrix[2][1] = true;

    var layout = SugiyamaLayout{ .allocator = alloc, .graph = &graph, .matrix = matrix, .n_nodes = n_nodes, .id_to_idx = undefined, .b = 0, .layers = undefined, .n_layers = null, .n_dummies = 0, .dummy_layout_data = null, .layout_data = null, .layer_lookup = null };

    try layout.removeIsolatedNodes(&v);

    try std.testing.expectEqual(3, v.keys().len);
    try std.testing.expectEqual(null, v.get(4));
    try std.testing.expectEqual(null, v.get(3));
}

test "fas Heur" {
    const alloc = std.testing.allocator;
    const dummy = std.ArrayList([]const u8).init(alloc);
    defer dummy.deinit();
    var graph = try graph_lib.Graph.init(alloc, "", dummy, 0.0, 0.0); // just a dummy
    //we don't initialize with the graph with init(), we initialize the field manually
    const n_nodes: usize = 5;

    var matrix = try alloc.alloc([]bool, n_nodes);
    for (0..n_nodes) |i| {
        matrix[i] = try alloc.alloc(bool, n_nodes);
        for (0..n_nodes) |j| {
            matrix[i][j] = false;
        }
    }

    //Vertices: 0,1,2,3,4
    var v = std.AutoArrayHashMap(usize, void).init(alloc);
    defer v.deinit();
    for (0..n_nodes) |i| {
        try v.put(i, {});
    }
    matrix[2][0] = true;
    matrix[0][1] = true;
    matrix[1][2] = true;
    matrix[3][4] = true;
    matrix[4][3] = true;

    var layout = SugiyamaLayout{ .allocator = alloc, .graph = &graph, .matrix = matrix, .n_nodes = n_nodes, .id_to_idx = undefined, .b = 0, .layers = undefined, .n_layers = null, .n_dummies = 0, .layout_data = null, .dummy_layout_data = null, .layer_lookup = null };
    std.debug.print("\n", .{});
    try layout.fasHeur();
    defer {
        for (0..n_nodes) |i| {
            alloc.free(layout.matrix[i]);
        }
        alloc.free(layout.matrix);
    }

    var n: usize = 0;
    for (layout.matrix) |row| {
        for (row) |val| {
            std.debug.print("{d}", .{@intFromBool(val)});
            if (val) n += 1;
        }
        std.debug.print("\n", .{});
    }

    std.testing.expectEqual(4, n) catch |err| {
        std.debug.print("Wrong number of edges", .{});
        return err;
    };

    std.testing.expectEqual(true, (layout.matrix[3][4] and !layout.matrix[4][3]) or (!layout.matrix[3][4] and layout.matrix[4][3])) catch |err| {
        std.debug.print("Two-cycle not removed", .{});
        return err;
    };

    std.testing.expectEqual(false, utils.graphIsCyclic(alloc, layout.matrix)) catch |err| {
        std.debug.print("Graph contains cycles", .{});
        return err;
    };
}

test "layer scheduling" {
    const alloc = std.testing.allocator;
    const dummy = std.ArrayList([]const u8).init(alloc);
    defer dummy.deinit();
    var graph = try graph_lib.Graph.init(alloc, "", dummy, 0.0, 0.0); // just a dummy
    //we don't initialize with the graph with init(), we initialize the field manually
    const n_nodes: usize = 8;

    var matrix = try alloc.alloc([]bool, n_nodes);
    defer alloc.free(matrix);
    for (0..n_nodes) |i| {
        matrix[i] = try alloc.alloc(bool, n_nodes);
        for (0..n_nodes) |j| {
            matrix[i][j] = false;
        }
    }
    defer {
        for (0..n_nodes) |i| {
            alloc.free(matrix[i]);
        }
    }

    var v = std.AutoArrayHashMap(usize, void).init(alloc);
    defer v.deinit();
    for (0..n_nodes) |i| {
        try v.put(i, {});
    }
    matrix[0][1] = true;
    matrix[0][2] = true;
    matrix[0][3] = true;
    matrix[4][5] = true;
    matrix[3][5] = true;

    const layers = try alloc.alloc(?usize, n_nodes);
    for (0..n_nodes) |i| {
        layers[i] = null;
    }
    defer alloc.free(layers);

    var layout = SugiyamaLayout{
        .allocator = alloc,
        .graph = &graph,
        .matrix = matrix,
        .n_nodes = n_nodes,
        .id_to_idx = undefined,
        .b = 2,
        .layers = layers,
        .n_layers = null,
        .n_dummies = 0,
        .layout_data = null,
        .dummy_layout_data = null,
        .layer_lookup = null,
    };
    try layout.layerScheduling();
    try std.testing.expect(layout.layers[0].? == 0);
    try std.testing.expect(layout.layers[1].? > 0);
    try std.testing.expect(layout.layers[2].? > 0);
    try std.testing.expect(layout.layers[3].? > 0);
    try std.testing.expect(layout.layers[4].? == 0);
    try std.testing.expect(layout.layers[5].? > layout.layers[4].?);
    try std.testing.expect(layout.layers[6].? > 2);
    try std.testing.expect(layout.layers[7].? > 2);
}

test "dummy nodes" {
    const alloc = std.testing.allocator;
    const dummy = std.ArrayList([]const u8).init(alloc);
    defer dummy.deinit();
    var graph = try graph_lib.Graph.init(alloc, "", dummy, 0.0, 0.0); // just a dummy
    //we don't initialize with the graph with init(), we initialize the field manually
    const n_nodes: usize = 6;

    var matrix = try alloc.alloc([]bool, n_nodes);
    // defer alloc.free(matrix);
    for (0..n_nodes) |i| {
        matrix[i] = try alloc.alloc(bool, n_nodes);
        for (0..n_nodes) |j| {
            matrix[i][j] = false;
        }
    }
    // defer {
    //     for (0..n_nodes) |i| {
    //         alloc.free(matrix[i]);
    //     }
    // }

    var v = std.AutoArrayHashMap(usize, void).init(alloc);
    defer v.deinit();
    for (0..n_nodes) |i| {
        try v.put(i, {});
    }
    matrix[0][1] = true;
    matrix[0][2] = true;
    matrix[0][3] = true;
    matrix[0][4] = true;
    matrix[4][5] = true;
    matrix[0][5] = true;

    const layers = try alloc.alloc(?usize, n_nodes);
    for (0..n_nodes) |i| {
        layers[i] = null;
    }
    defer alloc.free(layers);

    const sld = try alloc.alloc(SugiyamaLayoutData, n_nodes);
    defer alloc.free(sld);

    sld[0] = SugiyamaLayoutData{ .pos = undefined, .layer = 0, .alloc = alloc, .order = undefined, .edges = undefined };
    sld[1] = SugiyamaLayoutData{ .pos = undefined, .layer = 1, .alloc = alloc, .order = undefined, .edges = undefined };
    sld[2] = SugiyamaLayoutData{ .pos = undefined, .layer = 1, .alloc = alloc, .order = undefined, .edges = undefined };
    sld[3] = SugiyamaLayoutData{ .pos = undefined, .layer = 2, .alloc = alloc, .order = undefined, .edges = undefined };
    sld[4] = SugiyamaLayoutData{ .pos = undefined, .layer = 3, .alloc = alloc, .order = undefined, .edges = undefined };
    sld[5] = SugiyamaLayoutData{ .pos = undefined, .layer = 4, .alloc = alloc, .order = undefined, .edges = undefined };

    var layout_data: std.ArrayList(*SugiyamaLayoutData) = std.ArrayList(*SugiyamaLayoutData).init(alloc);
    defer layout_data.deinit();

    for (0..sld.len) |i| {
        try layout_data.append(&sld[i]);
    }

    var layout = SugiyamaLayout{
        .allocator = alloc,
        .graph = &graph,
        .matrix = matrix,
        .n_nodes = n_nodes,
        .id_to_idx = undefined,
        .b = 2,
        .layers = layers,
        .n_layers = null,
        .n_dummies = 0,
        .layout_data = try layout_data.clone(),
        .dummy_layout_data = null,
        .layer_lookup = null,
    };

    try layout.insertDummies();

    defer layout.layout_data.?.deinit();
    defer alloc.free(layout.matrix);
    defer {
        for (0..n_nodes + layout.dummy_layout_data.?.len) |i| {
            alloc.free(layout.matrix[i]);
        }
    }
    defer alloc.free(layout.dummy_layout_data.?);

    //everything that must be true in the matrix
    try std.testing.expectEqual(6, layout.n_dummies);
    try std.testing.expectEqual(true, layout.matrix[0][1]);
    try std.testing.expectEqual(true, layout.matrix[0][2]);

    try std.testing.expectEqual(true, layout.matrix[0][6]);
    try std.testing.expectEqual(true, layout.matrix[6][3]);

    try std.testing.expectEqual(true, layout.matrix[0][7]);
    try std.testing.expectEqual(true, layout.matrix[7][8]);
    try std.testing.expectEqual(true, layout.matrix[8][4]);

    try std.testing.expectEqual(true, layout.matrix[4][5]);

    try std.testing.expectEqual(true, layout.matrix[0][9]);
    try std.testing.expectEqual(true, layout.matrix[9][10]);
    try std.testing.expectEqual(true, layout.matrix[10][11]);
    try std.testing.expectEqual(true, layout.matrix[11][5]);

    //TODO only one next for each dummy node
    try std.testing.expectEqual(1, std.mem.count(bool, layout.matrix[6], &[_]bool{true}));
    try std.testing.expectEqual(1, std.mem.count(bool, layout.matrix[7], &[_]bool{true}));
    try std.testing.expectEqual(1, std.mem.count(bool, layout.matrix[8], &[_]bool{true}));
    try std.testing.expectEqual(1, std.mem.count(bool, layout.matrix[9], &[_]bool{true}));
    try std.testing.expectEqual(1, std.mem.count(bool, layout.matrix[10], &[_]bool{true}));
    try std.testing.expectEqual(1, std.mem.count(bool, layout.matrix[11], &[_]bool{true}));

    //TODO Check correct layer for each dummy node
    try std.testing.expectEqual(1, layout.layout_data.?.items[6].layer);
    try std.testing.expectEqual(1, layout.layout_data.?.items[7].layer);
    try std.testing.expectEqual(2, layout.layout_data.?.items[8].layer);
    try std.testing.expectEqual(1, layout.layout_data.?.items[9].layer);
    try std.testing.expectEqual(2, layout.layout_data.?.items[10].layer);
    try std.testing.expectEqual(3, layout.layout_data.?.items[11].layer);
}
