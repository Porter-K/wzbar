const std = @import("std");
const toml = @import("toml");

pub const ModuleType = enum {
    BlankModule,
    TimeModule,
    MemoryModule,
    BatteryModule,
    BrightnessModule,
};

pub const Module = struct {
    background_colour: u32,
    text_colour: u32,
    module_type: ModuleType,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Location = enum {
    top,
    bottom,
};

pub const Config = struct {
    height: u32,
    location: Location,
    background_colour: u32,
    font_size: u32,
    font_file: []const u8,
    modules: []const Module,
};

pub fn parse_config() !toml.Parsed(Config) {
    const allocator = std.heap.page_allocator;
    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();
    var env: std.process.EnvMap = try std.process.getEnvMap(allocator);
    defer env.deinit();

    const home_path:[]const u8 = env.get("HOME") orelse return error.NoHomeVariable;
    const config_ext: []const u8 = "/.config/wzbar/config.toml";

    const config_path: []u8 = try allocator.alloc(u8, home_path.len+config_ext.len);
    @memcpy(config_path[0..home_path.len], home_path);
    @memcpy(config_path[home_path.len..], config_ext);

    const result = try parser.parseFile(config_path);

    return result;
}
