//! A GPU storage buffer of plain data. Replaces redfish's `texture_buffer.zig` (GL texture
//! buffer objects); shaders read it as `var<storage, read> name: array<T>`.

const std = @import("std");
const wgpu = @import("wgpu");

const c = wgpu.c;

pub const StorageBuffer = struct {
    buffer: c.WGPUBuffer,
    size: u64,

    const Self = @This();

    /// Buffer sized for `data`, filled with it.
    pub fn init(device: c.WGPUDevice, queue: c.WGPUQueue, label: []const u8, comptime T: type, data: []const T) Self {
        const bytes = std.mem.sliceAsBytes(data);
        const self = initEmpty(device, label, bytes.len);
        c.wgpuQueueWriteBuffer(queue, self.buffer, 0, bytes.ptr, bytes.len);
        return self;
    }

    pub fn initEmpty(device: c.WGPUDevice, label: []const u8, size: u64) Self {
        std.debug.assert(size > 0 and size % 4 == 0);
        return .{
            .buffer = c.wgpuDeviceCreateBuffer(device, &.{
                .label = wgpu.stringView(label),
                .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
                .size = size,
            }),
            .size = size,
        };
    }

    /// Replace the contents from the start. Once per frame at most, before the draws that
    /// read it; writes land before the frame runs, so the last one wins.
    pub fn write(self: *const Self, queue: c.WGPUQueue, comptime T: type, data: []const T) void {
        const bytes = std.mem.sliceAsBytes(data);
        std.debug.assert(bytes.len <= self.size);
        c.wgpuQueueWriteBuffer(queue, self.buffer, 0, bytes.ptr, bytes.len);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBufferRelease(self.buffer);
    }
};
