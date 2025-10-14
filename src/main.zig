const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Location = enum {
    top,
    bottom,
};

const Config = struct {
    height: u32,
    location: Location,
    background_colour: u32,
};

const Context = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    layer_shell: ?*zwlr.LayerShellV1,
    layer_surface: ?*zwlr.LayerSurfaceV1,
    surface: ?*wl.Surface,
    running: bool,
    height: u32,
    width: u32,
    config: Config,
};

pub fn main() anyerror!void {
    const config = Config{
        .height = 30,
        .location = Location.top,
        .background_colour = 0xFF000000,
    };
    try createBar(config);
}

fn createBar(config: Config) !void {
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
        .top = config.location == Location.top,
        .right = true,
        .left = true,
        .bottom = config.location == Location.bottom,
    });
    zwlr_surface.setExclusiveZone(@intCast(context.config.height));

    zwlr_surface.setListener(*Context, zwlrSurfaceListener, &context);

    wl_surface.commit();
    if (wl_display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (context.running) {
        if (wl_display.dispatch() != .SUCCESS) return error.DispatchFailed;
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
    @memset(data, context.config.background_colour);

    const pool = try context.shm.?.createPool(fd, @intCast(size));
    defer pool.destroy();

    const buffer = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), wl.Shm.Format.argb8888);
    defer buffer.destroy();

    context.surface.?.attach(buffer, 0, 0);
    context.surface.?.commit();
}
