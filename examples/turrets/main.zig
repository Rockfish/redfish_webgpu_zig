//! Turret test bed (plan 008): turrets aim at a target flying a loop over the floor and
//! fire tracers or mortar shells at it. Each turret starts as its type in turret_types.zig;
//! the panel changes its pattern (or program), slew style and speeds, fire policy, cadence,
//! and weapon, to compare how they look:
//!
//! - "gatling": rate-limited slew (a motor-driven mount), fires while turning, a steady
//!   stream with wide jitter, no lead.
//! - "cannon": damped slew (snaps and settles), fires only once aligned, in bursts, tight
//!   jitter, with lead.
//! - "sweeper": sweeps a 20° arc either side of the target's bearing, firing a fan of
//!   shots while turning.
//! - "mortar": lobs finned rockets that get to where the target will be in a fixed flight
//!   time and burst there (in the air, or on the ground with a burn mark).
//! - "battery": a program: sweep for 3 s, two mortar rounds, a 1 s pause, repeat.
//! - "ball turret": one body turning freely toward the target (`motion.dampLookAt`).
//!
//! Lines: the target's route (gold); each turret's aim from the muzzle, green on target,
//! yellow turning; with lead, the target to the lead point (magenta); a sweep's arc as its
//! two ends (cyan); a mortar's predicted arc (orange). The target flashes white on each
//! hit.
//!
//! Keys: arrows circle the camera, W / S move it in and out, Space pauses (the camera and
//! panel still work), Escape quits.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const BallTurret = @import("ball_turret.zig").BallTurret;
const explosions_module = @import("explosions.zig");
const projectiles = @import("projectiles.zig");
const turret_module = @import("turret.zig");
const turret_types = @import("turret_types.zig");

const Arenas = core.Arenas;
const Camera = core.Camera;
const DrawUniforms = core.DrawUniforms;
const ExplosionShapes = explosions_module.ExplosionShapes;
const Explosions = explosions_module.Explosions;
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
const Step = turret_module.Step;
const TargetState = turret_module.TargetState;
const Turret = turret_module.Turret;
const TurretShapes = turret_module.TurretShapes;
const TurretType = turret_module.TurretType;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const degrees = std.math.radiansToDegrees;
const radians = std.math.degreesToRadians;

const CLEAR_COLOR = [4]f64{ 0.05, 0.06, 0.08, 1.0 };
const FLOOR_COLOR = vec4(0.4, 0.42, 0.45, 1.0);

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

/// A turret of a type, standing at a place.
const Placement = struct {
    turret_type: *const TurretType,
    position: Vec3,
};

const placements = [_]Placement{
    .{ .turret_type = &turret_types.gatling, .position = vec3(-5.0, 0.0, 2.0) },
    .{ .turret_type = &turret_types.cannon, .position = vec3(5.0, 0.0, 2.0) },
    .{ .turret_type = &turret_types.sweeper, .position = vec3(0.0, 0.0, -6.0) },
    .{ .turret_type = &turret_types.mortar, .position = vec3(10.0, 0.0, -3.0) },
    .{ .turret_type = &turret_types.battery, .position = vec3(-2.0, 0.0, 8.0) },
};
const TURRET_COUNT = placements.len;
const BALL_TURRET_POSITION = vec3(5.0, 0.0, 9.0);

/// Line segments drawn along the target's route.
const PATH_LINE_SEGMENTS = 200;
/// Aim lines per turret: the aim ray, and the lead line or the sweep's two ends.
const AIM_LINES_PER_TURRET = 3;
/// A mortar's aim ray; its arc shows where the shell goes.
const MORTAR_AIM_RAY_LENGTH: f32 = 3.0;
/// Line segments along a mortar's predicted arc.
const ARC_LINE_SEGMENTS = 24;
/// How fast the target's acceleration estimate settles, per second: smooths the jumps
/// where the route's curve changes at a waypoint.
const ACCELERATION_SMOOTHING: f32 = 10.0;
/// How fast the hit flash fades, per second.
const FLASH_DECAY: f32 = 6.0;

/// The panel's choices (a combo needs an i32-backed enum).
const SlewStyle = enum(i32) { rate_limited, damped };
const FirePolicy = enum(i32) { while_turning, when_aligned };
const CadenceKind = enum(i32) { rate, bursts };
const PatternKind = enum(i32) { track, sweep, mortar, wait, program };
/// A sweep's center or pitch: follow the target, or a fixed angle.
const SweepAngle = enum(i32) { target, fixed };

