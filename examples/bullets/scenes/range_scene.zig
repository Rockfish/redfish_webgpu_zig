//! The turret range (docs/reviews/2026-10-04-link-style-controller-review.md sections 11
//! and 5.5, phases C and D): a field with turrets of several sizes, the captain (the toon
//! soldier) at one end with the follow camera. LT (or F) holds first person: the left
//! stick moves, the right stick aims, RT (or the left mouse button) fires tracers. The
//! squad (phases E and F) follows the captain and, after a couple of his shots at one
//! spot, fires at it too.
//!
//! The turrets fire back (plan 019 phase G1, T toggles): slowly, so the player can react.
//! Each watches the ground within its detection range (a faint ring, brighter while it
//! has someone) and fires only at people inside it. Gun turrets traverse slowly toward
//! the captain or a squad member and fire as they turn; mortar shells hang in the air for
//! seconds, with a warning ring where they'll land. A hit on the captain shakes the
//! camera; a hit on a member makes it flinch. Blasts, hits, near misses, and incoming
//! shells frighten the squad (phase G2): frightened members scatter, then regroup.

const std = @import("std");
const zgui = @import("zgui");
const core = @import("core");
const math = @import("math");

const Context = core.Context;
const Scene = @import("../scene.zig").Scene;
const SceneCamera = @import("../scene_camera.zig").SceneCamera;
const FreeCamera = @import("../objects/free_camera.zig").FreeCamera;
const Floor = @import("../objects/floor.zig").Floor;
const scene_lights = @import("../objects/lights.zig");
const ToonSoldier = @import("../objects/toon_soldier.zig").ToonSoldier;
const target_turret = @import("../objects/target_turret.zig");
const TargetTurret = target_turret.TargetTurret;
const range_turret_types = @import("../objects/range_turret_types.zig");
const ShellWarnings = @import("../objects/shell_warnings.zig").ShellWarnings;
const FirstPerson = @import("../objects/first_person.zig").FirstPerson;
const squad_module = @import("../objects/squad.zig");
const Squad = squad_module.Squad;
const character_control = @import("../objects/character_control.zig");

const gameplay = core.gameplay;
const projectiles = gameplay.projectiles;
const Explosions = gameplay.Explosions;
const ExplosionShapes = gameplay.ExplosionShapes;
const FireControl = gameplay.FireControl;
const Projectiles = projectiles.Projectiles;
const ShotJitter = gameplay.ShotJitter;
const TurretShapes = gameplay.TurretShapes;
const TurretType = gameplay.turret.TurretType;
const TargetState = gameplay.turret.TargetState;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Random = core.Random;
const ResourceManager = core.ResourceManager;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const motion = core.motion;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;

const basic_lights = scene_lights.basic_lights;
const deg = std.math.degreesToRadians;

/// Where the captain starts, facing the turrets (down -Z).
const CAPTAIN_START = vec3(0.0, 0.0, 8.0);
/// A person as the turrets see them: a sphere this high above the feet, this big.
const PERSON_HIT_HEIGHT: f32 = 1.0;
const PERSON_HIT_RADIUS: f32 = 0.45;
/// Everyone the turrets shoot at: the captain (person 0), then the squad.
const PEOPLE = squad_module.SIZE + 1;
/// The camera shake's trauma (`motion.Shake`) when a tracer strikes the captain, and
/// when a shell's blast catches him. A blast that misses him still shakes the camera,
/// less the farther it is, out to `NEAR_MISS_REACH` blast radii beyond its edge.
const TRACER_TRAUMA: f32 = 0.3;
const BLAST_TRAUMA: f32 = 0.8;
const NEAR_MISS_REACH: f32 = 2.0;
/// A detection range's ring: its width as a fraction of the range, its height above the
/// floor, and its colors with nobody inside and with someone.
const RANGE_RING_WIDTH: f32 = 0.012;
const RANGE_RING_LIFT: f32 = 0.03;
const RANGE_IDLE_COLOR = vec4(0.38, 0.3, 0.22, 1.0);
const RANGE_ACTIVE_COLOR = vec4(0.85, 0.3, 0.12, 1.0);
/// The color burn marks fade into: about the floor's.
const FLOOR_COLOR = vec4(0.32, 0.31, 0.29, 1.0);

