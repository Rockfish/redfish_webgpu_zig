const std = @import("std");
const math = @import("math");
const containers = @import("containers");
const gltf_types = @import("gltf/gltf.zig");
const GltfAsset = @import("gltf_asset.zig").GltfAsset;
const Transform = @import("transform.zig").Transform;
const bindings = @import("bindings.zig");
const Context = @import("context.zig").Context;

const log = std.log.scoped(.animator);

const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const quat = math.quat;

pub const DEFAULT_ANIMATION_DURATION: f32 = 1.0;

pub const AnimationRepeatMode = union(enum) {
    Once,
    Count: u32,
    Forever,
};

/// glTF-specific animation state that tracks time in seconds
pub const AnimationState = struct {
    animation_index: u32,
    current_time: f32,
    start_time: f32,
    end_time: f32,
    repeat_mode: AnimationRepeatMode,
    num_completions: u32,

    pub fn init(
        animation_index: u32,
        start_time: f32,
        end_time: f32,
        repeat_mode: AnimationRepeatMode,
    ) AnimationState {
        return .{
            .animation_index = animation_index,
            .current_time = start_time,
            .start_time = start_time,
            .end_time = end_time,
            .repeat_mode = repeat_mode,
            .num_completions = 0,
        };
    }

    pub fn update(self: *AnimationState, delta_time: f32) void {
        self.current_time += delta_time;

        if (self.current_time > self.end_time) {
            self.num_completions +%= 1;
            switch (self.repeat_mode) {
                .Once => {
                    self.current_time = self.end_time;
                },
                .Count => |max_repeats| {
                    if (self.num_completions >= max_repeats) {
                        self.current_time = self.end_time;
                    } else {
                        // Loop back to start
                        const duration = self.end_time - self.start_time;
                        self.current_time = self.start_time + @mod(self.current_time - self.start_time, duration);
                    }
                },
                .Forever => {
                    // Loop back to start
                    const duration = self.end_time - self.start_time;
                    self.current_time = self.start_time + @mod(self.current_time - self.start_time, duration);
                },
            }
        }
    }
};

/// Animation clip that references a glTF animation by index
/// Maintains the same interface as the previous ASSIMP-based system
pub const AnimationClip = struct {
    animation_index: u32,
    start_time: f32 = 0.0,
    end_time: f32,
    repeat_mode: AnimationRepeatMode,

    pub fn init(
        animation_index: u32,
        start_time: f32,
        end_time: f32,
        repeat_mode: AnimationRepeatMode,
    ) AnimationClip {
        return .{
            .animation_index = animation_index,
            .start_time = start_time,
            .end_time = end_time,
            .repeat_mode = repeat_mode,
        };
    }
};

pub const WeightedAnimation = struct {
    animation_index: u32,
    start_time: f32, // Animation start time in seconds
    end_time: f32, // Animation end time in seconds
    weight: f32,
    offset: f32, // Time offset for animation synchronization
    optional_start: f32 = 0.0, // Optional start time for one-shot animations

    pub fn init(
        animation_index: u32,
        weight: f32,
        start_time: f32,
        end_time: f32,
        offset: f32,
        optional_start: f32,
    ) WeightedAnimation {
        return .{
            .animation_index = animation_index,
            .start_time = start_time,
            .end_time = end_time,
            .weight = weight,
            .offset = offset,
            .optional_start = optional_start,
        };
    }
};

/// Joint information from glTF skin
pub const Joint = struct {
    node_index: u32,
    inverse_bind_matrix: Mat4,
};

/// Keyframe interpolation result containing indices and interpolation factor
pub const KeyframeInfo = struct {
    start_index: usize,
    end_index: usize,
    factor: f32,
};

/// Linear interpolation modes (subset of gltf_types.Interpolation)
pub const LinearInterpolation = enum {
    linear,
    step,
};

/// Linear interpolation data structures
/// Linear/step interpolation data for Vec3 values
pub const Vec3LinearData = struct {
    interpolation: LinearInterpolation,
    keyframe_times: []const f32,
    values: []const Vec3,
};

/// Linear/step interpolation data for Quat values
pub const QuatLinearData = struct {
    interpolation: LinearInterpolation,
    keyframe_times: []const f32,
    values: []const Quat,
};

/// Linear/step interpolation data for scalar values
pub const ScalarLinearData = struct {
    interpolation: LinearInterpolation,
    keyframe_times: []const f32,
    values: []const f32,
};

/// Cubic spline data structures
/// Cubic spline data for Vec3 values (translation/scale)
pub const Vec3CubicData = struct {
    keyframe_times: []const f32,
    in_tangents: []const Vec3,
    values: []const Vec3,
    out_tangents: []const Vec3,
};

/// Cubic spline data for Quat values (rotation)
pub const QuatCubicData = struct {
    keyframe_times: []const f32,
    in_tangents: []const Quat,
    values: []const Quat,
    out_tangents: []const Quat,
};

/// Cubic spline data for scalar values (weights)
pub const ScalarCubicData = struct {
    keyframe_times: []const f32,
    in_tangents: []const f32,
    values: []const f32,
    out_tangents: []const f32,
};

/// Animation data unions
/// Translation animation data
pub const NodeTranslationData = union(enum) {
    linear: Vec3LinearData,
    cubic_spline: Vec3CubicData,
};

/// Rotation animation data
pub const NodeRotationData = union(enum) {
    linear: QuatLinearData,
    cubic_spline: QuatCubicData,
};

/// Scale animation data
pub const NodeScaleData = union(enum) {
    linear: Vec3LinearData,
    cubic_spline: Vec3CubicData,
};

/// Weight animation data
pub const NodeWeightData = union(enum) {
    linear: ScalarLinearData,
    cubic_spline: ScalarCubicData,
};

/// Pre-processed animation channels for a single node
/// Groups all animation data affecting one node together for optimal cache locality
pub const NodeAnimationData = struct {
    node_id: u32,
    translation: ?NodeTranslationData,
    rotation: ?NodeRotationData,
    scale: ?NodeScaleData,
    weights: ?NodeWeightData,
};

