const std = @import("std");
const stdout = std.io.getStdOut().writer();
const debug = std.debug;

const proc = std.process;
const mem = std.mem;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL_ttf.h");
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

pub const NodeRenderData = struct {
    // TODO slap data for the rendering of the node itself into their
    surface: *c.SDL_Surface, //owned
    texture: *c.SDL_Texture, //owned
    text: [200:0]u8,
    rect: c.SDL_Rect,      //owned
    node: *graph_lib.Node,

    font_color: c.SDL_Color,

    pub fn init(node: *graph_lib.Node, font: *c.TTF_Font, renderer: *c.SDL_Renderer) NodeRenderData{
        var color = c.SDL_Color{.r=255, .g=255, .b=255, .a=255};
        // TODO Display actual name 
        var surface = c.TTF_RenderText_Solid(font, node.file.ptr, color).?;
        var texture = c.SDL_CreateTextureFromSurface(renderer, surface).?;
        var ndr = NodeRenderData {
            .surface = surface,
            .texture = texture,
            .text = undefined,
            .rect = c.SDL_Rect{.x=@floatToInt(i32, node.position.x), .y=@floatToInt(i32, node.position.y), .w=60, .h=20}, // TODO
            .node = node,
            .font_color = color,
        };
        std.mem.copy(u8, &ndr.text, node.file);
        _ = c.SDL_QueryTexture(ndr.texture, null, null, &ndr. rect.w, &ndr.rect.h);
        return ndr;   
    }

    pub fn updateText(self: *NodeRenderData, text: []const u8, font: *c.TTF_Font, renderer: *c.SDL_Renderer) void {
        c.SDL_FreeSurface(self.surface);
        c.SDL_DestroyTexture(self.texture);
        var color = c.SDL_Color{.r=255, .g=255, .b=255, .a=255};
        // TODO Display actual name 
        self.text = std.mem.zeroes([200:0]u8);
        std.mem.copy(u8, &self.text, text);
        self.surface = c.TTF_RenderText_Solid(font, &self.text, color).?;
        self.texture = c.SDL_CreateTextureFromSurface(renderer, self.surface).?;

        _ = c.SDL_QueryTexture(self.texture, null, null, &self.rect.w, &self.rect.h);
    }

    pub fn deinit(self: *NodeRenderData) void {
        c.SDL_FreeSurface(self.surface);
        c.SDL_DestroyTexture(self.texture);
    }
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
    font: *c.TTF_Font,
    window_width: i32,
    window_height: i32,
    render_data: std.ArrayList(*NodeRenderData),
    allocator: std.mem.Allocator,
    
    pub fn init(window_width: i32, window_height: i32, font_size: i32, allocator: std.mem.Allocator) !Renderer {
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

        //init fonts
        if(c.TTF_Init() < 0){
            c.SDL_Log("Unable to initialize SDL TTF: %s", c.SDL_GetError());
            return error.FontInitializationFailed;
        }

        //TODO add font option to config
        var font_path = "fonts/Roboto-Medium.ttf";
        var font = c.TTF_OpenFont(font_path, font_size) orelse {
            c.SDL_Log("Unable to initialize SDL TTF: %s", c.SDL_GetError());
            return error.FontInitializationFailed;
        };

        return Renderer {
            .renderer = renderer,
            .window = window,
            .font=font,
            .window_height = window_height,
            .window_width = window_width,
            .allocator =  allocator,
            .render_data = std.ArrayList(*NodeRenderData).init(allocator),
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

        // TODO Remove me
        var color = c.SDL_Color{.r=255, .g=255, .b=255, .a=255};
        var surface = c.TTF_RenderText_Solid(self.font, "NoteGraph", color);
        var texture = c.SDL_CreateTextureFromSurface(self.renderer, surface);

        var Message_rect = c.SDL_Rect{.x=0, .y=0, .w=60, .h=20}; //create a rect

        while(iter.next()) |entry| {
            var edge = entry.key_ptr;

            // we assume the graph is valid
            var v = graph.nodes.get(edge.v) orelse unreachable;
            var u = graph.nodes.get(edge.u) orelse unreachable;

            
            _ = c.SDL_RenderDrawLine(
                self.renderer,
                @floatToInt(i32, u.position.x),
                @floatToInt(i32, u.position.y),
                @floatToInt(i32, v.position.x),
                @floatToInt(i32, v.position.y),
            );
        }
        
        //render vertices
        var iter_nodes = graph.nodes.iterator();

        setColor(self.renderer, VERT_COLOR);
        while(iter_nodes.next()) |entry| {
            var node = entry.value_ptr;
            var x: i32 = @floatToInt(i32, node.position.x);
            var y: i32 = @floatToInt(i32, node.position.y);

            self.renderNodeFilled(x,y,5);

            if(node.render_data) |nrd| {
                _ = c.SDL_RenderCopy(self.renderer, nrd.texture, null, &nrd.rect);
            } else {
                unreachable;
            }  
        }
        
        //Render text TODO Remove me
        _ = c.SDL_RenderCopy(self.renderer, texture, null, &Message_rect);

        c.SDL_RenderPresent(self.renderer);

        // TODO Remove me
        c.SDL_FreeSurface(surface);
        c.SDL_DestroyTexture(texture);
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

            _ = c.SDL_RenderDrawLine(self.renderer, x - offsety, y + offsetx,
                                         x + offsety, y + offsetx);
            _ = c.SDL_RenderDrawLine(self.renderer, x - offsetx, y + offsety,
                                         x + offsetx, y + offsety);
            _ = c.SDL_RenderDrawLine(self.renderer, x - offsetx, y - offsety,
                                         x + offsetx, y - offsety);
            _ = c.SDL_RenderDrawLine(self.renderer, x - offsety, y - offsetx,
                                         x + offsety, y - offsetx);


            if (d >= 2*offsetx) {
                d -= 2*offsetx + 1;
                offsetx +=1;
            }
            else if (d < 2 * (radius - offsety)) {
                d += 2 * offsety - 1;
                offsety -= 1;
            }
            else {
                d += 2 * (offsety - offsetx - 1);
                offsety -= 1;
                offsetx += 1;
            }
        }

    }
    fn renderNode(self: *Renderer, x0: i32, y0: i32, radius: i32) void {

        var x = radius-1;
        var y: i32  = 0;
        var dx: i32 = 1;
        var dy: i32 = 1;
        var err: i32 = dx - (radius << 1);

        while (x >= y)
        {
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + x, y0 + y);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + y, y0 + x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - y, y0 + x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - x, y0 + y);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - x, y0 - y);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 - y, y0 - x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + y, y0 - x);
            _ = c.SDL_RenderDrawPoint(self.renderer, x0 + x, y0 - y);

            if (err <= 0){
                y +=1;
                err += dy;
                dy += 2;
            }
            
            if (err > 0){
                x -= 1;
                dx += 2;
                err += dx - (radius << 1);
            }
        }

    }

    pub fn updateRenderData(self: *Renderer, graph: *graph_lib.Graph) !void {
        var iter_nodes = graph.nodes.iterator();
        while(iter_nodes.next()) |entry| {
            var node = entry.value_ptr;
            if(node.render_data) |render_data| {
                render_data.rect.x = @floatToInt(i32, node.position.x);
                render_data.rect.y = @floatToInt(i32, node.position.y);
                if(!std.mem.eql(u8, &render_data.text, node.file)){
                    render_data.updateText(node.file, self.font, self.renderer);
                }

            } else {
                var ndr = try self.allocator.create(NodeRenderData);
                ndr.* = NodeRenderData.init(node, self.font, self.renderer);
                //TODO file name with zero at the end
                try self.render_data.append(ndr);
                node.render_data = self.render_data.items[self.render_data.items.len - 1];
            }
        }
    }

    pub fn deinit(self: *Renderer) void {
        for(self.render_data.items) |ndr| {
            self.allocator.destroy(ndr);
        }

        self.render_data.deinit();
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
