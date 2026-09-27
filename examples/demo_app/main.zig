const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const run = @import("run_app.zig").run;

const assets_list = @import("assets_list.zig");

const SCR_WIDTH: f32 = 1000.0;
const SCR_HEIGHT: f32 = 1000.0;

fn printUsage() void {
    std.debug.print("Usage: demo_app [options]\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --model-index, -m <index>    Start with model at specified index (0-{d})\n", .{assets_list.model_infos.len - 1});
    std.debug.print("  --list-models, -l            List available models and their indices\n", .{});
    std.debug.print("  --duration, -d <seconds>     Run for specified duration then exit\n", .{});
    std.debug.print("  --help, -h                   Show this help message\n", .{});
}

fn listModels() void {
    std.debug.print("Available models:\n", .{});
    for (assets_list.model_infos, 0..) |model, i| {
        std.debug.print("  {d:2}: {s} ({s}) - {s}\n", .{ i, model.name, model.format, model.description });
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // Skip program name

    var initial_model_index: ?usize = null;
    var runtime_duration: ?f32 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--list-models") or std.mem.eql(u8, arg, "-l")) {
            listModels();
            return;
        } else if (std.mem.eql(u8, arg, "--model-index") or std.mem.eql(u8, arg, "-m")) {
            if (args.next()) |index_str| {
                const index = std.fmt.parseInt(usize, index_str, 10) catch |err| {
                    std.debug.print("Invalid model index: {s}, error: {}\n", .{ index_str, err });
                    std.process.exit(1);
                };
                if (index >= assets_list.model_infos.len) {
                    std.debug.print("Model index {d} out of range (0-{d})\n", .{ index, assets_list.model_infos.len - 1 });
                    std.process.exit(1);
                }
                initial_model_index = index;
                std.debug.print("Starting with model index: {d}\n", .{index});
            } else {
                std.debug.print("Error: --model-index requires a value\n", .{});
                std.process.exit(1);
            }
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
        "Demo App",
        null,
        null,
    );
    defer window.destroy();

    var gpu = try core.GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    // Display initial model info
    const model_index = initial_model_index orelse 0;
    const initial_model = assets_list.model_infos[model_index];
    std.debug.print(
        "Starting with model {d}: {s} ({s}) - {s}\n",
        .{ model_index, initial_model.name, initial_model.format, initial_model.description },
    );
    std.debug.print("Press 'n' for next model, 'b' for previous model\n", .{});

    try run(init, window, &gpu, @as(i32, @intCast(model_index)), runtime_duration);
}
