const std = @import("std");
const stdout = std.io.getStdOut().writer();
const debug = std.debug;

const proc = std.process;
const mem = std.mem;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const graph_lib = @import("graph.zig");
const Graph = graph_lib.Graph;

const BACKGROUND_COLOR = 0xFF181818; // abgr
const EDGE_COLOR = 0xFFFFFFFF; // abgr
const VERT_COLOR = 0xFFFFFF00; // abgr
const ORANGE_COLOR = 0xFF5396EE; // abgr

const RenderError = error {
    InvalidGraph,
};

fn setColor(renderer: *c.SDL_Renderer, color: u32) void {
    const r = @truncate(u8, (color >> (0*8)) & 0xFF);
    const g = @truncate(u8, (color >> (1*8)) & 0xFF);
    const b = @truncate(u8, (color >> (2*8)) & 0xFF);
    const a = @truncate(u8, (color >> (3*8)) & 0xFF);
    _ = c.SDL_SetRenderDrawColor(renderer, r, g, b, a);
}

pub const Renderer = struct{

    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
    window_width: i32,
    window_height: i32,
    
    pub fn init(window_width: i32, window_height: i32) !Renderer {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        const window = c.SDL_CreateWindow("GraphNote", 0, 0, window_width, window_height, 0) orelse {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        return Renderer {
            .renderer = renderer,
            .window = window,
            .window_height = window_height,
            .window_width = window_width,
        };
    }

    pub fn render(self: *Renderer, graph: *Graph) !void {

        setColor(self.renderer, BACKGROUND_COLOR);
        _ = c.SDL_RenderClear(self.renderer);

        //render edges
        var iter = graph.edges.iterator();
        var w: i32 =0;
        var h: i32 = 0;
        c.SDL_GetWindowSize(self.window, &w, &h);
        setColor(self.renderer, EDGE_COLOR);

        while(iter.next()) |entry| {
            var edge = entry.key_ptr;
            var v = graph.nodes.get(edge.v) orelse return RenderError.InvalidGraph;
            var u = graph.nodes.get(edge.u) orelse return RenderError.InvalidGraph;

            
            _ = c.SDL_RenderDrawLine(
                self.renderer,
                @floatToInt(i32, u.position.x * @intToFloat(f32, w)),
                @floatToInt(i32, u.position.y * @intToFloat(f32, h)),
                @floatToInt(i32, v.position.x * @intToFloat(f32, w)),
                @floatToInt(i32, v.position.y * @intToFloat(f32, h)),
            );
        }
        
        //render vertices
        var iter_nodes = graph.nodes.iterator();

        setColor(self.renderer, VERT_COLOR);
        while(iter_nodes.next()) |entry| {
            var node = entry.value_ptr;
            var x: i32 = @floatToInt(i32, node.position.x * @intToFloat(f32, w)) - 10;
            var y: i32 = @floatToInt(i32, node.position.y * @intToFloat(f32, h)) - 10;

            var rect: c.SDL_Rect = c.SDL_Rect {.x=x, .y=y, .w=20, .h=20};

            _ = c.SDL_RenderDrawRect(self.renderer, &rect);
        }
        //render text

        c.SDL_RenderPresent(self.renderer);
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