pub const Animation = struct {
    name: []const u8,
    duration: f32,
    node_data: []NodeAnimationData,
};

pub const Node = struct {
    name: ?[]const u8,
    children: ?[]const u32,
    mesh: ?u32,
    skin: ?u32,
    is_visible: bool = true,
    initial_transform: Transform,
    calculated_transform: ?Transform,
};

pub const Animator = struct {
    // glTF animation data references
    gltf_asset: *const GltfAsset,
    skin_index: ?u32,
    joints: []Joint,

    // Cached root nodes (calculated once at init)
    root_nodes: []u32,

    // Preprocessed initial node data with transforms extracted from TRS or matrix
    nodes: []Node,

    // Preprocessed map of mesh to node
    meshToNode: []usize,

    // Pre-processed animations with names, durations, and node data
    animations: []Animation,

    // Animation state - support multiple concurrent animations
    active_animations: ManagedArrayList(AnimationState),

    // Weighted animations for blending multiple animations together
    weight_animations: ManagedArrayList(WeightedAnimation),

    // Final matrices for rendering
    joint_matrices: [bindings.MAX_JOINTS]Mat4,

    const Self = @This();

    pub fn init(context: Context, gltf_asset: *const GltfAsset) !*Self {
        const animator = try context.alloc.create(Animator);

        // Find the skin used by a mesh with skinning data
        var skin_index: ?u32 = null;
        if (gltf_asset.gltf.skins) |skins| {
            if (skins.len > 0) {
                // Find which skin is actually used by checking scene nodes
                if (gltf_asset.gltf.nodes) |nodes| {
                    for (nodes, 0..) |node, node_idx| {
                        if (node.mesh != null and node.skin != null) {
                            skin_index = node.skin.?;
                            log.debug("Found {d} skins, using skin {d} with {d} joints (from node {d})", .{ skins.len, skin_index.?, skins[skin_index.?].joints.len, node_idx });
                            break;
                        }
                    }
                }

                // Fallback to first skin if no node with both mesh and skin found
                if (skin_index == null) {
                    skin_index = 0;
                    log.debug("Found {d} skins, using fallback skin 0 with {d} joints", .{ skins.len, skins[0].joints.len });
                }
            }
        } else {
            log.debug("No skins found in model", .{});
        }

        // Initialize joint data from skin
        var joints = try preprocessJoints(context.alloc, gltf_asset, skin_index);

        // Calculate root nodes once at initialization
        var root_nodes_list = try preprocessRootNodes(context.alloc, gltf_asset);

        // Pre-process animation channels
        const animations = try preprocessAnimationChannels(context.alloc, gltf_asset);

        // Pre-process initial nodes
        const initial_nodes = preprocessNodes(context.alloc, gltf_asset);

        // Map mesh to Node
        const meshToNode = preprocessMeshes(context.alloc, gltf_asset, initial_nodes);

        var buf: [500]u8 = undefined;
        for (initial_nodes, 0..) |node, i| {
            log.debug(
                "Node {d}: '{s}' transform: {s}",
                .{ i, node.name orelse "unnamed", node.initial_transform.asString(&buf) },
            );
        }

        animator.* = Animator{
            .gltf_asset = gltf_asset,
            .skin_index = skin_index,
            .joints = try joints.toOwnedSlice(),
            .active_animations = ManagedArrayList(AnimationState).init(context.alloc),
            .weight_animations = ManagedArrayList(WeightedAnimation).init(context.alloc),
            .root_nodes = try root_nodes_list.toOwnedSlice(),
            .nodes = initial_nodes,
            .meshToNode = meshToNode,
            .animations = animations,
            .joint_matrices = [_]Mat4{Mat4.Identity} ** bindings.MAX_JOINTS,
        };

        // Nodes start with local transforms; compose them once so models that never
        // animate still draw with world transforms.
        animator.calculateWorldTransforms();
        animator.updateJointMatrices();

        return animator;
    }

    /// Play an animation clip
    pub fn playClip(self: *Self, clip: AnimationClip) !void {
        if (clip.animation_index >= self.animations.len) {
            log.debug("Invalid animation index: {d}", .{clip.animation_index});
            return;
        }

        self.active_animations.clearRetainingCapacity();

        const anim_state = AnimationState.init(
            clip.animation_index,
            clip.start_time,
            clip.end_time,
            clip.repeat_mode,
        );
        try self.active_animations.append(anim_state);

        log.debug("Playing clip animation {any}", .{clip});
    }

    /// Play animation by index
    pub fn playAnimationById(self: *Self, animation_index: u32) !void {
        if (animation_index >= self.animations.len) {
            log.debug("Invalid animation index: {d}", .{animation_index});
            return;
        }

        const animation = self.animations[animation_index];

        log.debug(
            "Animation {d} '{s}' duration: {d:.2}s, nodes: {d}",
            .{ animation_index, animation.name, animation.duration, animation.node_data.len },
        );

        // Clear all animations, play just this one (backward compatibility)
        self.active_animations.clearRetainingCapacity();
        const anim_state = AnimationState.init(
            animation_index,
            0.0,
            animation.duration,
            .Forever,
        );
        try self.active_animations.append(anim_state);

        log.debug("Playing glTF animation {d}", .{animation_index});
    }

    /// Play animation at specific time
    pub fn playTick(self: *Self, time: f32) !void {
        // Update time for ALL active animations
        for (self.active_animations.list.items) |*anim_state| {
            anim_state.current_time = time;
        }
        if (self.active_animations.list.items.len > 0) {
            self.updateNodeTransformations();
            self.calculateWorldTransforms();
            self.updateJointMatrices();
        }
    }

    /// Play all animations in the model simultaneously (for InterpolationTest)
    pub fn playAllAnimations(self: *Self) !void {
        if (self.animations.len == 0) return;

        self.active_animations.clearRetainingCapacity();

        for (0..self.animations.len) |i| {
            const animation_index: u32 = @intCast(i);
            const animation = self.animations[animation_index];
            const anim_state = AnimationState.init(
                animation_index,
                0.0,
                animation.duration,
                .Forever,
            );
            try self.active_animations.append(anim_state);
        }

        log.debug("Playing {d} animations simultaneously", .{self.animations.len});
    }

    /// Play specific animations by indices
    pub fn playAnimations(self: *Self, animation_indices: []const u32) !void {
        self.active_animations.clearRetainingCapacity();

        for (animation_indices) |animation_index| {
            if (animation_index >= self.animations.len) continue;
            const animation = self.animations[animation_index];
            const anim_state = AnimationState.init(
                animation_index,
                0.0,
                animation.duration,
                .Forever,
            );
            try self.active_animations.append(anim_state);
        }
    }

    pub fn getAnimationCount(self: *Self) u32 {
        return @intCast(self.animations.len);
    }

    pub fn getAnimationDuration(self: *Self, anim_id: u32) f32 {
        std.debug.assert(anim_id < self.animations.len);
        return self.animations[@intCast(anim_id)].duration;
    }

    pub fn updateAnimation(self: *Self, delta_time: f32) !void {
        for (self.active_animations.list.items) |*anim_state| {
            anim_state.update(delta_time);
        }
        if (self.active_animations.list.items.len > 0) {
            self.resetNodeTransformations();
            self.updateNodeTransformations();
            self.calculateWorldTransforms();
            self.updateJointMatrices();
        }
    }

    pub fn updateWeightedAnimations(self: *Self, weighted_animations: []const WeightedAnimation, frame_time: f32) !void {
        self.resetNodeTransformations();
        self.updateNodeTransformationsWeighted(weighted_animations, frame_time);
        self.calculateWorldTransforms();
        self.updateJointMatrices();
    }

    /// Reset all node transforms to their default values using preprocessed initial nodes
    fn resetNodeTransformations(self: *Self) void {
        for (self.nodes) |*node| {
            node.calculated_transform = null;
        }
    }

    /// Update node transformations from active animation states
    fn updateNodeTransformations(self: *Self) void {
        for (self.active_animations.list.items) |anim_state| {
            const node_anim_data = self.animations[anim_state.animation_index].node_data;

            for (node_anim_data) |anim_data| {
                const initial_transform = self.nodes[anim_data.node_id].initial_transform;
                const animated_transform = getAnimatedTransform(
                    initial_transform,
                    anim_data,
                    anim_state.current_time,
                );
                self.nodes[anim_data.node_id].calculated_transform = animated_transform;
            }
        }
    }

    fn updateNodeTransformationsWeighted(self: *Self, weighted_animations: []const WeightedAnimation, frame_time: f32) void {
        for (weighted_animations) |weighted| {
            if (weighted.weight <= 0.05) continue; // Skip animations with < 5% influence

            const time_range = weighted.end_time - weighted.start_time;

            var target_anim_time: f32 = weighted.start_time;

            if (weighted.optional_start > 0.0) {
                const time = (frame_time - weighted.optional_start) + weighted.offset;
                target_anim_time += @min(time, time_range);
            } else {
                target_anim_time += @mod((frame_time + weighted.offset), time_range);
            }

            if (target_anim_time < (weighted.start_time - 0.01)) {
                std.debug.panic(
                    "target_anim_ticks: {d}  less then start_time: {d}",
                    .{ target_anim_time, weighted.start_time - 0.01 },
                );
            }
            if (target_anim_time > (weighted.end_time + 0.01)) {
                std.debug.panic(
                    "target_anim_ticks: {d}  greater then end_time: {d}",
                    .{ target_anim_time, weighted.end_time + 0.01 },
                );
            }

            const node_anim_data = self.animations[weighted.animation_index].node_data;

            for (node_anim_data) |anim_data| {
                const node = &self.nodes[anim_data.node_id];

                const animated_transform = getAnimatedTransform(
                    node.initial_transform,
                    anim_data,
                    target_anim_time,
                );

                if (node.calculated_transform) |*calculated_transform| {
                    const blended_transform = calculated_transform.blendTransforms(animated_transform, weighted.weight);
                    node.calculated_transform = blended_transform;
                } else {
                    node.calculated_transform = animated_transform;
                }
            }
        }
    }

    /// Calculate world transforms for all nodes using Transform operations
    fn calculateWorldTransforms(self: *Self) void {
        if (self.gltf_asset.gltf.nodes == null) return;

        // Calculate world transforms by traversing the scene hierarchy
        for (self.root_nodes) |root_node_index| {
            self.calculateWorldTransformRecursive(root_node_index, Transform.identity());
        }
    }

    /// Recursively calculate node transforms with proper parent-child relationships
    fn calculateWorldTransformRecursive(self: *Self, node_index: usize, parent_transform: Transform) void {
        const local_transform = self.nodes[node_index].calculated_transform orelse self.nodes[node_index].initial_transform;
        const wold_transform = parent_transform.composeTransforms(local_transform);

        self.nodes[node_index].calculated_transform = wold_transform;

        if (self.nodes[node_index].children) |children| {
            for (children) |child_index| {
                self.calculateWorldTransformRecursive(child_index, self.nodes[node_index].calculated_transform.?);
            }
        }
    }

    /// Joint matrices for skinned meshes: node world transform times inverse bind matrix.
    fn updateJointMatrices(self: *Self) void {
        // Update joint matrices for skinned meshes
        for (0..@min(self.joints.len, bindings.MAX_JOINTS)) |i| {
            const joint = self.joints[i];

            if (joint.node_index < self.nodes.len) {
                const node_matrix = self.nodes[joint.node_index].calculated_transform.?.toMatrix();
                self.joint_matrices[i] = node_matrix.mulMat4(&joint.inverse_bind_matrix);
            } else {
                self.joint_matrices[i] = Mat4.Identity;
            }
        }

        // Fill remaining slots with identity matrices
        for (self.joints.len..bindings.MAX_JOINTS) |i| {
            self.joint_matrices[i] = Mat4.Identity;
        }
    }
};

