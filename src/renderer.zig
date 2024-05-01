const std = @import("std");
const stdout = std.io.getStdOut().writer();
const debug = std.debug;

const proc = std.process;
const mem = std.mem;

const c = @import("main.zig").c;
const graph_lib = @import("graph.zig");
const Graph = graph_lib.Graph;

const BACKGROUND_COLOR = 0xFF181818; // abgr
const EDGE_COLOR = 0xFFFFFFFF; // abgr
const VERT_COLOR = 0xFFFFFF00; // abgr
const ORANGE_COLOR = 0xFF5396EE; // abgr

const RenderError = error{
    InvalidGraph,
};

pub const NodeRenderData = struct {
    // TODO slap data for the rendering of the node itself into their
    surface: *c.SDL_Surface, //owned
    texture: *c.SDL_Texture, //owned
    text: [:0]const u8,
    rect: c.SDL_Rect, //owned
    node: *graph_lib.Node,

    font_color: c.SDL_Color,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, node: *graph_lib.Node, font: *c.TTF_Font, renderer: *c.SDL_Renderer) NodeRenderData {
        const color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
        // TODO Display actual name
        const surface = c.TTF_RenderText_Solid(font, node.file.ptr, color).?;
        const texture = c.SDL_CreateTextureFromSurface(renderer, surface).?;
        var ndr = NodeRenderData{
            .surface = surface,
            .texture = texture,
            .text = undefined,
            .rect = c.SDL_Rect{ .x = @as(i32, @intFromFloat(node.position.x)), .y = @as(i32, @intFromFloat(node.position.y)), .w = 60, .h = 20 }, // TODO
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
        self.surface = c.TTF_RenderText_Solid(font, self.text.ptr, color).?;
        self.texture = c.SDL_CreateTextureFromSurface(renderer, self.surface).?;

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
    gl_context: c.SDL_GLContext,
    ioptr: *c.ImGuiIO,

    pub fn init(window_width: i32, window_height: i32, font_size: i32, allocator: std.mem.Allocator) !Renderer {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }
        // prepare OpenGL stuff
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_FLAGS, 0);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 0);

        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_DRIVER, "opengl");
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_STENCIL_SIZE, 8);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
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
        const font_path = "fonts/Roboto-Medium.ttf";
        const font = c.TTF_OpenFont(font_path, font_size) orelse {
            c.SDL_Log("Unable to initialize SDL TTF: %s", c.SDL_GetError());
            return error.FontInitializationFailed;
        };

        //init imgui
        const gl_context = c.SDL_GL_CreateContext(window) orelse {
            c.SDL_Log("Unable to initialize Opengl Context: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        _ = c.SDL_GL_SetSwapInterval(1);
        _ = c.igCreateContext(null) orelse {
            c.SDL_Log("Unable to initialize ImGui Context: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        const ioptr = c.igGetIO();
        ioptr.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;
        if (!c.ImGui_ImplSDL2_InitForSDLRenderer(window, renderer)) {
            c.SDL_Log("Unable to initialize ImGui Context: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        if (!c.ImGui_ImplSDLRenderer2_Init(renderer)) {
            c.SDL_Log("Unable to initialize ImGui Context: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        // if (!c.ImGui_ImplOpenGL3_Init("#version 130")) {
        //     c.SDL_Log("Unable to initialize ImGui Context: %s", c.SDL_GetError());
        //     return error.SDLInitializationFailed;
        // }

        c.igStyleColorsDark(null);

        return Renderer{
            .renderer = renderer,
            .window = window,
            .font = font,
            .window_height = window_height,
            .window_width = window_width,
            .allocator = allocator,
            .render_data = std.ArrayList(*NodeRenderData).init(allocator),
            .gl_context = gl_context,
            .ioptr = ioptr,
        };
    }

    pub fn render(self: *Renderer, graph: *Graph) !void {

        // start imgui frame
        c.ImGui_ImplSDLRenderer2_NewFrame();
        c.ImGui_ImplSDL2_NewFrame();
        c.igNewFrame();
        var b = true;
        c.igShowDemoWindow(&b);
        _ = c.igBegin("Hello, world!", null, 0);
        c.igText("This is some useful text");

        c.igEnd();
        c.igRender();

        setColor(self.renderer, BACKGROUND_COLOR);
        _ = c.SDL_RenderClear(self.renderer);
        //render edges
        var iter = graph.edges.iterator();
        var w: i32 = 0;
        var h: i32 = 0;
        c.SDL_GetWindowSize(self.window, &w, &h);
        setColor(self.renderer, EDGE_COLOR);

        while (iter.next()) |entry| {
            const edge = entry.key_ptr;

            // we assume the graph is valid
            const v = graph.nodes.get(edge.v) orelse unreachable;
            const u = graph.nodes.get(edge.u) orelse unreachable;

            _ = c.SDL_RenderDrawLine(
                self.renderer,
                @as(i32, @intFromFloat(u.position.x)),
                @as(i32, @intFromFloat(u.position.y)),
                @as(i32, @intFromFloat(v.position.x)),
                @as(i32, @intFromFloat(v.position.y)),
            );
        }

        ////render vertices
        var iter_nodes = graph.nodes.iterator();

        setColor(self.renderer, VERT_COLOR);
        while (iter_nodes.next()) |entry| {
            const node: *graph_lib.Node = entry.value_ptr;
            const x: i32 = @as(i32, @intFromFloat(node.position.x));
            const y: i32 = @as(i32, @intFromFloat(node.position.y));

            self.renderNodeFilled(x, y, 5);
            // _ = c.filledCircleColor(self.renderer, @intCast(x), @intCast(y), 10, VERT_COLOR);

            if (node.render_data) |nrd| {
                _ = c.SDL_RenderCopy(self.renderer, nrd.texture, null, &nrd.rect);
            } else {
                unreachable;
            }
        }

        //Render text TODO Remove me
        c.ImGui_ImplSDLRenderer2_RenderDrawData(c.igGetDrawData());
        c.SDL_RenderPresent(self.renderer);
    }

    fn renderText(self: *Renderer, nrd: *NodeRenderData) void {
        _ = nrd;
        _ = self;
    }

    fn renderNodeFilled(self: *Renderer, x: i32, y: i32, radius: i32) void {
        var offsetx: i32 = 0;
        var offsety: i32 = radius;
        var d: i32 = radius - 1;

        while (offsety >= offsetx) {
            _ = c.SDL_RenderDrawLine(self.renderer, x - offsety, y + offsetx, x + offsety, y + offsetx);
            _ = c.SDL_RenderDrawLine(self.renderer, x - offsetx, y + offsety, x + offsetx, y + offsety);
            _ = c.SDL_RenderDrawLine(self.renderer, x - offsetx, y - offsety, x + offsetx, y - offsety);
            _ = c.SDL_RenderDrawLine(self.renderer, x - offsety, y - offsetx, x + offsety, y - offsetx);

            if (d >= 2 * offsetx) {
                d -= 2 * offsetx + 1;
                offsetx += 1;
            } else if (d < 2 * (radius - offsety)) {
                d += 2 * offsety - 1;
                offsety -= 1;
            } else {
                d += 2 * (offsety - offsetx - 1);
                offsety -= 1;
                offsetx += 1;
            }
        }
    }
    fn renderNode(self: *Renderer, x0: i32, y0: i32, radius: i32) void {
        var x = radius - 1;
        var y: i32 = 0;
        var dx: i32 = 1;
        var dy: i32 = 1;
        var err: i32 = dx - (radius << 1);

        while (x >= y) {
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + x, y0 + y);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + y, y0 + x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - y, y0 + x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - x, y0 + y);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - x, y0 - y);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - y, y0 - x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + y, y0 - x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + x, y0 - y);

            if (err <= 0) {
                y += 1;
                err += dy;
                dy += 2;
            }

            if (err > 0) {
                x -= 1;
                dx += 2;
                err += dx - (radius << 1);
            }
        }
    }

    pub fn updateRenderData(self: *Renderer, graph: *graph_lib.Graph) !void {
        var nodes = graph.nodes;
        var iter_nodes = nodes.iterator();
        while (iter_nodes.next()) |entry| {
            var node: *graph_lib.Node = entry.value_ptr;
            if (node.render_data) |render_data| {
                render_data.rect.x = @as(i32, @intFromFloat(node.position.x));
                render_data.rect.y = @as(i32, @intFromFloat(node.position.y));
                if (!std.mem.eql(u8, render_data.text, node.file)) {
                    try render_data.updateText(node.file, self.font, self.renderer);
                }
            } else {
                const ndr = try self.allocator.create(NodeRenderData);
                ndr.* = NodeRenderData.init(self.allocator, node, self.font, self.renderer);
                //TODO file name with zero at the end
                try self.render_data.append(ndr);
                node.render_data = self.render_data.items[self.render_data.items.len - 1];
            }
        }
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
