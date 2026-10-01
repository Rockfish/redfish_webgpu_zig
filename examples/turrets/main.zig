//! Turret test bed (plan 008): three turrets aim at a target flying a loop over the floor
//! and fire tracers at it. The panel sets each turret's pattern, slew style and speeds,
//! fire policy, cadence, and jitter, to compare how they look:
//!
//! - "gatling": rate-limited slew (a motor-driven mount), fires while turning, a steady
//!   stream with wide jitter, no lead.
//! - "cannon": damped slew (snaps and settles), fires only once aligned, in bursts, tight
//!   jitter, with lead.
//! - "sweeper": sweeps a 20° arc either side of the target's bearing, firing a fan of
//!   shots while turning.
//!
//! Lines: the target's route (gold); each turret's aim from the muzzle, green on target,
//! yellow turning; with lead, the target to the lead point (magenta); a sweep's arc as its
//! two ends (cyan). The target flashes
//! white on each hit.
//!
//! Keys: arrows circle the camera, W / S move it in and out, Escape quits.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const projectiles = @import("projectiles.zig");
const turret_module = @import("turret.zig");

const Arenas = core.Arenas;
const Camera = core.Camera;
const DrawUniforms = core.DrawUniforms;
const FireControl = core.FireControl;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const MovementDirection = core.MovementDirection;
const Random = core.Random;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const motion = core.motion;
const gui = core.gui;
const TargetState = turret_module.TargetState;
const Turret = turret_module.Turret;
const TurretShapes = turret_module.TurretShapes;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const CLEAR_COLOR = [4]f64{ 0.05, 0.06, 0.08, 1.0 };

/// The target's route: a closed loop around the turrets, rising and dipping.
const target_waypoints = [_]Vec3{
    vec3(14.0, 2.0, -2.0),
    vec3(8.0, 4.0, -12.0),
    vec3(-4.0, 2.5, -14.0),
    vec3(-14.0, 5.0, -6.0),
    vec3(-12.0, 2.0, 6.0),
    vec3(0.0, 3.0, 12.0),
    vec3(10.0, 6.0, 9.0),
};
const TARGET_RADIUS: f32 = 0.6;
/// Line segments drawn along the target's route.
const PATH_LINE_SEGMENTS = 200;
const TURRET_COUNT = 3;
/// Aim lines per turret: the aim ray, and the lead line or the sweep's two ends.
const AIM_LINES_PER_TURRET = 3;
/// How fast the hit flash fades, per second.
const FLASH_DECAY: f32 = 6.0;

/// The panel's choices (a combo needs an i32-backed enum).
const SlewStyle = enum(i32) { rate_limited, damped };
const FirePolicy = enum(i32) { while_turning, when_aligned };
const CadenceKind = enum(i32) { rate, bursts };
const PatternKind = enum(i32) { track, sweep };
/// A sweep's center or pitch: follow the target, or a fixed angle.
const SweepAngle = enum(i32) { target, fixed };

