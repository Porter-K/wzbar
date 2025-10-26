const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const cfg = @import("config");

const c = @cImport({
    @cInclude("freetype2/ft2build.h");
    @cInclude("freetype2/freetype/freetype.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const Context = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    layer_shell: ?*zwlr.LayerShellV1,
    layer_surface: ?*zwlr.LayerSurfaceV1,
    surface: ?*wl.Surface,
    running: bool,
    height: u32,
    width: u32,
    config: cfg.Config,
};

pub fn main() !void {
    const result = try cfg.parse_config();
    defer result.deinit();
    const config = result.value;

    try createBar(config);
}

fn draw_blank_module(module: cfg.Module, context: Context, data: []u32) anyerror!void {
    var j: u32 = module.y;
    while (j < module.y + module.height) : (j += 1) {
        var i: u32 = module.x;
        while (i < module.x + module.width) : (i += 1) {
            data[j * context.width + i] = module.background_colour;
        }
    }
}

fn draw_time_module(module: cfg.Module, context: Context, data: []u32) anyerror!void {
    var j: u32 = module.y;
    while (j < module.y + module.height) : (j += 1) {
        var i: u32 = module.x;
        while (i < module.x + module.width) : (i += 1) {
            data[j * context.width + i] = module.background_colour;
        }
    }
    const time = c.time(null);
    const local_time = c.localtime(&time);
    const c_time_str = c.asctime(local_time);
    var len: u8 = 0;
    while (c_time_str[len] != 0) {
        len += 1;
    }
    const time_str: []const u8 = c_time_str[0..len-1];

    try drawText(time_str, module.x, module.y, context, data);
    context.surface.?.damage(@intCast(module.x), @intCast(module.y), @intCast(module.width), @intCast(module.height));
    context.surface.?.commit();
}

fn createBar(config: cfg.Config) !void {
    var context = Context{
        .shm = null,
        .compositor = null,
        .layer_shell = null,
        .layer_surface = null,
        .surface = null,
        .running = true,
        .height = 0,
        .width = 0,
        .config = config,
    };

    const wl_display = try wl.Display.connect(null);
    const wl_registry = try wl_display.getRegistry();

    wl_registry.setListener(*Context, wlRegistryListener, &context);
    if (wl_display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const wl_compositor = context.compositor orelse return error.NoWlCompositor;
    const layer_shell = context.layer_shell orelse return error.NoShell;

    const wl_surface = try wl_compositor.createSurface();
    defer wl_surface.destroy();
    context.surface = wl_surface;

    const zwlr_surface = try layer_shell.getLayerSurface(wl_surface, null, zwlr.LayerShellV1.Layer.top, "wzbar");
    defer zwlr_surface.destroy();
    zwlr_surface.setSize(0, @intCast(config.height));
    zwlr_surface.setAnchor(.{
        .top = config.location == cfg.Location.top,
        .right = true,
        .left = true,
        .bottom = config.location == cfg.Location.bottom,
    });
    zwlr_surface.setExclusiveZone(@intCast(context.config.height));

    zwlr_surface.setListener(*Context, zwlrSurfaceListener, &context);

    wl_surface.commit();
    if (wl_display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (context.running) {
        if (wl_display.dispatch() != .SUCCESS) return error.DispatchFailed;
        try drawBar(context);
        _ = c.sleep(1);
    }
}

fn wlRegistryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerSurfaceV1.interface.name) == .eq) {
                context.layer_surface = registry.bind(global.name, zwlr.LayerSurfaceV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                context.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn zwlrSurfaceListener(zwlr_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, context: *Context) void {
    switch (event) {
        .configure => |configure| {
            zwlr_surface.ackConfigure(configure.serial);
            context.surface.?.commit();
            context.height = configure.height;
            context.width = configure.width;
            drawBar(context.*) catch |err| {
                std.debug.print("Error drawing: {}", .{err});
            };
        },
        .closed => {
            context.running = false;
        },
    }
}

fn drawBar(context: Context) !void {
    const width = context.width;
    const height = context.height;
    const stride = width * 4;
    const size = stride * height;

    const fd = try std.posix.memfd_create("wzbar", 0);
    try std.posix.ftruncate(fd, size);
    const data: []u32 = @ptrCast(try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    ));
    defer std.posix.munmap(@ptrCast(@alignCast(data)));
    @memset(data, context.config.background_colour);

    const pool = try context.shm.?.createPool(fd, @intCast(size));
    defer pool.destroy();

    const buffer = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), wl.Shm.Format.argb8888);
    defer buffer.destroy();

    context.surface.?.attach(buffer, 0, 0);
    for (context.config.modules) |module| {
        switch (module.module_type) {
            .BlankModule => try draw_blank_module(module, context, data),
            .TimeModule => try draw_time_module(module, context, data),
        }
    }
    context.surface.?.commit();
}

fn drawText(text: []const u8, x: u32, y: u32, context: Context, data: []u32) !void {
    var library: c.FT_Library = undefined;
    var face: c.FT_Face = undefined;
    var err: c.FT_Error = undefined;
    const load_flags = 0;

    var pen_x: u32 = x;
    var pen_y: u32 = y;

    err = c.FT_Init_FreeType(&library);
    defer _ = c.FT_Done_FreeType(library);
    if (err != 0) {
        return error.FailedToInitFreeType;
    }

    const allocator = std.heap.page_allocator;
    const temp = try allocator.alloc(u8, context.config.font_file.len+1);
    defer allocator.free(temp);
    const c_text: [*c]u8 = @ptrCast(temp);
    @memcpy(c_text[0..context.config.font_file.len], context.config.font_file);
    c_text[context.config.font_file.len] = 0;
    err = c.FT_New_Face(library, c_text, 0, &face);
    defer _ = c.FT_Done_Face(face);
    if (err == c.FT_Err_Unknown_File_Format) {
        return error.UnknownFontFileFormat;
    } else if (err != 0) {
        return error.FailedToCreateFace;
    }

    err = c.FT_Set_Pixel_Sizes(face, 0, context.config.font_size);
    if (err != 0) {
        return error.FailedToSetPixelSize;
    }

    for (text) |char| {
        const glyph_index = c.FT_Get_Char_Index(face, char);
        const render_mode: c.FT_Render_Mode = c.FT_RENDER_MODE_MONO;

        err = c.FT_Load_Glyph(face, glyph_index, load_flags);
        if (err != 0) {
            return error.FailedToLoadGlyph;
        }

        err = c.FT_Render_Glyph(face.*.glyph, render_mode);
        if (err != 0) {
            return error.FailedToRenderGlyph;
        }

        const slot: c.FT_GlyphSlot = face.*.glyph;
        var bitmap_top: i32 = @as(i32, @intCast(pen_y)) - @as(i32, @intCast(slot.*.metrics.horiBearingY >> 6));
        bitmap_top += 20;
        try draw_character(context, data, &slot.*.bitmap, pen_x, @intCast(bitmap_top));

        pen_x += @intCast(slot.*.advance.x >> 6);
        pen_y += @intCast(slot.*.advance.y >> 6);
    }
}

fn draw_character(context: Context, data: []u32, bitmap: *c.FT_Bitmap, pen_x: u32, pen_y: u32) !void {
    const x_max: u32 = pen_x + bitmap.*.width;
    const y_max: u32 = pen_y + bitmap.*.rows;
    var i: u32 = pen_x;
    var p: u32 = 0;
    while (i < x_max) : ({
        i += 1;
        p += 1;
    }) {
        if (i < 0 or i >= context.width) {
            continue;
        }
        var j: u32 = pen_y;
        var q: u32 = 0;
        while (j < y_max) : ({
            j += 1;
            q += 1;
        }) {
            if (j < 0 or j >= context.height) {
                continue;
            }

            if (monoPixelIsSet(bitmap, p, q)) {
                data[i + j * context.width] = 0xFFFFFFFF;
            }
        }
    }
}

/// returns true if the pixel at (x, y) is set in a mono bitmap
fn monoPixelIsSet(bitmap: *c.FT_Bitmap, x: usize, y: usize) bool {
    const y_cast: isize = @intCast(y);
    const row_start: isize = y_cast * bitmap.pitch; // signed because pitch can be <0
    const x_cast: isize = @intCast(x);
    const byte_offset = row_start + @divFloor(x_cast, 8);
    const bit_mask = @as(u8, 0x80) >> @as(u3, @intCast(x % 8));
    const byte = bitmap.buffer[@intCast(byte_offset)];
    return (byte & bit_mask) != 0;
}
