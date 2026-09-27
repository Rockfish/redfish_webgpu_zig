const std = @import("std");

pub const ManagedArrayList = @import("managed_list.zig").ManagedArrayList;

test {
    std.testing.refAllDecls(@This());
}
