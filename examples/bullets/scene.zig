const std = @import("std");
const core = @import("core");

const Frame = core.Frame;

const Allocator = std.mem.Allocator;

pub const Scene = struct {
    name: []const u8,
    dispatch: Dispatch,

    const Self = @This();

    const Dispatch = struct {
        obj_ptr: *anyopaque,
        type_id: usize,
        update_fn: *const fn (ptr: *anyopaque, state: *anyopaque) anyerror!void,
        draw_fn: *const fn (ptr: *anyopaque, frame: *const Frame, time: f32) void,
        clean_up_fn: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(allocator: Allocator, name: []const u8, object_ptr: anytype, state_ptr: anytype) !*Scene {
        const gen = struct {
            const ObjectType = @TypeOf(object_ptr);
            const StateType = @TypeOf(state_ptr);

            pub fn updateFn(obj_ptr: *anyopaque, state_pointer: *anyopaque) anyerror!void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                const state: StateType = @ptrCast(@alignCast(state_pointer));

                if (std.meta.hasMethod(ObjectType, "update")) {
                    return obj.update(state);
                }
            }

            pub fn drawFn(obj_ptr: *anyopaque, frame: *const Frame, time: f32) void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                if (std.meta.hasMethod(ObjectType, "draw")) {
                    return obj.draw(frame, time);
                }
            }

            pub fn cleanUpFn(obj_ptr: *anyopaque) void {
                const obj: ObjectType = @ptrCast(@alignCast(obj_ptr));
                if (std.meta.hasMethod(ObjectType, "cleanUp")) {
                    obj.cleanUp();
                }
            }
        };

        const scene = try allocator.create(Scene);
        scene.* = Scene{
            .name = name,
            .dispatch = .{
                .obj_ptr = object_ptr,
                .type_id = typeId(@TypeOf(object_ptr)),
                .update_fn = gen.updateFn,
                .draw_fn = gen.drawFn,
                .clean_up_fn = gen.cleanUpFn,
            },
        };
        return scene;
    }

    pub fn cleanUp(self: *Self) void {
        self.dispatch.clean_up_fn(self.dispatch.obj_ptr);
    }

    pub fn update(self: *Scene, state: *anyopaque) anyerror!void {
        try self.dispatch.update_fn(self.dispatch.obj_ptr, state);
    }

    pub fn draw(self: *Scene, frame: *const Frame, time: f32) void {
        self.dispatch.draw_fn(self.dispatch.obj_ptr, frame, time);
    }

    // Possible other functions:
    // frameStart()
    // frameEnd()
    // new()
    // exit()
    // resized()
    // render_gui()

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
