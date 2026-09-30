//! Camera rig showcase for the motion patterns (plan 016). A focus sphere travels a closed
//! Catmull-Rom loop (`motion.PathFollow`); a `CameraGimbal` rig follows it:
//!
//! - The base follows the focus with a lag. Each frame the focus point is damped
//!   (`motion.dampVec3`) and the base moves by as much as the damped focus moved, still
//!   looking at it. The base can be circled around the focus and moved in and out with
//!   `Movement`'s circle and radius commands, which the follow doesn't undo.
//!   (`motion.SmoothFollow` sets the camera's position outright each frame, so it
//!   would; the rig carries the base along instead.)
//! - The base can be tilted (banked about its forward axis), as a satellite's body is tilted
//!   against its orbit. The gimbal aims on top of its mount, which either follows the
//!   base's tilt (view "gimbal") or keeps the base's heading level with the horizontal
//!   plane (view "gimbal_level").
//! - A hit adds trauma to `motion.Shake`, applied to the frame's view after the rig.
//!
//! Keys: arrows circle the base around the focus, W / S move it in and out, I / J / K / L
//! aim the gimbal, C recenters it, Space is a hit, Escape quits.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const Arenas = core.Arenas;
const CameraGimbal = core.CameraGimbal;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const MovementDirection = core.MovementDirection;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const motion = core.motion;
const gui = core.gui;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const CLEAR_COLOR = [4]f64{ 0.05, 0.06, 0.08, 1.0 };

/// The focus's route: a closed loop over the floor, rising and dipping.
const focus_waypoints = [_]Vec3{
    vec3(8.0, 1.0, 0.0),
    vec3(4.0, 2.5, 7.0),
    vec3(-5.0, 1.0, 6.0),
    vec3(-8.0, 3.0, -2.0),
    vec3(-2.0, 1.0, -8.0),
    vec3(6.0, 2.0, -6.0),
};
/// Line segments drawn along the focus's route.
const PATH_LINE_SEGMENTS = 200;
/// Where the base starts relative to the focus.
const START_OFFSET = vec3(0.0, 5.0, 10.0);
/// The gimbal's mount on the base, in the base's own space: a little up and to the right.
const GIMBAL_MOUNT = vec3(0.6, 0.4, 0.0);

/// The panel's names for `CameraGimbal.ViewMode` (a combo needs an i32-backed enum).
const ViewMode = enum(i32) { base, gimbal, gimbal_level };

/// Everything the panel changes.
const Settings = struct {
    /// Units per second along the focus's route.
    focus_speed: f32 = 3.0,
    /// How fast the base catches up with the focus; higher is tighter.
    follow_rate: f32 = 2.0,
    view_mode: ViewMode = .gimbal,
    /// Bank of the base about its forward axis, in degrees.
    base_tilt: f32 = 0.0,
    show_path: bool = true,
    /// Trauma one hit adds.
    hit_trauma: f32 = 0.5,
};

/// One shape in the scene, with its placement and color.
const SceneObject = struct {
    shape: *Shape,
    model: Mat4,
    color: Vec4,
};

