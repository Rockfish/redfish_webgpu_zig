//! Owns the WebGPU instance, surface, device, depth texture, uniform ring, and shared
//! bindings, and brackets each frame. `beginFrame` acquires the surface texture and opens
//! the main render pass with group 0 bound; `endFrame` closes it, uploads the frame's
//! per-draw uniforms, submits, and presents. Parallel to redfish's clear / swapBuffers.

const std = @import("std");
const zglfw = @import("zglfw");
const wgpu = @import("wgpu");
const gpu_debug = @import("gpu_debug.zig");
const bindings_ = @import("bindings.zig");
const UniformRing = @import("uniform_ring.zig").UniformRing;
const SamplerCache = @import("texture.zig").SamplerCache;
const MipmapGenerator = @import("mipmaps.zig").MipmapGenerator;
const DefaultTextures = @import("material.zig").DefaultTextures;

const c = wgpu.c;
const stringView = wgpu.stringView;
const Allocator = std.mem.Allocator;
const Bindings = bindings_.Bindings;
const BindGroup = bindings_.BindGroup;
const FrameUniforms = bindings_.FrameUniforms;

const log = std.log.scoped(.gpu_context);

pub const depth_format = c.WGPUTextureFormat_Depth32Float;

/// One frame's GPU objects. Valid between `beginFrame` and `endFrame`.
pub const Frame = struct {
    gpu: *GpuContext,
    surface_texture: c.WGPUTexture,
    color_view: c.WGPUTextureView,
    encoder: c.WGPUCommandEncoder,
    pass: c.WGPURenderPassEncoder,
};

