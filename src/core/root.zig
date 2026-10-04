const std = @import("std");

pub const string = @import("string.zig");
pub const texture = @import("texture.zig");
pub const mipmaps = @import("mipmaps.zig");
pub const utils = @import("utils/root.zig");
pub const gltf_asset = @import("gltf_asset.zig");
pub const gltf_report = @import("gltf/report.zig");
pub const bindings = @import("bindings.zig");
pub const gpu_debug = @import("gpu_debug.zig");
pub const gui = @import("gui.zig");

pub const Arenas = @import("arenas.zig").Arenas;
pub const Context = @import("context.zig").Context;
pub const Shader = @import("shader.zig").Shader;
pub const Camera = @import("camera.zig").Camera;
pub const CameraGimbal = @import("camera_gimbal.zig").Camera;
pub const ProjectionType = @import("camera.zig").ProjectionType;
pub const FrameCounter = @import("frame_counter.zig").FrameCounter;
pub const Random = @import("random.zig").Random;
pub const Transform = @import("transform.zig").Transform;
pub const String = @import("string.zig").String;

pub const Input = @import("input.zig").Input;
pub const Model = @import("model.zig").Model;
pub const ModelInstance = @import("model_instance.zig").ModelInstance;
pub const Mesh = @import("mesh.zig").Mesh;
pub const MeshPrimitive = @import("mesh.zig").MeshPrimitive;
pub const material = @import("material.zig");

pub const animation = @import("animator.zig");
pub const Animator = @import("animator.zig").Animator;
pub const AnimationClip = @import("animator.zig").AnimationClip;
pub const AnimationRepeatMode = @import("animator.zig").AnimationRepeatMode;
pub const WeightedAnimation = @import("animator.zig").WeightedAnimation;
pub const AnimatorImpl = @import("model_instance.zig").AnimatorImpl;
pub const AnimationStateMachine = @import("animation_fsm.zig").AnimationStateMachine;

pub const BakedAnimation = @import("baked_animator.zig").BakedAnimation;
pub const BakedAnimator = @import("baked_animator.zig").BakedAnimator;
pub const StorageBuffer = @import("storage_buffer.zig").StorageBuffer;
pub const skinning = @import("skinning.zig");

pub const Movement = @import("movement.zig").Movement;
pub const MovementDirection = @import("movement.zig").MovementDirection;
pub const motion = @import("motion.zig");
pub const SmoothFollow = motion.SmoothFollow;
pub const gameplay = @import("gameplay/root.zig");

pub const AABB = @import("aabb.zig").AABB;
pub const Ray = @import("aabb.zig").Ray;

pub const gpu_context = @import("gpu_context.zig");
pub const GpuContext = gpu_context.GpuContext;
pub const Frame = gpu_context.Frame;
pub const UniformRing = @import("uniform_ring.zig").UniformRing;
pub const UniformDebug = @import("uniform_debug.zig").UniformDebug;
pub const screen_capture = @import("screen_capture.zig");
pub const ScreenCapture = screen_capture.ScreenCapture;
pub const ShadowMap = @import("shadow_map.zig").ShadowMap;
pub const ShadowMapArray = @import("shadow_map_array.zig").ShadowMapArray;
pub const SoundEngine = @import("sound_engine.zig").SoundEngine;
pub const PassTarget = gpu_context.PassTarget;
pub const pipeline = @import("pipeline.zig");
pub const RenderState = pipeline.RenderState;
pub const DrawUniforms = bindings.DrawUniforms;
pub const MaterialKind = bindings.MaterialKind;

pub const render = @import("render_context.zig");
pub const RenderContext = render.RenderContext;

pub const shapes = @import("shapes/root.zig");

pub const ResourceManager = @import("resource_manager.zig").ResourceManager;

pub const colors = @import("colors.zig");
pub const Color = @import("colors.zig").Color;

pub const lights = @import("lights.zig");
pub const SceneLights = lights.SceneLights;
pub const PointLight = lights.PointLight;
pub const DirectionLight = lights.DirectionLight;

test {
    std.testing.refAllDecls(@This());
}