/// The captain's tracers: meters per second, seconds before they're dropped, damage per
/// hit.
const TRACER_SPEED: f32 = 80.0;
const TRACER_LIFETIME: f32 = 1.5;
const TRACER_DAMAGE: f32 = 1.0;
const TRACER_COLOR = vec4(1.0, 0.85, 0.4, 1.0);
/// The squad's tracers, a redder yellow so the captain's own stand out.
const SQUAD_TRACER_COLOR = vec4(1.0, 0.55, 0.25, 1.0);
/// Shots leave from below and right of the eye (where the gun would be), so they're seen
/// flying instead of shrinking to a dot, aimed at what the crosshair is on.
const MUZZLE_OFFSET = vec3(0.18, -0.2, 0.0);
/// Where shots aim when the crosshair is on nothing (the sky), meters out.
const SKY_AIM_DISTANCE: f32 = 100.0;
/// A tracer's puff on the floor.
const FLOOR_PUFF_RADIUS: f32 = 0.1;

/// What the crosshair is on.
const CrosshairAim = struct {
    point: Vec3,
    /// The turret it's on (an index into `turrets`), if any.
    target: ?usize,
    /// False when it's on nothing (the sky): `point` is just far out along the view.
    is_on_something: bool,
};

const Placement = struct {
    turret_type: *const TurretType,
    position: Vec3,
    size: f32,
    /// Meters around it that it watches and fires into.
    detection_range: f32,
};

const placements = [_]Placement{
    .{ .turret_type = &range_turret_types.gatling, .position = vec3(-6.0, 0.0, -10.0), .size = 0.6, .detection_range = 14.0 },
    .{ .turret_type = &range_turret_types.cannon, .position = vec3(5.0, 0.0, -14.0), .size = 1.0, .detection_range = 16.0 },
    .{ .turret_type = &range_turret_types.sweeper, .position = vec3(-13.0, 0.0, -22.0), .size = 1.5, .detection_range = 18.0 },
    .{ .turret_type = &range_turret_types.mortar, .position = vec3(13.0, 0.0, -26.0), .size = 2.0, .detection_range = 24.0 },
    .{ .turret_type = &range_turret_types.gatling, .position = vec3(-22.0, 0.0, -34.0), .size = 1.0, .detection_range = 16.0 },
    .{ .turret_type = &range_turret_types.battery, .position = vec3(2.0, 0.0, -40.0), .size = 3.0, .detection_range = 24.0 },
};

