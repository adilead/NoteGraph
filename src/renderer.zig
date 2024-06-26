const std = @import("std");
const stdout = std.io.getStdOut().writer();
const debug = std.debug;

const proc = std.process;
const mem = std.mem;

const c = @import("c_include.zig").c;
const graph_lib = @import("graph.zig");
const Point = graph_lib.Point;
const gui = @import("gui.zig");
const Graph = graph_lib.Graph;

// Colors in abgr format
const BACKGROUND_COLOR = 0xFF181818;
const EDGE_COLOR = 0xFF707070;
const VERT_COLOR = 0xFFFFFF00;
const ORANGE_COLOR = 0xFF5396EE;

const EDGE_HIGHLIGHT = 0xFF0000B3;
const EDGE_UNHIGHLIGHTED = 0xFF303030;
const VERT_HIGHLIGHT = 0xFF0000B3;
const VERT_UNHIGHLIGHTED = 0xFF303030;

const RenderError = error{
    InvalidGraph,
};

pub const NodeRenderData = struct {
    // TODO slap data for the rendering of the node itself into their
    surface: ?*c.SDL_Surface, //owned
    texture: ?*c.SDL_Texture, //owned
    text: [:0]const u8,
    rect: c.SDL_Rect, //owned
    node: *graph_lib.Node,

    font_color: c.SDL_Color,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, node: *graph_lib.Node, font: *c.TTF_Font, renderer: *c.SDL_Renderer) NodeRenderData {
        _ = font;
        _ = renderer;
        const color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
        // const surface = c.TTF_RenderText_Solid(font, node.file.ptr, color).?;
        // const texture = c.SDL_CreateTextureFromSurface(renderer, surface).?;
        const pos = node.layout_data.?.getPos();
        var ndr = NodeRenderData{
            .surface = null,
            .texture = null,
            .text = undefined,
            .rect = c.SDL_Rect{ .x = @as(i32, @intFromFloat(pos.x)), .y = @as(i32, @intFromFloat(pos.y)), .w = 60, .h = 20 }, // TODO
            .node = node,
            .font_color = color,
            .allocator = allocator,
        };
        // std.mem.copy(u8, &ndr.text, node.file);
        // @memcpy(&ndr.text, node.file);
        _ = c.SDL_QueryTexture(ndr.texture, null, null, &ndr.rect.w, &ndr.rect.h);
        return ndr;
    }

    pub fn updateText(self: *NodeRenderData, text: []const u8, font: *c.TTF_Font, renderer: *c.SDL_Renderer) !void {
        c.SDL_FreeSurface(self.surface);
        c.SDL_DestroyTexture(self.texture);
        const color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
        self.text = try self.allocator.dupeZ(u8, std.fs.path.basename(text));
        self.surface = c.TTF_RenderText_Blended(font, self.text.ptr, color) orelse {
            debug.print("ERROR: {s}\n", .{self.text});
            return;
        };
        self.texture = c.SDL_CreateTextureFromSurface(renderer, self.surface) orelse {
            debug.print("ERROR: {s}\n", .{self.text});
            return;
        };

        _ = c.SDL_QueryTexture(self.texture, null, null, &self.rect.w, &self.rect.h);
    }

    pub fn deinit(self: *NodeRenderData) void {
        c.SDL_FreeSurface(self.surface);
        c.SDL_DestroyTexture(self.texture);
        self.allocator.free(self.text);
    }
};

fn setColor(renderer: *c.SDL_Renderer, color: u32) void {
    const r: u8 = @truncate((color >> (0 * 8)) & 0xFF);
    const g: u8 = @truncate((color >> (1 * 8)) & 0xFF);
    const b: u8 = @truncate((color >> (2 * 8)) & 0xFF);
    const a: u8 = @truncate((color >> (3 * 8)) & 0xFF);
    _ = c.SDL_SetRenderDrawColor(renderer, r, g, b, a);
}

