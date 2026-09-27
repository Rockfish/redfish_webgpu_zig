const std = @import("std");
const math = @import("math");
const log = std.log.scoped(.baked_animator);

const wgpu = @import("wgpu");
const bindings = @import("bindings.zig");
const gpu_context = @import("gpu_context.zig");
const skinning = @import("skinning.zig");

const c = wgpu.c;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const ModelInstance = @import("model_instance.zig").ModelInstance;
const Context = @import("context.zig").Context;
const GltfAsset = @import("gltf_asset.zig").GltfAsset;

const animation = @import("animator.zig");
const Shader = @import("shader.zig").Shader;
const StorageBuffer = @import("storage_buffer.zig").StorageBuffer;
const Frame = gpu_context.Frame;
const GpuContext = gpu_context.GpuContext;
const SkinBinding = skinning.SkinBinding;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec2 = math.vec2;
const vec3 = math.vec3;
const Mat4 = math.Mat4;
const Quat = math.Quat;

const Animator = animation.Animator;
const AnimationClip = animation.AnimationClip;

const print = log.debug;

const FrameData = struct {
    data: []Mat4,
};

pub const BakedHeader = struct {
    frame_delta: f32,
    duration: f32,
    num_frames: u32,
    num_meshes: u32,
    num_joints: u32,
    animation_offset: u32,
};

pub const BakedAnimationConfig = struct {
    frame_rate: f32 = 30.0,
    capture: union(enum) {
        all,
        indexes: []const u32,
        clips: []const AnimationClip,
    },
};

/// Animations sampled once into rows of matrices: per frame, `num_meshes` node matrices
/// then `num_joints` joint matrices. The rows are uploaded once to a storage buffer the
/// shader reads joints from; a CPU copy supplies node matrices for unskinned meshes.
pub const BakedAnimator = struct {
    anim_id: usize,
    current_time: f32,
    current_frame: u32,
    headers: []BakedHeader,
    /// CPU copy of the baked rows.
    data: []Mat4,
    storage: StorageBuffer,
    /// Group 2: the uniform ring plus `storage` as `joints`.
    object_bind_group: c.WGPUBindGroup,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, animator: *Animator, config: BakedAnimationConfig) !*BakedAnimator {
        log.debug("config: {any}", .{config});

        const baked_data = try BakedData.captureAnimationsData(context.temp_alloc, animator, config);

        const headers = try context.alloc.alloc(BakedHeader, baked_data.headers.len);
        std.mem.copyForwards(BakedHeader, headers, baked_data.headers);
        const data = try context.alloc.dupe(Mat4, baked_data.data);

        const storage = StorageBuffer.init(gpu.device, gpu.queue, "baked animation", Mat4, data);

        const bakedAnimator = try context.alloc.create(BakedAnimator);
        bakedAnimator.* = BakedAnimator{
            .anim_id = 0,
            .current_time = 0,
            .current_frame = 0,
            .headers = headers,
            .data = data,
            .storage = storage,
            .object_bind_group = bindings.createObjectBindGroup(
                gpu.device,
                gpu.bindings.object_layout,
                gpu.uniform_ring.buffer,
                storage.buffer,
                storage.size,
            ),
        };
        return bakedAnimator;
    }

    /// Frees the storage buffer holding the baked frames and its bind group.
    /// Call before the owning arena resets.
    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.object_bind_group);
        self.storage.releaseGpuObjects();
    }

    /// Select a baked animation by its index in the capture list. With `.all`
    /// this is the glTF animation index; with `.indexes` or `.clips` it is the
    /// position in the list passed at bake time. Clips are played by that index
    /// rather than by the original AnimationClip.
    pub fn playAnimationById(self: *Self, anim_id: u32) void {
        if (@as(usize, @intCast(anim_id)) >= self.headers.len) {
            log.err("BakedAnimator: Invalid animation id {d}, max is {d}", .{ anim_id, self.headers.len - 1 });
            return;
        }
        self.anim_id = @intCast(anim_id);
        self.current_time = 0;
    }

    pub fn getAnimationCount(self: *Self) u32 {
        return @intCast(self.headers.len);
    }

    pub fn getAnimationDuration(self: *Self, anim_id: u32) f32 {
        std.debug.assert(anim_id < self.headers.len);
        return self.headers[@intCast(anim_id)].duration;
    }

    pub fn updateAnimation(self: *Self, delta_time: f32) !void {
        self.current_frame = self.getFrame(delta_time);
    }

    /// Draws each mesh at its baked node matrix; skinned primitives read this frame's
    /// joints from the storage buffer. Replaces the `frameId` / `numMeshes` /
    /// `animationOffset` uniforms of redfish's pbr_anim_baked.vert.
    pub fn draw(self: *Self, model: *ModelInstance, frame: *const Frame, shader: *const Shader, model_transform: Mat4) void {
        const header = self.headers[self.anim_id];
        const row_start = header.animation_offset + self.current_frame * (header.num_meshes + header.num_joints);
        const skin: SkinBinding = .{
            .object_bind_group = self.object_bind_group,
            .joint_offset = row_start + header.num_meshes,
        };

        for (0..header.num_meshes) |index| {
            const mesh = model.gltf_asset.meshes[index];
            mesh.drawAt(frame, shader, model_transform, self.data[row_start + index], skin);
        }
    }

    fn getFrame(self: *Self, delta_time: f32) u32 {
        if (self.headers.len == 0) return 0;
        const header = self.headers[self.anim_id];
        if (header.num_frames == 1) return 0;

        self.current_time += delta_time;

        // Loop, keeping the overshoot so the clock does not drift each cycle.
        if (self.current_time >= header.duration) {
            self.current_time = @mod(self.current_time, header.duration);
        }

        const frame_index: u32 = @intFromFloat(@round(self.current_time / header.frame_delta));
        return @min(frame_index, header.num_frames - 1);
    }
};

