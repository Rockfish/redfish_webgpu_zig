//! GPU side of skinning: where a draw's joint matrices live. See
//! docs/designs/005-skinning.md.

const std = @import("std");
const math = @import("math");
const wgpu = @import("wgpu");
const bindings = @import("bindings.zig");
const StorageBuffer = @import("storage_buffer.zig").StorageBuffer;
const GpuContext = @import("gpu_context.zig").GpuContext;

const c = wgpu.c;
const Mat4 = math.Mat4;

/// The group 2 bind group and joint offset a skinned draw uses.
pub const SkinBinding = struct {
    object_bind_group: c.WGPUBindGroup,
    joint_offset: u32,
};

/// Joint matrices of one live-animated instance, written each frame it draws.
pub const JointBuffer = struct {
    storage: StorageBuffer,
    object_bind_group: c.WGPUBindGroup,

    const Self = @This();

    pub fn init(gpu: *const GpuContext) Self {
        const size = bindings.MAX_JOINTS * @sizeOf(Mat4);
        const storage = StorageBuffer.initEmpty(gpu.device, "joint matrices", size);
        return .{
            .storage = storage,
            .object_bind_group = bindings.createObjectBindGroup(
                gpu.device,
                gpu.bindings.object_layout,
                gpu.uniform_ring.buffer,
                storage.buffer,
                size,
            ),
        };
    }

    /// Upload this frame's pose and return the binding for its draws. Once per frame per
    /// instance (see the write rules in the design note).
    pub fn update(self: *const Self, gpu: *const GpuContext, joint_matrices: []const Mat4) SkinBinding {
        self.storage.write(gpu.queue, Mat4, joint_matrices);
        return .{ .object_bind_group = self.object_bind_group, .joint_offset = 0 };
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.object_bind_group);
        self.storage.releaseGpuObjects();
    }
};
