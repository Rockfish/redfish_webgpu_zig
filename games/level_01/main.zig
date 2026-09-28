const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");

const run_app = @import("run_app.zig").run;

const GpuContext = core.GpuContext;

pub const std_options: std.Options = .{ .log_level = .err };

const SCR_WIDTH: f32 = 1000.0;
const SCR_HEIGHT: f32 = 1000.0;

pub fn main(init: std.process.Init) !void {
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .no_api);
    const window = try glfw.Window.create(
        SCR_WIDTH,
        SCR_HEIGHT,
        "Level 01",
        null,
        null,
    );
    defer window.destroy();

    var gpu = try GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    try run_app(init, window, &gpu);
}