/// One turret's panel settings, in panel units (degrees, percent), applied to the turret
/// each frame.
const TurretSettings = struct {
    name: [:0]const u8,
    fire: bool = true,
    pattern: PatternKind = .track,
    /// For `track`.
    lead: bool = false,
    /// For `sweep`: degrees either side of the center, and degrees per second.
    sweep_half_width: f32 = 20.0,
    sweep_speed: f32 = 40.0,
    sweep_center: SweepAngle = .target,
    /// Degrees, for a fixed center.
    sweep_heading: f32 = 0.0,
    sweep_pitch: SweepAngle = .target,
    /// Degrees, for a fixed pitch.
    sweep_pitch_angle: f32 = 10.0,
    slew: SlewStyle,
    /// Degrees per second, for `rate_limited`.
    yaw_speed: f32 = 90.0,
    pitch_speed: f32 = 60.0,
    /// Approach rates per second, for `damped`.
    yaw_rate: f32 = 4.0,
    pitch_rate: f32 = 4.0,
    policy: FirePolicy,
    /// Degrees, for `when_aligned`.
    tolerance: f32 = 2.0,
    cadence: CadenceKind,
    /// Shots per second.
    rate: f32 = 10.0,
    burst_count: i32 = 3,
    /// Seconds.
    burst_interval: f32 = 0.12,
    burst_pause: f32 = 1.0,
    /// Units per second.
    speed: f32,
    /// Degrees.
    aim_jitter: f32,
    /// Percent.
    speed_jitter: f32,

    fn apply(self: TurretSettings, turret: *Turret) void {
        const radians = std.math.degreesToRadians;
        turret.aim.slew = switch (self.slew) {
            .rate_limited => .{ .rate_limited = .{ .yaw_speed = radians(self.yaw_speed), .pitch_speed = radians(self.pitch_speed) } },
            .damped => .{ .damped = .{ .yaw_rate = self.yaw_rate, .pitch_rate = self.pitch_rate } },
        };
        turret.fire_control.policy = switch (self.policy) {
            .while_turning => .while_turning,
            .when_aligned => .{ .when_aligned = radians(self.tolerance) },
        };
        turret.fire_control.cadence = switch (self.cadence) {
            .rate => .{ .rate = self.rate },
            .bursts => .{ .bursts = .{
                .count = @intCast(self.burst_count),
                .interval = self.burst_interval,
                .pause = self.burst_pause,
            } },
        };
        turret.weapon.speed = self.speed;
        turret.weapon.jitter = .{ .aim = radians(self.aim_jitter), .speed = self.speed_jitter / 100.0 };
        turret.pattern = switch (self.pattern) {
            .track => .{ .track = .{ .lead = self.lead } },
            .sweep => .{ .sweep = .{
                .swing = self.swing(turret.pattern),
                .center_yaw = if (self.sweep_center == .fixed) radians(self.sweep_heading) else null,
                .pitch = if (self.sweep_pitch == .fixed) radians(self.sweep_pitch_angle) else null,
            } },
        };
    }

    /// The swing with this frame's width and speed, going on from where it is if the turret
    /// is already sweeping.
    fn swing(self: TurretSettings, current: turret_module.Pattern) motion.Sweep {
        var result: motion.Sweep = switch (current) {
            .sweep => |sweep| sweep.swing,
            .track => .{ .half_width = 0.0, .speed = 0.0 },
        };
        result.half_width = std.math.degreesToRadians(self.sweep_half_width);
        result.speed = std.math.degreesToRadians(self.sweep_speed);
        return result;
    }
};

