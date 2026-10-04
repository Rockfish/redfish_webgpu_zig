const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const run_app = @import("run_app.zig").run_app;
const SceneId = @import("world.zig").SceneId;

const SCR_WIDTH: f32 = 1500.0;
const SCR_HEIGHT: f32 = 1200.0;

fn printUsage() void {
    std.debug.print("Usage: bullets [options]\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --duration, -d <seconds>     Run for specified duration then exit\n", .{});
    std.debug.print("  --scene, -s <name>           Start in debug, ruins_gallery, toon_gallery, or range\n", .{});
    std.debug.print("  --help, -h                   Show this help message\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // Skip program name

    var runtime_duration: ?f32 = null;
    var initial_scene: SceneId = .debug;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |duration_str| {
                runtime_duration = std.fmt.parseFloat(f32, duration_str) catch |err| {
                    std.debug.print("Invalid duration: {s}, error: {}\n", .{ duration_str, err });
                    std.process.exit(1);
                };
                std.debug.print("Runtime duration set to: {d} seconds\n", .{runtime_duration.?});
            } else {
                std.debug.print("Error: --duration requires a value\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--scene") or std.mem.eql(u8, arg, "-s")) {
            const name = args.next() orelse {
                std.debug.print("Error: --scene requires a value\n", .{});
                std.process.exit(1);
            };
            initial_scene = std.meta.stringToEnum(SceneId, name) orelse {
                std.debug.print("Unknown scene: {s}\n", .{name});
                printUsage();
                std.process.exit(1);
            };
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printUsage();
            std.process.exit(1);
        }
    }

    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .no_api);

    const window = try glfw.Window.create(
        SCR_WIDTH,
        SCR_HEIGHT,
        "Bullet App",
        null,
        null,
    );
    defer window.destroy();

    var gpu = try core.GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    try run_app(init, window, &gpu, runtime_duration, initial_scene);
}
