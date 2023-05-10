const std = @import("std");
const proc = std.process;
const mem = std.mem;

const config = @import("config.zig");
const graph_lib = @import("graph.zig");
const utils = @import("utils.zig");
const Graph = graph_lib.Graph;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;

var quit = false;
const stdout = std.io.getStdOut().writer();
const debug = std.debug;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var ngConf: config.NGConfig = try getConfig(arena.allocator());
    defer ngConf.deinit();
    
    var file_types = std.ArrayList([]const u8).init(arena.allocator());
    defer file_types.deinit();

    try file_types.append("md");
    try file_types.append("txt");

    var files = try utils.traverseRoot(gpa.allocator(), ngConf.root, &file_types);

    var graph: Graph = try Graph.init(gpa.allocator(), files);
    defer graph.deinit();

    try startWindow();
    
    // ngConf.* = config.NGConfig.initJSON(allocator, config_path);
}

pub fn startWindow() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("GraphNote", 0, 0, WINDOW_WIDTH, WINDOW_HEIGHT, 0) orelse {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    while (!quit){
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.@"type") {
                c.SDL_QUIT => {
                    quit = true;
                },
                else => {},
            }
        }
    }
}

pub fn getConfig(allocator: mem.Allocator) !config.NGConfig {
    
    var args = try proc.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();

    var map = std.StringHashMap([]const u8).init(
        allocator
    );
    defer map.deinit();


    var counter: u32 = 0;
    while(args.next()) |arg| {
        if(counter == 0){
            counter += 1;
            continue;
        }
        
        if(std.mem.eql(u8, arg, "--root")) {
            var root = args.next() orelse break;

            try map.put("root", root);
            debug.print("{s}\n", .{root});

        } else if(std.mem.eql(u8, arg, "--config")) {
            var config_path: []const u8 = args.next() orelse break;

            try map.put("config", config_path);
            debug.print("{s}\n", .{config_path});

        } else {
            debug.print("{s}\n", .{arg});
        }

        counter += 1;

    } 
    var conf: config.NGConfig = try config.NGConfig.init(allocator, map);

    return conf;
}