pub const GpuContext = struct {
    allocator: Allocator,
    window: *zglfw.Window,
    instance: c.WGPUInstance,
    surface: c.WGPUSurface,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    surface_format: c.WGPUTextureFormat,
    alpha_mode: c.WGPUCompositeAlphaMode,
    width: u32,
    height: u32,
    depth_texture: c.WGPUTexture = null,
    depth_view: c.WGPUTextureView = null,
    uniform_ring: UniformRing,
    bindings: Bindings,
    samplers: SamplerCache,
    mipmaps: MipmapGenerator,
    default_textures: DefaultTextures = undefined,
    /// Group 1 for `MaterialKind.texture` draws, set by `texture.bind(frame)`. Like GL's
    /// bound texture, it survives other draws (a PBR draw sets its own group 1 and the
    /// next shape draw sets this one back). Cleared each frame.
    bound_texture: c.WGPUBindGroup = null,

    const Self = @This();

    /// `allocator` holds the uniform ring's staging memory until `deinit`.
    pub fn init(allocator: Allocator, window: *zglfw.Window) !Self {
        const instance = c.wgpuCreateInstance(&.{}) orelse return error.NoWebGpuInstance;
        const surface = try createSurface(instance, window);
        const adapter = try requestAdapter(instance, surface);
        const device = try requestDevice(instance, adapter);

        gpu_debug.logAdapterInfo(adapter);

        const uniform_ring = try UniformRing.init(allocator, device);

        var self: Self = .{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .surface = surface,
            .adapter = adapter,
            .device = device,
            .queue = c.wgpuDeviceGetQueue(device),
            .surface_format = c.WGPUTextureFormat_Undefined,
            .alpha_mode = c.WGPUCompositeAlphaMode_Auto,
            .width = 0,
            .height = 0,
            .uniform_ring = uniform_ring,
            .bindings = Bindings.init(device, c.wgpuDeviceGetQueue(device), uniform_ring.buffer),
            .samplers = SamplerCache.init(allocator),
            .mipmaps = MipmapGenerator.init(device),
        };
        try self.chooseSurfaceFormat();
        self.default_textures = try DefaultTextures.init(allocator, &self);

        const size = window.getFramebufferSize();
        self.configure(@intCast(size[0]), @intCast(size[1]));
        return self;
    }

    /// Returns null when there is nothing to draw into this frame (minimized window,
    /// surface just reconfigured). Skip the frame's rendering in that case.
    pub fn beginFrame(self: *Self, clear_color: [4]f64) ?Frame {
        const size = self.window.getFramebufferSize();
        const width: u32 = @intCast(size[0]);
        const height: u32 = @intCast(size[1]);
        if (width == 0 or height == 0) return null;
        if (width != self.width or height != self.height) self.configure(width, height);

        var surface_texture: c.WGPUSurfaceTexture = .{};
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        switch (surface_texture.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
            => {},
            c.WGPUSurfaceGetCurrentTextureStatus_Outdated, c.WGPUSurfaceGetCurrentTextureStatus_Lost => {
                if (surface_texture.texture != null) c.wgpuTextureRelease(surface_texture.texture);
                self.configure(width, height);
                return null;
            },
            // wgpu-native (Metal): window hidden or fully covered. The surface stays valid;
            // wait briefly for events instead of spinning until it's visible again.
            c.WGPUSurfaceGetCurrentTextureStatus_Occluded => {
                zglfw.waitEventsTimeout(1.0 / 60.0);
                return null;
            },
            else => {
                log.warn("getCurrentTexture status {d}; skipping frame", .{surface_texture.status});
                return null;
            },
        }

        self.uniform_ring.reset();
        self.bound_texture = null;

        const color_view = c.wgpuTextureCreateView(surface_texture.texture, null);
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &.{});

        const color_attachment: c.WGPURenderPassColorAttachment = .{
            .view = color_view,
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = .{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] },
        };
        const depth_attachment: c.WGPURenderPassDepthStencilAttachment = .{
            .view = self.depth_view,
            .depthLoadOp = c.WGPULoadOp_Clear,
            .depthStoreOp = c.WGPUStoreOp_Store,
            .depthClearValue = 1.0,
        };
        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
            .label = stringView("main pass"),
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
            .depthStencilAttachment = &depth_attachment,
        });

        c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.frame, self.bindings.frame_bind_group, 0, null);

        return .{
            .gpu = self,
            .surface_texture = surface_texture.texture,
            .color_view = color_view,
            .encoder = encoder,
            .pass = pass,
        };
    }

    pub fn endFrame(self: *Self, frame: Frame) void {
        c.wgpuRenderPassEncoderEnd(frame.pass);
        c.wgpuRenderPassEncoderRelease(frame.pass);

        const commands = c.wgpuCommandEncoderFinish(frame.encoder, &.{});
        self.uniform_ring.upload(self.queue);
        c.wgpuQueueSubmit(self.queue, 1, &commands);
        c.wgpuCommandBufferRelease(commands);
        c.wgpuCommandEncoderRelease(frame.encoder);

        if (c.wgpuSurfacePresent(self.surface) != c.WGPUStatus_Success) log.warn("surface present failed", .{});

        c.wgpuTextureViewRelease(frame.color_view);
        c.wgpuTextureRelease(frame.surface_texture);
    }

    /// Write this frame's camera and time for group 0. Once per frame, before drawing.
    pub fn writeFrameUniforms(self: *Self, uniforms: FrameUniforms) void {
        c.wgpuQueueWriteBuffer(self.queue, self.bindings.frame_buffer, 0, &uniforms, @sizeOf(FrameUniforms));
    }

    pub fn deinit(self: *Self) void {
        self.default_textures.releaseGpuObjects();
        self.allocator.destroy(self.default_textures.white);
        self.allocator.destroy(self.default_textures.flat_normal);
        self.mipmaps.releaseGpuObjects();
        self.samplers.releaseGpuObjects();
        self.samplers.deinit();
        self.bindings.releaseGpuObjects();
        self.uniform_ring.releaseGpuObjects();
        self.uniform_ring.deinit(self.allocator);
        self.releaseDepthTexture();
        c.wgpuSurfaceUnconfigure(self.surface);
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuInstanceRelease(self.instance);
    }

    /// Prefer an sRGB surface format so shaders write linear color and the hardware
    /// encodes on store.
    fn chooseSurfaceFormat(self: *Self) !void {
        var caps: c.WGPUSurfaceCapabilities = .{};
        if (c.wgpuSurfaceGetCapabilities(self.surface, self.adapter, &caps) != c.WGPUStatus_Success) {
            return error.SurfaceCapabilities;
        }
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
        if (caps.formatCount == 0) return error.NoSurfaceFormats;

        const formats = caps.formats[0..caps.formatCount];
        self.surface_format = for (formats) |format| {
            if (format == c.WGPUTextureFormat_BGRA8UnormSrgb or format == c.WGPUTextureFormat_RGBA8UnormSrgb) break format;
        } else blk: {
            log.warn("no sRGB surface format; colors will be too dark", .{});
            break :blk formats[0];
        };
        if (caps.alphaModeCount > 0) self.alpha_mode = caps.alphaModes[0];

        log.info("surface format {d} (of {d} offered)", .{ self.surface_format, formats.len });
    }

    fn configure(self: *Self, width: u32, height: u32) void {
        c.wgpuSurfaceConfigure(self.surface, &.{
            .device = self.device,
            .format = self.surface_format,
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .width = width,
            .height = height,
            .alphaMode = self.alpha_mode,
            .presentMode = c.WGPUPresentMode_Fifo,
        });
        self.width = width;
        self.height = height;
        self.createDepthTexture();
    }

    fn createDepthTexture(self: *Self) void {
        self.releaseDepthTexture();
        self.depth_texture = c.wgpuDeviceCreateTexture(self.device, &.{
            .label = stringView("depth"),
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = self.width, .height = self.height, .depthOrArrayLayers = 1 },
            .format = depth_format,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        self.depth_view = c.wgpuTextureCreateView(self.depth_texture, null);
    }

    fn releaseDepthTexture(self: *Self) void {
        if (self.depth_view != null) c.wgpuTextureViewRelease(self.depth_view);
        if (self.depth_texture != null) c.wgpuTextureRelease(self.depth_texture);
        self.depth_view = null;
        self.depth_texture = null;
    }
};

