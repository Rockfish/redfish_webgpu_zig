//! The Station: a point-and-click game about a maintenance robot on a space station.
//! Design notes: `the-station/docs/game_notes/the_station_design.md`; plan 021.
//!
//! Room 01 as a greybox, seen through its open front by the cutaway camera
//! (`room_camera.zig`). Click the floor to walk there; click something (outlined under
//! the mouse) to walk to it and use it (`game.zig`). The red button stops the alarm and
//! opens the door. Drawn in ink: hatching and outlines (`ink.zig`). The robot is the
//! Blender model (`robot_model.zig`), or the box placeholder without it. A panel tunes
//! the camera, the ink, the room, and the alarm.
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
const interaction = @import("interaction.zig");
const ink = @import("ink.zig");
const Game = @import("game.zig").Game;
const Robot = @import("robot.zig").Robot;
const RobotModel = @import("robot_model.zig").RobotModel;

const Arenas = core.Arenas;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Input = core.Input;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const Ray = core.Ray;
const RenderContext = core.RenderContext;
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
/// The floor grid plus one hover outline.
const MAX_LINES = GRID_LINES + 12;

/// What a frame draws, in each of its passes.
const Scene = struct {
    room: *const Room,
    robot: *const Robot,
    /// Null: the box placeholder.
    robot_model: ?*const RobotModel,
    alarm_glow: f32,
    door_open: f32,

    fn draw(self: Scene, frame: *const Frame, shaders: ink.SceneShaders, hatching: room.Hatching) void {
        self.room.draw(frame, shaders.room, hatching, self.alarm_glow, self.door_open);
        if (self.robot_model) |model| {
            model.draw(frame, shaders.robot, self.robot, hatching);
        } else {
            self.robot.draw(frame, shaders.room, self.room, hatching);
        }
    }
};

/// Everything the panel changes besides the camera, the ink, and the game.
const Settings = struct {
    show_grid: bool = false,
    /// Draw the box robot even when the Blender model is loaded.
    use_placeholder: bool = false,
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
    const scene_shaders = try ink.SceneShaders.init(context, gpu, false);
    defer scene_shaders.releaseGpuObjects();

    const lines_shader = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/lines.wgsl", .{
        .vertex_buffers = &Lines.vertex_buffer_layouts,
        .topology = .line_list,
    });
    defer lines_shader.releaseGpuObjects();
    var lines = try Lines.init(context.alloc, lines_shader, 1.0, 0.6, MAX_LINES);

    const control_room = try Room.init(context, gpu);
    defer control_room.releaseGpuObjects();

    var ink_pass = try ink.Ink.init(context, gpu);
    defer ink_pass.releaseGpuObjects();

    var robot_model = RobotModel.load(context, gpu);
    defer if (robot_model) |*model| {
        model.cleanUp();
    };

    var camera: RoomCamera = .{};
    var settings: Settings = .{};
    var style: ink.Style = .{};
    var game: Game = .{};

    // Before gui.init: ImGui's GLFW backend chains to Input's callbacks
    const input = Input.init(window);
    gui.init(allocator, window, gpu);
    defer gui.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        input.update();
        processKeys(input, window, &camera, &game);

        const time = input.total_time;
        const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
        const render_context = camera.renderContext(Room.framing(), aspect, time);

        // A press counts even if released before the frame (a trackpad tap); none over a panel
        game.update(mouseRay(input, render_context), input.mousePressed(.left), input.delta_time);
        if (robot_model) |*model| {
            try model.update(&game.robot, input.delta_time);
        }

        const alarm_level = if (game.is_alarm_on) alarmPulse(time, settings.alarm_rate) else 0.0;

        var frame = gpu.acquireFrame() orelse continue;
        try ink_pass.update(gpu);

        var uniforms = render_context.frameUniforms();
        uniforms.lights = roomLights(settings, game.is_alarm_on, alarm_level).uniforms();
        gpu.writeFrameUniforms(uniforms);

        // The scene twice: its normals and depth for the outlines, then in color
        const scene: Scene = .{
            .room = &control_room,
            .robot = &game.robot,
            .robot_model = if (settings.use_placeholder) null else if (robot_model) |*model| model else null,
            .alarm_glow = alarm_level,
            .door_open = game.door_open,
        };
        if (style.show_outlines) {
            ink_pass.beginNormalDepthPass(&frame);
            scene.draw(&frame, ink_pass.normal_depth_shaders, style.hatching());
            frame.endPass();
        }

        frame.beginSurfacePass(CLEAR_COLOR);
        scene.draw(&frame, scene_shaders, style.hatching());
        ink_pass.drawOutlines(&frame, style);
        drawLines(&frame, &lines, settings.show_grid, game.hovered);

        gui.newFrame();
        drawLabel("remark", game.remark(), .{ zgui.io.getDisplaySize()[0] / 2.0, 24.0 }, 0.5);
        drawLabel("hovered", game.hoveredName(), .{ input.mouse_x + 18.0, input.mouse_y + 8.0 }, 0.0);
        drawPanel(&camera, &settings, &style, &game, aspect);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

fn processKeys(input: *Input, window: *zglfw.Window, camera: *RoomCamera, game: *Game) void {
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
        game.is_alarm_on = !game.is_alarm_on;
    }
}

