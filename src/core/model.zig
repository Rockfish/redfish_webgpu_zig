const std = @import("std");
const math = @import("math");
const containers = @import("containers");
const gltf_types = @import("gltf/gltf.zig");
const GltfAsset = @import("gltf_asset.zig").GltfAsset;
const Shader = @import("shader.zig").Shader;
const Mesh = @import("mesh.zig").Mesh;
const Animator = @import("animator.zig").Animator;
const Transform = @import("transform.zig").Transform;
const AABB = @import("aabb.zig").AABB;
const gpu_context = @import("gpu_context.zig");
const skinning = @import("skinning.zig");
const Context = @import("context.zig").Context;

const Frame = gpu_context.Frame;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;

const animation = @import("animator.zig");

const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;

pub const Model = struct {
    alloc: Allocator,
    name: []const u8,
    scene: usize,
    animator: *Animator,
    gltf_asset: *GltfAsset,
    /// Joint matrices on the GPU, for skinned models.
    joint_buffer: ?skinning.JointBuffer,

    const Self = @This();

    pub fn init(
        alloc: Allocator,
        name: []const u8,
        animator: *Animator,
        gltf_asset: *GltfAsset,
    ) !*Self {
        const model = try alloc.create(Model);
        model.* = Model{
            .alloc = alloc,
            .scene = 0,
            .name = try alloc.dupe(u8, name),
            .animator = animator,
            .gltf_asset = gltf_asset,
            .joint_buffer = if (animator.skin_index != null) skinning.JointBuffer.init(gltf_asset.gpu) else null,
        };

        return model;
    }

    pub fn cleanUp(self: *Self) void {
        if (self.joint_buffer) |*joint_buffer| joint_buffer.releaseGpuObjects();
        self.gltf_asset.cleanUp();
    }

    pub fn playTick(self: *Self, tick: f32) !void {
        try self.animator.playTick(tick);
    }

    pub fn updateWeightedAnimations(self: *Self, weighted_animations: []const animation.WeightedAnimation, frame_time: f32) !void {
        try self.animator.updateWeightedAnimations(weighted_animations, frame_time);
    }

    /// Play all animations in the model simultaneously (for InterpolationTest)
    pub fn playAllAnimations(self: *Self) !void {
        try self.animator.playAllAnimations();
    }

    /// Play specific animations by indices
    pub fn playAnimations(self: *Self, animation_indices: []const u32) !void {
        try self.animator.playAnimations(animation_indices);
    }

    /// `model_transform` places the whole model (redfish's `matModel`). A skinned model
    /// uploads its current pose; draw each `Model` once per frame.
    pub fn draw(self: *Self, frame: *const Frame, shader: *const Shader, model_transform: Mat4) void {
        const skin: ?skinning.SkinBinding = if (self.joint_buffer) |*joint_buffer|
            joint_buffer.update(frame.gpu, &self.animator.joint_matrices)
        else
            null;

        const scene = self.gltf_asset.gltf.scenes.?[self.scene];

        if (scene.nodes) |nodes| {
            for (nodes) |node_index| {
                const node = self.gltf_asset.gltf.nodes.?[node_index];
                self.drawNodes(frame, shader, model_transform, skin, node, node_index);
            }
        }
    }

    fn drawNodes(
        self: *Self,
        frame: *const Frame,
        shader: *const Shader,
        model_transform: Mat4,
        skin: ?skinning.SkinBinding,
        node: gltf_types.Node,
        node_index: usize,
    ) void {
        if (!self.animator.nodes[node_index].is_visible) return;

        if (node.mesh) |mesh_index| {
            const transform = self.animator.nodes[node_index].calculated_transform.?;
            const mesh: *Mesh = self.gltf_asset.meshes[mesh_index];
            mesh.drawAt(frame, shader, model_transform, transform.toMatrix(), skin);
        }

        if (node.children) |children| {
            for (children) |child_node_index| {
                const child = self.gltf_asset.gltf.nodes.?[child_node_index];
                self.drawNodes(frame, shader, model_transform, skin, child, child_node_index);
            }
        }
    }

    pub fn updateAnimation(self: *Self, delta_time: f32) !void {
        try self.animator.updateAnimation(delta_time);
    }

    /// Index of the first node named `name`, for `nodeTransform`.
    pub fn findNode(self: *const Self, name: []const u8) ?usize {
        for (self.animator.nodes, 0..) |node, i| {
            if (node.name) |node_name| {
                if (std.mem.eql(u8, node_name, name)) return i;
            }
        }
        return null;
    }

    /// A node's transform in model space as of the last animation update, e.g. to attach
    /// an effect to an animated part.
    pub fn nodeTransform(self: *const Self, node_index: usize) Mat4 {
        const node = self.animator.nodes[node_index];
        const transform = node.calculated_transform orelse node.initial_transform;
        return transform.toMatrix();
    }
};

// Debug functions for model analysis
pub fn debugPrintModelNodeStructure(model: *Model) void {
    std.debug.print("\n--- Model Node Structure for: {s} ---\n", .{model.name});
    const scene = model.gltf_asset.gltf.scenes.?[model.scene];
    if (scene.nodes) |nodes| {
        for (nodes) |node_index| {
            const node = model.gltf_asset.gltf.nodes.?[node_index];
            debugPrintNode(model.gltf_asset, node, node_index, 0);
        }
    }

    std.debug.print("--- End Node Structure ---\n\n", .{});
}

