const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ng",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("SDL2_ttf");
    exe.linkSystemLibrary("SDL2_gfx");
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("GL");

    const IMGUI_SOURCES = [_][]const u8{
        "deps/cimgui/cimgui.cpp",
        "deps/cimgui/imgui/imgui.cpp",
        "deps/cimgui/imgui/imgui_draw.cpp",
        "deps/cimgui/imgui/imgui_demo.cpp",
        "deps/cimgui/imgui/imgui_widgets.cpp",
        "deps/cimgui/imgui/imgui_tables.cpp",

        // These lines:
        "deps/cimgui/imgui/backends/imgui_impl_sdl2.cpp",
        "deps/cimgui/imgui/backends/imgui_impl_sdlrenderer2.cpp",
        "deps/cimgui/imgui/backends/imgui_impl_opengl3.cpp",
    };

    exe.linkLibC();

    exe.linkLibCpp();
    exe.addIncludePath(b.path("deps/cimgui"));
    exe.addIncludePath(b.path("deps/cimgui/imgui"));
    exe.addIncludePath(b.path("deps/cimgui/imgui/backends"));
    exe.addIncludePath(b.path("deps/cimgui/generator/output"));
    exe.addCSourceFiles(.{ .files = &IMGUI_SOURCES });
    exe.defineCMacro("IMGUI_IMPL_OPENGL_LOADER_GL3W", "");
    exe.defineCMacro("IMGUI_IMPL_API", "extern \"C\"");

    b.installArtifact(exe);

    const run_ng = b.addRunArtifact(exe);
    const run_ng_step = b.step("run", "Runs the app");
    run_ng_step.dependOn(&run_ng.step);
}
