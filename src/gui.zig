const std = @import("std");
const stdout = std.io.getStdOut().writer();
const debug = std.debug;
const Allocator = std.mem.Allocator;

const c = @import("c_include.zig").c;
const layout = @import("layout.zig");

pub const NgGUI = struct {
    allocator: Allocator,
    renderer_init: bool,
    ioptr: ?*c.ImGuiIO,

    selected_layout_method: layout.LayoutMethod,
    layout_changed: bool,

    show_font: bool,
    show_font_changed: bool,

    show_edges: bool,
    show_edges_changed: bool,

    pub fn init(allocator: Allocator) NgGUI {
        return NgGUI{
            .allocator = allocator,
            .renderer_init = false,
            .ioptr = null,
            .selected_layout_method = layout.LayoutMethod.sugiyama,
            .layout_changed = true,
            .show_font = true,
            .show_font_changed = true,
            .show_edges = true,
            .show_edges_changed = true,
        };
    }

    pub fn initRenderer(self: *NgGUI, window: *c.SDL_Window, renderer: *c.SDL_Renderer) !void {
        //init imgui
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

        c.igStyleColorsDark(null);
        self.ioptr = ioptr;
    }

    pub fn render(self: *NgGUI) void {
        _ = self;
        c.ImGui_ImplSDLRenderer2_RenderDrawData(c.igGetDrawData());
    }

    pub fn build(self: *NgGUI) !void {
        c.ImGui_ImplSDLRenderer2_NewFrame();
        c.ImGui_ImplSDL2_NewFrame();
        c.igNewFrame();

        // _ = c.igBegin("Hello, world!", null, c.ImGuiWindowFlags_None);
        _ = c.igBegin("Hello, world!", null, c.ImGuiWindowFlags_None);
        c.igText("Choose layout algorithm");
        c.igSeparator();

        //reset changed flags
        self.show_font_changed = false;
        self.show_edges_changed = false;

        //Layout selector
        if (c.igBeginCombo("Layout", self.selected_layout_method.toString(), c.ImGuiComboFlags_None)) {
            for (0..@typeInfo(layout.LayoutMethod).Enum.fields.len) |i| {
                const lm: layout.LayoutMethod = @enumFromInt(i);
                const isSelected = (lm == self.selected_layout_method);
                if (c.igSelectable_Bool(lm.toString(), isSelected, c.ImGuiSelectableFlags_None, c.ImVec2{ .x = 0.0, .y = 0.0 })) {
                    self.layout_changed = self.selected_layout_method != lm;
                    self.selected_layout_method = lm;
                }
                if (isSelected) c.igSetItemDefaultFocus();
            }
            c.igEndCombo();
        }

        //Font toggler
        if (c.igCheckbox("Show titles", &self.show_font)) {
            self.show_font_changed = true;
        }

        //Edges toggler
        if (c.igCheckbox("Show edges", &self.show_edges)) {
            self.show_edges_changed = true;
        }

        c.igEnd();
        c.igRender();
    }

    pub fn deinit(self: *NgGUI) void {
        _ = self; // autofix
    }
};
