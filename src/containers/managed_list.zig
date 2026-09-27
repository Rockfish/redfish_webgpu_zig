const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn ManagedArrayList(comptime T: type) type {
    return struct {
        list: std.ArrayList(T),
        allocator: Allocator,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .list = std.ArrayList(T).empty,
                .allocator = allocator,
            };
        }

        pub fn initCapacity(allocator: Allocator, cap: usize) !Self {
            return .{
                .list = try std.ArrayList(T).initCapacity(allocator, cap),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
        }

        // forward std.ArrayList methods you use most
        pub fn append(self: *Self, item: T) !void {
            try self.list.append(self.allocator, item);
        }

        pub fn appendSlice(self: *Self, itms: []const T) !void {
            try self.list.appendSlice(self.allocator, itms);
        }

        pub fn toOwnedSlice(self: *Self) ![]T {
            return try self.list.toOwnedSlice(self.allocator);
        }

        pub fn resize(self: *Self, new_len: usize) Allocator.Error!void {
            return self.list.resize(self.allocator, new_len);
        }

        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            return self.list.shrinkRetainingCapacity(new_len);
        }

        // pub const Writer = if (T != u8) void else std.Io.Writer; // (*Self, Allocator.Error, appendWrite);

        fn appendWrite(self: *Self, data: []const T) Allocator.Error!usize {
            try self.list.appendSlice(self.allocator, data);
            return data.len;
        }

        pub fn writer(self: *Self) std.Io.Writer.Allocating {
            //return .{ .context = self, .allocator = self.allocator };
            return std.Io.Writer.Allocating.init(self.allocator);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.list.clearRetainingCapacity();
        }

        pub fn clearAndFree(self: *Self) void {
            self.list.clearAndFree(self.allocator);
        }

        pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) !void {
            try self.list.ensureTotalCapacity(self.allocator, new_capacity);
        }

        // Accessor methods for ArrayList fields
        pub inline fn items(self: *Self) []T {
            return self.list.items;
        }

        pub inline fn itemsConst(self: *const Self) []const T {
            return self.list.items;
        }

        pub inline fn capacity(self: *const Self) usize {
            return self.list.capacity;
        }
    };
}
