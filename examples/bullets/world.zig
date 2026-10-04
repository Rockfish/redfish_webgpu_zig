const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Context = core.Context;
const Input = core.Input;
const GpuContext = core.GpuContext;
const Scene = @import("scene.zig").Scene;
const SceneDebug = @import("scenes/debug_scene.zig").SceneDebug;
const RuinsGalleryScene = @import("scenes/ruins_gallery_scene.zig").RuinsGalleryScene;
const ToonGalleryScene = @import("scenes/toon_gallery_scene.zig").ToonGalleryScene;
const RangeScene = @import("scenes/range_scene.zig").RangeScene;

pub const SceneId = enum {
    debug,
    ruins_gallery,
    toon_gallery,
    range,
};

const scene_order = [_]SceneId{ .debug, .ruins_gallery, .toon_gallery, .range };

pub const World = struct {
    alloc_arena: ArenaAllocator,
    temp_alloc_arena: ArenaAllocator,
    context: Context,
    input: *Input,
    gpu: *GpuContext,
    scene: *Scene,
    scene_index: usize = 0,

    const Self = @This();

    pub fn init(process_init: std.process.Init, gpu: *GpuContext, input: *Input, initial_scene: SceneId) !*Self {
        const alloc_arena = ArenaAllocator.init(process_init.gpa);
        const temp_alloc_arena = ArenaAllocator.init(process_init.gpa);
        const self = try process_init.gpa.create(Self);
        self.* = .{
            .alloc_arena = alloc_arena,
            .temp_alloc_arena = temp_alloc_arena,
            .context = .{
                .alloc = self.alloc_arena.allocator(),
                .temp_alloc = self.temp_alloc_arena.allocator(),
                .io = process_init.io,
            },
            .input = input,
            .gpu = gpu,
            .scene = undefined,
        };

        self.scene_index = std.mem.indexOfScalar(SceneId, &scene_order, initial_scene).?;
        self.scene = try self.createScene(initial_scene);
        _ = self.temp_alloc_arena.reset(.retain_capacity);
        std.debug.print("Scene: {s}\n", .{self.scene.name});
        return self;
    }

    pub fn switchScene(self: *Self, scene_id: SceneId) !void {
        self.scene.cleanUp();
        _ = self.alloc_arena.reset(.retain_capacity);
        _ = self.temp_alloc_arena.reset(.retain_capacity);

        self.scene = try self.createScene(scene_id);
        _ = self.temp_alloc_arena.reset(.retain_capacity);

        std.debug.print("Scene: {s}\n", .{self.scene.name});
    }

    fn createScene(self: *Self, scene_id: SceneId) !*Scene {
        return switch (scene_id) {
            .debug => try SceneDebug.init(self.context, self.gpu, self.input),
            .ruins_gallery => try RuinsGalleryScene.init(self.context, self.gpu, self.input),
            .toon_gallery => try ToonGalleryScene.init(self.context, self.gpu, self.input),
            .range => try RangeScene.init(self.context, self.gpu, self.input),
        };
    }

    pub fn nextScene(self: *Self) !void {
        self.scene_index = (self.scene_index + 1) % scene_order.len;
        try self.switchScene(scene_order[self.scene_index]);
    }

    pub fn prevScene(self: *Self) !void {
        if (self.scene_index == 0) {
            self.scene_index = scene_order.len - 1;
        } else {
            self.scene_index -= 1;
        }
        try self.switchScene(scene_order[self.scene_index]);
    }

    pub fn deinit(self: *Self, process_init: std.process.Init) void {
        self.scene.cleanUp();
        self.alloc_arena.deinit();
        self.temp_alloc_arena.deinit();
        process_init.gpa.destroy(self);
    }
};