pub const RangeScene = struct {
    resource_manager: *ResourceManager,
    scene_camera: *SceneCamera,
    floor: Floor,
    captain: *ToonSoldier,
    squad: Squad,
    follow: motion.FollowCamera,
    first_person: FirstPerson = .{},
    /// How the captain moves (K switches, or the soldier panel).
    control_style: character_control.Style = .wind_waker,
    shape_shader: *Shader,
    flash_shader: *Shader,
    tracer_shader: *Shader,
    rocket_shader: *Shader,
    turret_shapes: TurretShapes,
    explosion_shapes: ExplosionShapes,
    explosions: Explosions = .{ .floor_color = FLOOR_COLOR },
    turrets: [placements.len]TargetTurret,
    fire_back: target_turret.FireBack = .{},
    shell_warnings: ShellWarnings,
    /// A thin unit ring for the turrets' detection ranges.
    range_ring: *Shape,
    show_ranges: bool = true,
    /// The captain's hits as a camera shake, and this frame's offset from it.
    shake: motion.Shake = .{ .decay = 1.5, .max_offset = 0.25, .max_angle = 0.05 },
    shake_offset: motion.Shake.Offset = .none,
    tracers: Projectiles = .{},
    fire_control: FireControl = .{ .cadence = .{ .rate = 6.0 } },
    jitter: ShotJitter = .{ .aim = deg(0.6), .speed = 0.03 },
    random: Random,
    shots_fired: u32 = 0,
    hits: u32 = 0,
    squad_hits: u32 = 0,
    /// The turrets' hits on the captain and on squad members.
    captain_hits: u32 = 0,
    member_hits: u32 = 0,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, input: *core.Input) !*Scene {
        const rm = try ResourceManager.init(context, gpu);
        const camera = try FreeCamera.init(context.alloc, input.framebuffer_width, input.framebuffer_height);

        const captain = try ToonSoldier.init(rm, .soldier, .ShortCannon, true);
        captain.transform.translation = CAPTAIN_START;
        captain.transform.rotation = Quat.fromAxisAngle(Vec3.Y, std.math.pi);

        var random = Random.init();
        const squad = try Squad.init(rm, captain.transform, &random);

        var turrets: [placements.len]TargetTurret = undefined;
        for (placements, &turrets) |placement, *turret| {
            turret.* = .init(placement.turret_type.*, placement.position, placement.size, placement.detection_range);
        }

        var floor = try Floor.init(rm);
        floor.plane.shape.is_visible = true;

        const scene = try context.alloc.create(Self);
        scene.* = .{
            .resource_manager = rm,
            .scene_camera = camera,
            .floor = floor,
            .captain = captain,
            .squad = squad,
            .follow = .init(captain.transform.translation, character_control.facingYaw(captain.transform)),
            .shape_shader = try rm.createShader("src/core/shaders/basic_shape.wgsl", .{
                .vertex_buffers = &Shape.vertex_buffer_layouts,
            }),
            .flash_shader = try rm.createShader("src/core/shaders/basic_shape.wgsl", .{
                .vertex_buffers = &Shape.vertex_buffer_layouts,
                .constants = &.{.{ .key = "UNLIT", .value = 1.0 }},
            }),
            .tracer_shader = try rm.createShader("src/core/shaders/projectiles.wgsl", .{
                .vertex_buffers = &projectiles.InstanceLayouts.layouts,
            }),
            .rocket_shader = try rm.createShader("src/core/shaders/projectiles.wgsl", .{
                .vertex_buffers = &projectiles.InstanceLayouts.layouts,
                .constants = &.{.{ .key = "LIT", .value = 1.0 }},
            }),
            .turret_shapes = try .init(context, gpu),
            .explosion_shapes = try .init(context, gpu),
            .turrets = turrets,
            .shell_warnings = try .init(context, gpu),
            .range_ring = try core.shapes.createRing(context.alloc, gpu, 1.0 - RANGE_RING_WIDTH, 1.0, 96),
            .random = random,
        };
        return try Scene.init(context.alloc, "Range", scene, input);
    }

    pub fn cleanUp(self: *Self) void {
        self.turret_shapes.releaseGpuObjects();
        self.explosion_shapes.releaseGpuObjects();
        self.shell_warnings.releaseGpuObjects();
        self.range_ring.releaseGpuObjects();
        self.floor.cleanUp();
        self.resource_manager.cleanUp();
    }

    pub fn update(self: *Self, input: *core.Input) !void {
        const dt = input.delta_time;
        try self.scene_camera.update(input);
        try self.captain.update(input.delta_time);

        try self.controlCaptain(input);
        try self.squad.update(self.captain.transform, self.captain.motor.speed, &self.random, dt);
        self.processKeys(input);
        self.placeCamera(input);
        self.fire(input);

        self.updateTurrets(dt);
        self.moveTracers(dt);
        self.explosions.update(dt);
        self.shake_offset = self.shake.update(dt);
    }

    /// Camera (shaken by the captain's hits) and basic_lights go to the frame uniforms;
    /// objects draw with them.
    pub fn draw(self: *Self, frame: *const Frame, time: f32) void {
        const render_context = self.shake_offset.apply(self.scene_camera.getCamera().getRenderContext(time));
        var frame_uniforms = render_context.frameUniforms();
        frame_uniforms.lights = basic_lights.uniforms();
        frame.gpu.writeFrameUniforms(frame_uniforms);

        if (self.show_ranges) {
            self.drawDetectionRanges(frame);
        }
        for (&self.turrets) |*turret| {
            turret.draw(frame, self.shape_shader, &self.turret_shapes);
            turret.drawProjectiles(frame, self.tracer_shader, self.rocket_shader, &self.turret_shapes);
            self.shell_warnings.draw(frame, self.flash_shader, &turret.turret.shells);
        }
        self.captain.draw(frame);
        self.squad.draw(frame);
        const tracer_parts = [_]projectiles.Part{.{ .shape = self.turret_shapes.tracer, .model = Mat4.Identity, .color = TRACER_COLOR }};
        self.tracers.draw(frame, self.tracer_shader, &tracer_parts);
        const squad_tracer_parts = [_]projectiles.Part{.{ .shape = self.turret_shapes.tracer, .model = Mat4.Identity, .color = SQUAD_TRACER_COLOR }};
        self.squad.tracers.draw(frame, self.tracer_shader, &squad_tracer_parts);
        self.explosions.draw(frame, self.flash_shader, self.shape_shader, &self.explosion_shapes);
        self.floor.draw(frame);
    }

    /// The soldier's panel, the range's (each turret's health, shots, reset), and the
    /// crosshair in first person.
    pub fn drawGui(self: *Self) void {
        self.captain.drawGui(&self.control_style);
        self.squad.drawGui();
        self.drawRangePanel();
        if (self.first_person.hidesModel()) {
            drawCrosshair();
        }
    }

    pub fn getSceneCamera(self: *Self) *SceneCamera {
        return self.scene_camera;
    }

    /// In first person the captain strafes, facing the view; otherwise the follow-camera
    /// control.
    fn controlCaptain(self: *Self, input: *core.Input) !void {
        const held = input.gamepad.left_trigger > 0.5 or input.isDown(.f);
        const turn = character_control.cameraTurn(input);
        self.first_person.update(held, turn, character_control.facingYaw(self.captain.transform), input.delta_time);
        self.captain.visible = !self.first_person.hidesModel();

        if (self.first_person.active) {
            const yaw = self.first_person.yaw;
            const move = motion.cameraRelativeMove(character_control.moveStick(input), yaw);
            self.captain.strafe(move, character_control.headingOfYaw(yaw), input);
        } else {
            try character_control.control(self.captain, self.control_style, self.follow.yaw, input);
        }
    }

    /// The follow camera (behind the captain, along the aim, while in first person, so
    /// leaving it eases back to behind the captain), eased toward the eye.
    fn placeCamera(self: *Self, input: *core.Input) void {
        const position = self.captain.transform.translation;
        if (self.first_person.active) {
            self.follow.reset(position, self.first_person.yaw);
        } else {
            character_control.followCharacter(&self.follow, self.captain.transform, input.isDown(.q), input);
        }
        const view = self.first_person.view(self.follow.position, self.follow.focus, position);
        self.scene_camera.getCamera().movement.reset(view.position, view.focus);
    }

    /// RT or the left mouse button fires in first person, at the fire control's rate;
    /// each shot jittered a little.
    fn fire(self: *Self, input: *core.Input) void {
        const trigger = self.first_person.active and (input.gamepad.right_trigger > 0.5 or input.isMouseDown(.left));
        self.fire_control.update(input.delta_time, trigger, 0.0);

        const eye = FirstPerson.eye(self.captain.transform.translation);
        const direction = self.first_person.direction();
        const muzzle = eye.add(self.viewOffset(MUZZLE_OFFSET));
        const aim = self.crosshairAim(eye, direction);
        const toward = aim.point.sub(muzzle).toNormalized();
        while (self.fire_control.nextShot()) |age| {
            const shot = self.jitter.apply(&self.random, toward, TRACER_SPEED);
            self.tracers.spawn(muzzle, shot.direction.mulScalar(shot.speed), TRACER_LIFETIME, age);
            self.shots_fired += 1;
            if (aim.is_on_something) {
                self.squad.reportShot(aim.point, aim.target);
            }
        }
    }

    /// What the crosshair is on: the nearest point where the view's ray from `eye` meets a
    /// live turret's hit sphere or the floor; far out along it when it meets neither.
    fn crosshairAim(self: *const Self, eye: Vec3, direction: Vec3) CrosshairAim {
        var nearest: f32 = SKY_AIM_DISTANCE;
        var target: ?usize = null;
        var is_on_something = false;
        if (direction.y < 0.0 and -eye.y / direction.y < nearest) {
            nearest = -eye.y / direction.y;
            is_on_something = true;
        }
        for (self.turrets, 0..) |turret, index| {
            if (turret.destroyed) {
                continue;
            }
            const sphere = turret.hitSphere();
            if (raySphere(eye, direction, sphere.center, sphere.radius)) |distance| {
                if (distance < nearest) {
                    nearest = distance;
                    target = index;
                    is_on_something = true;
                }
            }
        }
        return .{ .point = eye.add(direction.mulScalar(nearest)), .target = target, .is_on_something = is_on_something };
    }

    /// `offset` (right, up, forward) in the view's frame.
    fn viewOffset(self: *const Self, offset: Vec3) Vec3 {
        const forward = self.first_person.direction();
        const right = forward.cross(Vec3.Y).toNormalized();
        const up = right.cross(forward);
        return right.mulScalar(offset.x).add(up.mulScalar(offset.y)).add(forward.mulScalar(offset.z));
    }

    /// The captain's and the squad's tracers fly on; one that strikes a turret hurts it,
    /// one that hits the floor puffs. A destroyed focus turret ends the squad's fire.
    fn moveTracers(self: *Self, dt: f32) void {
        self.hits += self.moveTracerPool(&self.tracers, dt);
        self.squad_hits += self.moveTracerPool(&self.squad.tracers, dt);
        if (self.squad.focus.target) |index| {
            if (self.turrets[index].destroyed) {
                self.squad.clearFocus();
            }
        }
    }

    /// Returns how many struck a turret.
    fn moveTracerPool(self: *Self, tracers: *Projectiles, dt: f32) u32 {
        var targets: [placements.len]projectiles.Target = undefined;
        var owners: [placements.len]*TargetTurret = undefined;
        var count: usize = 0;
        for (&self.turrets) |*turret| {
            if (turret.destroyed) {
                continue;
            }
            const sphere = turret.hitSphere();
            targets[count] = .{ .position = sphere.center, .radius = sphere.radius };
            owners[count] = turret;
            count += 1;
        }

        var endings: [projectiles.MAX_PROJECTILES]projectiles.Ending = undefined;
        var hits: u32 = 0;
        for (tracers.updateTargets(dt, targets[0..count], &self.explosions, &endings)) |ending| {
            if (ending.target) |index| {
                owners[index].hit(ending.position, TRACER_DAMAGE, &self.explosions);
                hits += 1;
            } else if (ending.grounded) {
                self.explosions.add(ending.position, FLOOR_PUFF_RADIUS);
            }
        }
        return hits;
    }

    /// The turrets aim at and fire on the captain and the squad; what their shots strike
    /// shakes the camera or makes members flinch.
    fn updateTurrets(self: *Self, dt: f32) void {
        const people = self.peopleTargets();
        var strikes: target_turret.Strikes = .{};
        for (&self.turrets) |*turret| {
            turret.update(dt, &people, self.fire_back, &self.random, &self.explosions, &strikes);
        }
        for (strikes.slice()) |strike| {
            self.takeStrike(strike, &people);
        }
        self.warnSquad(dt);
    }

    /// Members under an incoming shell's warning ring are frightened before it lands.
    fn warnSquad(self: *Self, dt: f32) void {
        for (&self.turrets) |*turret| {
            const shells = &turret.turret.shells;
            for (0..shells.count) |i| {
                self.squad.warn(shells.predictedEnd(i).position, shells.blast_radius, dt);
            }
        }
    }

    /// The captain (person 0) and the squad as the turrets see them.
    fn peopleTargets(self: *const Self) [PEOPLE]TargetState {
        var people: [PEOPLE]TargetState = undefined;
        for (&people, 0..) |*person, index| {
            const feet = if (index == 0) self.captain.transform.translation else self.squad.memberPosition(index - 1);
            person.* = .{
                .position = feet.add(vec3(0.0, PERSON_HIT_HEIGHT, 0.0)),
                .velocity = Vec3.Zero,
                .acceleration = Vec3.Zero,
                .radius = PERSON_HIT_RADIUS,
            };
        }
        return people;
    }

    /// A tracer hits the one it struck, or frightens members near where it struck the
    /// floor; a shell's blast hits everyone it reaches, frightens the squad around it,
    /// and shakes the camera a little when it misses the captain nearby.
    fn takeStrike(self: *Self, strike: target_turret.Strike, people: []const TargetState) void {
        if (strike.blast_radius == 0.0) {
            if (strike.person) |person| {
                self.hitPerson(person, strike, TRACER_TRAUMA);
            } else {
                self.squad.nearMiss(strike.position, strike.source, strike.source_range);
            }
            return;
        }
        self.squad.blast(strike.position, strike.blast_radius);
        for (people, 0..) |person, index| {
            const reach = strike.blast_radius + person.radius;
            const distance = person.position.sub(strike.position).length();
            if (distance < reach) {
                self.hitPerson(index, strike, BLAST_TRAUMA);
            } else if (index == 0) {
                const closeness = 1.0 - (distance - reach) / (NEAR_MISS_REACH * strike.blast_radius);
                self.shake.addTrauma(0.5 * BLAST_TRAUMA * std.math.clamp(closeness, 0.0, 1.0));
            }
        }
    }

    /// The captain's hit is a camera shake of `trauma`; a member's a flinch and a fright,
    /// from the turret that fired `strike`.
    fn hitPerson(self: *Self, index: usize, strike: target_turret.Strike, trauma: f32) void {
        if (index == 0) {
            self.shake.addTrauma(trauma);
            self.captain_hits += 1;
        } else {
            self.squad.hit(index - 1, strike.source, strike.source_range);
            self.member_hits += 1;
        }
    }

    /// Each live turret's detection range as a ring on the floor, brighter while it has
    /// someone in it.
    fn drawDetectionRanges(self: *const Self, frame: *const Frame) void {
        for (&self.turrets) |*turret| {
            if (turret.destroyed) {
                continue;
            }
            const range = turret.detectionRange(self.fire_back);
            const center = vec3(turret.home.x, RANGE_RING_LIFT, turret.home.z);
            const model = Mat4.fromTranslation(center).mulMat4(&Mat4.fromScale(vec3(range, 1.0, range)));
            const color = if (turret.person != null and self.fire_back.enabled) RANGE_ACTIVE_COLOR else RANGE_IDLE_COLOR;
            self.range_ring.draw(frame, self.flash_shader, core.DrawUniforms.init(model, color));
        }
    }

    fn processKeys(self: *Self, input: *core.Input) void {
        if (input.pressedOnce(.k)) {
            self.control_style = character_control.nextStyle(self.control_style);
        }
        if (input.pressedOnce(.t)) {
            self.fire_back.enabled = !self.fire_back.enabled;
        }
        if (input.pressedOnce(.r)) {
            self.resetTurrets();
        }
    }

    fn resetTurrets(self: *Self) void {
        for (&self.turrets) |*turret| {
            turret.reset();
        }
    }

    fn drawRangePanel(self: *Self) void {
        zgui.setNextWindowPos(.{ .x = 20, .y = 420, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 360, .h = 260, .cond = .first_use_ever });
        if (zgui.begin("range", .{})) {
            zgui.text("LT / F: first person   RT / mouse: fire   R: reset", .{});
            zgui.text("shots: {d}   hits: {d}   squad hits: {d}", .{ self.shots_fired, self.hits, self.squad_hits });
            _ = zgui.checkbox("turrets fire back (T)", .{ .v = &self.fire_back.enabled });
            _ = zgui.checkbox("show detection ranges", .{ .v = &self.show_ranges });
            _ = zgui.sliderFloat("detection (x range)", .{ .v = &self.fire_back.detection_scale, .min = 0.2, .max = 3.0 });
            zgui.text("turret hits on the captain: {d}   on the squad: {d}", .{ self.captain_hits, self.member_hits });
            for (self.turrets, placements) |turret, placement| {
                if (turret.destroyed) {
                    zgui.text("{s} {d:.1}: destroyed", .{ placement.turret_type.name, placement.size });
                } else {
                    zgui.text("{s} {d:.1}: {d:.0} / {d:.0}", .{ placement.turret_type.name, placement.size, turret.health, turret.max_health });
                }
            }
            if (zgui.button("reset (R)", .{})) {
                self.resetTurrets();
            }
            _ = zgui.sliderFloat("aim yaw (rad/s)", .{ .v = &self.first_person.yaw_speed, .min = 0.5, .max = 6.0 });
            _ = zgui.sliderFloat("aim pitch (rad/s)", .{ .v = &self.first_person.pitch_speed, .min = 0.5, .max = 6.0 });
        }
        zgui.end();
    }
};

