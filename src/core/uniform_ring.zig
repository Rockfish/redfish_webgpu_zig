//! Per-draw uniform data. Each draw copies its struct into a CPU staging slice and gets a
//! byte offset; `upload` writes the used part to the GPU buffer once, before submit; draws
//! bind group 2 with their offset as the dynamic offset.
//!
//! One buffer is reused every frame. That is safe because queue operations run in order:
//! frame N+1's `wgpuQueueWriteBuffer` can't overtake frame N's draws.

const std = @import("std");
const wgpu = @import("wgpu");

const c = wgpu.c;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.uniform_ring);

pub const UniformRing = struct {
    buffer: c.WGPUBuffer,
    staging: []align(ALIGNMENT) u8,
    used: u32 = 0,

    /// Raise if a busy scene panics in `allocate`.
    pub const SIZE: u32 = 4 * 1024 * 1024;
    /// WebGPU's default `minUniformBufferOffsetAlignment`.
    pub const ALIGNMENT = 256;

    const Self = @This();

    pub fn init(allocator: Allocator, device: c.WGPUDevice) !Self {
        const staging = try allocator.alignedAlloc(u8, .fromByteUnits(ALIGNMENT), SIZE);
        const buffer = c.wgpuDeviceCreateBuffer(device, &.{
            .label = wgpu.stringView("uniform ring"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = SIZE,
        });
        return .{ .buffer = buffer, .staging = staging };
    }

    /// Copy `value` into this frame's staging memory; returns its dynamic offset.
    pub fn allocate(self: *Self, comptime T: type, value: T) u32 {
        const offset = self.used;
        const end = offset + @sizeOf(T);
        if (end > SIZE) {
            std.debug.panic("uniform ring full ({d} bytes); raise UniformRing.SIZE", .{SIZE});
        }

        @memcpy(self.staging[offset..end], std.mem.asBytes(&value));
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
