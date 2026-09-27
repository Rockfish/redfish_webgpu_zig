//! Per-frame GPU data that changes every draw: per-draw uniforms (`UniformRing`) and
//! per-frame vertex data such as lines and instance attributes (`VertexRing`). Each draw
//! copies its data into a CPU staging slice and gets a byte offset; `upload` writes the
//! used part to the GPU buffer once, before submit; draws bind their own offset.
//!
//! One buffer is reused every frame. That is safe because queue operations run in order:
//! frame N+1's `wgpuQueueWriteBuffer` can't overtake frame N's draws.

const std = @import("std");
const wgpu = @import("wgpu");

const c = wgpu.c;
const Allocator = std.mem.Allocator;

/// Per-draw uniforms, bound with a dynamic offset. WebGPU's default
/// `minUniformBufferOffsetAlignment` is 256.
pub const UniformRing = FrameRing(c.WGPUBufferUsage_Uniform, 256, "uniform ring");

/// Per-frame vertex data (line vertices, instance attributes), bound at an offset with
/// `wgpuRenderPassEncoderSetVertexBuffer`.
pub const VertexRing = FrameRing(c.WGPUBufferUsage_Vertex, 16, "vertex ring");

pub fn FrameRing(comptime usage: c.WGPUBufferUsage, comptime alignment: u32, comptime label: []const u8) type {
    return struct {
        buffer: c.WGPUBuffer,
        staging: []align(ALIGNMENT) u8,
        used: u32 = 0,

        /// Raise if a busy scene panics in `allocate`.
        pub const SIZE: u32 = 4 * 1024 * 1024;
        pub const ALIGNMENT = alignment;

        const Self = @This();

        pub fn init(allocator: Allocator, device: c.WGPUDevice) !Self {
            const staging = try allocator.alignedAlloc(u8, .fromByteUnits(ALIGNMENT), SIZE);
            const buffer = c.wgpuDeviceCreateBuffer(device, &.{
                .label = wgpu.stringView(label),
                .usage = usage | c.WGPUBufferUsage_CopyDst,
                .size = SIZE,
            });
            return .{ .buffer = buffer, .staging = staging };
        }

        /// Copy `value` into this frame's staging memory; returns its offset.
        pub fn allocate(self: *Self, comptime T: type, value: T) u32 {
            return self.allocateBytes(std.mem.asBytes(&value));
        }

        /// Copy `bytes` into this frame's staging memory; returns its offset.
        pub fn allocateBytes(self: *Self, bytes: []const u8) u32 {
            const offset = self.used;
            const end = offset + @as(u32, @intCast(bytes.len));
            if (end > SIZE) {
                std.debug.panic("{s} full ({d} bytes); raise its SIZE", .{ label, SIZE });
            }

            @memcpy(self.staging[offset..end], bytes);
            self.used = std.mem.alignForward(u32, end, ALIGNMENT);
            return offset;
        }

        pub fn upload(self: *Self, queue: c.WGPUQueue) void {
            if (self.used == 0) return;
            c.wgpuQueueWriteBuffer(queue, self.buffer, 0, self.staging.ptr, self.used);
        }

        pub fn reset(self: *Self) void {
            self.used = 0;
        }

        pub fn releaseGpuObjects(self: *Self) void {
            c.wgpuBufferRelease(self.buffer);
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.staging);
        }
    };
}

test "allocate aligns each slice and reports offsets in order" {
    var staging: [3 * UniformRing.ALIGNMENT]u8 align(UniformRing.ALIGNMENT) = undefined;
    var ring: UniformRing = .{ .buffer = null, .staging = &staging };

    const first = ring.allocate([4]f32, .{ 1, 2, 3, 4 });
    const second = ring.allocate(u32, 7);

    try std.testing.expectEqual(@as(u32, 0), first);
    try std.testing.expectEqual(@as(u32, UniformRing.ALIGNMENT), second);
    try std.testing.expectEqual(@as(u32, 2 * UniformRing.ALIGNMENT), ring.used);
    try std.testing.expectEqual(@as(u32, 7), std.mem.bytesToValue(u32, staging[second..][0..4]));

    ring.reset();
    try std.testing.expectEqual(@as(u32, 0), ring.allocate(u32, 1));
}

test "vertex ring packs slices at its smaller alignment" {
    var staging: [64]u8 align(VertexRing.ALIGNMENT) = undefined;
    var ring: VertexRing = .{ .buffer = null, .staging = &staging };

    const first = ring.allocateBytes(&[_]u8{ 1, 2, 3 });
    const second = ring.allocateBytes(&[_]u8{ 4, 5, 6, 7 });

    try std.testing.expectEqual(@as(u32, 0), first);
    try std.testing.expectEqual(@as(u32, VertexRing.ALIGNMENT), second);
}
