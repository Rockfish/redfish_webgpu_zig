//! Replaces redfish's gl_caps: logs adapter info and limits, clears the window, and
//! shows a zgui panel. The clear color is linear 0.5 gray; on an sRGB surface it must
//! appear as sRGB 188 (0xBC), not 128.

const std = @import("std");
const core = @import("core");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const GpuContext = core.GpuContext;
const gui = core.gui;

const log = std.log.scoped(.gpu_caps);

const CLEAR_COLOR = [4]f64{ 0.5, 0.5, 0.5, 1.0 };

pub fn main(init: std.process.Init) !void {
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(1280, 800, "gpu_caps", null, null);
    defer window.destroy();

    var gpu = try GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    core.gpu_debug.logAdapterLimits(gpu.adapter);

    gui.init(init.gpa, window, &gpu);
    defer gui.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        if (window.getKey(.escape) == .press) window.setShouldClose(true);

        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;

        gui.newFrame();
        drawPanel(&gpu);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

fn drawPanel(gpu: *const GpuContext) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    if (zgui.begin("gpu_caps", .{})) {
        zgui.text("surface: {d} x {d}", .{ gpu.width, gpu.height });
        zgui.text("surface format: {d}", .{gpu.surface_format});
        zgui.text("clear: linear 0.5 gray, expect sRGB 188", .{});
        zgui.text("frame time: {d:.2} ms", .{1000.0 / zgui.io.getFramerate()});
    }
    zgui.end();
}
