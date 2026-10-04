const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");

const Context = core.Context;
const Scene = @import("../scene.zig").Scene;
const SceneCamera = @import("../scene_camera.zig").SceneCamera;
const ResourceManager = core.ResourceManager;

const FreeCamera = @import("../objects/free_camera.zig").FreeCamera;
const AxisLines = @import("../objects/axis_lines.zig").AxisLines;
const Cube = @import("../objects/cube.zig").Cube;
const Cannon = @import("../objects/cannon.zig").Cannon;
const Floor = @import("../objects/floor.zig").Floor;
const scene_lights = @import("../objects/lights.zig");
const Lights = scene_lights.Lights;
const SkyBoxDirections = @import("../objects/skyboxes.zig").SkyBoxDirections;
const Spacesuit = @import("../objects/spacesuit.zig").Spacesuit;
const ToonSoldier = @import("../objects/toon_soldier.zig").ToonSoldier;
const character_control = @import("../objects/character_control.zig");

const bullet_system = @import("../projectiles/bullet_system.zig");
const Turret = @import("../projectiles/turret.zig").Turret;

const Vec2 = math.Vec2;
const vec2 = math.vec2;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const quat = math.quat;

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Shader = core.Shader;
const Texture = core.texture.Texture;
const Shape = core.shapes.Shape;
const Lines = core.shapes.Lines;
const Plane = core.shapes.Plane;

const Transform = core.Transform;
const motion = core.motion;
const Frame = core.Frame;
const GpuContext = core.GpuContext;

const basic_lights = scene_lights.basic_lights;

/// Which object gets the mode keys (arrows, W/A/S/D, digits, ...): one at a time, picked
/// with C, N, T, M, Z.
pub const InputMode = enum {
    camera,
    cannon,
    turret,
    spacesuit,
    soldier,
};

/// In the soldier and spacesuit modes: a third-person camera following the character, or
/// the free camera left where it is (V switches).
pub const CameraView = enum {
    follow,
    free,
};