fn getAnimatedTransform(initial_transform: Transform, node_anim: NodeAnimationData, current_time: f32) Transform {
    var transform = initial_transform;

    if (getAnimatedTranslation(node_anim.translation, current_time)) |value| {
        transform.translation = value;
    }

    if (getAnimatedRotation(node_anim.rotation, current_time)) |value| {
        transform.rotation = value;
    }

    if (getAnimatedScale(node_anim.scale, current_time)) |value| {
        transform.scale = value;
    }

    // Weight animation (morph targets) - not yet implemented

    return transform;
}

/// Type testing and dispatch functions
/// Get animated translation value - tests data type and calls appropriate helper
fn getAnimatedTranslation(translation_data: ?NodeTranslationData, current_time: f32) ?Vec3 {
    if (translation_data) |data| {
        return switch (data) {
            .linear => |linear_data| interpolateVec3Linear(linear_data, current_time),
            .cubic_spline => |cubic_data| interpolateVec3Cubic(cubic_data, current_time),
        };
    }
    return null;
}

/// Get animated rotation value - tests data type and calls appropriate helper
fn getAnimatedRotation(rotation_data: ?NodeRotationData, current_time: f32) ?Quat {
    if (rotation_data) |data| {
        return switch (data) {
            .linear => |linear_data| interpolateQuatLinear(linear_data, current_time),
            .cubic_spline => |cubic_data| interpolateQuatCubic(cubic_data, current_time),
        };
    }
    return null;
}

