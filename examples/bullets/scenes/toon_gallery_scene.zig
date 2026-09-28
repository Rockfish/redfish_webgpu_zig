const std = @import("std");
const core = @import("core");
const math = @import("math");

const Context = core.Context;
const Scene = @import("../scene.zig").Scene;
const SceneCamera = @import("../scene_camera.zig").SceneCamera;
const FreeCamera = @import("../objects/free_camera.zig").FreeCamera;
const scene_lights = @import("../objects/lights.zig");
const Floor = @import("../objects/floor.zig").Floor;

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Mat4 = math.Mat4;

const Allocator = std.mem.Allocator;
const ResourceManager = core.ResourceManager;
const Shader = core.Shader;
const ModelInstance = core.ModelInstance;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const MeshPrimitive = core.MeshPrimitive;

const gallery_lights = scene_lights.gallery_lights;

const gltf_dir = "assets/toon_shooter_kit/Environment/glTF/";

const gltf_files = [_][]const u8{
    "Barrier_Fixed.gltf",
    "Barrier_Large.gltf",
    "Barrier_Single.gltf",
    "Barrier_Trash.gltf",
    "BearTrap_Closed.gltf",
    "BearTrap_Open.gltf",
    "BrickWall_1.gltf",
    "BrickWall_2.gltf",
    "CardboardBoxes_1.gltf",
    "CardboardBoxes_2.gltf",
    "CardboardBoxes_3.gltf",
    "CardboardBoxes_4.gltf",
    "Container_Long.gltf",
    "Container_Small.gltf",
    "Crate.gltf",
    "Debris_BrokenCar.gltf",
    "Debris_Papers_1.gltf",
    "Debris_Papers_2.gltf",
    "Debris_Papers_3.gltf",
    "Debris_Pile.gltf",
    "Debris_Tires.gltf",
    "ExplodingBarrel.gltf",
    "ExplodingBarrel_Spilled.gltf",
    "Fence.gltf",
    "Fence_Long.gltf",
    "GasCan.gltf",
    "GasTank.gltf",
    "Health.gltf",
    "Key.gltf",
    "Landmine.gltf",
    "MetalFence.gltf",
    "Pallet.gltf",
    "Pallet_Broken.gltf",
    "Pipes.gltf",
    "SackTrench.gltf",
    "SackTrench_Small.gltf",
    "Sign.gltf",
    "Sofa.gltf",
    "Sofa_Small.gltf",
    "StreetLight.gltf",
    "Structure_1.gltf",
    "Structure_2.gltf",
    "Structure_3.gltf",
    "Structure_4.gltf",
    "Tank.gltf",
    "TrafficCone.gltf",
    "TrashContainer.gltf",
    "TrashContainer_Open.gltf",
    "Tree_1.gltf",
    "Tree_2.gltf",
    "Tree_3.gltf",
    "Tree_4.gltf",
    "WaterTank_Floor.gltf",
    "WaterTank_Platform.gltf",
    "WoodPlanks.gltf",
};

const grid_spacing: f32 = 5.0;
const grid_cols: usize = 8;

pub const ToonGalleryScene = struct {
    resource_manager: *ResourceManager,
    scene_camera: *SceneCamera,
    floor: Floor,
    models: [gltf_files.len]*ModelInstance,
    model_matrices: [gltf_files.len]Mat4,
    shader: *Shader,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, input: *core.Input) !*Scene {
        const camera = try FreeCamera.init(
            context.alloc,
            input.framebuffer_width,
            input.framebuffer_height,
        );

        const rm = try ResourceManager.init(context, gpu);

        // level_01's animated_pbr is the same shader as core pbr
        const shader = try rm.createShader("src/core/shaders/pbr.wgsl", .{
            .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts,
            .material = .pbr,
        });

        var models: [gltf_files.len]*ModelInstance = undefined;
        var model_matrices: [gltf_files.len]Mat4 = undefined;

        for (gltf_files, 0..) |file, i| {
            var path_buf: [256]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ gltf_dir, file }) catch unreachable;

            // Strip .gltf extension for the name
            const name = file[0 .. file.len - 5];
            models[i] = try rm.loadModel(name, full_path);

            const col: f32 = @floatFromInt(i % grid_cols);
            const row: f32 = @floatFromInt(i / grid_cols);
            const x = (col - @as(f32, @floatFromInt(grid_cols)) / 2.0) * grid_spacing;
            const z = (row - @as(f32, @floatFromInt(gltf_files.len / grid_cols)) / 2.0) * grid_spacing;
            model_matrices[i] = Mat4.fromTranslation(vec3(x, 0.0, z));
        }

        const floor = try Floor.init(rm);

        const scene = try context.alloc.create(Self);
        scene.* = .{
            .resource_manager = rm,
            .scene_camera = camera,
            .floor = floor,
            .models = models,
            .model_matrices = model_matrices,
            .shader = shader,
        };

        scene.floor.plane.shape.is_visible = true;

        return try Scene.init(context.alloc, "ToonGallery", scene, input);
    }

    pub fn cleanUp(self: *Self) void {
        self.floor.cleanUp();
        self.resource_manager.cleanUp();
    }

    pub fn getSceneCamera(self: *Self) *SceneCamera {
        return self.scene_camera;
    }

    pub fn update(self: *Self, input: *core.Input) !void {
        try self.scene_camera.update(input);
        try self.scene_camera.processInput(input);
    }

    pub fn draw(self: *Self, frame: *const Frame, time: f32) void {
        var camera = self.getSceneCamera().getCamera();
        var frame_uniforms = camera.getRenderContext(time).frameUniforms();
        frame_uniforms.lights = toonLights().uniforms();
        frame.gpu.writeFrameUniforms(frame_uniforms);

        for (self.models, 0..) |model, i| {
            model.draw(frame, self.shader, self.model_matrices[i]);
        }

        self.floor.draw(frame);
    }
};

/// One light set per frame: gallery_lights (the floor's) plus redfish's PBR light for the
/// models, (10, 20, 10), color (1, 0.95, 0.9), intensity 2.5 with pbr.frag's falloff.
fn toonLights() core.SceneLights {
    var lights = gallery_lights;
    lights.setPointLight(2, .{
        .world_pos = vec3(10.0, 20.0, 10.0),
        .color = vec3(2.5, 2.375, 2.25),
        .constant = 1.0,
        .linear = 0.01,
        .quadratic = 0.001,
        .enabled = true,
    });
    return lights;
}
