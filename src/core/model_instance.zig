const std = @import("std");
const math = @import("math");
const Shader = @import("shader.zig").Shader;
const gpu_context = @import("gpu_context.zig");
const skinning = @import("skinning.zig");
const BakedAnimator = @import("baked_animator.zig").BakedAnimator;
const Mesh = @import("mesh.zig").Mesh;
const Animator = @import("animator.zig").Animator;
const WeightedAnimation = @import("animator.zig").WeightedAnimation;
const AnimationClip = @import("animator.zig").AnimationClip;
const gltf_types = @import("gltf/gltf.zig");
const GltfAsset = @import("gltf_asset.zig").GltfAsset;
const Context = @import("context.zig").Context;

const log = std.log.scoped(.model_instance);

const Allocator = std.mem.Allocator;
const Frame = gpu_context.Frame;
const GpuContext = gpu_context.GpuContext;
const Mat4 = math.Mat4;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const AnimatorType = enum {
    none,
    live_animator,
    baked_animator,
};

pub const AnimatorImpl = union(enum) {
    null_animator,
    live_animator: *Animator,
    baked_animator: *BakedAnimator,
};

pub const ModelConfig = struct {
    name: []const u8,
    file_path: []const u8,
    animator_type: AnimatorType = .none,
    // addTextures: []const TexConfigs,
};

pub const ModelInstance = struct {
    // alloc: Allocator,
    name: []const u8,
    animator_impl: AnimatorImpl,
    gltf_asset: *GltfAsset,
    /// Joint matrices on the GPU, for skinned models with a live animator. Baked
    /// animators carry their own.
    joint_buffer: ?skinning.JointBuffer,

    const Self = @This();

    pub fn init(
        alloc: Allocator,
        name: []const u8,
        animator: AnimatorImpl,
        gltf_asset: *GltfAsset,
    ) !*Self {
        const model = try alloc.create(ModelInstance);
        model.* = ModelInstance{
            .name = try alloc.dupe(u8, name),
            .animator_impl = animator,
            .gltf_asset = gltf_asset,
            .joint_buffer = jointBufferFor(animator, gltf_asset),
        };

        return model;
    }

    pub fn initWithConfig(context: Context, gpu: *GpuContext, config: ModelConfig) !*Self {
        var gltf_asset = try GltfAsset.init(context, gpu, config.name, config.file_path);
        try gltf_asset.load();

        const animator = try Animator.init(context, gltf_asset);

        const animator_impl: AnimatorImpl = switch (config.animator_type) {
            .none => .null_animator,
            .live_animator => .{ .live_animator = animator },
            .baked_animator => .{ .baked_animator = try BakedAnimator.init(context, gpu, animator, .{ .frame_rate = 30.0, .capture = .all }) },
        };

        const model = try context.alloc.create(ModelInstance);
        model.* = ModelInstance{
            .name = try context.alloc.dupe(u8, config.name),
            .animator_impl = animator_impl,
            .gltf_asset = gltf_asset,
            .joint_buffer = jointBufferFor(animator_impl, gltf_asset),
        };

        return model;
    }

    pub fn cleanUp(self: *Self) void {
        if (self.joint_buffer) |*joint_buffer| joint_buffer.releaseGpuObjects();
        switch (self.animator_impl) {
            .baked_animator => |obj| obj.releaseGpuObjects(),
            else => {},
        }
        self.gltf_asset.cleanUp();
    }

    pub fn updateAnimation(self: *Self, delta_time: f32) !void {
        switch (self.animator_impl) {
            .live_animator => |obj| try obj.updateAnimation(delta_time),
            .baked_animator => |obj| try obj.updateAnimation(delta_time),
            else => {},
        }
    }

    pub fn updateWeightedAnimations(self: *Self, weighted_animations: []const WeightedAnimation, frame_time: f32) !void {
        switch (self.animator_impl) {
            .live_animator => |obj| try obj.updateWeightedAnimations(weighted_animations, frame_time),
            .baked_animator => log.err("Baked animations not supported yet for weighted updates", .{}),
            else => {},
        }
    }

    pub fn playClip(self: *Self, clip: AnimationClip) !void {
        switch (self.animator_impl) {
            .live_animator => |obj| try obj.playClip(clip),
            // Baked animations are played by index; see BakedAnimator.playAnimationById.
            .baked_animator => return error.ClipPlaybackNotSupported,
            else => {},
        }
    }

    pub fn playAnimationById(self: *Self, anim_id: u32) !void {
        switch (self.animator_impl) {
            .live_animator => |obj| try obj.playAnimationById(anim_id),
            .baked_animator => |obj| obj.playAnimationById(anim_id),
            else => {},
        }
    }

    pub fn playAllAnimations(self: *Self) !void {
        switch (self.animator_impl) {
            .live_animator => |obj| try obj.playAllAnimations(),
            else => {},
        }
    }

    pub fn getAnimationCount(self: *Self) u32 {
        switch (self.animator_impl) {
            .live_animator => |obj| return obj.getAnimationCount(),
            .baked_animator => |obj| return obj.getAnimationCount(),
            else => return 0,
        }
    }

    pub fn getAnimationDuration(self: *Self, anim_id: u32) f32 {
        switch (self.animator_impl) {
            .live_animator => |obj| return obj.getAnimationDuration(anim_id),
            .baked_animator => |obj| return obj.getAnimationDuration(anim_id),
            else => return 0.0,
        }
    }

    /// `model_transform` places the whole model (redfish's `matModel`). With a live
    /// animator each mesh draws at its node's animated world transform (was
    /// `Animator.draw` in redfish) and skinned meshes upload this frame's pose; draw each
    /// instance once per frame. Without an animator, meshes draw at the identity.
    pub fn draw(self: *Self, frame: *const Frame, shader: *const Shader, model_transform: Mat4) void {
        switch (self.animator_impl) {
            .live_animator => |animator| {
                const skin: ?skinning.SkinBinding = if (self.joint_buffer) |*joint_buffer|
                    joint_buffer.update(frame.gpu, &animator.joint_matrices)
                else
                    null;

                for (self.gltf_asset.meshes, 0..) |mesh, index| {
                    const node_index = animator.meshToNode[index];
                    const transform = animator.nodes[node_index].calculated_transform.?;
                    mesh.drawAt(frame, shader, model_transform, transform.toMatrix(), skin);
                }
            },
            .baked_animator => |baked| baked.draw(self, frame, shader, model_transform),
            .null_animator => {
                for (self.gltf_asset.meshes) |mesh| {
                    mesh.drawAt(frame, shader, model_transform, Mat4.Identity, null);
                }
            },
        }
    }
};

/// A live animator on a skinned model needs its own joint buffer.
fn jointBufferFor(animator_impl: AnimatorImpl, gltf_asset: *GltfAsset) ?skinning.JointBuffer {
    return switch (animator_impl) {
        .live_animator => |animator| if (animator.skin_index != null) skinning.JointBuffer.init(gltf_asset.gpu) else null,
        else => null,
    };
}