/// Get animated scale value - tests data type and calls appropriate helper
fn getAnimatedScale(scale_data: ?NodeScaleData, current_time: f32) ?Vec3 {
    if (scale_data) |data| {
        return switch (data) {
            .linear => |linear_data| interpolateVec3Linear(linear_data, current_time),
            .cubic_spline => |cubic_data| interpolateVec3Cubic(cubic_data, current_time),
        };
    }
    return null;
}

/// Linear/step interpolation functions
/// Linear/step interpolation for Vec3
fn interpolateVec3Linear(data: Vec3LinearData, current_time: f32) Vec3 {
    const keyframe_info = findKeyframeIndices(data.keyframe_times, current_time);

    if (data.values.len == 0 or keyframe_info.start_index >= data.values.len) return vec3(0.0, 0.0, 0.0);

    const start_value = data.values[keyframe_info.start_index];
    const end_value = if (keyframe_info.end_index < data.values.len) data.values[keyframe_info.end_index] else start_value;

    return switch (data.interpolation) {
        .linear => Vec3.lerp(start_value, end_value, keyframe_info.factor),
        .step => start_value,
    };
}

/// Linear/step interpolation for Quat
fn interpolateQuatLinear(data: QuatLinearData, current_time: f32) Quat {
    const keyframe_info = findKeyframeIndices(data.keyframe_times, current_time);

    if (data.values.len == 0 or keyframe_info.start_index >= data.values.len) return quat(0.0, 0.0, 0.0, 1.0);

    const start_value = data.values[keyframe_info.start_index];
    const end_value = if (keyframe_info.end_index < data.values.len) data.values[keyframe_info.end_index] else start_value;

    return switch (data.interpolation) {
        .linear => start_value.slerp(end_value, keyframe_info.factor),
        .step => start_value,
    };
}

/// Linear/step interpolation for scalars
fn interpolateScalarLinear(data: ScalarLinearData, current_time: f32) f32 {
    const keyframe_info = findKeyframeIndices(data.keyframe_times, current_time);

    if (data.values.len == 0 or keyframe_info.start_index >= data.values.len) return 0.0;

    const start_value = data.values[keyframe_info.start_index];
    const end_value = if (keyframe_info.end_index < data.values.len) data.values[keyframe_info.end_index] else start_value;

    return switch (data.interpolation) {
        .linear => start_value + (end_value - start_value) * keyframe_info.factor,
        .step => start_value,
    };
}

/// Cubic spline interpolation functions
/// Cubic spline interpolation for Vec3
fn interpolateVec3Cubic(data: Vec3CubicData, current_time: f32) Vec3 {
    const keyframe_info = findKeyframeIndices(data.keyframe_times, current_time);

    if (keyframe_info.start_index == keyframe_info.end_index) {
        return data.values[keyframe_info.start_index];
    }

    const t = keyframe_info.factor;

    const v0 = data.values[keyframe_info.start_index];
    const v1 = data.values[keyframe_info.end_index];

    // Pre-scale tangents by keyDelta (matches Khronos exactly)
    const dt = data.keyframe_times[keyframe_info.end_index] -
        data.keyframe_times[keyframe_info.start_index];
    const a = data.in_tangents[keyframe_info.end_index].mulScalar(dt);
    const b = data.out_tangents[keyframe_info.start_index].mulScalar(dt);

    // Hermite basis functions (exactly matching Khronos hermite function)
    const t2 = t * t;
    const factor1 = t2 * (2.0 * t - 3.0) + 1.0; // = 2t³ - 3t² + 1
    const factor2 = t2 * (t - 2.0) + t; // = t³ - 2t² + t
    const factor3 = t2 * (t - 1.0); // = t³ - t²
    const factor4 = t2 * (3.0 - 2.0 * t); // = -2t³ + 3t²

    // hermite(out, a, b, c, d, t) where a=v0, b=out_tangent, c=in_tangent, d=v1
    return v0.mulScalar(factor1)
        .add(b.mulScalar(factor2))
        .add(a.mulScalar(factor3))
        .add(v1.mulScalar(factor4));
}

