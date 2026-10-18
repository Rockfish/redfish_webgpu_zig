//! The Station: a point-and-click game about a maintenance robot on a space station.
//! Design notes: `the-station/docs/game_notes/the_station_design.md`; plan 021.
//!
//! Phase A: Room 01 as a greybox, seen through its open front by the cutaway camera
//! (`room_camera.zig`), with a panel to tune the camera and a pulsing red alarm.
//!
//! Keys: 1 / 2 / 3 pick the view (shifted, aimed, orthographic), Space toggles the
//! alarm, Escape quits.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const room_camera = @import("room_camera.zig");
const room = @import("room.zig");

const Arenas = core.Arenas;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Input = core.Input;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const SceneLights = core.SceneLights;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const gui = core.gui;
const Room = room.Room;
const RoomCamera = room_camera.RoomCamera;
const vec3 = math.vec3;

/// The space outside the station.
const CLEAR_COLOR = [4]f64{ 0.01, 0.01, 0.012, 1.0 };
/// One line per meter across and along the floor.
const GRID_LINES = @as(usize, @intFromFloat(room.WIDTH + room.DEPTH)) + 2;

/// Everything the panel changes besides the camera.
const Settings = struct {
    show_grid: bool = true,
    is_alarm_on: bool = true,
    /// Alarm pulses per second.
    alarm_rate: f32 = 0.8,
    /// The alarm light's brightness at the top of a pulse.
    alarm_intensity: f32 = 4.0,
    /// The room's light while the alarm is off; with the alarm on it drops to the
    /// emergency level.
    room_light: f32 = 0.8,
    emergency_light: f32 = 0.25,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(1440, 810, "The Station", null, null);
    defer window.destroy();

    var gpu = try GpuContext.init(allocator, window);
    defer gpu.deinit();

    var arenas = try Arenas.init(allocator);
    defer arenas.deinit();

    try run(allocator, arenas.context(init.io), window, &gpu);
}

/// `allocator` is for ImGui, which frees in any order (an arena wouldn't reclaim it).
fn run(allocator: std.mem.Allocator, context: core.Context, window: *zglfw.Window, gpu: *GpuContext) !void {
    const room_shader = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/room.wgsl", .{
        .vertex_buffers = &Shape.vertex_buffer_layouts,
    });
    defer room_shader.releaseGpuObjects();

    const lines_shader = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/lines.wgsl", .{
        .vertex_buffers = &Lines.vertex_buffer_layouts,
        .topology = .line_list,
    });
    defer lines_shader.releaseGpuObjects();
    var grid_lines = try Lines.init(context.alloc, lines_shader, 1.0, 0.35, GRID_LINES);

    const control_room = try Room.init(context, gpu);
    defer control_room.releaseGpuObjects();

    var camera: RoomCamera = .{};
    var settings: Settings = .{};

    // Before gui.init: ImGui's GLFW backend chains to Input's callbacks
    const input = Input.init(window);
    gui.init(allocator, window, gpu);
    defer gui.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        input.update();
        processKeys(input, window, &camera, &settings);

        const time = input.total_time;
        const alarm_level = if (settings.is_alarm_on) alarmPulse(time, settings.alarm_rate) else 0.0;

        var frame = gpu.acquireFrame() orelse continue;

        const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
        var uniforms = camera.renderContext(Room.framing(), aspect, time).frameUniforms();
        uniforms.lights = roomLights(settings, alarm_level).uniforms();
        gpu.writeFrameUniforms(uniforms);

        frame.beginSurfacePass(CLEAR_COLOR);
        control_room.draw(&frame, room_shader, alarm_level);
        if (settings.show_grid) {
            drawFloorGrid(&frame, &grid_lines);
        }

        gui.newFrame();
        drawPanel(&camera, &settings, aspect);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

fn processKeys(input: *Input, window: *zglfw.Window, camera: *RoomCamera, settings: *Settings) void {
    if (input.isDown(.escape)) {
        window.setShouldClose(true);
    }
    if (input.pressedOnce(.one)) {
        camera.view = .shifted;
    }
    if (input.pressedOnce(.two)) {
        camera.view = .aimed;
    }
    if (input.pressedOnce(.three)) {
        camera.view = .orthographic;
    }
    if (input.pressedOnce(.space)) {
        settings.is_alarm_on = !settings.is_alarm_on;
    }
}

