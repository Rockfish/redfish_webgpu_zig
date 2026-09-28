const std = @import("std");
const assert = std.debug.assert;
const math = @import("math");
const core = @import("core");
const containers = @import("containers");
const Transform = @import("core").Transform;
const Shader = @import("core").Shader;
const AABB = @import("core").AABB;

const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Quat = math.Quat;

pub const Node = struct {
    allocator: Allocator,
    name: []const u8,
    dispatch: Dispatch,
    parent: ?*Node,
    children: ManagedArrayList(*Node),
    transform: Transform,
    global_transform: Transform,
    is_visible: bool = true,

    const Self = @This();

    const Dispatch = struct {
        obj_ptr: *anyopaque,
        type_id: usize,
        draw_fn: *const fn (ptr: *anyopaque, frame: *const Frame, shader: *const Shader, draw_uniforms: DrawUniforms) void,
        update_animation_fn: *const fn (ptr: *anyopaque, delta_time: f32) void,
        get_bounding_box_fn: *const fn (ptr: *anyopaque) ?AABB,
    };

    pub fn init(allocator: Allocator, name: []const u8, object_ptr: anytype) !*Node {
        const gen = struct {
            const ObjectType = @TypeOf(object_ptr);

            pub fn drawFn(obj_ptr: *anyopaque, frame: *const Frame, shader: *const Shader, draw_uniforms: DrawUniforms) void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                if (std.meta.hasMethod(ObjectType, "draw")) {
                    return obj.draw(frame, shader, draw_uniforms);
                }
            }

            pub fn updateAnimationFn(obj_ptr: *anyopaque, delta_time: f32) void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                if (std.meta.hasMethod(ObjectType, "updateAnimation")) {
                    obj.updateAnimation(delta_time) catch {};
                }
            }

            pub fn getBoundingBoxFn(obj_ptr: *anyopaque) ?AABB {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                if (std.meta.hasMethod(ObjectType, "getBoundingBox")) {
                    return obj.getBoundingBox();
                }
                return null;
            }
        };

        const node = try allocator.create(Node);
        node.* = Node{
            .allocator = allocator,
            .name = name,
            .parent = null,
            .children = ManagedArrayList(*Node).init(allocator),
            .transform = Transform.identity(),
            .global_transform = Transform.identity(),
            .dispatch = .{
                .obj_ptr = object_ptr,
                .type_id = typeId(@TypeOf(object_ptr)),
                .draw_fn = gen.drawFn,
                .update_animation_fn = gen.updateAnimationFn,
                .get_bounding_box_fn = gen.getBoundingBoxFn,
            },
        };
        return node;
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
        self.allocator.destroy(self);
    }

    /// Add child
    pub fn addChild(self: *Node, child: *Node) !void {
        assert(self != child);
        if (child.parent) |p| {
            if (p == self) return;

            // Leave old parent
            for (p.children.list.items, 0..) |_c, idx| {
                if (_c == child) {
                    _ = p.children.list.swapRemove(idx);
                    break;
                }
            } else unreachable;
        }

        child.parent = self;
        try self.children.append(child);
    }

    /// Remove child
    pub fn removeChild(self: *Node, child: *Node) void {
        if (child.parent) |p| {
            if (p != self) return;

            for (self.children.list.items, 0..) |_c, idx| {
                if (_c == child) {
                    _ = self.children.list.swapRemove(idx);
                    break;
                }
            } else unreachable;
        }

        child.parent = null;
    }

    /// Remove itself from scene
    pub fn removeSelf(self: *Node) void {
        if (self.parent) |p| {
            // Leave old parent
            for (p.children.list.items, 0..) |c, idx| {
                if (self == c) {
                    _ = p.children.list.swapRemove(idx);
                    break;
                }
            } else unreachable;

            self.parent = null;
        }
    }

    /// Update all objects' transform matrix in tree
    pub fn updateTransforms(self: *Node, parent_transform: ?*Transform) void {
        if (parent_transform) |transform| {
            self.global_transform = transform.composeTransforms(self.transform);
        } else {
            self.global_transform = self.transform;
        }

        for (self.children.list.items) |child| {
            child.updateTransforms(&self.global_transform);
        }
    }

    pub fn setTransform(self: *Node, transform: Transform) void {
        self.transform = transform;
        self.updateTransforms(null);
    }

    pub fn setTranslation(self: *Node, translation: Vec3) void {
        self.transform.translation = translation;
        self.updateTransforms(null);
    }

    pub fn setRotation(self: *Node, rotation: Quat) void {
        self.transform.rotation = rotation;
        self.updateTransforms(null);
    }

    pub fn setScale(self: *Node, scale: Vec3) void {
        self.transform.scale = scale;
        self.updateTransforms(null);
    }

    /// `color` is added to the shape's color (redfish's hitColor).
    pub fn draw(self: *Node, frame: *const Frame, shader: *const Shader, color: Vec4) void {
        const draw_uniforms = DrawUniforms.init(self.global_transform.toMatrix(), color);
        self.dispatch.draw_fn(self.dispatch.obj_ptr, frame, shader, draw_uniforms);
    }

    pub fn updateAnimation(self: *Node, delta_time: f32) void {
        self.dispatch.update_animation_fn(self.dispatch.obj_ptr, delta_time);
    }

    pub fn getBoundingBox(self: *Node) ?AABB {
        return self.dispatch.get_bounding_box_fn(self.dispatch.obj_ptr);
    }

    pub fn castTo(self: *Self, comptime T: type) ?T {
        if (self.dispatch.type_id != typeId(T)) return null;
        return @as(T, @ptrCast(@alignCast(self.dispatch.obj_ptr)));
    }

    fn typeId(comptime T: type) usize {
        _ = T;
        const H = struct {
            var id: u8 = 0;
        };
        return @intFromPtr(&H.id);
    }
};

pub const NodeManager = struct {
    allocator: Allocator,
    node_list: ManagedArrayList(*Node),

    const Self = @This();

    pub fn init(allocator: Allocator) !*Self {
        const manager = try allocator.create(Self);
        manager.* = .{
            .allocator = allocator,
            .node_list = ManagedArrayList(*Node).init(allocator),
        };
        return manager;
    }

    pub fn deinit(self: *Self) void {
        for (self.node_list.list.items) |node| {
            node.deinit();
        }
        self.node_list.deinit();
        self.allocator.destroy(self);
    }

    pub fn create(self: *Self, name: []const u8, object_ptr: anytype) !*Node {
        const node = try Node.init(self.allocator, name, object_ptr);
        try self.node_list.append(node);
        return node;
    }
};
