const std = @import("std");

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Context = struct {
    alloc: Allocator,
    temp_alloc: Allocator,
    io: Io,
};