/// Cubic spline interpolation for Quat - component-wise Hermite + normalization
fn interpolateQuatCubic(data: QuatCubicData, current_time: f32) Quat {
    const keyframe_info = findKeyframeIndices(data.keyframe_times, current_time);

    if (keyframe_info.start_index == keyframe_info.end_index) {
        return data.values[keyframe_info.start_index];
    }

    const t = keyframe_info.factor;

    const v0 = data.values[keyframe_info.start_index];
    const v1 = data.values[keyframe_info.end_index];

    // Pre-scale tangents by keyDelta (matches Khronos exactly)
    const dt = data.keyframe_times[keyframe_info.end_index] -
        data.keyframe_times[keyframe_info.start_index];

    const a = Quat{ .data = .{
        dt * data.in_tangents[keyframe_info.end_index].data[0],
        dt * data.in_tangents[keyframe_info.end_index].data[1],
        dt * data.in_tangents[keyframe_info.end_index].data[2],
        dt * data.in_tangents[keyframe_info.end_index].data[3],
    } };

    const b = Quat{ .data = .{
        dt * data.out_tangents[keyframe_info.start_index].data[0],
        dt * data.out_tangents[keyframe_info.start_index].data[1],
        dt * data.out_tangents[keyframe_info.start_index].data[2],
        dt * data.out_tangents[keyframe_info.start_index].data[3],
    } };

    // Hermite basis functions (exactly matching Khronos hermite function)
    const t2 = t * t;
    const factor1 = t2 * (2.0 * t - 3.0) + 1.0; // = 2t³ - 3t² + 1
    const factor2 = t2 * (t - 2.0) + t; // = t³ - 2t² + t
    const factor3 = t2 * (t - 1.0); // = t³ - t²
    const factor4 = t2 * (3.0 - 2.0 * t); // = -2t³ + 3t²

    // Component-wise calculation (exactly matches Khronos hermite function)
    // hermite(out, a, b, c, d, t) where a=v0, b=out_tangent, c=in_tangent, d=v1
    const result = Quat{
        .data = .{
            v0.data[0] * factor1 + b.data[0] * factor2 + a.data[0] * factor3 + v1.data[0] * factor4, // x
            v0.data[1] * factor1 + b.data[1] * factor2 + a.data[1] * factor3 + v1.data[1] * factor4, // y
            v0.data[2] * factor1 + b.data[2] * factor2 + a.data[2] * factor3 + v1.data[2] * factor4, // z
            v0.data[3] * factor1 + b.data[3] * factor2 + a.data[3] * factor3 + v1.data[3] * factor4, // w
        },
    };

    // Normalize result (essential for quaternions)
    return result.toNormalized();
}

/// Cubic spline interpolation for scalars
fn interpolateScalarCubic(data: ScalarCubicData, current_time: f32) f32 {
    const keyframe_info = findKeyframeIndices(data.keyframe_times, current_time);

    if (keyframe_info.start_index == keyframe_info.end_index) {
        return data.values[keyframe_info.start_index];
    }

    const t = keyframe_info.factor;

    const v0 = data.values[keyframe_info.start_index];
    const v1 = data.values[keyframe_info.end_index];

    // Pre-scale tangents by keyDelta (matches Khronos exactly)
    const dt = data.keyframe_times[keyframe_info.end_index] -
        data.keyframe_times[keyframe_info.start_index];
    const a = data.in_tangents[keyframe_info.end_index] * dt;
    const b = data.out_tangents[keyframe_info.start_index] * dt;

    // Hermite basis functions (exactly matching Khronos hermite function)
    const t2 = t * t;
    const factor1 = t2 * (2.0 * t - 3.0) + 1.0; // = 2t³ - 3t² + 1
    const factor2 = t2 * (t - 2.0) + t; // = t³ - 2t² + t
    const factor3 = t2 * (t - 1.0); // = t³ - t²
    const factor4 = t2 * (3.0 - 2.0 * t); // = -2t³ + 3t²

    // hermite(out, a, b, c, d, t) where a=v0, b=out_tangent, c=in_tangent, d=v1
    return v0 * factor1 + b * factor2 + a * factor3 + v1 * factor4;
}

/// Get the last keyframe time from a keyframe times array
fn getLastKeyframeTime(keyframe_times: []const f32) f32 {
    return if (keyframe_times.len > 0) keyframe_times[keyframe_times.len - 1] else 0.0;
}

/// Find interpolation factor and surrounding keyframe indices
fn findKeyframeIndices(times: []const f32, current_time: f32) KeyframeInfo {
    if (times.len == 0) return .{ .start_index = 0, .end_index = 0, .factor = 0.0 };
    if (times.len == 1) return .{ .start_index = 0, .end_index = 0, .factor = 0.0 };

    // Find the keyframes that surround the current time
    for (0..times.len - 1) |i| {
        if (current_time >= times[i] and current_time <= times[i + 1]) {
            const duration = times[i + 1] - times[i];
            const factor = if (duration > 0.0) (current_time - times[i]) / duration else 0.0;
            return .{ .start_index = i, .end_index = i + 1, .factor = factor };
        }
    }

    // If we're past the end, use the last keyframe
    if (current_time >= times[times.len - 1]) {
        return .{ .start_index = times.len - 1, .end_index = times.len - 1, .factor = 0.0 };
    }

    // If we're before the start, use the first keyframe
    return .{ .start_index = 0, .end_index = 0, .factor = 0.0 };
}

/// Helper function to read accessor data as f32 slice (standalone version for preprocessing)
fn readAccessorAsF32Slice(gltf_asset: *const GltfAsset, accessor_index: u32) []const f32 {
    const accessor = gltf_asset.gltf.accessors.?[accessor_index];
    const buffer_view = gltf_asset.gltf.buffer_views.?[accessor.buffer_view.?];
    const buffer_data = gltf_asset.buffer_data.list.items[buffer_view.buffer];

    const start = accessor.byte_offset + buffer_view.byte_offset;
    const data_size = @sizeOf(f32) * accessor.count;
    const end = start + data_size;

    const data = buffer_data[start..end];
    return @as([*]const f32, @ptrCast(@alignCast(data)))[0..accessor.count];
}

/// Helper function to read accessor data as Vec3 slice (standalone version for preprocessing)
fn readAccessorAsVec3Slice(gltf_asset: *const GltfAsset, accessor_index: u32) []const Vec3 {
    const accessor = gltf_asset.gltf.accessors.?[accessor_index];
    const buffer_view = gltf_asset.gltf.buffer_views.?[accessor.buffer_view.?];
    const buffer_data = gltf_asset.buffer_data.list.items[buffer_view.buffer];

    const start = accessor.byte_offset + buffer_view.byte_offset;
    const data_size = @sizeOf(Vec3) * accessor.count;
    const end = start + data_size;

    const data = buffer_data[start..end];
    return @as([*]const Vec3, @ptrCast(@alignCast(data)))[0..accessor.count];
}