/// The base following the focus: the damped focus point, carried along each frame.
const BaseFollow = struct {
    focus: Vec3,

    /// Damps the focus point toward `focus` and moves the base by as much as it moved,
    /// looking at it, then banks it by `tilt_degrees`. Circle and radius changes made to
    /// the base stay, since the base is moved relative to where it is. The look-at
    /// rebuilds the orientation level each frame, so the tilt is applied fresh each
    /// frame and doesn't add up.
    fn update(self: *BaseFollow, camera: *CameraGimbal, focus: Vec3, rate: f32, tilt_degrees: f32, dt: f32) void {
        const damped = motion.dampVec3(self.focus, focus, rate, dt);
        const moved = damped.sub(self.focus);
        self.focus = damped;
        camera.base_movement.reset(camera.getBasePosition().add(moved), damped);
        camera.base_movement.applyMovement(.roll_right, 0.0, std.math.degreesToRadians(tilt_degrees), 0.0);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(1280, 800, "camera_rig", null, null);
    defer window.destroy();

    var gpu = try GpuContext.init(allocator, window);
    defer gpu.deinit();

    var arenas = try Arenas.init(allocator);
    defer arenas.deinit();

    try run(allocator, arenas.context(init.io), window, &gpu);
}

/// `allocator` is for ImGui, which frees in any order (an arena wouldn't reclaim it).
fn run(allocator: std.mem.Allocator, context: core.Context, window: *zglfw.Window, gpu: *GpuContext) !void {
    const shape_shader = try Shader.init(context.io, context.alloc, gpu, "examples/camera_rig/shaders/basic_shape.wgsl", .{
        .vertex_buffers = &Shape.vertex_buffer_layouts,
    });
    defer shape_shader.releaseGpuObjects();

    const lines_shader = try Shader.init(context.io, context.alloc, gpu, "examples/camera_rig/shaders/lines.wgsl", .{
        .vertex_buffers = &Lines.vertex_buffer_layouts,
        .topology = .line_list,
    });
    defer lines_shader.releaseGpuObjects();
    var path_lines = try Lines.init(context.alloc, lines_shader, 1.0, 1.0, PATH_LINE_SEGMENTS);

    var shapes: SceneShapes = try .init(context, gpu);
    defer shapes.releaseGpuObjects();
    const objects = shapes.sceneObjects();

    var focus_path: motion.PathFollow = .{ .points = &focus_waypoints, .speed = 0.0, .shape = .catmull_rom, .repeat = .loop };
    const start_focus = focus_path.position();

    const camera = try CameraGimbal.init(allocator, .{
        .base_position = start_focus.add(START_OFFSET),
        .base_target = start_focus,
        .gimbal_position = GIMBAL_MOUNT,
        // Straight ahead from the mount (the default target is ahead of the base's center)
        .gimbal_target = GIMBAL_MOUNT.add(vec3(0.0, 0.0, -1.0)),
        .scr_width = @floatFromInt(gpu.width),
        .scr_height = @floatFromInt(gpu.height),
    });
    defer camera.deinit();
    camera.base_movement.orbit_speed = 60.0;

    var follow: BaseFollow = .{ .focus = start_focus };
    var shake: motion.Shake = .{ .decay = 1.2, .max_offset = 0.4, .max_angle = 0.06 };

    gui.init(allocator, window, gpu);
    defer gui.deinit();

    var settings: Settings = .{};
    var space_was_down = false;
    var last_time: f32 = @floatCast(zglfw.getTime());

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        if (window.getKey(.escape) == .press) {
            window.setShouldClose(true);
        }

        const time: f32 = @floatCast(zglfw.getTime());
        const delta_time = time - last_time;
        last_time = time;

        // A hit on each Space press, not each frame it's held
        const space_down = window.getKey(.space) == .press and !zgui.io.getWantCaptureKeyboard();
        if (space_down and !space_was_down) {
            shake.addTrauma(settings.hit_trauma);
        }
        space_was_down = space_down;

        processKeys(window, camera, delta_time);

        // The focus moves on; the base follows, then the view mode picks what's shown
        focus_path.speed = settings.focus_speed;
        const focus = focus_path.update(delta_time);
        follow.update(camera, focus, settings.follow_rate, settings.base_tilt, delta_time);
        camera.setViewMode(switch (settings.view_mode) {
            .base => .base,
            .gimbal => .gimbal,
            .gimbal_level => .gimbal_level,
        });

        var frame = gpu.acquireFrame() orelse continue;

        camera.setScreenDimensions(@floatFromInt(gpu.width), @floatFromInt(gpu.height));
        // The shake goes on top of the rig's view; the rig itself isn't touched
        const shaken = shake.update(delta_time).apply(camera.getRenderContext(time));
        gpu.writeFrameUniforms(shaken.frameUniforms());

        frame.beginSurfacePass(CLEAR_COLOR);
        drawObjects(&frame, shape_shader, &objects);
        shapes.focus.draw(&frame, shape_shader, DrawUniforms.init(Mat4.fromTranslation(focus), vec4(1.0, 0.45, 0.1, 1.0)));
        if (settings.show_path) {
            drawPath(&frame, &path_lines, focus_path);
        }

        gui.newFrame();
        drawPanel(&settings, camera, &shake);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

/// The shapes, created once, and where the static ones go.
const SceneShapes = struct {
    floor: *Shape,
    cube: *Shape,
    cylinder: *Shape,
    /// The moving focus.
    focus: *Shape,

    fn init(context: core.Context, gpu: *const GpuContext) !SceneShapes {
        return .{
            .floor = try core.shapes.createCube(context.alloc, gpu, .{ .width = 30.0, .height = 0.2, .depth = 30.0 }),
            .cube = try core.shapes.createCube(context.alloc, gpu, .{}),
            .cylinder = try core.shapes.createCylinder(context.alloc, gpu, 1.0, 1.0, 24),
            .focus = try core.shapes.createSphere(context.alloc, gpu, 0.5, 24, 24),
        };
    }

    /// A floor with a few pillars and blocks, to see the rig move against.
    fn sceneObjects(self: *const SceneShapes) [7]SceneObject {
        const floor_color = vec4(0.45, 0.47, 0.5, 1.0);
        const stone = vec4(0.6, 0.58, 0.55, 1.0);
        const teal = vec4(0.2, 0.5, 0.55, 1.0);
        return .{
            .{ .shape = self.floor, .model = Mat4.fromTranslation(vec3(0.0, -0.1, 0.0)), .color = floor_color },
            .{ .shape = self.cylinder, .model = place(vec3(0.0, 2.0, 0.0), vec3(1.0, 4.0, 1.0)), .color = stone },
            .{ .shape = self.cylinder, .model = place(vec3(-6.0, 1.5, 3.0), vec3(0.7, 3.0, 0.7)), .color = stone },
            .{ .shape = self.cylinder, .model = place(vec3(5.0, 1.5, -2.0), vec3(0.7, 3.0, 0.7)), .color = stone },
            .{ .shape = self.cube, .model = place(vec3(3.0, 0.75, 4.0), vec3(1.5, 1.5, 1.5)), .color = teal },
            .{ .shape = self.cube, .model = place(vec3(-3.0, 0.5, -4.0), vec3(2.0, 1.0, 1.0)), .color = teal },
            .{ .shape = self.cube, .model = place(vec3(-7.0, 1.0, -6.0), vec3(1.0, 2.0, 1.0)), .color = teal },
        };
    }

    fn releaseGpuObjects(self: *SceneShapes) void {
        self.floor.releaseGpuObjects();
        self.cube.releaseGpuObjects();
        self.cylinder.releaseGpuObjects();
        self.focus.releaseGpuObjects();
    }
};

fn place(position: Vec3, scale: Vec3) Mat4 {
    return Mat4.fromTranslation(position).mulMat4(&Mat4.fromScale(scale));
}

fn processKeys(window: *zglfw.Window, camera: *CameraGimbal, delta_time: f32) void {
    if (zgui.io.getWantCaptureKeyboard()) {
        return;
    }
    const base_keys = [_]struct { key: zglfw.Key, direction: MovementDirection }{
        .{ .key = .left, .direction = .circle_left },
        .{ .key = .right, .direction = .circle_right },
        .{ .key = .up, .direction = .circle_up },
        .{ .key = .down, .direction = .circle_down },
        .{ .key = .w, .direction = .radius_in },
        .{ .key = .s, .direction = .radius_out },
    };
    for (base_keys) |binding| {
        if (window.getKey(binding.key) == .press) {
            camera.processBaseMovement(binding.direction, delta_time);
        }
    }
    const gimbal_keys = [_]struct { key: zglfw.Key, direction: MovementDirection }{
        .{ .key = .j, .direction = .rotate_left },
        .{ .key = .l, .direction = .rotate_right },
        .{ .key = .i, .direction = .rotate_up },
        .{ .key = .k, .direction = .rotate_down },
    };
    for (gimbal_keys) |binding| {
        if (window.getKey(binding.key) == .press) {
            camera.processGimbalMovement(binding.direction, delta_time);
        }
    }
    if (window.getKey(.c) == .press) {
        recenterGimbal(camera);
    }
}

/// The gimbal back on its mount, looking where the base looks.
fn recenterGimbal(camera: *CameraGimbal) void {
    camera.gimbal_movement.reset(GIMBAL_MOUNT, GIMBAL_MOUNT.add(vec3(0.0, 0.0, -1.0)));
}

fn drawObjects(frame: *const Frame, shader: *const Shader, objects: []const SceneObject) void {
    for (objects) |object| {
        object.shape.draw(frame, shader, DrawUniforms.init(object.model, object.color));
    }
}

/// The focus's route, sampled along its length. A copy of the path, so the focus's own
/// position is untouched.
fn drawPath(frame: *const Frame, lines: *Lines, path: motion.PathFollow) void {
    var sampler = path;
    const length = sampler.length();
    var segments: [PATH_LINE_SEGMENTS]LineSegment = undefined;
    var previous = sampler.points[0];
    for (&segments, 1..) |*segment, i| {
        sampler.distance = length * @as(f32, @floatFromInt(i)) / PATH_LINE_SEGMENTS;
        const point = sampler.position();
        segment.* = .{ .start = previous, .end = point, .color = .gold };
        previous = point;
    }
    lines.draw(frame, &segments);
}

fn drawPanel(settings: *Settings, camera: *CameraGimbal, shake: *motion.Shake) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 320, .h = 0, .cond = .first_use_ever });
    if (zgui.begin("camera rig", .{})) {
        zgui.text("frame time: {d:.2} ms", .{1000.0 / zgui.io.getFramerate()});
        zgui.text("arrows: circle base   W / S: in / out", .{});
        zgui.text("IJKL: aim gimbal   C: recenter", .{});
        zgui.text("Space: hit", .{});

        zgui.separatorText("Focus");
        _ = zgui.sliderFloat("speed", .{ .v = &settings.focus_speed, .min = 0.0, .max = 10.0 });
        _ = zgui.checkbox("show path", .{ .v = &settings.show_path });

        zgui.separatorText("Rig");
        _ = zgui.sliderFloat("follow rate", .{ .v = &settings.follow_rate, .min = 0.2, .max = 10.0 });
        _ = zgui.sliderFloat("base tilt", .{ .v = &settings.base_tilt, .min = -60.0, .max = 60.0 });
        _ = zgui.comboFromEnum("view", &settings.view_mode);
        if (zgui.button("recenter gimbal", .{})) {
            recenterGimbal(camera);
        }
        const forward = camera.getCameraForward();
        zgui.text("camera forward: {d:.2} {d:.2} {d:.2}", .{ forward.x, forward.y, forward.z });

        zgui.separatorText("Shake");
        if (zgui.button("hit", .{})) {
            shake.addTrauma(settings.hit_trauma);
        }
        _ = zgui.sliderFloat("hit trauma", .{ .v = &settings.hit_trauma, .min = 0.1, .max = 1.0 });
        _ = zgui.sliderFloat("decay", .{ .v = &shake.decay, .min = 0.2, .max = 4.0 });
        _ = zgui.sliderFloat("max offset", .{ .v = &shake.max_offset, .min = 0.0, .max = 2.0 });
        _ = zgui.sliderFloat("max angle", .{ .v = &shake.max_angle, .min = 0.0, .max = 0.3 });
        zgui.text("trauma: {d:.2}", .{shake.trauma});
    }
    zgui.end();
}