/// One turret's panel settings, in panel units (degrees, percent). They start from the
/// turret's type and are applied to the turret each frame.
const TurretSettings = struct {
    name: [:0]const u8,
    fire: bool = true,
    pattern: PatternKind = .track,
    /// The type's program, if it has one.
    program_steps: ?[]const Step = null,
    /// For `track` and `mortar`.
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
    /// For `mortar`: seconds from launch to burst.
    flight_time: f32 = 1.6,
    blast_radius: f32 = 2.0,
    /// Degrees per second about the nose.
    shell_spin: f32 = 0.0,
    slew: SlewStyle = .rate_limited,
    /// Degrees per second, for `rate_limited`.
    yaw_speed: f32 = 90.0,
    pitch_speed: f32 = 60.0,
    /// Approach rates per second, for `damped`.
    yaw_rate: f32 = 4.0,
    pitch_rate: f32 = 4.0,
    policy: FirePolicy = .while_turning,
    /// Degrees, for `when_aligned`.
    tolerance: f32 = 2.0,
    cadence: CadenceKind = .rate,
    /// Shots per second.
    rate: f32 = 10.0,
    burst_count: i32 = 3,
    /// Seconds.
    burst_interval: f32 = 0.12,
    burst_pause: f32 = 1.0,
    /// Units per second.
    speed: f32 = 30.0,
    /// Degrees.
    aim_jitter: f32 = 1.0,
    /// Percent.
    speed_jitter: f32 = 5.0,

    /// The panel's values for a turret of `turret_type`.
    fn fromType(turret_type: TurretType) TurretSettings {
        var settings: TurretSettings = .{
            .name = turret_type.name,
            .program_steps = turret_type.program,
            .speed = turret_type.weapon.speed,
            .aim_jitter = degrees(turret_type.weapon.jitter.aim),
            .speed_jitter = turret_type.weapon.jitter.speed * 100.0,
            .blast_radius = turret_type.weapon.blast_radius,
            .shell_spin = degrees(turret_type.weapon.shell_spin),
        };
        switch (turret_type.aim.slew) {
            .rate_limited => |speeds| {
                settings.slew = .rate_limited;
                settings.yaw_speed = degrees(speeds.yaw_speed);
                settings.pitch_speed = degrees(speeds.pitch_speed);
            },
            .damped => |rates| {
                settings.slew = .damped;
                settings.yaw_rate = rates.yaw_rate;
                settings.pitch_rate = rates.pitch_rate;
            },
        }
        settings.readFire(turret_type.fire);
        settings.readPattern(turret_type.pattern);
        if (turret_type.program != null) {
            settings.pattern = .program;
        }
        return settings;
    }

    fn readFire(self: *TurretSettings, fire: turret_module.FireSettings) void {
        switch (fire.policy) {
            .while_turning => self.policy = .while_turning,
            .when_aligned => |tolerance| {
                self.policy = .when_aligned;
                self.tolerance = degrees(tolerance);
            },
        }
        switch (fire.cadence) {
            .rate => |rate| {
                self.cadence = .rate;
                self.rate = rate;
            },
            .bursts => |bursts| {
                self.cadence = .bursts;
                self.burst_count = @intCast(bursts.count);
                self.burst_interval = bursts.interval;
                self.burst_pause = bursts.pause;
            },
        }
    }

    fn readPattern(self: *TurretSettings, pattern: turret_module.Pattern) void {
        switch (pattern) {
            .track => |track| {
                self.pattern = .track;
                self.lead = track.lead;
            },
            .sweep => |sweep| {
                self.pattern = .sweep;
                self.sweep_half_width = degrees(sweep.swing.half_width);
                self.sweep_speed = degrees(sweep.swing.speed);
                self.sweep_center = if (sweep.center_yaw != null) .fixed else .target;
                self.sweep_heading = degrees(sweep.center_yaw orelse 0.0);
                self.sweep_pitch = if (sweep.pitch != null) .fixed else .target;
                self.sweep_pitch_angle = degrees(sweep.pitch orelse radians(10.0));
            },
            .mortar => |mortar| {
                self.pattern = .mortar;
                self.flight_time = mortar.flight_time;
                self.lead = mortar.lead;
            },
            .wait => self.pattern = .wait,
        }
    }

    /// Slew and weapon always; under a program the program sets the pattern and fire
    /// settings, otherwise the panel does.
    fn apply(self: TurretSettings, turret: *Turret) void {
        turret.aim.slew = switch (self.slew) {
            .rate_limited => .{ .rate_limited = .{ .yaw_speed = radians(self.yaw_speed), .pitch_speed = radians(self.pitch_speed) } },
            .damped => .{ .damped = .{ .yaw_rate = self.yaw_rate, .pitch_rate = self.pitch_rate } },
        };
        turret.weapon.speed = self.speed;
        turret.weapon.jitter = .{ .aim = radians(self.aim_jitter), .speed = self.speed_jitter / 100.0 };
        turret.weapon.blast_radius = self.blast_radius;
        turret.weapon.shell_spin = radians(self.shell_spin);

        if (self.pattern == .program) {
            self.applyProgram(turret);
            return;
        }
        if (turret.program != null) {
            turret.runProgram(null);
        }
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
        turret.pattern = switch (self.pattern) {
            .track => .{ .track = .{ .lead = self.lead } },
            .sweep => .{ .sweep = .{
                .swing = self.swing(turret.pattern),
                .center_yaw = if (self.sweep_center == .fixed) radians(self.sweep_heading) else null,
                .pitch = if (self.sweep_pitch == .fixed) radians(self.sweep_pitch_angle) else null,
            } },
            .mortar => .{ .mortar = .{ .flight_time = self.flight_time, .lead = self.lead } },
            .wait => .wait,
            .program => unreachable,
        };
    }

    /// Starts the type's program if it isn't running; a type without one waits.
    fn applyProgram(self: TurretSettings, turret: *Turret) void {
        if (turret.program != null) {
            return;
        }
        if (self.program_steps) |steps| {
            turret.runProgram(.{ .steps = steps });
        } else {
            turret.pattern = .wait;
        }
    }

    /// The swing with this frame's width and speed, going on from where it is if the turret
    /// is already sweeping.
    fn swing(self: TurretSettings, current: turret_module.Pattern) motion.Sweep {
        var result: motion.Sweep = switch (current) {
            .sweep => |sweep| sweep.swing,
            .track, .mortar, .wait => .{ .half_width = 0.0, .speed = 0.0 },
        };
        result.half_width = radians(self.sweep_half_width);
        result.speed = radians(self.sweep_speed);
        return result;
    }
};