/// Helper function to read accessor data as Quat slice (standalone version for preprocessing)
fn readAccessorAsQuatSlice(gltf_asset: *const GltfAsset, accessor_index: u32) []const Quat {
    const accessor = gltf_asset.gltf.accessors.?[accessor_index];
    const buffer_view = gltf_asset.gltf.buffer_views.?[accessor.buffer_view.?];
    const buffer_data = gltf_asset.buffer_data.list.items[buffer_view.buffer];

    const start = accessor.byte_offset + buffer_view.byte_offset;
    const data_size = @sizeOf(Quat) * accessor.count;
    const end = start + data_size;

    const data = buffer_data[start..end];
    return @as([*]const Quat, @ptrCast(@alignCast(data)))[0..accessor.count];
}

/// Pre-process all animation channels into Animation structs with pre-calculated durations
/// Groups all animation data affecting each node together for better cache locality
fn preprocessAnimationChannels(allocator: Allocator, gltf_asset: *const GltfAsset) ![]Animation {
    if (gltf_asset.gltf.animations) |gltf_animations| {
        var all_animations: []Animation = allocator.alloc(Animation, gltf_animations.len) catch {
            std.debug.panic("Failed to allocate memory for animations\n", .{});
        };

        for (gltf_animations, 0..) |gltf_animation, anim_idx| {
            // Use a HashMap to group channels by node_id
            var node_channel_map = std.HashMap(
                u32,
                NodeAnimationData,
                std.hash_map.AutoContext(u32),
                std.hash_map.default_max_load_percentage,
            ).init(allocator);
            defer node_channel_map.deinit();

            // Process each channel in this animation
            for (gltf_animation.channels) |channel| {
                const node_id = channel.target.node orelse continue;
                const sampler = gltf_animation.samplers[channel.sampler];

                // Read input and output data once
                const input_times = readAccessorAsF32Slice(gltf_asset, sampler.input);

                // Get or create NodeAnimationData for this node
                var node_channels = node_channel_map.get(node_id) orelse NodeAnimationData{
                    .node_id = node_id,
                    .translation = null,
                    .rotation = null,
                    .scale = null,
                    .weights = null,
                };

                // Add the appropriate channel data
                switch (channel.target.path) {
                    .translation => {
                        switch (sampler.interpolation) {
                            .linear, .step => {
                                const output_values = readAccessorAsVec3Slice(gltf_asset, sampler.output);
                                node_channels.translation = NodeTranslationData{
                                    .linear = Vec3LinearData{
                                        .interpolation = toLinearInterpolation(sampler.interpolation),
                                        .keyframe_times = input_times,
                                        .values = output_values,
                                    },
                                };
                            },
                            .cubic_spline => {
                                const cubic_data = try parseCubicSplineVec3Data(allocator, gltf_asset, sampler.output);
                                node_channels.translation = NodeTranslationData{
                                    .cubic_spline = Vec3CubicData{
                                        .keyframe_times = input_times,
                                        .in_tangents = cubic_data.in_tangents,
                                        .values = cubic_data.values,
                                        .out_tangents = cubic_data.out_tangents,
                                    },
                                };
                                log.debug("Parsed cubic spline translation with {d} keyframes", .{cubic_data.values.len});
                            },
                        }
                    },
                    .rotation => {
                        switch (sampler.interpolation) {
                            .linear, .step => {
                                const output_values = readAccessorAsQuatSlice(gltf_asset, sampler.output);
                                node_channels.rotation = NodeRotationData{
                                    .linear = QuatLinearData{
                                        .interpolation = toLinearInterpolation(sampler.interpolation),
                                        .keyframe_times = input_times,
                                        .values = output_values,
                                    },
                                };
                            },
                            .cubic_spline => {
                                const cubic_data = try parseCubicSplineQuatData(allocator, gltf_asset, sampler.output);
                                node_channels.rotation = NodeRotationData{
                                    .cubic_spline = QuatCubicData{
                                        .keyframe_times = input_times,
                                        .in_tangents = cubic_data.in_tangents,
                                        .values = cubic_data.values,
                                        .out_tangents = cubic_data.out_tangents,
                                    },
                                };
                                log.debug("Parsed cubic spline rotation with {d} keyframes", .{cubic_data.values.len});
                            },
                        }
                    },
                    .scale => {
                        switch (sampler.interpolation) {
                            .linear, .step => {
                                const output_values = readAccessorAsVec3Slice(gltf_asset, sampler.output);
                                node_channels.scale = NodeScaleData{
                                    .linear = Vec3LinearData{
                                        .interpolation = toLinearInterpolation(sampler.interpolation),
                                        .keyframe_times = input_times,
                                        .values = output_values,
                                    },
                                };
                            },
                            .cubic_spline => {
                                const cubic_data = try parseCubicSplineVec3Data(allocator, gltf_asset, sampler.output);
                                node_channels.scale = NodeScaleData{
                                    .cubic_spline = Vec3CubicData{
                                        .keyframe_times = input_times,
                                        .in_tangents = cubic_data.in_tangents,
                                        .values = cubic_data.values,
                                        .out_tangents = cubic_data.out_tangents,
                                    },
                                };
                                log.debug("Parsed cubic spline scale with {d} keyframes", .{cubic_data.values.len});
                            },
                        }
                    },
                    .weights => {
                        switch (sampler.interpolation) {
                            .linear, .step => {
                                const output_values = readAccessorAsF32Slice(gltf_asset, sampler.output);
                                node_channels.weights = NodeWeightData{
                                    .linear = ScalarLinearData{
                                        .interpolation = toLinearInterpolation(sampler.interpolation),
                                        .keyframe_times = input_times,
                                        .values = output_values,
                                    },
                                };
                            },
                            .cubic_spline => {
                                const cubic_data = try parseCubicSplineScalarData(allocator, gltf_asset, sampler.output);
                                node_channels.weights = NodeWeightData{
                                    .cubic_spline = ScalarCubicData{
                                        .keyframe_times = input_times,
                                        .in_tangents = cubic_data.in_tangents,
                                        .values = cubic_data.values,
                                        .out_tangents = cubic_data.out_tangents,
                                    },
                                };
                                log.debug("Parsed cubic spline weights with {d} keyframes", .{cubic_data.values.len});
                            },
                        }
                    },
                }

                // Update the map
                try node_channel_map.put(node_id, node_channels);
            }

            // Convert HashMap to array
            const node_channels_list = try allocator.alloc(NodeAnimationData, node_channel_map.count());
            var iterator = node_channel_map.iterator();
            var i: usize = 0;
            while (iterator.next()) |entry| {
                node_channels_list[i] = entry.value_ptr.*;
                i += 1;
            }

            // Calculate animation duration from all channels
            var max_time: f32 = 0.0;
            for (node_channels_list) |node_anim| {
                if (node_anim.translation) |translation_data| {
                    const keyframe_times = switch (translation_data) {
                        .linear => |linear_data| linear_data.keyframe_times,
                        .cubic_spline => |cubic_data| cubic_data.keyframe_times,
                    };
                    max_time = @max(max_time, getLastKeyframeTime(keyframe_times));
                }
                if (node_anim.rotation) |rotation_data| {
                    const keyframe_times = switch (rotation_data) {
                        .linear => |linear_data| linear_data.keyframe_times,
                        .cubic_spline => |cubic_data| cubic_data.keyframe_times,
                    };
                    max_time = @max(max_time, getLastKeyframeTime(keyframe_times));
                }
                if (node_anim.scale) |scale_data| {
                    const keyframe_times = switch (scale_data) {
                        .linear => |linear_data| linear_data.keyframe_times,
                        .cubic_spline => |cubic_data| cubic_data.keyframe_times,
                    };
                    max_time = @max(max_time, getLastKeyframeTime(keyframe_times));
                }
                if (node_anim.weights) |weight_data| {
                    const keyframe_times = switch (weight_data) {
                        .linear => |linear_data| linear_data.keyframe_times,
                        .cubic_spline => |cubic_data| cubic_data.keyframe_times,
                    };
                    max_time = @max(max_time, getLastKeyframeTime(keyframe_times));
                }
            }

            // Use default duration if no time data found
            if (max_time == 0.0) {
                max_time = DEFAULT_ANIMATION_DURATION;
            }

            // Create Animation struct with name, duration, and node data
            const animation_name = if (gltf_animation.name) |name| name else try std.fmt.allocPrint(allocator, "Animation_{d}", .{anim_idx});

            all_animations[anim_idx] = Animation{
                .name = animation_name,
                .duration = max_time,
                .node_data = node_channels_list,
            };

            log.debug(
                "Pre-processed animation {d} '{s}': {d:.2}s duration, {d} nodes with animation data",
                .{ anim_idx, animation_name, max_time, node_channels_list.len },
            );
        }

        return all_animations;
    }

    const all_animations: []Animation = allocator.alloc(Animation, 0) catch {
        std.debug.panic("Failed to allocate memory for animations\n", .{});
    };
    return all_animations;
}

