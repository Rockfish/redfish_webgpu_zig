const std = @import("std");
const containers = @import("containers");
const testing = std.testing;

pub fn removeRange(comptime T: type, list: *containers.ManagedArrayList(T), start: usize, end: usize) !void {
    if (start >= end or end > list.list.items.len) {
        return error.InvalidRange;
    }
    const count = end - start; // + 1;

    // Call deinit on each item in the range if T is a pointer type
    if (@typeInfo(T) == .pointer) {
        for (start..end) |i| {
            list.list.items[i].deinit();
        }
    }

    // Move the items to fill the gap using bulk memory copy
    // Use copyForwards since we're moving data to lower addresses (overlapping memory)
    if (end < list.list.items.len) {
        const src = list.list.items[end..];
        const dest = list.list.items[start..];
        std.mem.copyForwards(T, dest, src);
    }

    // Update the length of the list
    list.shrinkRetainingCapacity(list.list.items.len - count);
}

test "removeRange removes values and closes the gap" {
    var list = containers.ManagedArrayList(u32).init(testing.allocator);
    defer list.deinit();
    for (0..10) |i| {
        try list.append(@intCast(i));
    }

    try removeRange(u32, &list, 2, 5);

    try testing.expectEqualSlices(u32, &.{ 0, 1, 5, 6, 7, 8, 9 }, list.list.items);
}

test "removeRange deinits removed pointers" {
    const Item = struct {
        value: u32,
        allocator: std.mem.Allocator,

        fn deinit(self: *@This()) void {
            self.allocator.destroy(self);
        }
    };

    var list = containers.ManagedArrayList(*Item).init(testing.allocator);
    defer list.deinit();
    for (0..5) |i| {
        const item = try testing.allocator.create(Item);
        item.* = .{ .value = @intCast(i), .allocator = testing.allocator };
        try list.append(item);
    }

    // testing.allocator fails the test if a removed item leaks or is freed twice.
    try removeRange(*Item, &list, 1, 3);

    try testing.expectEqual(@as(usize, 3), list.list.items.len);
    try testing.expectEqual(@as(u32, 0), list.list.items[0].value);
    try testing.expectEqual(@as(u32, 3), list.list.items[1].value);
    try testing.expectEqual(@as(u32, 4), list.list.items[2].value);
    for (list.list.items) |item| {
        item.deinit();
    }
}

test "removeRange rejects an empty or out-of-bounds range" {
    var list = containers.ManagedArrayList(u32).init(testing.allocator);
    defer list.deinit();
    try list.appendSlice(&.{ 1, 2, 3 });

    try testing.expectError(error.InvalidRange, removeRange(u32, &list, 2, 2));
    try testing.expectError(error.InvalidRange, removeRange(u32, &list, 0, 4));
}
