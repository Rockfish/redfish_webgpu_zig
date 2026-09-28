const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const world_module = @import("world.zig");

const Allocator = std.mem.Allocator;
const Input = core.Input;
const GpuContext = core.GpuContext;
const World = world_module.World;

const log = std.log.scoped(.BulletsApp);

const FULL_SCREEN: bool = false;

const CLEAR_COLOR = [4]f64{ 0.0, 0.0, 0.0, 1.0 };

pub fn run_app(init: std.process.Init, window: *glfw.Window, gpu: *GpuContext, max_duration: ?f32, initial_scene: world_module.SceneId) !void {
    log.info("Starting simple bullets test app", .{});
    const input = Input.init(window);

    const world = try World.init(init, gpu, input, initial_scene);
    defer world.deinit(init);

    log.info("Starting main loop", .{});

    // glfw.setWindowMonitor( window, null, 0, 0, 3440, 1440, 3000);
    // 1836.2 fps

    if (FULL_SCREEN) {
        const monitor = glfw.getPrimaryMonitor();
        const mode = try glfw.getVideoMode(monitor.?); // Gets native res/refresh
        glfw.setWindowMonitor(window, monitor, 0, 0, mode.*.width, mode.*.height, mode.*.refresh_rate);
        glfw.maximizeWindow(window);
    }

    // Disable cursor
    // try glfw.setInputMode(window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).disabled);

    // Turn off vsync
    var frame_counter = core.FrameCounter.init(init.io);

    var count: u64 = 0;
    while (!window.shouldClose()) {
        glfw.pollEvents();
        input.update();

        count += 1;
        frame_counter.update();

        if (@mod(count, 10000) == 0) {
            std.debug.print("{d:.1} fps\n", .{frame_counter.fps});
        }

        if (max_duration) |duration| {
            if (input.total_time >= duration) {
                log.info("Reached maximum duration of {d} seconds, exiting", .{duration});
                break;
            }
        }

        // Scene switching
        if (input.key_presses.contains(.page_down) and !input.key_processed.contains(.page_down)) {
            input.key_processed.insert(.page_down);
            try world.nextScene();
        }
        if (input.key_presses.contains(.page_up) and !input.key_processed.contains(.page_up)) {
            input.key_processed.insert(.page_up);
            try world.prevScene();
        }

        try world.scene.update(input);

        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;
        world.scene.draw(&frame, input.total_time);
        gpu.endFrame(frame);
    }

    log.info("Simple bullets test app completed", .{});
}
