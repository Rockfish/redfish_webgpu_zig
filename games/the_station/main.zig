//! The Station: a point-and-click game about a maintenance robot on a space station.
//! Design notes: `the-station/docs/game_notes/the_station_design.md`; plan 021.
//!
//! The station (`station.zig`): Room 01 and, through its door, Room 02, each seen through
//! its open front by the cutaway camera (`room_camera.zig`), which pans to the robot's
//! room.
//! Click the floor to walk there; click something (outlined under the mouse) to walk to
//! it and use it (`game.zig`). Main power is out: the red button stops the alarm, the
//! console's third button turns on the emergency lights, its middle button opens and
//! closes the door. Room 02 has a ladder down. Drawn in ink: hatching and outlines
//! (`ink.zig`). The robot is the Blender model (`robot_model.zig`), or the box
//! placeholder without it. A panel tunes the camera, the ink, the rooms, the lights, and
//! the alarm, and saves settings one at a time (`settings.zig`).
//!
//! Keys: 1 / 2 / 3 pick the view (shifted, aimed, orthographic), Space toggles the
//! alarm, Escape quits.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const room_camera = @import("room_camera.zig");
const room_kit = @import("room_kit.zig");
const room_01 = @import("room_01.zig");
const station = @import("station.zig");
const robot_placeholder = @import("robot_placeholder.zig");
const interaction = @import("interaction.zig");
const cursor = @import("cursor.zig");
const ink = @import("ink.zig");
const settings_file = @import("settings.zig");
const Game = @import("game.zig").Game;
const Robot = @import("robot.zig").Robot;
const RobotModel = @import("robot_model.zig").RobotModel;
const Overlay = @import("overlay.zig").Overlay;

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
const Framing = room_camera.Framing;
const RoomCamera = room_camera.RoomCamera;
const Settings = settings_file.Settings;
const Scenery = station.Scenery;
const Station = @import("state.zig").Station;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;

/// How fast the camera pans to the robot's room (`motion.dampAlpha` rate).
const PAN_RATE: f32 = 3.0;
/// How much the ceiling lights' tubes glow with the emergency lights on.
const EMERGENCY_GLOW: f32 = 0.6;
/// Each tube's share of the emergency light (`LightSettings.emergency`): a room has a
/// light at each tube, two in a room 3 cells wide, where it had one in its middle.
const EMERGENCY_PER_TUBE: f32 = 0.6;
/// The hovered control's highlight breathes this much below full, this often a second.
const HIGHLIGHT_PULSE_DEPTH: f32 = 0.2;
const HIGHLIGHT_PULSE_RATE: f32 = 0.8;

/// The space outside the station.
const CLEAR_COLOR = [4]f64{ 0.01, 0.01, 0.012, 1.0 };
/// One line per meter across and along the floor, for a room up to 20 m wide.
const GRID_LINES = 20 + @as(usize, @intFromFloat(room_kit.DEPTH)) + 2;
/// The floor grid (a line may be split around a hole) plus one hover outline.
const MAX_LINES = 2 * GRID_LINES + 12;

