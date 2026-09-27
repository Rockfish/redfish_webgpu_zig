const std = @import("std");

pub const Component = struct {
    name: []const u8,
    ptr: *anyopaque,
    type_id: usize,
    type_name: []const u8,

    pub fn init(comptime T: type, name: []const u8, ptr: *anyopaque) Component {
        return .{
            .name = name,
            .ptr = ptr,
            .type_id = typeId(T),
            .type_name = @typeName(T),
        };
    }

    pub fn cast(self: Component, comptime T: type) ?*T {
        if (self.type_id != typeId(T)) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    fn typeId(comptime T: type) usize {
        _ = T;
        const H = struct {
            var id: u8 = 0;
        };
        return @intFromPtr(&H.id);
    }
};
