const std = @import("std");
const Context = @import("context.zig").Context;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Arenas = struct {
    allocator: Allocator,
    alloc_arena: ArenaAllocator,
    temp_arena: ArenaAllocator,

    pub fn init(gpa: Allocator) !*Arenas {
        const arenas = try gpa.create(Arenas);
        arenas.* = .{
            .allocator = gpa,
            .alloc_arena = ArenaAllocator.init(gpa),
            .temp_arena = ArenaAllocator.init(gpa),
        };

        return arenas;
    }

    pub fn context(self: *Arenas, io: Io) Context {
        return .{
            .io = io,
            .alloc = self.alloc_arena.allocator(),
            .temp_alloc = self.temp_arena.allocator(),
        };
    }

    /// Orphans everything allocated from `alloc` — any object built from
    /// this arena's context is dead after this call. Callers should go
    /// through their scope's `cleanUp` (GL objects first) rather than
    /// calling this directly.
    pub fn resetAlloc(self: *Arenas) void {
        _ = self.alloc_arena.reset(.retain_capacity);
    }

    pub fn resetTemp(self: *Arenas) void {
        _ = self.temp_arena.reset(.retain_capacity);
    }

    pub fn resetAll(self: *Arenas) void {
        _ = self.alloc_arena.reset(.retain_capacity);
        _ = self.temp_arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *Arenas) void {
        self.alloc_arena.deinit();
        self.temp_arena.deinit();
        self.allocator.destroy(self);
    }
};