/// What a frame draws, in each of its passes.
const Scene = struct {
    scenery: *const Scenery,
    robot: *const Robot,
    /// Null: the box placeholder.
    robot_model: ?*const RobotModel,
    state: station.DrawState,

    fn draw(self: Scene, frame: *const Frame, shaders: ink.SceneShaders, hatching: room_kit.Hatching) void {
        self.scenery.draw(frame, shaders.room, shaders.model, hatching, self.state);
        if (self.robot_model) |model| {
            model.draw(frame, shaders.model, self.robot, hatching);
        } else {
            const shapes: room_kit.PartBuilder = .{ .cube = self.scenery.cube, .cylinder = self.scenery.cylinder };
            robot_placeholder.draw(self.robot, frame, shaders.room, shapes, hatching);
        }
    }
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

    const scenery = try Scenery.init(context, gpu);
    defer scenery.cleanUp();

    var ink_pass = try ink.Ink.init(context, gpu);
    defer ink_pass.releaseGpuObjects();

    const sprites = try Overlay.init(context, gpu);
    defer sprites.releaseGpuObjects();

    // Null without the-station's sheet: the OS cursor shows
    const cursor_sheet = cursor.CursorSheet.load(context, gpu);
    defer if (cursor_sheet) |sheet| {
        sheet.releaseGpuObjects();
    };

    var robot_model = RobotModel.load(context, gpu);
    defer if (robot_model) |*model| {
        model.cleanUp();
    };

    var saved_settings = settings_file.File.load(allocator, context.io, settings_file.SETTINGS_PATH);
    var settings: Settings = .{};
    saved_settings.apply(&settings);
    const camera = &settings.camera;
    const style = &settings.ink;
    var game: Game = .{};
    // The shown room's framing; its center eases there as the room shown changes or, in a
    // large room, as the robot walks
    var view = station.cameraFraming(game.room, game.robot.position, settings.room.frame_whole_room);

    // Before gui.init: ImGui's GLFW backend chains to Input's callbacks
    const input = Input.init(window);
    gui.init(allocator, window, gpu);
    defer gui.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        input.update();
        processKeys(input, window, camera, &game);

        const time = input.total_time;
        const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
        // A pan to a room beside; a cut while the screen fades to another floor
        const target = station.cameraFraming(game.room, game.robot.position, settings.room.frame_whole_room);
        view = if (game.isCut()) target else panTo(view, target, input.delta_time);
        const render_context = camera.renderContext(view, aspect, time);
        const visible = visibleRooms(camera, view, aspect);

        // A press counts even if released before the frame (a trackpad tap); none over a panel
        game.update(mouseRay(input, render_context), input.mousePressed(.left), input.delta_time);
        if (robot_model) |*model| {
            try model.update(&game.robot, input.delta_time);
        }

        const alarm_level = if (game.station.isAlarmSounding()) pulse(time, settings.alarm.rate) else 0.0;

        var frame = gpu.acquireFrame() orelse continue;
        try ink_pass.update(context.alloc, gpu);

        var uniforms = render_context.frameUniforms();
        uniforms.lights = stationLights(settings, game.station, alarm_level, game.room, visible).uniforms();
        gpu.writeFrameUniforms(uniforms);

        // The scene twice: its normals and depth for the outlines, then in color
        const scene: Scene = .{
            .scenery = &scenery,
            .robot = &game.robot,
            .robot_model = if (settings.room.use_placeholder) null else if (robot_model) |*model| model else null,
            .state = .{
                .visible = visible,
                .alarm_glow = alarm_level,
                .light_glow = lightGlow(game.station),
                .door_open = game.door_open,
                .use_greybox = settings.room.use_greybox,
                .highlight = highlight(&game, time, style.highlight_strength),
            },
        };
        if (style.show_outlines) {
            ink_pass.beginNormalDepthPass(&frame);
            scene.draw(&frame, ink_pass.normal_depth_shaders, style.hatching());
            frame.endPass();
        }

        frame.beginSurfacePass(CLEAR_COLOR);
        scene.draw(&frame, scene_shaders, style.hatching());
        ink_pass.drawOutlines(&frame, style.*);
        drawLines(&frame, &lines, settings.room, game.room, game.hovered);
        const fade = game.fade();
        if (fade > 0.0) {
            sprites.fill(&frame, vec4(0.0, 0.0, 0.0, fade));
        }
        if (cursor_sheet) |sheet| {
            if (!input.gui_has_mouse) {
                sheet.draw(&frame, &sprites, game.cursor(), input.mouse_x, input.mouse_y, input.window_width, input.window_height);
            }
        }

        gui.newFrame();
        setOsCursor(input, cursor_sheet != null, game.hovered);
        drawLabel("remark", game.remark(), .{ zgui.io.getDisplaySize()[0] / 2.0, 24.0 }, 0.5);
        drawLabel("hovered", game.hoveredName(), .{ input.mouse_x + 18.0, input.mouse_y + 8.0 }, 0.0);
        drawPanel(.{ .file = &saved_settings, .values = &settings }, &game, aspect);
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
        game.station.alarm = switch (game.station.alarm) {
            .sounding => .silenced,
            .silenced => .sounding,
        };
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

/// Over the game, hidden while the game draws its own, else a hand over a hotspot; over
/// the panel, ImGui's. After `gui.newFrame`: ImGui's backend sets the OS cursor every
/// frame from what it was told last.
fn setOsCursor(input: *const Input, has_game_cursor: bool, hovered: interaction.Target) void {
    if (input.gui_has_mouse) {
        return;
    }
    if (has_game_cursor) {
        zgui.setMouseCursor(.none);
    } else if (hovered == .hotspot) {
        zgui.setMouseCursor(.hand);
    }
}

/// `view` with its center and floor eased toward `target`'s, and `target`'s size: the
/// camera pans to the robot's room, and follows it in a large one.
fn panTo(view: Framing, target: Framing, dt: f32) Framing {
    const alpha = core.motion.dampAlpha(PAN_RATE, dt);
    var panned = target;
    panned.center_x = std.math.lerp(view.center_x, target.center_x, alpha);
    panned.center_y = std.math.lerp(view.center_y, target.center_y, alpha);
    panned.floor_y = std.math.lerp(view.floor_y, target.floor_y, alpha);
    return panned;
}

/// The rooms the camera sees, as it shows `view` on a screen `aspect` wide.
fn visibleRooms(camera: *const RoomCamera, view: Framing, aspect: f32) std.EnumSet(station.RoomId) {
    const fitted = RoomCamera.fitToAspect(view, aspect);
    const eye = camera.eyePosition(fitted);
    const back_scale = camera.depthScale(room_kit.DEPTH + room_kit.WALL);
    var visible: std.EnumSet(station.RoomId) = .initEmpty();
    for (std.enums.values(station.RoomId)) |id| {
        if (station.isVisible(id, fitted, eye, back_scale)) {
            visible.insert(id);
        }
    }
    return visible;
}

/// 0..1, a smooth rise and fall `rate` times a second.
fn pulse(time: f32, rate: f32) f32 {
    return 0.5 - 0.5 * @cos(time * rate * std.math.tau);
}

/// How much the ceiling lights' tubes glow.
fn lightGlow(state: Station) f32 {
    return switch (state.lights()) {
        .off => 0.0,
        .emergency => EMERGENCY_GLOW,
    };
}

/// The hovered control's highlight, `strength` at full, breathing a little while it is on.
fn highlight(game: *const Game, time: f32, strength: f32) ?station.Highlight {
    const hotspot = game.highlighted orelse return null;
    const breath = 1.0 - HIGHLIGHT_PULSE_DEPTH * pulse(time, HIGHLIGHT_PULSE_RATE);
    return .{ .hotspot = hotspot, .amount = game.highlight * breath * strength };
}

/// Main power is out: no light from above, only a dim ambient, the alarm's red point
/// light, and with the emergency lights on a yellowish light under each ceiling tube.
/// Each room's lights stay in the room (`station.lightBounds`). Only the rooms the camera
/// sees are lit, the room shown first, then the nearest (8 point lights at most).
fn stationLights(settings: Settings, state: Station, alarm_level: f32, shown: station.RoomId, visible: std.EnumSet(station.RoomId)) SceneLights {
    const is_emergency = state.lights() == .emergency;

    var lights = SceneLights.init();
    lights.ambient = if (is_emergency)
        station.EMERGENCY_TINT.mulScalar(settings.lights.dark + 0.06 * settings.lights.emergency)
    else
        vec3(1.0, 1.0, 1.0).mulScalar(settings.lights.dark);
    lights.direction_light = .{ .dir = vec3(0.25, -1.0, -0.6), .color = vec3(0.0, 0.0, 0.0) };
    const alarm_bounds = station.lightBounds(.room_01);
    lights.setPointLight(0, .{
        .world_pos = station.place(.room_01, room_01.ALARM_LIGHT_POSITION),
        .color = room_01.alarmLightColor(settings.alarm.intensity * alarm_level),
        .constant = 1.0,
        .linear = 0.35,
        .quadratic = 0.15,
        .enabled = state.isAlarmSounding() and visible.contains(.room_01),
        .bounds = .{ .min = alarm_bounds.min, .max = alarm_bounds.max },
    });
    var lit: [station.ROOM_COUNT]station.RoomId = undefined;
    lit[0] = shown;
    var count: usize = 1;
    var others = visible;
    others.remove(shown);
    var iterator = others.iterator();
    while (iterator.next()) |id| : (count += 1) {
        lit[count] = id;
    }
    std.mem.sort(station.RoomId, lit[1..count], shown, isNearer);
    if (!is_emergency) {
        return lights;
    }
    var index: usize = 1;
    for (lit[0..count]) |id| {
        const bounds = station.lightBounds(id);
        for (station.room(id).ceiling_lights) |x| {
            if (index == core.bindings.MAX_POINT_LIGHTS) {
                return lights;
            }
            lights.setPointLight(index, .{
                .world_pos = station.emergencyLightPosition(id, x),
                .color = station.EMERGENCY_TINT.mulScalar(settings.lights.emergency * EMERGENCY_PER_TUBE),
                .constant = 1.0,
                .linear = 0.2,
                .quadratic = 0.08,
                .enabled = true,
                .bounds = .{ .min = bounds.min, .max = bounds.max },
            });
            index += 1;
        }
    }
    return lights;
}

/// Whether room `a` is nearer room `shown` than room `b` is, by their origins.
fn isNearer(shown: station.RoomId, a: station.RoomId, b: station.RoomId) bool {
    const origin = station.room(shown).origin();
    return station.room(a).origin().sub(origin).length() < station.room(b).origin().sub(origin).length();
}

/// The room shown's floor grid and the bounds of the hotspot under the mouse, if on (for
/// checking a hotspot's box; the game shows a hotspot by lighting it up).
fn drawLines(frame: *const Frame, lines: *Lines, room: settings_file.RoomSettings, shown: station.RoomId, hovered: interaction.Target) void {
    var segments: [MAX_LINES]LineSegment = undefined;
    var count: usize = 0;
    if (room.show_grid) {
        count += floorGrid(segments[0 .. 2 * GRID_LINES], shown);
    }
    switch (hovered) {
        .hotspot => |index| if (room.show_hotspot_bounds) {
            const outline = interaction.outline(station.hotspots[index].bounds);
            @memcpy(segments[count..][0..outline.len], &outline);
            count += outline.len;
        },
        .floor, .nothing => {},
    }
    if (count > 0) {
        lines.draw(frame, segments[0..count]);
    }
}

/// A 1 m grid on room `id`'s floor, to see the perspective by, around a hole in it.
/// Returns the number of segments.
fn floorGrid(segments: []LineSegment, id: station.RoomId) usize {
    const half_width = station.room(id).width() / 2.0;
    const hole = station.room(id).floor_hole;
    const y = 0.002;
    var count: usize = 0;

    var x = -half_width;
    while (x <= half_width) : (x += 1.0) {
        const across = hole != null and x > hole.?.min_x and x < hole.?.max_x;
        if (across) {
            count += gridLine(segments[count..], id, vec3(x, y, 0.0), vec3(x, y, hole.?.max_z));
            count += gridLine(segments[count..], id, vec3(x, y, hole.?.min_z), vec3(x, y, -room_kit.DEPTH));
        } else {
            count += gridLine(segments[count..], id, vec3(x, y, 0.0), vec3(x, y, -room_kit.DEPTH));
        }
    }
    var z: f32 = 0.0;
    while (z >= -room_kit.DEPTH) : (z -= 1.0) {
        const across = hole != null and z > hole.?.min_z and z < hole.?.max_z;
        if (across) {
            count += gridLine(segments[count..], id, vec3(-half_width, y, z), vec3(hole.?.min_x, y, z));
            count += gridLine(segments[count..], id, vec3(hole.?.max_x, y, z), vec3(half_width, y, z));
        } else {
            count += gridLine(segments[count..], id, vec3(-half_width, y, z), vec3(half_width, y, z));
        }
    }
    return count;
}

/// One grid line from `start` to `end` in room `id`'s coordinates. Returns 1.
fn gridLine(segments: []LineSegment, id: station.RoomId, start: Vec3, end: Vec3) usize {
    segments[0] = .{ .start = station.place(id, start), .end = station.place(id, end), .color = .black };
    return 1;
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

fn drawPanel(panel: settings_file.Panel, game: *Game, aspect: f32) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 340, .h = 0, .cond = .first_use_ever });
    // Collapsed at first: open it covers the door
    zgui.setNextWindowCollapsed(.{ .collapsed = true, .cond = .first_use_ever });
    if (zgui.begin("the station", .{})) {
        zgui.text("1 / 2 / 3: view   Space: alarm", .{});
        zgui.text("Right-click a setting: save, revert, reset", .{});

        panel.section(.camera, "Camera");
        panel.combo(.camera, .view, "view");
        panel.slider(.camera, .distance, "distance", 2.0, 40.0);
        panel.slider(.camera, .eye_height, "eye height", -1.0, 5.0);
        panel.slider(.camera, .eye_x, "eye x", -4.0, 4.0);
        const camera = &panel.values.camera;
        const framing = RoomCamera.fitToAspect(station.framing(.room_01), aspect);
        zgui.text("vertical field of view: {d:.1}°", .{camera.verticalFov(framing)});
        zgui.text("horizontal field of view: {d:.1}°", .{horizontalFov(camera.verticalFov(framing), aspect)});

        panel.section(.ink, "Ink");
        panel.checkbox(.ink, .show_outlines, "outlines");
        panel.slider(.ink, .line_width, "line width", 1.0, 4.0);
        panel.slider(.ink, .depth_threshold, "depth threshold", 0.005, 0.2);
        panel.slider(.ink, .normal_threshold, "crease threshold", 0.05, 1.0);
        panel.slider(.ink, .ink_opacity, "ink opacity", 0.0, 1.0);
        panel.checkbox(.ink, .show_hatching, "hatching");
        panel.slider(.ink, .hatch_strength, "hatch strength", 0.0, 1.0);
        panel.slider(.ink, .hatch_spacing, "hatch spacing", 0.02, 0.2);
        panel.slider(.ink, .highlight_strength, "highlight", 0.0, 2.0);

        panel.section(.room, "Room");
        panel.checkbox(.room, .show_grid, "floor grid");
        panel.checkbox(.room, .show_hotspot_bounds, "hotspot bounds");
        panel.checkbox(.room, .use_placeholder, "placeholder robot");
        panel.checkbox(.room, .use_greybox, "greybox room");
        panel.checkbox(.room, .frame_whole_room, "frame large rooms whole");
        _ = zgui.comboFromEnum("door", game.station.doors.getPtr(.room_01_left));
        if (zgui.button("restart", .{})) {
            game.restore(.{});
        }
        zgui.sameLine(.{});
        if (zgui.button("back to room entry", .{})) {
            game.restore(game.room_entry);
        }

        panel.section(.lights, "Lights");
        _ = zgui.comboFromEnum("emergency power", &game.station.power.emergency);
        panel.slider(.lights, .dark, "dark", 0.0, 0.3);
        panel.slider(.lights, .emergency, "emergency", 0.0, 4.0);

        panel.section(.alarm, "Alarm");
        _ = zgui.comboFromEnum("alarm", &game.station.alarm);
        panel.slider(.alarm, .rate, "pulses per second", 0.2, 3.0);
        panel.slider(.alarm, .intensity, "intensity", 0.0, 12.0);
    }
    zgui.end();
}

fn horizontalFov(vertical_degrees: f32, aspect: f32) f32 {
    const half_vertical = std.math.degreesToRadians(vertical_degrees) / 2.0;
    return std.math.radiansToDegrees(2.0 * std.math.atan(std.math.tan(half_vertical) * aspect));
}
