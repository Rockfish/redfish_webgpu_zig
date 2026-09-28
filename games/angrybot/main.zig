const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");

const log = std.log.scoped(.Main);
const run_app = @import("run_app.zig").run;

const GpuContext = core.GpuContext;

const VIEW_PORT_WIDTH: f32 = 1500.0;
const VIEW_PORT_HEIGHT: f32 = 1000.0;

pub fn main(init: std.process.Init) !void {
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .no_api);

    const window = try glfw.Window.create(
        VIEW_PORT_WIDTH,
        VIEW_PORT_HEIGHT,
        "Angry Monsters",
        null,
        null,
    );
    defer window.destroy();

    var gpu = try GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    try run_app(init, window, &gpu);

    log.info("Exiting main", .{});
}