pub const Renderer = struct {
    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
    font: *c.TTF_Font,
    window_width: i32,
    window_height: i32,
    render_data: std.ArrayList(*NodeRenderData),
    allocator: std.mem.Allocator,
    scale: f32,
    center: @Vector(2, f32),
    shift: @Vector(2, f32),
    selected_node: ?*graph_lib.Node,
    // ioptr: *c.ImGuiIO,

    pub fn init(window_width: i32, window_height: i32, font_size: i32, allocator: std.mem.Allocator) !Renderer {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        var current: c.SDL_DisplayMode = undefined;
        _ = c.SDL_GetCurrentDisplayMode(0, &current);

        const window = c.SDL_CreateWindow("NoteGraph", 0, 0, window_width, window_height, c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_OPENGL) orelse {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        const renderer = c.SDL_CreateRenderer(window, -1, 0) orelse {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        //init fonts
        if (c.TTF_Init() < 0) {
            c.SDL_Log("Unable to initialize SDL TTF: %s", c.SDL_GetError());
            return error.FontInitializationFailed;
        }

        //TODO add font option to config
        const font_rel_path = "fonts/Roboto-Medium.ttf";
        const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(exe_dir);
        const font_path = try std.fs.path.joinZ(allocator, &[3][]const u8{ exe_dir, "../../", font_rel_path });
        const font = c.TTF_OpenFont(font_path, font_size) orelse {
            c.SDL_Log("Unable to initialize SDL TTF: %s", c.SDL_GetError());
            return error.FontInitializationFailed;
        };

        return Renderer{
            .renderer = renderer,
            .window = window,
            .font = font,
            .window_height = window_height,
            .window_width = window_width,
            .allocator = allocator,
            .render_data = std.ArrayList(*NodeRenderData).init(allocator),
            .scale = 1.0,
            .center = @Vector(2, f32){ @as(f32, @floatFromInt(window_width)) / 2.0, @as(f32, @floatFromInt(window_height)) / 2.0 },
            .shift = @Vector(2, f32){ 0, 0 },
            .selected_node = null,
        };
    }

    pub fn initNgGUI(self: *Renderer, ngGui: *gui.NgGUI) !void {
        try ngGui.initRenderer(self.window, self.renderer);
    }

    pub fn render(self: *Renderer, graph: *Graph, ngGui: *gui.NgGUI) !void {
        setColor(self.renderer, BACKGROUND_COLOR);
        _ = c.SDL_RenderClear(self.renderer);
        //render edges
        var w: i32 = 0;
        var h: i32 = 0;
        c.SDL_GetWindowSize(self.window, &w, &h);

        var center = Point{ .x = self.center[0], .y = self.center[1] };
        center = shift(&center, &self.shift);

        if (ngGui.show_edges) {
            for (graph.nodes.values()) |node| {
                if (self.selected_node) |selected_node| {
                    if (selected_node.id == node.id) {
                        setColor(self.renderer, EDGE_HIGHLIGHT);
                    } else {
                        setColor(self.renderer, EDGE_UNHIGHLIGHTED);
                    }
                } else {
                    setColor(self.renderer, EDGE_COLOR);
                }
                const edges: [][2]Point = try node.layout_data.?.getEdges();
                for (edges) |edge| {
                    var u, var v = edge;
                    u = shift(&u, &self.shift);
                    v = shift(&v, &self.shift);
                    u = scale(&u, &center, self.scale);
                    v = scale(&v, &center, self.scale);
                    _ = c.SDL_RenderDrawLine(
                        self.renderer,
                        @as(i32, @intFromFloat(u.x)),
                        @as(i32, @intFromFloat(u.y)),
                        @as(i32, @intFromFloat(v.x)),
                        @as(i32, @intFromFloat(v.y)),
                    );
                }
            }
        }

        ////render vertices
        var iter_nodes = graph.nodes.iterator();

        setColor(self.renderer, VERT_COLOR);
        while (iter_nodes.next()) |entry| {
            const node: *graph_lib.Node = entry.value_ptr;
            var color: u32 = VERT_COLOR;

            var pos = node.layout_data.?.getPos();
            pos = shift(&pos, &self.shift);
            pos = scale(&pos, &center, self.scale);
            const x: i32 = @as(i32, @intFromFloat(pos.x));
            const y: i32 = @as(i32, @intFromFloat(pos.y));

            var node_is_highlighted = false;
            if (self.selected_node) |selected_node| {
                if (selected_node.id == node.id or std.mem.containsAtLeast(u32, selected_node.edges.items, 1, &[_]u32{node.id})) {
                    color = VERT_HIGHLIGHT;
                    node_is_highlighted = true;
                } else {
                    color = VERT_UNHIGHLIGHTED;
                }
            }

            // self.renderNodeFilled(x, y, 5);
            _ = c.filledCircleColor(self.renderer, @intCast(x), @intCast(y), 5, color);

            if (ngGui.show_font and self.selected_node == null or (self.selected_node != null and node_is_highlighted)) {
                if (node.render_data) |nrd| {
                    _ = c.SDL_RenderCopy(self.renderer, nrd.texture, null, &nrd.rect);
                } else {
                    unreachable;
                }
            }
        }

        //Render text TODO Remove me
        // c.ImGui_ImplSDLRenderer2_RenderDrawData(c.igGetDrawData());
        ngGui.render();
        c.SDL_RenderPresent(self.renderer);
    }

    pub fn updateRenderData(self: *Renderer, graph: *graph_lib.Graph, ngGui: *gui.NgGUI) !void {
        var nodes = graph.nodes;
        var iter_nodes = nodes.iterator();
        if (ngGui.reset_cam) {
            self.scale = 1.0;
            self.shift = @splat(0.0);
            self.center = @Vector(2, f32){ @as(f32, @floatFromInt(self.window_width)) / 2.0, @as(f32, @floatFromInt(self.window_height)) / 2.0 };
        }
        //TODO current mouse point needs to be transformed
        var mouse_point: c.SDL_Point = undefined;
        _ = c.SDL_GetMouseState(&mouse_point.x, &mouse_point.y);
        const mp = Point{ .x = @floatFromInt(mouse_point.x), .y = @floatFromInt(mouse_point.y) };
        // mp = shift(&mp, &self.shift);
        // mp = scale(&mp, &Point{ .x = self.center[0], .y = self.center[1] }, self.scale);
        mouse_point.x = @intFromFloat(mp.x);
        mouse_point.y = @intFromFloat(mp.y);

        self.selected_node = null;
        var center = Point{ .x = self.center[0], .y = self.center[1] };
        center = shift(&center, &self.shift);

        while (iter_nodes.next()) |entry| {
            var node: *graph_lib.Node = entry.value_ptr;
            if (node.render_data) |_| {} else {
                const ndr = try self.allocator.create(NodeRenderData);
                ndr.* = NodeRenderData.init(self.allocator, node, self.font, self.renderer);
                try ndr.updateText(node.file, self.font, self.renderer);
                try self.render_data.append(ndr);
                node.render_data = self.render_data.items[self.render_data.items.len - 1];
            }
            var pos = node.layout_data.?.getPos();
            pos = shift(&pos, &self.shift);
            pos = scale(&pos, &Point{ .x = center.x, .y = center.y }, self.scale);
            node.render_data.?.rect.x = @as(i32, @intFromFloat(pos.x)) - @divFloor(node.render_data.?.rect.w, 2);
            node.render_data.?.rect.y = @as(i32, @intFromFloat(pos.y)) + 5;
            if (c.SDL_PointInRect(&mouse_point, &node.render_data.?.rect) != 0) {
                self.selected_node = node;
            }
            if (!std.mem.eql(u8, node.render_data.?.text, node.file)) {
                debug.print("Updated Text {s}\n", .{node.file});
                try node.render_data.?.updateText(node.file, self.font, self.renderer);
            }
        }
        graph.changed = false;
    }

    pub fn deinit(self: *Renderer) void {
        for (self.render_data.items) |ndr| {
            self.allocator.destroy(ndr);
        }

        self.render_data.deinit();
        c.ImGui_ImplSDLRenderer2_Shutdown();
        c.ImGui_ImplSDL2_Shutdown();
        c.igDestroyContext(null);

        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};

inline fn scale(p: *const Point, center: *const Point, s: f32) Point {
    return Point{ .x = (p.x - center.x) * s + center.x, .y = (p.y - center.y) * s + center.y };
}

inline fn shift(p: *const Point, d: *const @Vector(2, f32)) Point {
    return Point{ .x = p.x + d[0], .y = p.y + d[1] };
}
