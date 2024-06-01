const std = @import("std");
const proc = std.process;
const mem = std.mem;

const config = @import("config.zig");
const graph_lib = @import("graph.zig");
const utils = @import("utils.zig");
const rendering_lib = @import("renderer.zig");
const layout = @import("layout.zig");
const Graph = graph_lib.Graph;
const Renderer = rendering_lib.Renderer;
const NgGui = @import("gui.zig").NgGUI;
const tests = @import("tests.zig");
const nvim = @import("nvim.zig");

const c = @import("c_include.zig").c;
const WINDOW_WIDTH: i32 = 1500;
const WINDOW_HEIGHT: i32 = 1000;

const FPS: u32 = 30;

const BACKGROUND_COLOR: u32 = 0xFF181818; // abgr
const ORANGE_COLOR: u32 = 0xFF5396EE; // abgr

var quit = false;
const stdout = std.io.getStdOut().writer();
const debug = std.debug;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var ngConf: config.NGConfig = try getConfig(arena.allocator());
    defer ngConf.deinit();

    var file_types = std.ArrayList([]const u8).init(arena.allocator());
    defer file_types.deinit();

    try file_types.append(".md");

    const files = try utils.traverseRoot(arena.allocator(), ngConf.root, &file_types);
    defer {
        for (files.items) |file| {
            arena.allocator().free(file);
        }
    }

    var graph: Graph = try Graph.init(gpa.allocator(), ngConf.root, files, @floatFromInt(WINDOW_WIDTH), @floatFromInt(WINDOW_HEIGHT));
    defer graph.deinit();

    var renderer = try Renderer.init(WINDOW_WIDTH, WINDOW_HEIGHT, ngConf.font_size, arena.allocator());
    defer renderer.deinit();

    var ng_gui = NgGui.init(gpa.allocator());
    defer ng_gui.deinit();
    try renderer.initNgGUI(&ng_gui);

    var mouse_start: ?@Vector(2, f32) = null;
    var mouse_end: ?@Vector(2, f32) = null;
    var mouse_down: ?@Vector(2, f32) = null;
    var mouse_up: ?@Vector(2, f32) = null;
    while (!quit) {
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event) != 0) {
            _ = c.ImGui_ImplSDL2_ProcessEvent(&event);
            if (ng_gui.ioptr.?.WantCaptureMouse) {
                mouse_start = null;
                mouse_end = null;
                continue;
            }
            switch (event.type) {
                c.SDL_QUIT => {
                    quit = true;
                },
                c.SDL_MOUSEWHEEL => {
                    if (event.wheel.y != 0) {
                        renderer.scale += @as(f32, @floatFromInt(event.wheel.y)) * 0.2;
                    }
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    if (event.button.button == 1) {
                        mouse_start = mouse_start orelse @Vector(2, f32){
                            @floatFromInt(event.button.x),
                            @floatFromInt(event.button.y),
                        };
                        mouse_down = mouse_start;
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (mouse_start) |_| {
                        mouse_end = @Vector(2, f32){
                            @floatFromInt(event.motion.x),
                            @floatFromInt(event.motion.y),
                        };
                    }
                },
                c.SDL_MOUSEBUTTONUP => {
                    if (event.button.button == 1) {
                        mouse_start = null;
                        mouse_end = null;
                    }
                    mouse_up = mouse_start orelse @Vector(2, f32){
                        @floatFromInt(event.button.x),
                        @floatFromInt(event.button.y),
                    };
                },
                else => {},
            }
        }

        //process what to do with the mouse on the canvas
        //for now, we simply want to move the canvas
        if (mouse_start != null and mouse_end != null) {
            //check if a text box was clicked
            var mouse_point: c.SDL_Point = .{ .x = @intFromFloat(mouse_start.?[0]), .y = @intFromFloat(mouse_start.?[1]) };
            var shift_cam = true;
            for (graph.nodes.values()) |node| {
                if (node.render_data) |nrd| {
                    if (c.SDL_PointInRect(&mouse_point, &nrd.rect) != 0) {
                        shift_cam = false;
                        break;
                    }
                }
            }
            if (shift_cam) {
                renderer.shift += (mouse_end.? - mouse_start.?);
                mouse_start = mouse_end;
            } else {
                mouse_start = null;
                mouse_end = null;
            }
        }

        if (mouse_down != null and mouse_up != null) {
            // var shift_ = true;
            var mouse_down_point: c.SDL_Point = .{ .x = @intFromFloat(mouse_down.?[0]), .y = @intFromFloat(mouse_down.?[1]) };
            var mouse_up_point: c.SDL_Point = .{ .x = @intFromFloat(mouse_up.?[0]), .y = @intFromFloat(mouse_up.?[1]) };

            var path: ?[]const u8 = null;
            for (graph.nodes.values()) |node| {
                if (node.render_data) |nrd| {
                    // mp = shift(&mp, &self.shift);
                    // mp = scale(&mp, &Point{ .x = self.center[0], .y = self.center[1] }, self.scale);
                    if (c.SDL_PointInRect(&mouse_down_point, &nrd.rect) != 0 and c.SDL_PointInRect(&mouse_up_point, &nrd.rect) != 0) {
                        path = node.path;
                        break;
                    }
                }
            }
            if (path) |p| {
                try nvim.openInNvim(gpa.allocator(), p, ngConf.pipe);
                mouse_down = null;
                mouse_up = null;
            }
        }

        try ng_gui.build();

        if (ng_gui.layout_changed) {
            debug.print("Change layout\n", .{});
            layout.resetLayout(&graph); //TODO Remove me
            const new_layout = ng_gui.selected_layout_method;
            try layout.layout(gpa.allocator(), &graph, new_layout, WINDOW_WIDTH, WINDOW_HEIGHT);
            ng_gui.layout_changed = false;
        }

        try renderer.updateRenderData(&graph, &ng_gui);
        try renderer.render(&graph, &ng_gui);

        _ = c.SDL_Delay(1000 / 30);
    }
}

pub fn getConfig(allocator: mem.Allocator) !config.NGConfig {
    var args = try proc.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();

    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();

    var counter: u32 = 0;
    while (args.next()) |arg| {
        if (counter == 0) {
            counter += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--root")) {
            const root = args.next() orelse break;

            try map.put("root", root);
            debug.print("{s}\n", .{root});
        } else if (std.mem.eql(u8, arg, "--pipe")) {
            const root = args.next() orelse break;

            try map.put("pipe", root);
            debug.print("{s}\n", .{root});
        } else if (std.mem.eql(u8, arg, "--config")) {
            const config_path: []const u8 = args.next() orelse break;

            try map.put("config", config_path);
            debug.print("{s}\n", .{config_path});
        } else if (std.mem.eql(u8, arg, "--fontsize")) {
            const fontsize: []const u8 = args.next() orelse break;

            try map.put("fontsize", fontsize);
        } else {
            debug.print("{s}\n", .{arg});
        }

        counter += 1;
    }
    const conf: config.NGConfig = try config.NGConfig.init(allocator, map);

    return conf;
}