/// Everything the panel changes.
const Settings = struct {
    /// Units per second along the target's route.
    target_speed: f32 = 5.0,
    show_path: bool = true,
    show_aim: bool = true,
    turrets: [TURRET_COUNT]TurretSettings = .{
        .{
            .name = "gatling",
            .slew = .rate_limited,
            .policy = .while_turning,
            .cadence = .rate,
            .speed = 30.0,
            .aim_jitter = 1.5,
            .speed_jitter = 5.0,
        },
        .{
            .name = "cannon",
            .lead = true,
            .slew = .damped,
            // A damped aim trails a moving target by about its angular speed / rate, so
            // fast rates and a few degrees of tolerance keep it firing
            .yaw_rate = 8.0,
            .pitch_rate = 8.0,
            .policy = .when_aligned,
            .tolerance = 4.0,
            .cadence = .bursts,
            .speed = 40.0,
            .aim_jitter = 0.5,
            .speed_jitter = 3.0,
        },
        .{
            .name = "sweeper",
            .pattern = .sweep,
            .slew = .rate_limited,
            .yaw_speed = 180.0,
            .pitch_speed = 90.0,
            .policy = .while_turning,
            .cadence = .rate,
            .rate = 15.0,
            .speed = 35.0,
            .aim_jitter = 1.0,
            .speed_jitter = 5.0,
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(1280, 800, "turrets", null, null);
    defer window.destroy();

    var gpu = try GpuContext.init(allocator, window);
    defer gpu.deinit();

    var arenas = try Arenas.init(allocator);
    defer arenas.deinit();

    try run(allocator, arenas.context(init.io), window, &gpu);
}

/// `allocator` is for ImGui, which frees in any order (an arena wouldn't reclaim it).
fn run(allocator: std.mem.Allocator, context: core.Context, window: *zglfw.Window, gpu: *GpuContext) !void {
    const shape_shader = try Shader.init(context.io, context.alloc, gpu, "examples/turrets/shaders/basic_shape.wgsl", .{
        .vertex_buffers = &Shape.vertex_buffer_layouts,
    });
    defer shape_shader.releaseGpuObjects();

    const projectile_shader = try Shader.init(context.io, context.alloc, gpu, "examples/turrets/shaders/projectiles.wgsl", .{
        .vertex_buffers = &projectiles.InstanceLayouts.layouts,
    });
    defer projectile_shader.releaseGpuObjects();

    const lines_shader = try Shader.init(context.io, context.alloc, gpu, "examples/turrets/shaders/lines.wgsl", .{
        .vertex_buffers = &Lines.vertex_buffer_layouts,
        .topology = .line_list,
    });
    defer lines_shader.releaseGpuObjects();
    var path_lines = try Lines.init(context.alloc, lines_shader, 1.0, 1.0, PATH_LINE_SEGMENTS);
    var aim_lines = try Lines.init(context.alloc, lines_shader, 1.0, 1.0, TURRET_COUNT * AIM_LINES_PER_TURRET);

    var scene_shapes: SceneShapes = try .init(context, gpu);
    defer scene_shapes.releaseGpuObjects();
    var turret_shapes: TurretShapes = try .init(context, gpu);
    defer turret_shapes.releaseGpuObjects();

    const camera = try Camera.init(context.alloc, .{
        // Off to the left, so the scene sits right of the panel
        .position = vec3(-5.0, 12.0, 18.0),
        .target = vec3(-5.0, 1.0, -1.0),
        .scr_width = @floatFromInt(gpu.width),
        .scr_height = @floatFromInt(gpu.height),
    });

    var settings: Settings = .{};
    var turrets = [TURRET_COUNT]Turret{
        createTurret(vec3(-5.0, 0.0, 2.0), vec4(0.55, 0.42, 0.18, 1.0), vec4(1.0, 0.75, 0.3, 1.0), settings.turrets[0]),
        createTurret(vec3(5.0, 0.0, 2.0), vec4(0.2, 0.42, 0.5, 1.0), vec4(0.4, 0.9, 1.0, 1.0), settings.turrets[1]),
        createTurret(vec3(0.0, 0.0, -6.0), vec4(0.25, 0.45, 0.25, 1.0), vec4(0.6, 1.0, 0.5, 1.0), settings.turrets[2]),
    };
    var random = Random.init();

    var target_path: motion.PathFollow = .{ .points = &target_waypoints, .speed = 0.0, .shape = .catmull_rom, .repeat = .loop };
    var flash: f32 = 0.0;

    gui.init(allocator, window, gpu);
    defer gui.deinit();

    var last_time: f32 = @floatCast(zglfw.getTime());

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        if (window.getKey(.escape) == .press) {
            window.setShouldClose(true);
        }

        const time: f32 = @floatCast(zglfw.getTime());
        const delta_time = time - last_time;
        last_time = time;

        processKeys(window, camera, delta_time);

        target_path.speed = settings.target_speed;
        const target: TargetState = .{
            .position = target_path.update(delta_time),
            .velocity = target_path.tangent().mulScalar(settings.target_speed),
            .radius = TARGET_RADIUS,
        };

        const hits_before = totalHits(&turrets);
        for (&turrets, settings.turrets) |*turret, turret_settings| {
            turret_settings.apply(turret);
            turret.update(delta_time, target, turret_settings.fire, &random);
        }
        flash = if (totalHits(&turrets) > hits_before) 1.0 else flash * (1.0 - motion.dampAlpha(FLASH_DECAY, delta_time));

        var frame = gpu.acquireFrame() orelse continue;

        camera.setScreenDimensions(@floatFromInt(gpu.width), @floatFromInt(gpu.height));
        gpu.writeFrameUniforms(camera.getRenderContext(time).frameUniforms());

        frame.beginSurfacePass(CLEAR_COLOR);
        scene_shapes.floor.draw(&frame, shape_shader, DrawUniforms.init(Mat4.fromTranslation(vec3(0.0, -0.1, 0.0)), vec4(0.4, 0.42, 0.45, 1.0)));
        const target_color = vec4(1.0, 0.35, 0.1, 1.0).lerp(Vec4.One, flash);
        scene_shapes.target.draw(&frame, shape_shader, DrawUniforms.init(Mat4.fromTranslation(target.position), target_color));
        for (&turrets) |*turret| {
            turret.draw(&frame, shape_shader, &turret_shapes);
            turret.drawProjectiles(&frame, projectile_shader, &turret_shapes);
        }
        if (settings.show_path) {
            drawPath(&frame, &path_lines, target_path);
        }
        if (settings.show_aim) {
            drawAimLines(&frame, &aim_lines, &turrets, target);
        }

        gui.newFrame();
        drawPanel(&settings, &turrets);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

/// The floor and the target's sphere, created once.
const SceneShapes = struct {
    floor: *Shape,
    target: *Shape,

    fn init(context: core.Context, gpu: *const GpuContext) !SceneShapes {
        return .{
            .floor = try core.shapes.createCube(context.alloc, gpu, .{ .width = 40.0, .height = 0.2, .depth = 40.0 }),
            .target = try core.shapes.createSphere(context.alloc, gpu, TARGET_RADIUS, 24, 24),
        };
    }

    fn releaseGpuObjects(self: *SceneShapes) void {
        self.floor.releaseGpuObjects();
        self.target.releaseGpuObjects();
    }
};

/// A turret at `position`, configured by its panel settings. Pitch is limited to just
/// below level up to steep.
fn createTurret(position: Vec3, color: Vec4, tracer_color: Vec4, turret_settings: TurretSettings) Turret {
    var turret: Turret = .init(.{
        .position = position,
        .aim = .{
            .slew = .{ .damped = .{ .yaw_rate = 1.0, .pitch_rate = 1.0 } },
            .min_pitch = std.math.degreesToRadians(-10.0),
            .max_pitch = std.math.degreesToRadians(70.0),
        },
        .fire_control = .{},
        .weapon = .{ .speed = 1.0, .jitter = .{}, .tracer_color = tracer_color },
        .pattern = .{ .track = .{ .lead = false } },
        .color = color,
    });
    turret_settings.apply(&turret);
    return turret;
}

fn totalHits(turrets: []const Turret) u32 {
    var hits: u32 = 0;
    for (turrets) |turret| {
        hits += turret.projectiles.hits;
    }
    return hits;
}

fn processKeys(window: *zglfw.Window, camera: *Camera, delta_time: f32) void {
    if (zgui.io.getWantCaptureKeyboard()) {
        return;
    }
    const bindings = [_]struct { key: zglfw.Key, direction: MovementDirection }{
        .{ .key = .left, .direction = .circle_left },
        .{ .key = .right, .direction = .circle_right },
        .{ .key = .up, .direction = .circle_up },
        .{ .key = .down, .direction = .circle_down },
        .{ .key = .w, .direction = .radius_in },
        .{ .key = .s, .direction = .radius_out },
    };
    for (bindings) |binding| {
        if (window.getKey(binding.key) == .press) {
            camera.processMovement(binding.direction, delta_time);
        }
    }
}

/// The target's route, sampled along its length. A copy of the path, so the target's own
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

/// Each turret's aim ray from the muzzle, as long as the distance to its aim point; with
/// lead, a line from the target to the point aimed at; for a sweep, lines to its arc's ends.
fn drawAimLines(frame: *const Frame, lines: *Lines, turrets: []const Turret, target: TargetState) void {
    var segments: [TURRET_COUNT * AIM_LINES_PER_TURRET]LineSegment = undefined;
    var count: usize = 0;
    for (turrets) |*turret| {
        const muzzle = turret.muzzle();
        const reach = turret.aim_point.sub(muzzle).length();
        segments[count] = .{
            .start = muzzle,
            .end = muzzle.add(turret.aim.direction().mulScalar(reach)),
            .color = if (turret.isOnTarget()) .green else .yellow,
        };
        count += 1;

        const is_leading = switch (turret.pattern) {
            .track => |track| track.lead,
            .sweep => false,
        };
        if (is_leading) {
            segments[count] = .{ .start = target.position, .end = turret.aim_point, .color = .magenta };
            count += 1;
        }
        if (turret.sweep_ends) |ends| {
            for (ends) |end| {
                segments[count] = .{ .start = turret.pivot(), .end = end, .color = .cyan };
                count += 1;
            }
        }
    }
    lines.draw(frame, segments[0..count]);
}

fn drawPanel(settings: *Settings, turrets: []const Turret) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 340, .h = 740, .cond = .first_use_ever });
    if (zgui.begin("turrets", .{})) {
        zgui.text("frame time: {d:.2} ms", .{1000.0 / zgui.io.getFramerate()});
        zgui.text("arrows: circle camera   W / S: in / out", .{});

        zgui.separatorText("Target");
        _ = zgui.sliderFloat("speed", .{ .v = &settings.target_speed, .min = 0.0, .max = 15.0 });
        _ = zgui.checkbox("show path", .{ .v = &settings.show_path });
        _ = zgui.checkbox("show aim", .{ .v = &settings.show_aim });

        for (&settings.turrets, turrets, 0..) |*turret_settings, *turret, i| {
            zgui.pushIntId(@intCast(i));
            if (zgui.collapsingHeader(turret_settings.name, .{ .default_open = true })) {
                drawTurretSettings(turret_settings, turret);
            }
            zgui.popId();
        }
    }
    zgui.end();
}