fn createSurface(instance: c.WGPUInstance, window: *zglfw.Window) !c.WGPUSurface {
    const ns_window = zglfw.getCocoaWindow(window) orelse return error.NoCocoaWindow;
    const metal_source: c.WGPUSurfaceSourceMetalLayer = .{
        .chain = .{ .sType = c.WGPUSType_SurfaceSourceMetalLayer },
        .layer = wgpu.metal_layer.createForCocoaWindow(ns_window),
    };
    return c.wgpuInstanceCreateSurface(instance, &.{
        .nextInChain = @constCast(&metal_source.chain),
        .label = stringView("window surface"),
    }) orelse error.NoSurface;
}

/// Result slot for the async request callbacks.
fn Request(comptime T: type) type {
    return struct {
        done: bool = false,
        result: T = null,
        message: [256]u8 = undefined,
        message_len: usize = 0,

        fn setMessage(self: *@This(), message: c.WGPUStringView) void {
            const text = wgpu.sliceFromView(message);
            self.message_len = @min(text.len, self.message.len);
            @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
        }
    };
}

fn requestAdapter(instance: c.WGPUInstance, surface: c.WGPUSurface) !c.WGPUAdapter {
    var request: Request(c.WGPUAdapter) = .{};
    _ = c.wgpuInstanceRequestAdapter(instance, &.{
        .compatibleSurface = surface,
        .powerPreference = c.WGPUPowerPreference_HighPerformance,
    }, .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = onAdapter,
        .userdata1 = &request,
    });
    while (!request.done) c.wgpuInstanceProcessEvents(instance);

    return request.result orelse {
        log.err("requestAdapter failed: {s}", .{request.message[0..request.message_len]});
        return error.NoAdapter;
    };
}

fn onAdapter(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const request: *Request(c.WGPUAdapter) = @ptrCast(@alignCast(userdata1));
    if (status == c.WGPURequestAdapterStatus_Success) request.result = adapter;
    request.setMessage(message);
    request.done = true;
}

fn requestDevice(instance: c.WGPUInstance, adapter: c.WGPUAdapter) !c.WGPUDevice {
    var request: Request(c.WGPUDevice) = .{};
    _ = c.wgpuAdapterRequestDevice(adapter, &.{
        .label = stringView("device"),
        .deviceLostCallbackInfo = gpu_debug.deviceLostCallbackInfo(),
        .uncapturedErrorCallbackInfo = gpu_debug.uncapturedErrorCallbackInfo(),
    }, .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = onDevice,
        .userdata1 = &request,
    });
    while (!request.done) c.wgpuInstanceProcessEvents(instance);

    return request.result orelse {
        log.err("requestDevice failed: {s}", .{request.message[0..request.message_len]});
        return error.NoDevice;
    };
}

fn onDevice(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const request: *Request(c.WGPUDevice) = @ptrCast(@alignCast(userdata1));
    if (status == c.WGPURequestDeviceStatus_Success) request.result = device;
    request.setMessage(message);
    request.done = true;
}
