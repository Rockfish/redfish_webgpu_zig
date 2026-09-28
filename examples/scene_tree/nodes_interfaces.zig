const std = @import("std");
const math = @import("math");
const containers = @import("containers");
const core = @import("core");
const State = @import("main.zig").State;

const Transform = core.Transform;
const Shader = core.Shader;
const Frame = core.Frame;
const DrawUniforms = core.DrawUniforms;

const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;

pub const Node = struct {
    allocator: Allocator,
    name: []const u8,
    dispatch: Dispatch,
    parent: ?*Node,
    children: ManagedArrayList(*Node),
    transform: Transform,
    global_transform: Transform,

    const Self = @This();

    const Dispatch = struct {
        obj_ptr: *anyopaque,
        type_id: usize,
        update_fn: *const fn (ptr: *anyopaque, state: *anyopaque) anyerror!void,
        draw_fn: *const fn (ptr: *anyopaque, frame: *const Frame, shader: *const Shader, draw_uniforms: DrawUniforms) void,
        clean_up_fn: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(allocator: Allocator, name: []const u8, object_ptr: anytype, state_ptr: anytype) !*Node {
        const gen = struct {
            const ObjectType = @TypeOf(object_ptr);
            const StateType = @TypeOf(state_ptr);
            const node_ptr_info = @typeInfo(ObjectType);

            pub fn updateFn(obj_ptr: *anyopaque, state_pointer: *anyopaque) anyerror!void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                const state: StateType = @ptrCast(@alignCast(state_pointer));

                // Object should own updating animation
                if (std.meta.hasMethod(ObjectType, "updateAnimation")) {
                    return obj.updateAnimation(state.delta_time);
                }

                if (std.meta.hasMethod(ObjectType, "update")) {
                    return obj.update(state);
                }
            }

            pub fn drawFn(obj_ptr: *anyopaque, frame: *const Frame, shader: *const Shader, draw_uniforms: DrawUniforms) void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                if (std.meta.hasMethod(ObjectType, "draw")) {
                    return obj.draw(frame, shader, draw_uniforms);
                }
            }

            pub fn cleanUpFn(obj_ptr: *anyopaque) void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                if (std.meta.hasMethod(ObjectType, "cleanUp")) {
                    return obj.cleanUp();
                }
            }
        };

        std.debug.print("Node type: {s}\n", .{@typeName(@TypeOf(object_ptr))});

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
                .update_fn = gen.updateFn,
                .draw_fn = gen.drawFn,
                .clean_up_fn = gen.cleanUpFn,
            },
        };
        return node;
    }

    pub fn addChild(self: *Node, child: *Node) void {
        _ = self.children.append(child) catch unreachable;
        child.*.parent = self;
    }

    pub fn updateTransform(self: *Node, parent_transform: ?*Transform) void {
        if (parent_transform) |transform| {
            self.global_transform = transform.composeTransforms(self.transform);
        } else {
            self.global_transform = self.transform;
        }

        for (self.children.items()) |*child| {
            child.*.updateTransform(&self.global_transform);
        }
    }

    pub fn update(self: *Node, state: *anyopaque) anyerror!void {
        try self.dispatch.update_fn(self.dispatch.obj_ptr, state);
    }

    /// Draws this node with its own global transform, then its children. `color` goes to
    /// every draw in the subtree (scene_tree's shader adds it, for hit highlighting).
    pub fn draw(self: *Node, frame: *const Frame, shader: *const Shader, color: Vec4) void {
        const draw_uniforms = DrawUniforms.init(self.global_transform.toMatrix(), color);
        self.dispatch.draw_fn(self.dispatch.obj_ptr, frame, shader, draw_uniforms);
        for (self.children.items()) |child| {
            child.draw(frame, shader, color);
        }
    }

    pub fn cleanUp(self: *Self) void {
        self.dispatch.clean_up_fn(self.dispatch.obj_ptr);
    }

    pub fn castTo(self: *Self, comptime T: type) ?*T {
        if (self.dispatch.type_id != typeId(T)) {
            return null;
        }
        return @as(*T, @ptrCast(@alignCast(self.dispatch.obj_ptr)));
    }

    fn typeId(comptime T: type) usize {
        _ = T;
        const H = struct {
            var id: u8 = 0;
        };
        return @intFromPtr(&H.id);
    }
};
