//! The turret range (docs/reviews/2026-10-04-link-style-controller-review.md section 11,
//! phase C): a field with turrets of several sizes, the captain (the toon soldier) at one
//! end with the follow camera. The turrets watch the captain but hold fire for now.
//! Until the captain can shoot (phase D), H hits the turret the captain faces.

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
const TargetTurret = @import("../objects/target_turret.zig").TargetTurret;
const character_control = @import("../objects/character_control.zig");

const gameplay = core.gameplay;
const turret_types = gameplay.turret_types;
const Explosions = gameplay.Explosions;
const ExplosionShapes = gameplay.ExplosionShapes;
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
const Quat = math.Quat;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;

const basic_lights = scene_lights.basic_lights;

/// Where the captain starts, facing the turrets (down -Z).
const CAPTAIN_START = vec3(0.0, 0.0, 8.0);
/// The point on the captain the turrets aim at: about chest height.
const CAPTAIN_AIM_HEIGHT: f32 = 1.2;
/// The color burn marks fade into: about the floor's.
const FLOOR_COLOR = vec4(0.32, 0.31, 0.29, 1.0);

const Placement = struct {
    turret_type: *const TurretType,
    position: Vec3,
    size: f32,
};

const placements = [_]Placement{
    .{ .turret_type = &turret_types.gatling, .position = vec3(-6.0, 0.0, -10.0), .size = 0.6 },
    .{ .turret_type = &turret_types.cannon, .position = vec3(5.0, 0.0, -14.0), .size = 1.0 },
    .{ .turret_type = &turret_types.sweeper, .position = vec3(-13.0, 0.0, -22.0), .size = 1.5 },
    .{ .turret_type = &turret_types.mortar, .position = vec3(13.0, 0.0, -26.0), .size = 2.0 },
    .{ .turret_type = &turret_types.gatling, .position = vec3(-22.0, 0.0, -34.0), .size = 1.0 },
    .{ .turret_type = &turret_types.battery, .position = vec3(2.0, 0.0, -40.0), .size = 3.0 },
};