fn drawTurretSettings(turret_settings: *TurretSettings, turret: *const Turret) void {
    zgui.text("hits: {d}   in flight: {d}", .{ turret.projectiles.hits, turret.projectiles.count });
    _ = zgui.checkbox("fire", .{ .v = &turret_settings.fire });

    _ = zgui.comboFromEnum("pattern", &turret_settings.pattern);
    switch (turret_settings.pattern) {
        .track => {
            _ = zgui.checkbox("lead", .{ .v = &turret_settings.lead });
        },
        .sweep => {
            _ = zgui.sliderFloat("half width (deg)", .{ .v = &turret_settings.sweep_half_width, .min = 0.0, .max = 90.0 });
            _ = zgui.sliderFloat("sweep speed (deg/s)", .{ .v = &turret_settings.sweep_speed, .min = 5.0, .max = 180.0 });
            _ = zgui.comboFromEnum("center", &turret_settings.sweep_center);
            if (turret_settings.sweep_center == .fixed) {
                _ = zgui.sliderFloat("heading (deg)", .{ .v = &turret_settings.sweep_heading, .min = -180.0, .max = 180.0 });
            }
            _ = zgui.comboFromEnum("sweep pitch", &turret_settings.sweep_pitch);
            if (turret_settings.sweep_pitch == .fixed) {
                _ = zgui.sliderFloat("pitch (deg)", .{ .v = &turret_settings.sweep_pitch_angle, .min = -10.0, .max = 70.0 });
            }
        },
    }

    _ = zgui.comboFromEnum("slew", &turret_settings.slew);
    switch (turret_settings.slew) {
        .rate_limited => {
            _ = zgui.sliderFloat("yaw speed (deg/s)", .{ .v = &turret_settings.yaw_speed, .min = 10.0, .max = 360.0 });
            _ = zgui.sliderFloat("pitch speed (deg/s)", .{ .v = &turret_settings.pitch_speed, .min = 10.0, .max = 360.0 });
        },
        .damped => {
            _ = zgui.sliderFloat("yaw rate", .{ .v = &turret_settings.yaw_rate, .min = 0.5, .max = 20.0 });
            _ = zgui.sliderFloat("pitch rate", .{ .v = &turret_settings.pitch_rate, .min = 0.5, .max = 20.0 });
        },
    }

    _ = zgui.comboFromEnum("policy", &turret_settings.policy);
    if (turret_settings.policy == .when_aligned) {
        _ = zgui.sliderFloat("tolerance (deg)", .{ .v = &turret_settings.tolerance, .min = 0.1, .max = 15.0 });
    }
    _ = zgui.comboFromEnum("cadence", &turret_settings.cadence);
    switch (turret_settings.cadence) {
        .rate => {
            _ = zgui.sliderFloat("shots/s", .{ .v = &turret_settings.rate, .min = 0.5, .max = 30.0 });
        },
        .bursts => {
            _ = zgui.sliderInt("burst count", .{ .v = &turret_settings.burst_count, .min = 1, .max = 10 });
            _ = zgui.sliderFloat("burst interval (s)", .{ .v = &turret_settings.burst_interval, .min = 0.02, .max = 0.5 });
            _ = zgui.sliderFloat("burst pause (s)", .{ .v = &turret_settings.burst_pause, .min = 0.1, .max = 3.0 });
        },
    }

    _ = zgui.sliderFloat("shot speed", .{ .v = &turret_settings.speed, .min = 5.0, .max = 80.0 });
    _ = zgui.sliderFloat("aim jitter (deg)", .{ .v = &turret_settings.aim_jitter, .min = 0.0, .max = 10.0 });
    _ = zgui.sliderFloat("speed jitter (%)", .{ .v = &turret_settings.speed_jitter, .min = 0.0, .max = 30.0 });
}
