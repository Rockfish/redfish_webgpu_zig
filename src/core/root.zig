const std = @import("std");

pub const string = @import("string.zig");
pub const texture = @import("texture.zig");
pub const mipmaps = @import("mipmaps.zig");
pub const utils = @import("utils/root.zig");
// Exported until gltf_asset.zig (Step 4) imports them, so the build checks them.
pub const gltf = @import("gltf/gltf.zig");
pub const gltf_parser = @import("gltf/parser.zig");
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
pub const Movement = @import("movement.zig").Movement;
pub const MovementDirection = @import("movement.zig").MovementDirection;

pub const AABB = @import("aabb.zig").AABB;
pub const Ray = @import("aabb.zig").Ray;

pub const gpu_context = @import("gpu_context.zig");
pub const GpuContext = gpu_context.GpuContext;
pub const Frame = gpu_context.Frame;
pub const UniformRing = @import("uniform_ring.zig").UniformRing;
pub const pipeline = @import("pipeline.zig");
pub const RenderState = pipeline.RenderState;
pub const DrawUniforms = bindings.DrawUniforms;
pub const MaterialKind = bindings.MaterialKind;

pub const render = @import("render_context.zig");
pub const RenderContext = render.RenderContext;

pub const shapes = @import("shapes/root.zig");

pub const colors = @import("colors.zig");
pub const Color = @import("colors.zig").Color;

test {
    std.testing.refAllDecls(@This());
}