pub fn debugMatrixMultiplication() void {
    std.debug.print("\n=== MATRIX MULTIPLICATION DEBUG ===\n", .{});

    // Create parent transform (180° Y rotation)
    const parent_transform = Transform{
        .translation = vec3(0.0, 0.0, 0.0),
        .rotation = math.quat(0.0, 1.0, 0.0, 0.0), // 180° Y rotation
        .scale = vec3(1.0, 1.0, 1.0),
    };
    const parent_matrix = parent_transform.toMatrix();

    // Create child transform (translation only)
    const child_transform = Transform{
        .translation = vec3(-3.82, 13.02, 0.0),
        .rotation = math.quat(0.0, 0.0, 0.0, 1.0), // Identity
        .scale = vec3(1.0, 1.0, 1.0),
    };
    const child_matrix = child_transform.toMatrix();

    // Test multiplication
    const result_matrix = parent_matrix.mulMat4(&child_matrix);

    // Extract translation from result
    const result_translation = vec3(result_matrix.data[3][0], result_matrix.data[3][1], result_matrix.data[3][2]);

    // Debug the matrices themselves
    std.debug.print(
        "Parent matrix [3] (translation): ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ parent_matrix.data[3][0], parent_matrix.data[3][1], parent_matrix.data[3][2], parent_matrix.data[3][3] },
    );
    std.debug.print(
        "Parent matrix [0]: ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ parent_matrix.data[0][0], parent_matrix.data[0][1], parent_matrix.data[0][2], parent_matrix.data[0][3] },
    );
    std.debug.print(
        "Parent matrix [1]: ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ parent_matrix.data[1][0], parent_matrix.data[1][1], parent_matrix.data[1][2], parent_matrix.data[1][3] },
    );
    std.debug.print(
        "Parent matrix [2]: ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ parent_matrix.data[2][0], parent_matrix.data[2][1], parent_matrix.data[2][2], parent_matrix.data[2][3] },
    );

    std.debug.print(
        "Child matrix [3] (translation): ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ child_matrix.data[3][0], child_matrix.data[3][1], child_matrix.data[3][2], child_matrix.data[3][3] },
    );

    std.debug.print(
        "Parent quaternion: ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ parent_transform.rotation.data[0], parent_transform.rotation.data[1], parent_transform.rotation.data[2], parent_transform.rotation.data[3] },
    );
    std.debug.print(
        "Child translation: ({d:.2}, {d:.2}, {d:.2})\n",
        .{ child_transform.translation.x, child_transform.translation.y, child_transform.translation.z },
    );
    std.debug.print(
        "Result matrix [3] (translation): ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ result_matrix.data[3][0], result_matrix.data[3][1], result_matrix.data[3][2], result_matrix.data[3][3] },
    );
    std.debug.print(
        "Result matrix [0]: ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n",
        .{ result_matrix.data[0][0], result_matrix.data[0][1], result_matrix.data[0][2], result_matrix.data[0][3] },
    );
    std.debug.print(
        "Result translation: ({d:.2}, {d:.2}, {d:.2})\n",
        .{ result_translation.x, result_translation.y, result_translation.z },
    );
    std.debug.print(
        "Expected (manual): ({d:.2}, {d:.2}, {d:.2})\n",
        .{ 3.82, 13.02, 0.0 },
    ); // 180° Y rotation should flip X sign
    std.debug.print("=== END MATRIX DEBUG ===\n\n", .{});
}

fn debugPrintNode(gltf_asset: *GltfAsset, node: gltf_types.Node, node_index: usize, depth: usize) void {
    var indent_buf: [20]u8 = undefined;
    for (0..depth * 2) |i| {
        if (i < indent_buf.len) indent_buf[i] = ' ';
    }
    const indent = indent_buf[0..@min(depth * 2, indent_buf.len)];

    const transform = Transform{
        .translation = node.translation orelse vec3(0.0, 0.0, 0.0),
        .rotation = node.rotation orelse math.quat(0.0, 0.0, 0.0, 1.0),
        .scale = node.scale orelse vec3(1.0, 1.0, 1.0),
    };

    std.debug.print(
        "{s}Node[{}]: mesh={?} translation=({d:.2}, {d:.2}, {d:.2}) rotation=({d:.2}, {d:.2}, {d:.2}, {d:.2}) scale=({d:.2}, {d:.2}, {d:.2})\n",
        .{ indent, node_index, node.mesh, transform.translation.x, transform.translation.y, transform.translation.z, transform.rotation.data[0], transform.rotation.data[1], transform.rotation.data[2], transform.rotation.data[3], transform.scale.x, transform.scale.y, transform.scale.z },
    );

    if (node.children) |children| {
        for (children) |child_index| {
            const child_node = gltf_asset.gltf.nodes.?[child_index];
            debugPrintNode(gltf_asset, child_node, child_index, depth + 1);
        }
    }
}

pub fn dumpModelNodes(model: *Model) !void {
    std.debug.print("\n--- Dumping nodes ---\n", .{});
    var buf: [1024:0]u8 = undefined;

    var node_iterator = model.animator.node_transform_map.iterator();
    while (node_iterator.next()) |entry| { // |node_name, node_transform| {
        const name = entry.key_ptr.*;
        const transform = entry.value_ptr.*;
        const str = transform.transform.asString(&buf);
        std.debug.print("node_name: {s} : {s}\n", .{ name, str });
    }
    std.debug.print("\n", .{});

    var bone_iterator = model.animator.bone_map.iterator();
    while (bone_iterator.next()) |entry| { // |node_name, node_transform| {
        const name = entry.key_ptr.*;
        const transform = entry.value_ptr.*;
        const str = transform.offset_transform.asString(&buf);
        std.debug.print("bone_name: {s} : {s}\n", .{ name, str });
    }
}