/// How far along the ray from `origin` along `direction` (a unit vector) it first meets the
/// sphere; null when it misses or the sphere is behind.
fn raySphere(origin: Vec3, direction: Vec3, center: Vec3, radius: f32) ?f32 {
    const to_center = center.sub(origin);
    const along = to_center.dot(direction);
    const miss_squared = to_center.lengthSquared() - along * along;
    const radius_squared = radius * radius;
    if (miss_squared > radius_squared) {
        return null;
    }
    const half_chord = @sqrt(radius_squared - miss_squared);
    const near = along - half_chord;
    if (near >= 0.0) {
        return near;
    }
    const far = along + half_chord;
    return if (far >= 0.0) 0.0 else null;
}

/// A small cross with a gap at the screen's center.
fn drawCrosshair() void {
    const size = zgui.io.getDisplaySize();
    const center = [2]f32{ size[0] * 0.5, size[1] * 0.5 };
    const color = zgui.colorConvertFloat4ToU32(.{ 1.0, 1.0, 1.0, 0.85 });
    const draw_list = zgui.getForegroundDrawList();
    const gap: f32 = 4.0;
    const arm: f32 = 12.0;
    draw_list.addLine(.{ .p1 = .{ center[0] - gap - arm, center[1] }, .p2 = .{ center[0] - gap, center[1] }, .col = color, .thickness = 2.0 });
    draw_list.addLine(.{ .p1 = .{ center[0] + gap, center[1] }, .p2 = .{ center[0] + gap + arm, center[1] }, .col = color, .thickness = 2.0 });
    draw_list.addLine(.{ .p1 = .{ center[0], center[1] - gap - arm }, .p2 = .{ center[0], center[1] - gap }, .col = color, .thickness = 2.0 });
    draw_list.addLine(.{ .p1 = .{ center[0], center[1] + gap }, .p2 = .{ center[0], center[1] + gap + arm }, .col = color, .thickness = 2.0 });
}