pub const SceneDebug = struct {
    resource_manager: *ResourceManager,
    scene_camera: *SceneCamera,
    cube: Cube = undefined,
    cannon: Cannon = undefined,
    skybox: SkyBoxDirections = undefined,
    floor: Floor = undefined,
    axis_lines: AxisLines = undefined,
    turret: *Turret = undefined,
    spacesuit: *Spacesuit = undefined,
    toon_soldier: *ToonSoldier = undefined,
    barrel: *Shape = undefined,
    input_tick: u64 = 0,
    input_mode: InputMode = .spacesuit,
    camera_view: CameraView = .follow,
    /// How the soldier and spacesuit move (K switches, or the soldier panel).
    control_style: character_control.Style = .wind_waker,
    follow: motion.FollowCamera = undefined,
    reset: bool = false,
    run_animation: bool = true,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, input: *core.Input) !*Scene {
        const camera = try FreeCamera.init(
            context.alloc,
            input.framebuffer_width,
            input.framebuffer_height,
        );

        const rm = try ResourceManager.init(context, gpu);

        const scene = try context.alloc.create(SceneDebug);
        scene.* = .{
            .resource_manager = rm,
            .scene_camera = camera,
            .cube = try Cube.init(rm),
            .cannon = try Cannon.init(rm),
            .skybox = try SkyBoxDirections.init(rm),
            .floor = try Floor.init(rm),
            .axis_lines = try AxisLines.init(rm),
            .turret = try Turret.init(rm),
            .spacesuit = try Spacesuit.init(rm),
            .toon_soldier = try ToonSoldier.init(rm, .soldier, .ShortCannon, true),
            .barrel = try rm.loadOBJ("assets/modular_ruins/OBJ/Barrel.obj"),
        };

        scene.cannon.transform = Transform.fromTranslation(vec3(5.0, 0.0, 0.0));

        scene.floor.plane.shape.is_visible = true;
        scene.skybox.is_visible = false;
        scene.follow = .init(scene.spacesuit.transform.translation, character_control.facingYaw(scene.spacesuit.transform));

        return try Scene.init(context.alloc, "Debug", scene, input);
    }

    pub fn cleanUp(self: *Self) void {
        self.floor.cleanUp();
        self.skybox.cleanUp();
        self.resource_manager.cleanUp();
    }

    pub fn getSceneCamera(self: *Self) *SceneCamera {
        return self.scene_camera;
    }

    pub fn update(self: *Self, input: *core.Input) !void {
        try self.scene_camera.update(input);
        try self.spacesuit.update(input);
        try self.toon_soldier.update(input.delta_time);

        try self.processInput(input);
        self.updateFollowCamera(input);

        if (self.run_animation == true) {
            try self.turret.update(input);
        }
        self.cannon.update(input.delta_time);
    }

    /// Camera and basic_lights go to the frame uniforms; objects draw with them.
    pub fn draw(self: *Self, frame: *const Frame, time: f32) void {
        var camera = self.getSceneCamera().getCamera();
        var frame_uniforms = camera.getRenderContext(time).frameUniforms();
        frame_uniforms.lights = basic_lights.uniforms();
        frame.gpu.writeFrameUniforms(frame_uniforms);

        self.cube.draw(frame);
        self.axis_lines.draw(frame);
        self.skybox.draw(frame);

        self.turret.draw(frame);
        self.cannon.draw(frame);
        self.spacesuit.draw(frame);
        self.toon_soldier.draw(frame);

        self.floor.draw(frame);
    }

    /// The soldier's tuning panel in the soldier mode.
    pub fn drawGui(self: *Self) void {
        if (self.input_mode == .soldier) {
            self.toon_soldier.drawGui(&self.control_style);
        }
    }

    /// The mode's object handles its keys first; the global keys then see only the keys
    /// it didn't claim (`pressedOnce` marks a key as used). So Space is a jump or a roll in
    /// the soldier and spacesuit modes, and pauses the turret in the others.
    fn processInput(self: *Self, input: *core.Input) !void {
        try self.processModeInput(input);
        try self.processGlobalKeys(input);
    }

    fn processModeInput(self: *Self, input: *core.Input) !void {
        switch (self.input_mode) {
            .camera => try self.scene_camera.processInput(input),
            .cannon => try self.cannon.processInput(input),
            .turret => try self.turret.processInput(input),
            .spacesuit => try self.controlCharacter(self.spacesuit, input),
            .soldier => try self.controlCharacter(self.toon_soldier, input),
        }
    }

    fn controlCharacter(self: *Self, character: anytype, input: *core.Input) !void {
        try character_control.control(character, self.control_style, self.follow.yaw, input);
    }

    /// The controlled character's transform, in the modes that have a character.
    fn characterTransform(self: *const Self) ?Transform {
        return switch (self.input_mode) {
            .spacesuit => self.spacesuit.transform,
            .soldier => self.toon_soldier.transform,
            .camera, .cannon, .turret => null,
        };
    }

    /// The follow camera trails the character; the right stick or the arrow keys turn it,
    /// the left trigger or Q swing it behind the character.
    fn updateFollowCamera(self: *Self, input: *core.Input) void {
        if (self.camera_view != .follow) {
            return;
        }
        const transform = self.characterTransform() orelse return;
        const recenter = input.isDown(.q) or input.gamepad.left_trigger > 0.5;
        character_control.followCharacter(&self.follow, transform, recenter, input);
        self.getSceneCamera().getCamera().movement.reset(self.follow.position, self.follow.focus);
    }

    /// One-shot keys that work in every mode.
    fn processGlobalKeys(self: *Self, input: *core.Input) !void {
        // Mode switches
        const mode_keys = [_]struct { key: glfw.Key, mode: InputMode }{
            .{ .key = .c, .mode = .camera },
            .{ .key = .n, .mode = .cannon },
            .{ .key = .t, .mode = .turret },
            .{ .key = .m, .mode = .spacesuit },
            .{ .key = .z, .mode = .soldier },
        };
        for (mode_keys) |binding| {
            if (input.pressedOnce(binding.key)) {
                self.input_mode = binding.mode;
                // A new character: start behind it
                if (self.characterTransform()) |transform| {
                    self.follow.reset(transform.translation, character_control.facingYaw(transform));
                }
                std.debug.print("Input mode: {s}\n", .{@tagName(binding.mode)});
            }
        }

        if (input.pressedOnce(.k)) {
            self.control_style = character_control.nextStyle(self.control_style);
            std.debug.print("Control style: {s}\n", .{@tagName(self.control_style)});
        }

        if (input.pressedOnce(.v)) {
            self.camera_view = if (self.camera_view == .follow) .free else .follow;
            std.debug.print("Camera view: {s}\n", .{@tagName(self.camera_view)});
        }

        // Scene toggles
        if (input.pressedOnce(.b)) {
            self.skybox.is_visible = !self.skybox.is_visible;
        }
        if (input.pressedOnce(.f)) {
            self.floor.plane.shape.is_visible = !self.floor.plane.shape.is_visible;
        }
        if (input.pressedOnce(.space)) {
            self.run_animation = !self.run_animation;
        }

        // Bullets
        if (input.pressedOnce(.r)) {
            try self.turret.fire();
        }
        if (input.pressedOnce(.g)) {
            const gravity: f32 = if (self.turret.bullets.gravity == 0.0) bullet_system.GRAVITY else 0.0;
            self.turret.bullets.gravity = gravity;
            self.cannon.bullets.gravity = gravity;
            std.debug.print("Bullet gravity: {d}\n", .{gravity});
        }
        if (input.pressedOnce(.p)) {
            const is_visible = !self.turret.bullets.is_lines_visible;
            self.turret.bullets.is_lines_visible = is_visible;
            self.cannon.bullets.is_lines_visible = is_visible;
            std.debug.print("Predicted bullet paths: {}\n", .{is_visible});
        }

        // Camera
        const camera = self.getSceneCamera().getCamera();
        if (input.pressedOnce(.l)) {
            // Explicit re-level after orbit/circle basis drift (see Movement.levelTowardTarget)
            if (input.key_shift) {
                camera.movement.levelTowardTarget(null);
                std.debug.print("Level: right ∥ XZ, preserve bank\n", .{});
            } else {
                camera.movement.levelUpright();
                std.debug.print("Level: upright (world up)\n", .{});
            }
        }
        if (input.pressedOnce(.minus)) {
            camera.setPerspective();
            std.debug.print("Projection: Perspective\n", .{});
        }
        if (input.pressedOnce(.equal)) {
            camera.setOrthographic();
            std.debug.print("Projection: Orthographic\n", .{});
        }
        if (input.pressedOnce(.F12)) {
            std.debug.print("Screenshot requested (F12)\n", .{});
        }
    }
};
