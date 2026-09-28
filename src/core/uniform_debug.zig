//! Uniform values captured for debugging: demo_app's G / U keys and the F12 screenshot's
//! JSON dump. redfish captured each `shader.setX(name, value)`; here uniforms are structs,
//! so values are recorded by field path (`frame.lights.ambient`, `draw.model`,
//! `material.roughness_factor`). Later captures overwrite earlier ones, so per-draw values
//! are the last draw's, as in GL. Off unless `enable`d; capturing costs nothing then.

const std = @import("std");
const math = @import("math");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

pub const UniformDebug = struct {
    allocator: Allocator,
    enabled: bool = false,
    /// Owned keys and values.
    values: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
        self.values.deinit(self.allocator);
    }

    pub fn enable(self: *Self) void {
        self.enabled = true;
    }

    pub fn disable(self: *Self) void {
        self.clear();
        self.enabled = false;
    }

    pub fn clear(self: *Self) void {
        for (self.values.keys(), self.values.values()) |key, value| {
            self.allocator.free(key);
            self.allocator.free(value);
        }
        self.values.clearRetainingCapacity();
    }

    /// An app value that isn't a uniform (camera position, frame time), as redfish's
    /// `addDebugValue`.
    pub fn addValue(self: *Self, key: []const u8, value: []const u8) void {
        if (!self.enabled) return;
        self.put(key, value) catch |err| std.log.warn("uniform debug: {any}", .{err});
    }

    /// Records every field of a uniform struct under `prefix`. Padding fields (`_pad`)
    /// are skipped.
    pub fn captureStruct(self: *Self, comptime prefix: []const u8, value: anytype) void {
        if (!self.enabled) return;
        self.captureValue(prefix, value);
    }

    /// Text listing for the console (U key).
    pub fn dump(self: *Self, writer: *Io.Writer) !void {
        self.sortKeys();
        try writer.print("=== Shader Debug Uniforms ===\n", .{});
        try writer.print("Total uniforms: {d}\n\n", .{self.values.count()});
        for (self.values.keys(), self.values.values()) |key, value| {
            try writer.print("{s}: {s}\n", .{ key, value });
        }
    }

    /// JSON file next to a screenshot, in redfish's layout with sorted keys.
    pub fn saveJson(self: *Self, io: Io, path: []const u8, timestamp_str: []const u8, shader_path: []const u8) !void {
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try self.writeJson(&file_writer.interface, io, timestamp_str, shader_path);
        try file_writer.interface.flush();
    }

    fn writeJson(self: *Self, writer: *Io.Writer, io: Io, timestamp_str: []const u8, shader_path: []const u8) !void {
        self.sortKeys();
        const timestamp = Io.Timestamp.now(io, .real);

        try writer.print("{{\n", .{});
        try writer.print("  \"timestamp\": {d},\n", .{timestamp.toMilliseconds()});
        try writer.print("  \"timestamp_str\": \"{s}\",\n", .{timestamp_str});
        try writer.print("  \"shader\": \"{s}\",\n", .{shader_path});
        try writer.print("  \"uniform_count\": {d},\n", .{self.values.count()});
        try writer.print("  \"uniforms\": {{\n", .{});

        for (self.values.keys(), self.values.values(), 0..) |key, value, i| {
            const separator = if (i + 1 < self.values.count()) "," else "";
            try writer.print("    \"{s}\": \"{s}\"{s}\n", .{ key, value, separator });
        }

        try writer.print("  }}\n", .{});
        try writer.print("}}\n", .{});
    }

    fn captureValue(self: *Self, comptime key: []const u8, value: anytype) void {
        const T = @TypeOf(value);
        var buf: [512]u8 = undefined;

        const text: []const u8 = if (T == Mat4)
            value.asString(&buf)
        else if (T == Vec3 or T == Vec4)
            value.asString(&buf)
        else if (T == f32)
            std.fmt.bufPrint(&buf, "{d:.3}", .{value}) catch unreachable
        else if (T == u32)
            std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable
        else switch (@typeInfo(T)) {
            .@"struct" => |info| {
                inline for (info.fields) |field| {
                    if (comptime field.name[0] != '_') {
                        self.captureValue(key ++ "." ++ field.name, @field(value, field.name));
                    }
                }
                return;
            },
            .array => |info| {
                inline for (0..info.len) |i| {
                    self.captureValue(std.fmt.comptimePrint("{s}[{d}]", .{ key, i }), value[i]);
                }
                return;
            },
            else => @compileError("UniformDebug: unsupported uniform type " ++ @typeName(T)),
        };

        self.put(key, text) catch |err| std.log.warn("uniform debug: {any}", .{err});
    }

    fn put(self: *Self, key: []const u8, value: []const u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const entry = try self.values.getOrPut(self.allocator, key);
        if (entry.found_existing) {
            self.allocator.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
                self.values.swapRemoveAt(entry.index);
                return err;
            };
        }
        entry.value_ptr.* = owned_value;
    }

    fn sortKeys(self: *Self) void {
        const SortContext = struct {
            keys: []const []const u8,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx.keys[a], ctx.keys[b]);
            }
        };
        self.values.sort(SortContext{ .keys = self.values.keys() });
    }
};

test "captureStruct records fields by path, skips padding, last write wins" {
    const Inner = extern struct { color: Vec3, _pad: f32 = 0.0 };
    const Outer = extern struct { scale: f32, flags: u32, items: [2]Inner };

    var debug = UniformDebug.init(std.testing.allocator);
    defer debug.deinit();

    debug.captureStruct("draw", Outer{ .scale = 1.0, .flags = 3, .items = .{ .{ .color = Vec3.init(1.0, 0.0, 0.0) }, .{ .color = Vec3.init(0.0, 1.0, 0.0) } } });
    try std.testing.expectEqual(@as(usize, 0), debug.values.count());

    debug.enable();
    debug.captureStruct("draw", Outer{ .scale = 1.0, .flags = 3, .items = .{ .{ .color = Vec3.init(1.0, 0.0, 0.0) }, .{ .color = Vec3.init(0.0, 1.0, 0.0) } } });
    debug.captureStruct("draw", Outer{ .scale = 2.0, .flags = 5, .items = .{ .{ .color = Vec3.init(1.0, 0.0, 0.0) }, .{ .color = Vec3.init(0.0, 1.0, 0.0) } } });
    debug.addValue("frame_time", "0.016s");

    try std.testing.expectEqual(@as(usize, 5), debug.values.count());
    try std.testing.expectEqualStrings("2.000", debug.values.get("draw.scale").?);
    try std.testing.expectEqualStrings("5", debug.values.get("draw.flags").?);
    try std.testing.expect(debug.values.get("draw.items[1].color") != null);
    try std.testing.expect(debug.values.get("draw.items[0]._pad") == null);

    var buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try debug.dump(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Total uniforms: 5") != null);

    debug.disable();
    try std.testing.expectEqual(@as(usize, 0), debug.values.count());
}