/// The ball turret's panel settings, applied each frame.
const BallSettings = struct {
    fire: bool = true,
    lead: bool = true,
    /// Per second (`dampLookAt`).
    turn_rate: f32 = 6.0,
    /// Degrees.
    tolerance: f32 = 4.0,
    /// Shots per second.
    rate: f32 = 8.0,

    fn apply(self: BallSettings, ball: *BallTurret) void {
        ball.turn_rate = self.turn_rate;
        ball.lead = self.lead;
        ball.fire_control.policy = .{ .when_aligned = radians(self.tolerance) };
        ball.fire_control.cadence = .{ .rate = self.rate };
    }
};

/// Everything the panel changes.
const Settings = struct {
    /// Units per second along the target's route.
    target_speed: f32 = 5.0,
    show_path: bool = true,
    show_aim: bool = true,
    /// Everything but the camera and the panel stands still.
    paused: bool = false,
    turrets: [TURRET_COUNT]TurretSettings,
    ball: BallSettings = .{},
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

    // The same shaders with their override constants set: lit rockets, unlit fireballs
    const rocket_shader = try Shader.init(context.io, context.alloc, gpu, "examples/turrets/shaders/projectiles.wgsl", .{
        .vertex_buffers = &projectiles.InstanceLayouts.layouts,
        .constants = &.{.{ .key = "LIT", .value = 1.0 }},
    });
    defer rocket_shader.releaseGpuObjects();

    const flash_shader = try Shader.init(context.io, context.alloc, gpu, "examples/turrets/shaders/basic_shape.wgsl", .{
        .vertex_buffers = &Shape.vertex_buffer_layouts,
        .constants = &.{.{ .key = "UNLIT", .value = 1.0 }},
    });
    defer flash_shader.releaseGpuObjects();

    const lines_shader = try Shader.init(context.io, context.alloc, gpu, "examples/turrets/shaders/lines.wgsl", .{
        .vertex_buffers = &Lines.vertex_buffer_layouts,
        .topology = .line_list,
    });
    defer lines_shader.releaseGpuObjects();
    var path_lines = try Lines.init(context.alloc, lines_shader, 1.0, 1.0, PATH_LINE_SEGMENTS);
    // One more aim ray for the ball turret
    var aim_lines = try Lines.init(context.alloc, lines_shader, 1.0, 1.0, TURRET_COUNT * AIM_LINES_PER_TURRET + 1);
    var arc_lines = try Lines.init(context.alloc, lines_shader, 1.0, 1.0, TURRET_COUNT * ARC_LINE_SEGMENTS);

    var scene_shapes: SceneShapes = try .init(context, gpu);
    defer scene_shapes.releaseGpuObjects();
    var turret_shapes: TurretShapes = try .init(context, gpu);
    defer turret_shapes.releaseGpuObjects();
    var explosion_shapes: ExplosionShapes = try .init(context, gpu);
    defer explosion_shapes.releaseGpuObjects();

    const camera = try Camera.init(context.alloc, .{
        // Off to the left, so the scene sits right of the panel
        .position = vec3(-5.0, 12.0, 18.0),
        .target = vec3(-5.0, 1.0, -1.0),
        .scr_width = @floatFromInt(gpu.width),
        .scr_height = @floatFromInt(gpu.height),
    });

    var settings: Settings = .{ .turrets = undefined };
    var turrets: [TURRET_COUNT]Turret = undefined;
    for (placements, &turrets, &settings.turrets) |placement, *turret, *turret_settings| {
        turret.* = .init(placement.turret_type.*, placement.position);
        turret_settings.* = .fromType(placement.turret_type.*);
    }
    var ball = createBallTurret();
    var random = Random.init();
    var explosions: Explosions = .{ .floor_color = FLOOR_COLOR };

    var target_path: motion.PathFollow = .{ .points = &target_waypoints, .speed = 0.0, .shape = .catmull_rom, .repeat = .loop };
    var flash: f32 = 0.0;
    var target_motion: TargetMotion = .{};
    var target: TargetState = .{
        .position = target_path.position(),
        .velocity = Vec3.Zero,
        .acceleration = Vec3.Zero,
        .radius = TARGET_RADIUS,
    };
    var space_was_down = false;

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

        // Pause on each Space press, not each frame it's held
        const space_down = window.getKey(.space) == .press and !zgui.io.getWantCaptureKeyboard();
        if (space_down and !space_was_down) {
            settings.paused = !settings.paused;
        }
        space_was_down = space_down;

        processKeys(window, camera, delta_time);

        if (!settings.paused) {
            target_path.speed = settings.target_speed;
            const position = target_path.update(delta_time);
            const velocity = target_path.tangent().mulScalar(settings.target_speed);
            target = .{
                .position = position,
                .velocity = velocity,
                .acceleration = target_motion.update(velocity, delta_time),
                .radius = TARGET_RADIUS,
            };

            const hits_before = totalHits(&turrets, &ball);
            for (&turrets, settings.turrets) |*turret, turret_settings| {
                turret_settings.apply(turret);
                turret.update(delta_time, target, turret_settings.fire, &random, &explosions);
            }
            settings.ball.apply(&ball);
            ball.update(delta_time, target, settings.ball.fire, &random, &explosions);
            explosions.update(delta_time);
            flash = if (totalHits(&turrets, &ball) > hits_before) 1.0 else flash * (1.0 - motion.dampAlpha(FLASH_DECAY, delta_time));
        }

        var frame = gpu.acquireFrame() orelse continue;

        camera.setScreenDimensions(@floatFromInt(gpu.width), @floatFromInt(gpu.height));
        gpu.writeFrameUniforms(camera.getRenderContext(time).frameUniforms());

        frame.beginSurfacePass(CLEAR_COLOR);
        scene_shapes.floor.draw(&frame, shape_shader, DrawUniforms.init(Mat4.fromTranslation(vec3(0.0, -0.1, 0.0)), FLOOR_COLOR));
        const target_color = vec4(1.0, 0.35, 0.1, 1.0).lerp(Vec4.One, flash);
        scene_shapes.target.draw(&frame, shape_shader, DrawUniforms.init(Mat4.fromTranslation(target.position), target_color));
        for (&turrets) |*turret| {
            turret.draw(&frame, shape_shader, &turret_shapes);
            turret.drawProjectiles(&frame, projectile_shader, rocket_shader, &turret_shapes);
        }
        ball.draw(&frame, shape_shader, &turret_shapes);
        ball.drawProjectiles(&frame, projectile_shader, &turret_shapes);
        explosions.draw(&frame, flash_shader, shape_shader, &explosion_shapes);
        if (settings.show_path) {
            drawPath(&frame, &path_lines, target_path);
        }
        if (settings.show_aim) {
            drawAimLines(&frame, &aim_lines, &turrets, &ball, target);
            drawArcs(&frame, &arc_lines, &turrets);
        }

        gui.newFrame();
        drawPanel(&settings, &turrets, &ball);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

/// The target's acceleration, estimated from how its velocity changes each frame and
/// smoothed (`dampVec3`).
const TargetMotion = struct {
    previous_velocity: ?Vec3 = null,
    acceleration: Vec3 = Vec3.Zero,

    fn update(self: *TargetMotion, velocity: Vec3, dt: f32) Vec3 {
        if (self.previous_velocity) |previous| {
            if (dt > 0.0) {
                const measured = velocity.sub(previous).mulScalar(1.0 / dt);
                self.acceleration = motion.dampVec3(self.acceleration, measured, ACCELERATION_SMOOTHING, dt);
            }
        }
        self.previous_velocity = velocity;
        return self.acceleration;
    }
};

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

/// The ball turret: turns fast, fires once within its tolerance, with lead. The panel's
/// `BallSettings` sets its turn rate and fire settings each frame.
fn createBallTurret() BallTurret {
    return .{
        .position = BALL_TURRET_POSITION,
        .turn_rate = 6.0,
        .lead = true,
        .fire_control = .{},
        .weapon = .{
            .speed = 35.0,
            .jitter = .{ .aim = radians(0.8), .speed = 0.03 },
            .tracer_color = vec4(1.0, 1.0, 0.6, 1.0),
        },
        .color = vec4(0.6, 0.6, 0.65, 1.0),
    };
}

fn totalHits(turrets: []const Turret, ball: *const BallTurret) u32 {
    var hits: u32 = ball.tracers.hits;
    for (turrets) |turret| {
        hits += turret.hits();
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
fn drawAimLines(frame: *const Frame, lines: *Lines, turrets: []const Turret, ball: *const BallTurret, target: TargetState) void {
    var segments: [TURRET_COUNT * AIM_LINES_PER_TURRET + 1]LineSegment = undefined;
    var count: usize = 0;
    for (turrets) |*turret| {
        const muzzle = turret.muzzle();
        // A lob's aim points up its launch velocity, not at the target: keep its ray short
        const reach = if (turret.launch_velocity != null) MORTAR_AIM_RAY_LENGTH else turret.aim_point.sub(muzzle).length();
        segments[count] = .{
            .start = muzzle,
            .end = muzzle.add(turret.aim.direction().mulScalar(reach)),
            .color = if (turret.isOnTarget()) .green else .yellow,
        };
        count += 1;

        const is_leading = switch (turret.pattern) {
            .track => |track| track.lead,
            .sweep, .wait => false,
            .mortar => |mortar| mortar.lead,
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

    const ball_muzzle = ball.muzzle();
    segments[count] = .{
        .start = ball_muzzle,
        .end = ball_muzzle.add(ball.rotation.forward().mulScalar(ball.aim_point.sub(ball_muzzle).length())),
        .color = if (ball.isOnTarget()) .green else .yellow,
    };
    count += 1;
    lines.draw(frame, segments[0..count]);
}

/// Each mortar's predicted arc: where a shell fired now would fly, without jitter.
fn drawArcs(frame: *const Frame, lines: *Lines, turrets: []const Turret) void {
    var segments: [TURRET_COUNT * ARC_LINE_SEGMENTS]LineSegment = undefined;
    var count: usize = 0;
    for (turrets) |*turret| {
        const launch_velocity = turret.launch_velocity orelse continue;
        const flight_time = switch (turret.pattern) {
            .mortar => |mortar| mortar.flight_time,
            .track, .sweep, .wait => continue,
        };
        const muzzle = turret.muzzle();
        var previous = muzzle;
        for (1..ARC_LINE_SEGMENTS + 1) |i| {
            const time = flight_time * @as(f32, @floatFromInt(i)) / ARC_LINE_SEGMENTS;
            const point = core.ballistics.positionAt(muzzle, launch_velocity, turret_module.GRAVITY, time);
            segments[count] = .{ .start = previous, .end = point, .color = .orange };
            count += 1;
            previous = point;
        }
    }
    lines.draw(frame, segments[0..count]);
}

fn drawPanel(settings: *Settings, turrets: []const Turret, ball: *const BallTurret) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 340, .h = 740, .cond = .first_use_ever });
    if (zgui.begin("turrets", .{})) {
        zgui.text("frame time: {d:.2} ms", .{1000.0 / zgui.io.getFramerate()});
        zgui.text("arrows: circle camera   W / S: in / out", .{});
        zgui.text("Space: pause", .{});
        _ = zgui.checkbox("paused", .{ .v = &settings.paused });

        zgui.separatorText("Target");
        _ = zgui.sliderFloat("speed", .{ .v = &settings.target_speed, .min = 0.0, .max = 15.0 });
        _ = zgui.checkbox("show path", .{ .v = &settings.show_path });
        _ = zgui.checkbox("show aim", .{ .v = &settings.show_aim });

        for (&settings.turrets, turrets, 0..) |*turret_settings, *turret, i| {
            zgui.pushIntId(@intCast(i));
            if (zgui.collapsingHeader(turret_settings.name, .{})) {
                drawTurretSettings(turret_settings, turret);
            }
            zgui.popId();
        }
        if (zgui.collapsingHeader("ball turret", .{})) {
            drawBallSettings(&settings.ball, ball);
        }
    }
    zgui.end();
}

fn drawTurretSettings(turret_settings: *TurretSettings, turret: *const Turret) void {
    zgui.text("hits: {d}   in flight: {d}", .{ turret.hits(), turret.inFlight() });
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
        .mortar => {
            _ = zgui.checkbox("lead", .{ .v = &turret_settings.lead });
            _ = zgui.sliderFloat("flight time (s)", .{ .v = &turret_settings.flight_time, .min = 0.8, .max = 5.0 });
            _ = zgui.sliderFloat("blast radius", .{ .v = &turret_settings.blast_radius, .min = 0.5, .max = 5.0 });
            _ = zgui.sliderFloat("spin (deg/s)", .{ .v = &turret_settings.shell_spin, .min = 0.0, .max = 720.0 });
        },
        .wait => {},
        .program => drawProgramStatus(turret),
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

    // A program sets its steps' fire settings
    if (turret_settings.pattern != .program) {
        drawFireSettings(turret_settings);
    }

    // A mortar's shell speed comes from its flight time
    if (turret_settings.pattern != .mortar) {
        _ = zgui.sliderFloat("shot speed", .{ .v = &turret_settings.speed, .min = 5.0, .max = 80.0 });
    }
    _ = zgui.sliderFloat("aim jitter (deg)", .{ .v = &turret_settings.aim_jitter, .min = 0.0, .max = 10.0 });
    _ = zgui.sliderFloat("speed jitter (%)", .{ .v = &turret_settings.speed_jitter, .min = 0.0, .max = 30.0 });
}

fn drawFireSettings(turret_settings: *TurretSettings) void {
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
}

/// The program's steps, the running one marked, with its progress.
fn drawProgramStatus(turret: *const Turret) void {
    const program = turret.program orelse {
        zgui.text("(this type has no program)", .{});
        return;
    };
    for (program.steps, 0..) |step, i| {
        const marker: []const u8 = if (i == program.index) ">" else " ";
        const name = @tagName(step.pattern);
        switch (step.until) {
            .seconds => |seconds| zgui.text("{s} {s}: {d:.1} / {d:.1} s", .{ marker, name, if (i == program.index) program.elapsed else 0.0, seconds }),
            .shots => |shots| zgui.text("{s} {s}: {d} / {d} shots", .{ marker, name, if (i == program.index) program.shots else 0, shots }),
        }
    }
}

fn drawBallSettings(ball_settings: *BallSettings, ball: *const BallTurret) void {
    zgui.text("hits: {d}   in flight: {d}", .{ ball.tracers.hits, ball.tracers.count });
    zgui.text("one body, aimed with dampLookAt", .{});
    _ = zgui.checkbox("fire", .{ .v = &ball_settings.fire });
    _ = zgui.checkbox("lead", .{ .v = &ball_settings.lead });
    _ = zgui.sliderFloat("turn rate", .{ .v = &ball_settings.turn_rate, .min = 0.5, .max = 20.0 });
    _ = zgui.sliderFloat("tolerance (deg)", .{ .v = &ball_settings.tolerance, .min = 0.1, .max = 15.0 });
    _ = zgui.sliderFloat("shots/s", .{ .v = &ball_settings.rate, .min = 0.5, .max = 30.0 });
}