pub const RangeScene = struct {
    resource_manager: *ResourceManager,
    scene_camera: *SceneCamera,
    floor: Floor,
    captain: *ToonSoldier,
    follow: motion.FollowCamera,
    /// How the captain moves (K switches, or the soldier panel).
    control_style: character_control.Style = .wind_waker,
    shape_shader: *Shader,
    flash_shader: *Shader,
    turret_shapes: TurretShapes,
    explosion_shapes: ExplosionShapes,
    explosions: Explosions = .{ .floor_color = FLOOR_COLOR },
    turrets: [placements.len]TargetTurret,
    random: Random,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, input: *core.Input) !*Scene {
        const rm = try ResourceManager.init(context, gpu);
        const camera = try FreeCamera.init(context.alloc, input.framebuffer_width, input.framebuffer_height);

        const captain = try ToonSoldier.init(rm);
        captain.transform.translation = CAPTAIN_START;
        captain.transform.rotation = Quat.fromAxisAngle(Vec3.Y, std.math.pi);

        var turrets: [placements.len]TargetTurret = undefined;
        for (placements, &turrets) |placement, *turret| {
            turret.* = .init(placement.turret_type.*, placement.position, placement.size);
        }

        var floor = try Floor.init(rm);
        floor.plane.shape.is_visible = true;

        const scene = try context.alloc.create(Self);
        scene.* = .{
            .resource_manager = rm,
            .scene_camera = camera,
            .floor = floor,
            .captain = captain,
            .follow = .init(captain.transform.translation, character_control.facingYaw(captain.transform)),
            .shape_shader = try rm.createShader("src/core/shaders/basic_shape.wgsl", .{
                .vertex_buffers = &Shape.vertex_buffer_layouts,
            }),
            .flash_shader = try rm.createShader("src/core/shaders/basic_shape.wgsl", .{
                .vertex_buffers = &Shape.vertex_buffer_layouts,
                .constants = &.{.{ .key = "UNLIT", .value = 1.0 }},
            }),
            .turret_shapes = try .init(context, gpu),
            .explosion_shapes = try .init(context, gpu),
            .turrets = turrets,
            .random = Random.init(),
        };
        return try Scene.init(context.alloc, "Range", scene, input);
    }

    pub fn cleanUp(self: *Self) void {
        self.turret_shapes.releaseGpuObjects();
        self.explosion_shapes.releaseGpuObjects();
        self.floor.cleanUp();
        self.resource_manager.cleanUp();
    }

    pub fn update(self: *Self, input: *core.Input) !void {
        const dt = input.delta_time;
        try self.scene_camera.update(input);
        try self.captain.update(input);

        try character_control.control(self.captain, self.control_style, self.follow.yaw, input);
        self.processKeys(input);
        character_control.followCharacter(&self.follow, self.captain.transform, input);
        self.scene_camera.getCamera().movement.reset(self.follow.position, self.follow.focus);

        const target = self.captainTarget();
        for (&self.turrets) |*turret| {
            turret.update(dt, target, &self.random, &self.explosions);
        }
        self.explosions.update(dt);
    }

    /// Camera and basic_lights go to the frame uniforms; objects draw with them.
    pub fn draw(self: *Self, frame: *const Frame, time: f32) void {
        var frame_uniforms = self.scene_camera.getCamera().getRenderContext(time).frameUniforms();
        frame_uniforms.lights = basic_lights.uniforms();
        frame.gpu.writeFrameUniforms(frame_uniforms);

        for (&self.turrets) |*turret| {
            turret.draw(frame, self.shape_shader, &self.turret_shapes);
        }
        self.captain.draw(frame);
        self.explosions.draw(frame, self.flash_shader, self.shape_shader, &self.explosion_shapes);
        self.floor.draw(frame);
    }

    /// The soldier's panel and the range's: each turret's health, hit and reset buttons.
    pub fn drawGui(self: *Self) void {
        self.captain.drawGui(&self.control_style);

        zgui.setNextWindowPos(.{ .x = 20, .y = 420, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 360, .h = 240, .cond = .first_use_ever });
        if (zgui.begin("range", .{})) {
            zgui.text("H: hit the turret in front   R: reset turrets", .{});
            for (self.turrets, placements) |turret, placement| {
                if (turret.destroyed) {
                    zgui.text("{s} {d:.1}: destroyed", .{ placement.turret_type.name, placement.size });
                } else {
                    zgui.text("{s} {d:.1}: {d:.0} / {d:.0}", .{ placement.turret_type.name, placement.size, turret.health, turret.max_health });
                }
            }
            if (zgui.button("hit (H)", .{})) {
                self.hitTurretInFront();
            }
            zgui.sameLine(.{});
            if (zgui.button("reset (R)", .{})) {
                self.resetTurrets();
            }
        }
        zgui.end();
    }

    pub fn getSceneCamera(self: *Self) *SceneCamera {
        return self.scene_camera;
    }

    fn processKeys(self: *Self, input: *core.Input) void {
        if (input.pressedOnce(.k)) {
            self.control_style = character_control.nextStyle(self.control_style);
        }
        if (input.pressedOnce(.h)) {
            self.hitTurretInFront();
        }
        if (input.pressedOnce(.r)) {
            self.resetTurrets();
        }
    }

    /// The captain as the turrets see it: standing, aimed at the chest.
    fn captainTarget(self: *const Self) TargetState {
        return .{
            .position = self.captain.transform.translation.add(vec3(0.0, CAPTAIN_AIM_HEIGHT, 0.0)),
            .velocity = Vec3.Zero,
            .acceleration = Vec3.Zero,
            .radius = 0.5,
        };
    }

    /// A stand-in for shooting until phase D: one damage to the live turret closest to the
    /// way the captain faces, struck on the side facing the captain, a little off center.
    fn hitTurretInFront(self: *Self) void {
        const eye = self.captainTarget().position;
        const facing = self.captain.transform.rotation.rotateVec(Vec3.Z);

        var best: ?*TargetTurret = null;
        var best_alignment: f32 = -2.0;
        for (&self.turrets) |*turret| {
            if (turret.destroyed) {
                continue;
            }
            const alignment = turret.hitSphere().center.sub(eye).toNormalized().dot(facing);
            if (alignment > best_alignment) {
                best_alignment = alignment;
                best = turret;
            }
        }

        const turret = best orelse return;
        const sphere = turret.hitSphere();
        const toward_captain = eye.sub(sphere.center).toNormalized();
        const off_center = vec3(self.random.randClamped(), self.random.randClamped(), self.random.randClamped()).mulScalar(0.5);
        const point = sphere.center.add(toward_captain.add(off_center).toNormalized().mulScalar(sphere.radius * 0.8));
        turret.hit(point, 1.0, &self.explosions);
    }

    fn resetTurrets(self: *Self) void {
        for (&self.turrets) |*turret| {
            turret.reset();
        }
    }
};
