const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;

pub const SceneCamera = struct {
    name: []const u8,
    dispatch: Dispatch,

    const Self = @This();

    const Dispatch = struct {
        obj_ptr: *anyopaque,
        update_fn: *const fn (ptr: *anyopaque, input: *core.Input) anyerror!void,
        process_input_fn: *const fn (ptr: *anyopaque, input: *core.Input) anyerror!void,
        getCamera_fn: *const fn (ptr: *anyopaque) *core.Camera,
    };

    pub fn init(allocator: Allocator, name: []const u8, object_ptr: anytype) !*Self {
        const gen = struct {
            const ObjectType = @TypeOf(object_ptr);
            const node_ptr_info = @typeInfo(ObjectType);

            pub fn update(obj_ptr: *anyopaque, input: *core.Input) anyerror!void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                return obj.update(input);
            }

            pub fn processInput(obj_ptr: *anyopaque, input: *core.Input) anyerror!void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                return obj.processInput(input);
            }

            pub fn getCamera(obj_ptr: *anyopaque) *core.Camera {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                return obj.camera;
            }
        };

        const scene_camera = try allocator.create(Self);
        scene_camera.* = Self{
            .name = name,
            .dispatch = .{
                .obj_ptr = object_ptr,
                .update_fn = gen.update,
                .process_input_fn = gen.processInput,
                .getCamera_fn = gen.getCamera,
            },
        };
        return scene_camera;
    }

    pub fn update(self: *Self, input: *core.Input) anyerror!void {
        try self.dispatch.update_fn(self.dispatch.obj_ptr, input);
    }

    pub fn processInput(self: *Self, input: *core.Input) !void {
        try self.dispatch.process_input_fn(self.dispatch.obj_ptr, input);
    }

    pub fn getCamera(self: *Self) *core.Camera {
        return self.dispatch.getCamera_fn(self.dispatch.obj_ptr);
    }
};
