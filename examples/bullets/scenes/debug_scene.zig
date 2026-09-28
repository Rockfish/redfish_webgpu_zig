const std = @import("std");
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

const BulletSystem = @import("../projectiles/bullet_system.zig").BulletSystem;
const Turret = @import("../projectiles/turret.zig").Turret;

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
const Frame = core.Frame;
const GpuContext = core.GpuContext;

const basic_lights = scene_lights.basic_lights;

pub const MotionType = enum {
    /// Direct movement along camera's local axes (Left, Right, Up, Down)
    translate,
    /// Rotation around target point (OrbitLeft, OrbitRight, OrbitUp, OrbitDown)
    orbit,
    /// Movement around target maintaining height (CircleLeft, CircleRight)
    circle,
    /// In-place rotation (RotateLeft, RotateRight, RotateUp, RotateDown)
    rotate,
    /// Move look view
    look,
};

pub const MotionObject = enum {
    base,
    gimbal,
    turret,
    cannon,
    spacesuit,
    soldier,
    enemy,
    camera,
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
    motion_type: MotionType = .circle,
    motion_object: MotionObject = .spacesuit,
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
            .toon_soldier = try ToonSoldier.init(rm),
            .barrel = try rm.loadOBJ("assets/modular_ruins/OBJ/Barrel.obj"),
        };

        scene.cannon.transform = Transform.fromTranslation(vec3(5.0, 0.0, 0.0));

        scene.floor.plane.shape.is_visible = true;
        scene.skybox.is_visible = false;

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
        try self.toon_soldier.update(input);

        try self.processInput(input);

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

    fn processInput(self: *Self, input: *core.Input) !void {
        // const dt = input.delta_time;

        switch (self.motion_object) {
            .turret => try self.turret.processInput(input),
            .cannon => try self.cannon.processInput(input),
            .camera => try self.scene_camera.processInput(input),
            .spacesuit => try self.spacesuit.processInput(input),
            .soldier => try self.toon_soldier.processInput(input),
            else => {},
        }

        var iterator = input.key_presses.iterator();
        while (iterator.next()) |k| {
            // if (self.motion_object != .turret) {
            // const movement_object = if (self.motion_object == .base) &self.getCamera().base_movement else &self.getCamera().gimbal_movement;
            //
            // switch (self.motion_type) {
            //     .translate => switch (k) {
            //         .w => movement_object.processMovement(.forward, dt),
            //         .s => movement_object.processMovement(.backward, dt),
            //         .a, .left => movement_object.processMovement(.left, dt),
            //         .d, .right => movement_object.processMovement(.right, dt),
            //         .up => movement_object.processMovement(.up, dt),
            //         .down => movement_object.processMovement(.down, dt),
            //         else => {},
            //     },
            //     .orbit => switch (k) {
            //         .w, .up => movement_object.processMovement(.orbit_up, dt),
            //         .s, .down => movement_object.processMovement(.orbit_down, dt),
            //         .a, .left => movement_object.processMovement(.orbit_left, dt),
            //         .d, .right => movement_object.processMovement(.orbit_right, dt),
            //         else => {},
            //     },
            //     .circle => switch (k) {
            //         .w, .up => movement_object.processMovement(.circle_up, dt),
            //         .s, .down => movement_object.processMovement(.circle_down, dt),
            //         .a, .left => movement_object.processMovement(.circle_left, dt),
            //         .d, .right => movement_object.processMovement(.circle_right, dt),
            //         else => {},
            //     },
            //     .rotate, .look => switch (k) {
            //         .w, .up => movement_object.processMovement(.rotate_up, dt),
            //         .s, .down => movement_object.processMovement(.rotate_down, dt),
            //         .a, .left => movement_object.processMovement(.rotate_left, dt),
            //         .d, .right => movement_object.processMovement(.rotate_right, dt),
            //         else => {},
            //     },
            // }
            // }

            // One-shot keys: fire once per press
            if (input.key_processed.contains(k)) {
                continue;
            }
            input.key_processed.insert(k);

            switch (k) {
                .b => {
                    self.skybox.is_visible = !self.skybox.is_visible;
                },
                .c => {
                    self.motion_object = .camera;
                },
                .n => {
                    self.motion_object = .cannon;
                    std.debug.print("Motion object: cannon (arrows aim, r fires)\n", .{});
                },
                .f => {
                    self.floor.plane.shape.is_visible = !self.floor.plane.shape.is_visible;
                },
                .l => {
                    // Explicit re-level after orbit/circle basis drift (see Movement.levelTowardTarget)
                    const cam = self.getSceneCamera().getCamera();
                    if (input.key_shift) {
                        cam.movement.levelTowardTarget(null);
                        std.debug.print("Level: right ∥ XZ, preserve bank\n", .{});
                    } else {
                        cam.movement.levelUpright();
                        std.debug.print("Level: upright (world up)\n", .{});
                    }
                },
                .m => {
                    self.motion_object = .spacesuit;
                },
                .r => try self.turret.fire(),
                .t => {
                    self.motion_object = .turret;
                },
                .z => {
                    self.motion_object = .soldier;
                },
                .minus => {
                    self.getSceneCamera().getCamera().setPerspective();
                    std.debug.print("Projection: Perspective\n", .{});
                },
                .equal => {
                    self.getSceneCamera().getCamera().setOrthographic();
                    std.debug.print("Projection: Orthographic\n", .{});
                },
                .three => {
                    // self.motion_type = .orbit;
                    // self.printMotionViewState();
                },
                .four => {
                    // self.motion_type = .rotate;
                    // self.printMotionViewState();
                },
                .five => {
                    // self.motion_type = .look;
                    // self.printMotionViewState();
                },
                .six => {
                    // self.motion_object = if (self.motion_object == .base) .gimbal else .base;
                    // self.printMotionViewState();
                },
                .seven => {
                    // const camera = self.getCamera();
                    // camera.view_mode = if (camera.view_mode == .base) .gimbal else .base;
                    // camera.view_cache_valid = false;
                    // self.printMotionViewState();
                },
                .eight => {},
                .nine => {},
                .zero => {
                    // self.motion_object = .turret;
                },
                .F12 => {
                    std.debug.print("Screenshot requested (F12)\n", .{});
                },
                .space => {
                    self.run_animation = !self.run_animation;
                },
                else => {},
            }
        }
    }

    pub fn printMotionViewState(self: *Self) void {
        std.debug.print("-----\n", .{});
        // std.debug.print("Look mode: {any}\n", .{self.getCamera().view_mode});
        std.debug.print("Motion type: {any}\n", .{self.motion_type});
        std.debug.print("Motion object: {any}\n", .{self.motion_object});
        std.debug.print("-----\n", .{});
    }
};