/// Preprocess all glTF nodes into Node structs with transforms extracted from either TRS or matrix
fn preprocessNodes(allocator: Allocator, gltf_asset: *const GltfAsset) []Node {
    if (gltf_asset.gltf.nodes) |gltf_nodes| {
        var nodes = allocator.alloc(Node, gltf_nodes.len) catch {
            std.debug.panic("Failed to allocate memory for nodes\n", .{});
        };

        for (gltf_nodes, 0..) |gltf_node, i| {
            var transform: Transform = undefined;

            if (gltf_node.matrix) |matrix| {
                transform = Transform.fromMatrix(&matrix);
            } else {
                transform = Transform{
                    .translation = gltf_node.translation orelse Vec3.Zero,
                    .rotation = gltf_node.rotation orelse Quat.Identity,
                    .scale = gltf_node.scale orelse Vec3.One,
                };
            }

            nodes[i] = Node{
                .name = gltf_node.name,
                .children = gltf_node.children,
                .mesh = gltf_node.mesh,
                .skin = gltf_node.skin,
                .initial_transform = transform,
                .calculated_transform = transform,
            };
        }

        log.debug("Preprocessed {d} nodes with transform data", .{nodes.len});
        return nodes;
    }

    const nodes: []Node = allocator.alloc(Node, 0) catch {
        std.debug.panic("Failed to allocate memory for nodes\n", .{});
    };
    return nodes;
}

// Create an array of mesh to node indexes
fn preprocessMeshes(allocator: Allocator, gltf_asset: *const GltfAsset, nodes: []Node) []usize {
    if (gltf_asset.gltf.meshes) |gltf_meshes| {
        var meshToNode = allocator.alloc(usize, gltf_meshes.len) catch {
            std.debug.panic("Failed to allocate memory for mesh to nodes array\n", .{});
        };

        for (0..nodes.len) |node_index| {
            if (nodes[node_index].mesh) |mesh_index| {
                meshToNode[mesh_index] = node_index;
            }
        }
        return meshToNode;
    }

    const meshToNode = allocator.alloc(usize, 0) catch {
        std.debug.panic("Failed to allocate memory for mesh to nodes array\n", .{});
    };
    return meshToNode;
}

