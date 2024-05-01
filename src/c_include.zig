pub const c = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cInclude("cimgui.h");
    @cDefine("CIMGUI_USE_SDL2", {});
    @cDefine("CIMGUI_USE_OPENGL3", {});
    @cInclude("cimgui_impl.h");

    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL_render.h");
    @cInclude("SDL_ttf.h");
    @cInclude("SDL2_gfxPrimitives.h");

    @cInclude("GL/gl.h");
    @cInclude("GL/glu.h");
});
