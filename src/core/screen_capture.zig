//! Screenshots: one extra frame drawn into an offscreen texture and read back to the CPU.
//! Replaces redfish's screenshot framebuffer plus `glReadPixels`. The texture uses the
//! surface format, so every pipeline can draw into it, and its origin is top-left, so
//! rows come back in image order (no vertical flip on write).
//!
//! The copy to the readback buffer is its own submission after the frame's: the queue
//! runs them in order, so the copy sees the finished frame.

const std = @import("std");
const wgpu = @import("wgpu");
const gpu_context = @import("gpu_context.zig");

const c = wgpu.c;
const stringView = wgpu.stringView;
const Allocator = std.mem.Allocator;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;

const log = std.log.scoped(.screen_capture);

/// WebGPU's `bytesPerRow` alignment for texture-to-buffer copies.
const COPY_ROW_ALIGNMENT = 256;

/// Tightly packed RGBA8 rows, top row first, sRGB-encoded as the surface would show it.
pub const CapturedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *CapturedImage, allocator: Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const ScreenCapture = struct {
    texture: c.WGPUTexture = null,
    view: c.WGPUTextureView = null,
    readback: c.WGPUBuffer = null,
    width: u32 = 0,
    height: u32 = 0,
    padded_bytes_per_row: u32 = 0,

    const Self = @This();

    /// Draw one frame into the capture texture. Same size as the surface (the depth
    /// texture is shared), so sizes follow the window.
    pub fn beginFrame(self: *Self, gpu: *GpuContext, clear_color: [4]f64) Frame {
        self.ensureSize(gpu);
        return gpu.beginOffscreenFrame(self.view, clear_color);
    }

    /// Submit the frame, copy the texture out, and wait for it.
    pub fn endFrame(self: *Self, allocator: Allocator, frame: Frame) !CapturedImage {
        const gpu = frame.gpu;
        gpu.submitFrame(frame);

        const encoder = c.wgpuDeviceCreateCommandEncoder(gpu.device, &.{});
        c.wgpuCommandEncoderCopyTextureToBuffer(
            encoder,
            &.{ .texture = self.texture, .mipLevel = 0, .aspect = c.WGPUTextureAspect_All },
            &.{ .buffer = self.readback, .layout = .{ .bytesPerRow = self.padded_bytes_per_row, .rowsPerImage = self.height } },
            &.{ .width = self.width, .height = self.height, .depthOrArrayLayers = 1 },
        );
        const commands = c.wgpuCommandEncoderFinish(encoder, &.{});
        c.wgpuQueueSubmit(gpu.queue, 1, &commands);
        c.wgpuCommandBufferRelease(commands);
        c.wgpuCommandEncoderRelease(encoder);

        try self.mapReadback(gpu);
        defer c.wgpuBufferUnmap(self.readback);

        return self.copyPixels(allocator, gpu.surface_format);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        if (self.readback != null) c.wgpuBufferRelease(self.readback);
        if (self.view != null) c.wgpuTextureViewRelease(self.view);
        if (self.texture != null) c.wgpuTextureRelease(self.texture);
        self.* = .{};
    }

    fn ensureSize(self: *Self, gpu: *GpuContext) void {
        if (self.texture != null and self.width == gpu.width and self.height == gpu.height) return;
        self.releaseGpuObjects();

        self.width = gpu.width;
        self.height = gpu.height;
        self.padded_bytes_per_row = std.mem.alignForward(u32, self.width * 4, COPY_ROW_ALIGNMENT);

        self.texture = c.wgpuDeviceCreateTexture(gpu.device, &.{
            .label = stringView("screen capture"),
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = self.width, .height = self.height, .depthOrArrayLayers = 1 },
            .format = gpu.surface_format,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        self.view = c.wgpuTextureCreateView(self.texture, null);
        self.readback = c.wgpuDeviceCreateBuffer(gpu.device, &.{
            .label = stringView("screen capture readback"),
            .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
            .size = @as(u64, self.padded_bytes_per_row) * self.height,
        });
    }

    fn mapReadback(self: *Self, gpu: *GpuContext) !void {
        // The real size: wgpu-native rejects WGPU_WHOLE_MAP_SIZE here.
        const size = @as(usize, self.padded_bytes_per_row) * self.height;
        var request: MapRequest = .{};
        _ = c.wgpuBufferMapAsync(self.readback, c.WGPUMapMode_Read, 0, size, .{
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = onMapped,
            .userdata1 = &request,
        });
        while (!request.done) c.wgpuInstanceProcessEvents(gpu.instance);

        if (request.status != c.WGPUMapAsyncStatus_Success) {
            log.err("readback map failed: status {d}", .{request.status});
            return error.ReadbackMapFailed;
        }
    }

    /// Drop each row's copy padding and put the channels in RGBA order.
    fn copyPixels(self: *Self, allocator: Allocator, format: c.WGPUTextureFormat) !CapturedImage {
        const size = @as(usize, self.padded_bytes_per_row) * self.height;
        const mapped: [*]const u8 = @ptrCast(c.wgpuBufferGetConstMappedRange(self.readback, 0, size) orelse
            return error.ReadbackNotMapped);

        const row_bytes = self.width * 4;
        const pixels = try allocator.alloc(u8, @as(usize, row_bytes) * self.height);
        for (0..self.height) |y| {
            const src = mapped[y * self.padded_bytes_per_row ..][0..row_bytes];
            @memcpy(pixels[y * row_bytes ..][0..row_bytes], src);
        }

        const is_bgra = format == c.WGPUTextureFormat_BGRA8UnormSrgb or format == c.WGPUTextureFormat_BGRA8Unorm;
        if (is_bgra) {
            var i: usize = 0;
            while (i < pixels.len) : (i += 4) std.mem.swap(u8, &pixels[i], &pixels[i + 2]);
        }

        return .{ .pixels = pixels, .width = self.width, .height = self.height };
    }
};

const MapRequest = struct {
    done: bool = false,
    status: c.WGPUMapAsyncStatus = 0,
};

fn onMapped(
    status: c.WGPUMapAsyncStatus,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    const request: *MapRequest = @ptrCast(@alignCast(userdata1));
    request.status = status;
    request.done = true;
}