/// Preprocess joint data from glTF skin information
fn preprocessJoints(allocator: Allocator, gltf_asset: *const GltfAsset, skin_index: ?u32) !ManagedArrayList(Joint) {
    var joints = ManagedArrayList(Joint).init(allocator);

    if (skin_index) |skin_idx| {
        if (gltf_asset.gltf.skins) |skins| {
            const skin = skins[skin_idx];

            // Get inverse bind matrices
            var inverse_bind_matrices: []Mat4 = &[_]Mat4{};
            if (skin.inverse_bind_matrices) |ibm_accessor_index| {
                // Read actual inverse bind matrices from accessor data
                const accessor = gltf_asset.gltf.accessors.?[ibm_accessor_index];
                const buffer_view = gltf_asset.gltf.buffer_views.?[accessor.buffer_view.?];
                const buffer_data = gltf_asset.buffer_data.list.items[buffer_view.buffer];

                const start = accessor.byte_offset + buffer_view.byte_offset;
                const data_size = @sizeOf(Mat4) * accessor.count;
                const end = start + data_size;

                const data = buffer_data[start..end];
                const matrices_data = @as([*]const Mat4, @ptrCast(@alignCast(data)))[0..accessor.count];

                inverse_bind_matrices = try allocator.alloc(Mat4, matrices_data.len);
                @memcpy(inverse_bind_matrices, matrices_data);
            } else {
                // Fallback to identity matrices if no inverse bind matrices provided
                inverse_bind_matrices = try allocator.alloc(Mat4, skin.joints.len);
                for (0..skin.joints.len) |i| {
                    inverse_bind_matrices[i] = Mat4.Identity;
                }
            }

            // Create joint array
            for (0..skin.joints.len) |i| {
                const joint = Joint{
                    .node_index = skin.joints[i],
                    .inverse_bind_matrix = if (inverse_bind_matrices.len > i) inverse_bind_matrices[i] else Mat4.Identity,
                };
                try joints.append(joint);
            }
        }
    }

    return joints;
}

/// Preprocess root nodes by identifying nodes that are not children of other nodes
fn preprocessRootNodes(allocator: Allocator, gltf_asset: *const GltfAsset) !ManagedArrayList(u32) {
    var root_nodes_list = ManagedArrayList(u32).init(allocator);

    if (gltf_asset.gltf.nodes) |nodes| {
        var is_child = try allocator.alloc(bool, nodes.len);
        defer allocator.free(is_child);

        // Initialize all as root nodes
        for (0..nodes.len) |i| {
            is_child[i] = false;
        }

        // Mark child nodes
        for (0..nodes.len) |i| {
            const node = nodes[i];
            if (node.children) |children| {
                for (children) |child_index| {
                    if (child_index < is_child.len) {
                        is_child[child_index] = true;
                    }
                }
            }
        }

        // Collect root nodes
        for (0..nodes.len) |i| {
            if (!is_child[i]) {
                try root_nodes_list.append(@intCast(i));
            }
        }
    }

    return root_nodes_list;
}

/// Helper function to parse cubic spline Vec3 data from accessor
/// glTF cubic spline layout: [in_tangent0, value0, out_tangent0, in_tangent1, value1, out_tangent1, ...]
fn parseCubicSplineVec3Data(allocator: Allocator, gltf_asset: *const GltfAsset, accessor_index: u32) !struct { in_tangents: []Vec3, values: []Vec3, out_tangents: []Vec3 } {
    const raw_data = readAccessorAsVec3Slice(gltf_asset, accessor_index);

    // Each keyframe has 3 Vec3s: in_tangent, value, out_tangent
    const keyframe_count = raw_data.len / 3;
    var in_tangents = try allocator.alloc(Vec3, keyframe_count);
    var values = try allocator.alloc(Vec3, keyframe_count);
    var out_tangents = try allocator.alloc(Vec3, keyframe_count);

    for (0..keyframe_count) |i| {
        const base_index = i * 3;
        in_tangents[i] = raw_data[base_index + 0];
        values[i] = raw_data[base_index + 1];
        out_tangents[i] = raw_data[base_index + 2];
    }

    return .{ .in_tangents = in_tangents, .values = values, .out_tangents = out_tangents };
}

/// Helper function to parse cubic spline Quat data from accessor
/// glTF cubic spline layout: [in_tangent0, value0, out_tangent0, in_tangent1, value1, out_tangent1, ...]
fn parseCubicSplineQuatData(allocator: Allocator, gltf_asset: *const GltfAsset, accessor_index: u32) !struct { in_tangents: []Quat, values: []Quat, out_tangents: []Quat } {
    const raw_data = readAccessorAsQuatSlice(gltf_asset, accessor_index);

    // Each keyframe has 3 Quats: in_tangent, value, out_tangent
    const keyframe_count = raw_data.len / 3;
    var in_tangents = try allocator.alloc(Quat, keyframe_count);
    var values = try allocator.alloc(Quat, keyframe_count);
    var out_tangents = try allocator.alloc(Quat, keyframe_count);

    for (0..keyframe_count) |i| {
        const base_index = i * 3;
        in_tangents[i] = raw_data[base_index + 0];
        values[i] = raw_data[base_index + 1];
        out_tangents[i] = raw_data[base_index + 2];
    }

    return .{ .in_tangents = in_tangents, .values = values, .out_tangents = out_tangents };
}

/// Helper function to parse cubic spline scalar data from accessor
/// glTF cubic spline layout: [in_tangent0, value0, out_tangent0, in_tangent1, value1, out_tangent1, ...]
fn parseCubicSplineScalarData(allocator: Allocator, gltf_asset: *const GltfAsset, accessor_index: u32) !struct { in_tangents: []f32, values: []f32, out_tangents: []f32 } {
    const raw_data = readAccessorAsF32Slice(gltf_asset, accessor_index);

    // Each keyframe has 3 scalars: in_tangent, value, out_tangent
    const keyframe_count = raw_data.len / 3;
    var in_tangents = try allocator.alloc(f32, keyframe_count);
    var values = try allocator.alloc(f32, keyframe_count);
    var out_tangents = try allocator.alloc(f32, keyframe_count);

    for (0..keyframe_count) |i| {
        const base_index = i * 3;
        in_tangents[i] = raw_data[base_index + 0];
        values[i] = raw_data[base_index + 1];
        out_tangents[i] = raw_data[base_index + 2];
    }

    return .{ .in_tangents = in_tangents, .values = values, .out_tangents = out_tangents };
}

/// Convert from gltf_types.Interpolation to LinearInterpolation
/// Panics if the interpolation is cubic_spline since that should not be used with linear data
fn toLinearInterpolation(interpolation: gltf_types.Interpolation) LinearInterpolation {
    return switch (interpolation) {
        .linear => .linear,
        .step => .step,
        .cubic_spline => @panic("cubic_spline interpolation should not be used with linear data"),
    };
}