const BakedData = struct {
    headers: []BakedHeader,
    data: []Mat4,

    pub fn captureAnimationsData(allocator: Allocator, animator: *Animator, config: BakedAnimationConfig) !*BakedData {
        var baked_animations: []*BakedAnimation = &[0]*BakedAnimation{};

        switch (config.capture) {
            .all => {
                const num_animations = animator.animations.len;
                baked_animations = try allocator.alloc(*BakedAnimation, num_animations);

                for (0..num_animations) |i| {
                    try animator.playAnimationById(@intCast(i));
                    baked_animations[i] = try BakedAnimation.bakeAnimation(allocator, animator, config.frame_rate);
                }
            },
            .indexes => |indexes| {
                const num_animations = indexes.len;
                baked_animations = try allocator.alloc(*BakedAnimation, num_animations);

                for (indexes, 0..) |index, i| {
                    try animator.playAnimationById(index);
                    baked_animations[i] = try BakedAnimation.bakeAnimation(allocator, animator, config.frame_rate);
                }
            },
            .clips => |clips| {
                const num_animations = clips.len;
                baked_animations = try allocator.alloc(*BakedAnimation, num_animations);

                for (0..num_animations) |i| {
                    try animator.playClip(clips[i]);
                    baked_animations[i] = try BakedAnimation.bakeAnimation(allocator, animator, config.frame_rate);
                }
            },
        }

        if (baked_animations.len == 0) {
            baked_animations = try allocator.alloc(*BakedAnimation, 1);
            baked_animations[0] = try BakedAnimation.bakeNodes(allocator, animator);
        }

        const baked_data = try allocator.create(BakedData);
        baked_data.*.headers = try allocator.alloc(BakedHeader, baked_animations.len);

        for (0..baked_animations.len) |i| {
            baked_data.*.headers[i] = baked_animations[i].header;
        }

        var data_size: u32 = 0;
        for (baked_animations) |baked_anim| {
            data_size += baked_anim.header.num_frames * (baked_anim.header.num_meshes + baked_anim.header.num_joints);
        }

        baked_data.*.data = try allocator.alloc(Mat4, data_size);

        var offset: usize = 0;
        for (baked_animations, 0..) |baked_anim, i| {
            baked_data.headers[i].animation_offset = @intCast(offset);
            const baked_anim_data = try baked_anim.getBakedData(allocator);
            log.debug("animation: {d}  header: {any}  data.len: {d}", .{ i, baked_anim.header, baked_anim_data.len });
            std.mem.copyForwards(Mat4, baked_data.data[offset .. offset + baked_anim_data.len], baked_anim_data);
            offset += baked_anim_data.len;
        }

        return baked_data;
    }
};

