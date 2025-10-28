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

    const allocator = std.heap.page_allocator;
    try createBar(config, allocator);
}

fn createBar(config: cfg.Config, allocator: std.mem.Allocator) !void {
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
        try drawBar(context, allocator);
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
            const allocator = std.heap.page_allocator;
            drawBar(context.*, allocator) catch |err| {
                std.debug.print("Error drawing: {}", .{err});
            };
        },
        .closed => {
            context.running = false;
        },
    }
}

fn drawBar(context: Context, allocator: std.mem.Allocator) !void {
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
            .BlankModule => try draw_blank_module(module, context, data, allocator),
            .TimeModule => try draw_time_module(module, context, data, allocator),
            .BatteryModule => try draw_battery_module(module, context, data, allocator),
            .BrightnessModule => try draw_brightness_module(module, context, data, allocator),
            .MemoryModule => try draw_memory_module(module, context, data, allocator),
        }
    }
    context.surface.?.commit();
}

fn drawText(text: []const u8, x: u32, y: u32, context: Context, data: []u32, allocator: std.mem.Allocator) !void {
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

    const temp = try allocator.alloc(u8, context.config.font_file.len + 1);
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

fn draw_brightness_module(module: cfg.Module, context: Context, data: []u32, allocator: std.mem.Allocator) anyerror!void {
    var j: u32 = module.y;
    while (j < module.y + module.height) : (j += 1) {
        var i: u32 = module.x;
        while (i < module.x + module.width) : (i += 1) {
            data[j * context.width + i] = module.background_colour;
        }
    }

    const brightness = try get_brightness(allocator);
    const brightness_str = try std.fmt.allocPrint(allocator, "{}", .{brightness});

    try drawText(brightness_str, module.x, module.y, context, data, allocator);
    context.surface.?.damage(@intCast(module.x), @intCast(module.y), @intCast(module.width), @intCast(module.height));
}

pub fn get_brightness(allocator: std.mem.Allocator) !u16 {
    const max_brightness_file = try std.fs.cwd().openFile("/sys/class/backlight/intel_backlight/max_brightness", .{});
    defer max_brightness_file.close();
    const max_brightness_buf = try max_brightness_file.readToEndAlloc(allocator, 4);
    defer allocator.free(max_brightness_buf);
    const max_brightness = try std.fmt.parseInt(u16, max_brightness_buf[0 .. max_brightness_buf.len - 1], 10);

    const brightness_file = try std.fs.cwd().openFile("/sys/class/backlight/intel_backlight/brightness", .{});
    defer brightness_file.close();
    const brightness_buf = try brightness_file.readToEndAlloc(allocator, 4);
    defer allocator.free(brightness_buf);
    const brightness = try std.fmt.parseInt(u16, brightness_buf[0 .. brightness_buf.len - 1], 10);

    const rel_brightness = (brightness * 100) / max_brightness;

    return rel_brightness;
}

fn draw_battery_module(module: cfg.Module, context: Context, data: []u32, allocator: std.mem.Allocator) anyerror!void {
    var j: u32 = module.y;
    while (j < module.y + module.height) : (j += 1) {
        var i: u32 = module.x;
        while (i < module.x + module.width) : (i += 1) {
            data[j * context.width + i] = module.background_colour;
        }
    }

    const battery_charge = try get_battery_charge(allocator);
    const battery_status = try get_battery_status(allocator);
    const battery_str = try std.fmt.allocPrint(allocator, "{}: {s}", .{ battery_charge, battery_status });
    defer allocator.free(battery_str);

    try drawText(battery_str, module.x, module.y, context, data, allocator);
    context.surface.?.damage(@intCast(module.x), @intCast(module.y), @intCast(module.width), @intCast(module.height));
}

pub fn get_battery_charge(allocator: std.mem.Allocator) !u8 {
    const file = try std.fs.cwd().openFile("/sys/class/power_supply/BAT0/capacity", .{});
    defer file.close();

    const buf = try file.readToEndAlloc(allocator, 4);
    defer allocator.free(buf);
    const charge = try std.fmt.parseInt(u8, buf[0 .. buf.len - 1], 10);
    return charge;
}

pub fn get_battery_status(allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile("/sys/class/power_supply/BAT0/status", .{});
    defer file.close();
    const battery_status = try file.readToEndAlloc(allocator, 20);
    return battery_status[0 .. battery_status.len - 1];
}

fn draw_memory_module(module: cfg.Module, context: Context, data: []u32, allocator: std.mem.Allocator) anyerror!void {
    var j: u32 = module.y;
    while (j < module.y + module.height) : (j += 1) {
        var i: u32 = module.x;
        while (i < module.x + module.width) : (i += 1) {
            data[j * context.width + i] = module.background_colour;
        }
    }

    const memory = try get_memory_usage();
    const mem_str = try std.fmt.allocPrint(allocator, "{}", .{memory});

    try drawText(mem_str, module.x, module.y, context, data, allocator);
    context.surface.?.damage(@intCast(module.x), @intCast(module.y), @intCast(module.width), @intCast(module.height));
}

pub fn get_memory_usage() !usize {
    var file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();

    const file_size = 4096; // large enough for /proc/meminfo
    var buffer: [file_size]u8 = undefined;
    const read_len = try file.readAll(&buffer);
    const content = buffer[0..read_len];

    var total: usize = 0;
    var free: usize = 0;
    var available: usize = 0;
    var buffers: usize = 0;
    var cached: usize = 0;

    var lines = std.mem.splitAny(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total = try parse_kb_value(line);
        } else if (std.mem.startsWith(u8, line, "MemFree:")) {
            free = try parse_kb_value(line);
        } else if (std.mem.startsWith(u8, line, "Buffers:")) {
            buffers = try parse_kb_value(line);
        } else if (std.mem.startsWith(u8, line, "Cached:")) {
            cached = try parse_kb_value(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available = try parse_kb_value(line);
        }
    }

    // const used: usize = total - free - buffers - cached;
    const used: usize = total - available;
    return used / 1000;
}

fn parse_kb_value(line: []const u8) !usize {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    _ = parts.next(); // skip key

    const value_str = parts.next() orelse return error.InvalidFormat;
    return std.fmt.parseInt(usize, value_str, 10);
}

fn draw_blank_module(module: cfg.Module, context: Context, data: []u32, allocator: std.mem.Allocator) anyerror!void {
    _ = allocator;
    var j: u32 = module.y;
    while (j < module.y + module.height) : (j += 1) {
        var i: u32 = module.x;
        while (i < module.x + module.width) : (i += 1) {
            data[j * context.width + i] = module.background_colour;
        }
    }
}

fn draw_time_module(module: cfg.Module, context: Context, data: []u32, allocator: std.mem.Allocator) anyerror!void {
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
    const time_str: []const u8 = c_time_str[0 .. len - 1];

    try drawText(time_str, module.x, module.y, context, data, allocator);
    context.surface.?.damage(@intCast(module.x), @intCast(module.y), @intCast(module.width), @intCast(module.height));
}