/// 0..1, a smooth rise and fall `rate` times a second.
fn alarmPulse(time: f32, rate: f32) f32 {
    return 0.5 - 0.5 * @cos(time * rate * std.math.tau);
}

/// Dim light from above the opening, and the alarm's red point light.
fn roomLights(settings: Settings, alarm_level: f32) SceneLights {
    const room_light = if (settings.is_alarm_on) settings.emergency_light else settings.room_light;

    var lights = SceneLights.init();
    lights.ambient = vec3(1.0, 1.0, 1.0).mulScalar(0.06 + 0.1 * room_light);
    lights.direction_light = .{ .dir = vec3(0.25, -1.0, -0.6), .color = vec3(1.0, 1.0, 1.0).mulScalar(room_light) };
    lights.setPointLight(0, .{
        .world_pos = room.ALARM_LIGHT_POSITION,
        .color = room.alarmLightColor(settings.alarm_intensity * alarm_level),
        .constant = 1.0,
        .linear = 0.35,
        .quadratic = 0.15,
        .enabled = settings.is_alarm_on,
    });
    return lights;
}

/// A 1 m grid on the floor, to see the perspective by.
fn drawFloorGrid(frame: *const Frame, lines: *Lines) void {
    const half_width = room.WIDTH / 2.0;
    const y = 0.002;
    var segments: [GRID_LINES]LineSegment = undefined;
    var count: usize = 0;

    var x = -half_width;
    while (x <= half_width) : (x += 1.0) {
        segments[count] = .{ .start = vec3(x, y, 0.0), .end = vec3(x, y, -room.DEPTH), .color = .black };
        count += 1;
    }
    var z: f32 = 0.0;
    while (z >= -room.DEPTH) : (z -= 1.0) {
        segments[count] = .{ .start = vec3(-half_width, y, z), .end = vec3(half_width, y, z), .color = .black };
        count += 1;
    }
    lines.draw(frame, segments[0..count]);
}

fn drawPanel(camera: *RoomCamera, settings: *Settings, aspect: f32) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 340, .h = 0, .cond = .first_use_ever });
    if (zgui.begin("room 01", .{})) {
        zgui.text("1 / 2 / 3: view   Space: alarm", .{});

        zgui.separatorText("Camera");
        _ = zgui.comboFromEnum("view", &camera.view);
        _ = zgui.sliderFloat("distance", .{ .v = &camera.distance, .min = 2.0, .max = 40.0 });
        _ = zgui.sliderFloat("eye height", .{ .v = &camera.eye_height, .min = -1.0, .max = 5.0 });
        _ = zgui.sliderFloat("eye x", .{ .v = &camera.eye_x, .min = -4.0, .max = 4.0 });
        if (zgui.button("reset camera", .{})) {
            camera.* = .{ .view = camera.view };
        }
        const framing = RoomCamera.fitToAspect(Room.framing(), aspect);
        zgui.text("vertical field of view: {d:.1}°", .{camera.verticalFov(framing)});
        zgui.text("horizontal field of view: {d:.1}°", .{horizontalFov(camera.verticalFov(framing), aspect)});

        zgui.separatorText("Room");
        _ = zgui.checkbox("floor grid", .{ .v = &settings.show_grid });
        _ = zgui.sliderFloat("room light", .{ .v = &settings.room_light, .min = 0.0, .max = 1.5 });

        zgui.separatorText("Alarm");
        _ = zgui.checkbox("on", .{ .v = &settings.is_alarm_on });
        _ = zgui.sliderFloat("pulses per second", .{ .v = &settings.alarm_rate, .min = 0.2, .max = 3.0 });
        _ = zgui.sliderFloat("intensity", .{ .v = &settings.alarm_intensity, .min = 0.0, .max = 12.0 });
        _ = zgui.sliderFloat("emergency light", .{ .v = &settings.emergency_light, .min = 0.0, .max = 1.0 });
    }
    zgui.end();
}

fn horizontalFov(vertical_degrees: f32, aspect: f32) f32 {
    const half_vertical = std.math.degreesToRadians(vertical_degrees) / 2.0;
    return std.math.radiansToDegrees(2.0 * std.math.atan(std.math.tan(half_vertical) * aspect));
}