pub const BakedAnimation = struct {
    header: BakedHeader,
    frames: []FrameData,

    const Self = @This();

    pub fn bakeNodes(allocator: Allocator, animator: *Animator) !*Self {
        const num_frames: u32 = 1;
        const frame_index: u32 = 0;

        const self = try allocator.create(BakedAnimation);
        self.* = .{
            .header = .{
                .frame_delta = 0.0,
                .duration = 0.0,
                .num_frames = num_frames,
                .num_meshes = @intCast(animator.gltf_asset.gltf.meshes.?.len),
                .num_joints = 0,
                .animation_offset = 0,
            },
            .frames = try allocator.alloc(FrameData, num_frames),
        };

        try self.saveFrameData(allocator, animator, frame_index);

        return self;
    }

    pub fn bakeAnimation(allocator: Allocator, animator: *Animator, frame_rate: f32) !*Self {
        const animation_state = &animator.active_animations.list.items[0];

        const state_duration = animation_state.end_time - animation_state.start_time;
        const frame_delta = 1.0 / frame_rate;
        const num_frames: u32 = @as(u32, @ceil(state_duration / frame_delta)) + 1;

        const num_joints: u32 = if (animator.gltf_asset.gltf.skins) |skins| @intCast(skins[0].joints.len) else 0;

        const self = try allocator.create(BakedAnimation);
        self.* = .{
            .header = .{
                .frame_delta = frame_delta,
                .duration = state_duration,
                .num_frames = num_frames,
                .num_meshes = @intCast(animator.gltf_asset.gltf.meshes.?.len),
                .num_joints = num_joints,
                .animation_offset = 0,
            },
            .frames = try allocator.alloc(FrameData, num_frames),
        };

        log.debug("Initial bake data: {any}", .{self.header});

        log.debug("Frame rate; {d}  frame_delta: {d}", .{ frame_rate, frame_delta });
        log.debug("Number joints: {d}", .{self.header.num_joints});

        const completions = animation_state.num_completions;

        for (0..self.header.num_frames) |frame_index| {
            // Sample at an explicit time rather than accumulating deltas. The last
            // frame is clamped to the clip end so it captures the end pose instead
            // of wrapping to the start, which caused a duplicated frame at the loop.
            const frame_time = @min(@as(f32, @floatFromInt(frame_index)) * frame_delta, state_duration);
            animation_state.current_time = animation_state.start_time + frame_time;
            try animator.updateAnimation(0.0);
            try self.saveFrameData(allocator, animator, frame_index);
            log.debug("Frame number: {d}  frame_time: {d}  animation_state.current_time: {d}", .{ frame_index, frame_time, animation_state.current_time });
        }

        // Assert frame count is correct. One more update should bump completions
        try animator.updateAnimation(frame_delta);
        std.debug.assert(animation_state.num_completions > completions);

        return self;
    }

    fn saveFrameData(self: *BakedAnimation, allocator: Allocator, animator: *Animator, frame_index: usize) !void {
        const data = try allocator.alloc(Mat4, self.header.num_meshes + self.header.num_joints);

        // Meshes with no node, or whose node is outside the scene hierarchy, never
        // get a transform from the animator; leave those slots as identity.
        @memset(data, Mat4.Identity);

        const num_joints = self.header.num_joints;

        for (animator.gltf_asset.gltf.nodes.?, 0..) |node, node_index| {
            const mesh = node.mesh orelse continue;
            if (animator.nodes[node_index].calculated_transform) |transform| {
                data[mesh] = transform.toMatrix();
            }
        }

        if (num_joints > 0) {
            std.mem.copyForwards(Mat4, data[self.header.num_meshes..], animator.joint_matrices[0..num_joints]);
        }

        self.frames[frame_index] = FrameData{
            .data = data,
        };
    }

    pub fn getBakedData(self: *Self, allocator: Allocator) ![]Mat4 {
        const data_size = self.header.num_frames * (self.header.num_meshes + self.header.num_joints);
        const data = try allocator.alloc(Mat4, data_size);
        var index: usize = 0;
        for (self.frames) |frame| {
            std.mem.copyForwards(Mat4, data[index..], frame.data);
            index += frame.data.len;
        }
        return data;
    }

    pub fn printData(self: *BakedAnimation) void {
        log.info("BakedAnimation header:", .{});
        log.info("   frame_delta: {d}", .{self.header.frame_delta});
        log.info("   duration: {d}", .{self.header.duration});
        log.info("   num_frames: {d}", .{self.header.num_frames});
        log.info("   num_meshes: {d}", .{self.header.num_meshes});
        log.info("   num_joints: {d}", .{self.header.num_joints});
        log.info("   animation_offset: {d}", .{self.header.animation_offset});
    }
};
