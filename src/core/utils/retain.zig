const std = @import("std");
const containers = @import("containers");
const testing = std.testing;

pub fn retain(comptime TA: type, comptime TS: type, list: *containers.ManagedArrayList(?TA), filter: TS) void {
    const length = list.list.items.len;
    var i: usize = 0;
    var f: usize = 0;
    var flag = true;
    var count: usize = 0;

    while (true) {
        // test if false
        if (i < length and (list.list.items[i] == null or !filter.predicate(list.list.items[i].?))) {
            if (flag) {
                f = i;
                flag = false;
            }

            while (i < length and (list.list.items[i] == null or !filter.predicate(list.list.items[i].?))) {
                i += 1;
            }

            // move true to here
            if (i < length) {
                const delete = list.list.items[f];
                list.list.items[f] = list.list.items[i];
                list.list.items[i] = null;

                if (delete != null and @typeInfo(TA) == .pointer) {
                    delete.?.deinit();
                }
                f += 1;
                count += 1;
            }
        } else {
            count += 1;
            // fill in gaps
            if (i < length and f < i and flag == false) {
                const delete = list.list.items[f];
                list.list.items[f] = list.list.items[i];
                list.list.items[i] = null;

                if (delete != null and @typeInfo(TA) == .pointer) {
                    delete.?.deinit();
                }
                f += 1;
            }
        }
        i += 1;
        if (i >= length) {
            break;
        }
    }

    // delete remainder
    if (count < length) {
        for (list.list.items[count..length]) |d| {
            if (d != null and @typeInfo(TA) == .pointer) {
                d.?.deinit();
            }
        }
        list.shrinkRetainingCapacity(count);
    }
}

const KeepEven = struct {
    fn predicate(_: KeepEven, value: u32) bool {
        return value % 2 == 0;
    }
};

test "retain keeps matching values in order and drops nulls" {
    var list = containers.ManagedArrayList(?u32).init(testing.allocator);
    defer list.deinit();
    try list.appendSlice(&.{ 0, 1, null, 2, 3, 3, 4, null, 5, 6 });

    retain(u32, KeepEven, &list, .{});

    try testing.expectEqualSlices(?u32, &.{ 0, 2, 4, 6 }, list.list.items);
}

test "retain deinits dropped pointers" {
    const Item = struct {
        value: u32,
        allocator: std.mem.Allocator,

        fn deinit(self: *@This()) void {
            self.allocator.destroy(self);
        }
    };
    const KeepEvenItem = struct {
        fn predicate(_: @This(), item: *Item) bool {
            return item.value % 2 == 0;
        }
    };

    var list = containers.ManagedArrayList(?*Item).init(testing.allocator);
    defer list.deinit();
    for (0..9) |i| {
        const item = try testing.allocator.create(Item);
        item.* = .{ .value = @intCast(i), .allocator = testing.allocator };
        try list.append(item);
    }

    // testing.allocator fails the test if a dropped item leaks or is freed twice.
    retain(*Item, KeepEvenItem, &list, .{});

    try testing.expectEqual(@as(usize, 5), list.list.items.len);
    for (list.list.items, 0..) |item, i| {
        try testing.expectEqual(@as(u32, @intCast(i * 2)), item.?.value);
        item.?.deinit();
    }
}