/// The ray under the mouse, or null while the mouse is over a panel. Mouse positions are
/// in window units, not framebuffer pixels.
fn mouseRay(input: *const Input, render_context: RenderContext) ?Ray {
    if (input.gui_has_mouse) {
        return null;
    }
    const ray = math.getWorldRayFromMouse(
        input.window_width,
        input.window_height,
        &render_context.projection,
        &render_context.view,
        input.mouse_x,
        input.mouse_y,
    );
    return .{ .origin = ray.origin, .direction = ray.direction };
}

/// 0..1, a smooth rise and fall `rate` times a second.
fn alarmPulse(time: f32, rate: f32) f32 {
    return 0.5 - 0.5 * @cos(time * rate * std.math.tau);
}

/// Dim light from above the opening, and the alarm's red point light.
fn roomLights(settings: Settings, is_alarm_on: bool, alarm_level: f32) SceneLights {
    const room_light = if (is_alarm_on) settings.emergency_light else settings.room_light;

    var lights = SceneLights.init();
    lights.ambient = vec3(1.0, 1.0, 1.0).mulScalar(0.06 + 0.1 * room_light);
    lights.direction_light = .{ .dir = vec3(0.25, -1.0, -0.6), .color = vec3(1.0, 1.0, 1.0).mulScalar(room_light) };
    lights.setPointLight(0, .{
        .world_pos = room.ALARM_LIGHT_POSITION,
        .color = room.alarmLightColor(settings.alarm_intensity * alarm_level),
        .constant = 1.0,
        .linear = 0.35,
        .quadratic = 0.15,
        .enabled = is_alarm_on,
    });
    return lights;
}

/// The floor grid, if on, and an outline around the hotspot under the mouse.
fn drawLines(frame: *const Frame, lines: *Lines, show_grid: bool, hovered: interaction.Target) void {
    var segments: [MAX_LINES]LineSegment = undefined;
    var count: usize = 0;
    if (show_grid) {
        count += floorGrid(segments[0..GRID_LINES]);
    }
    switch (hovered) {
        .hotspot => |index| {
            const outline = interaction.outline(room.hotspots[index].bounds);
            @memcpy(segments[count..][0..outline.len], &outline);
            count += outline.len;
        },
        .floor, .nothing => {},
    }
    if (count > 0) {
        lines.draw(frame, segments[0..count]);
    }
}

/// A 1 m grid on the floor, to see the perspective by. Returns the number of segments.
fn floorGrid(segments: []LineSegment) usize {
    const half_width = room.WIDTH / 2.0;
    const y = 0.002;
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
    return count;
}

/// A line of text in a small window that ignores the mouse, at `position` (window units);
/// `pivot_x` 0.5 centers it there. Nothing for empty text. `id` names the ImGui window.
fn drawLabel(id: [:0]const u8, text: []const u8, position: [2]f32, pivot_x: f32) void {
    if (text.len == 0) {
        return;
    }
    zgui.setNextWindowPos(.{ .x = position[0], .y = position[1], .pivot_x = pivot_x });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.6 });
    const flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_mouse_inputs = true,
        .no_nav_inputs = true,
        .no_nav_focus = true,
        .no_focus_on_appearing = true,
        .always_auto_resize = true,
        .no_saved_settings = true,
    };
    if (zgui.begin(id, .{ .flags = flags })) {
        zgui.text("{s}", .{text});
    }
    zgui.end();
}

fn drawPanel(camera: *RoomCamera, settings: *Settings, style: *ink.Style, game: *Game, aspect: f32) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 340, .h = 0, .cond = .first_use_ever });
    // Collapsed at first: open it covers the door
    zgui.setNextWindowCollapsed(.{ .collapsed = true, .cond = .first_use_ever });
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

        zgui.separatorText("Ink");
        _ = zgui.checkbox("outlines", .{ .v = &style.show_outlines });
        _ = zgui.sliderFloat("line width", .{ .v = &style.line_width, .min = 1.0, .max = 4.0 });
        _ = zgui.sliderFloat("depth threshold", .{ .v = &style.depth_threshold, .min = 0.005, .max = 0.2 });
        _ = zgui.sliderFloat("crease threshold", .{ .v = &style.normal_threshold, .min = 0.05, .max = 1.0 });
        _ = zgui.sliderFloat("ink opacity", .{ .v = &style.ink_opacity, .min = 0.0, .max = 1.0 });
        _ = zgui.checkbox("hatching", .{ .v = &style.show_hatching });
        _ = zgui.sliderFloat("hatch strength", .{ .v = &style.hatch_strength, .min = 0.0, .max = 1.0 });
        _ = zgui.sliderFloat("hatch spacing", .{ .v = &style.hatch_spacing, .min = 0.02, .max = 0.2 });
        if (zgui.button("reset ink", .{})) {
            style.* = .{};
        }

        zgui.separatorText("Room");
        _ = zgui.checkbox("floor grid", .{ .v = &settings.show_grid });
        _ = zgui.checkbox("placeholder robot", .{ .v = &settings.use_placeholder });
        _ = zgui.sliderFloat("room light", .{ .v = &settings.room_light, .min = 0.0, .max = 1.5 });
        if (zgui.button("reset room", .{})) {
            game.* = .{};
        }

        zgui.separatorText("Alarm");
        _ = zgui.checkbox("on", .{ .v = &game.is_alarm_on });
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
