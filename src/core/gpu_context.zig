//! Owns the WebGPU instance, surface, device, depth texture, uniform ring, and shared
//! bindings, and brackets each frame. `beginFrame` acquires the surface texture and opens
//! the main render pass with group 0 bound; `endFrame` closes it, uploads the frame's
//! per-draw uniforms, submits, and presents. Parallel to redfish's clear / swapBuffers.
//!
//! Frames with several passes (shadow map, render targets) start with `acquireFrame` and
//! open each pass with `frame.beginPass` / `frame.endPass`, the window's last with
//! `frame.beginSurfacePass`. `beginOffscreenFrame` / `submitFrame` draw a frame into
//! another texture (screenshots).

const std = @import("std");
const build_options = @import("build_options");
const zglfw = @import("zglfw");
const wgpu = @import("wgpu");
const gpu_debug = @import("gpu_debug.zig");
const bindings_ = @import("bindings.zig");
const UniformRing = @import("uniform_ring.zig").UniformRing;
const VertexRing = @import("uniform_ring.zig").VertexRing;
const SamplerCache = @import("texture.zig").SamplerCache;
const MipmapGenerator = @import("mipmaps.zig").MipmapGenerator;
const DefaultTextures = @import("material.zig").DefaultTextures;
const UniformDebug = @import("uniform_debug.zig").UniformDebug;

const c = wgpu.c;
const stringView = wgpu.stringView;
const Allocator = std.mem.Allocator;
const Bindings = bindings_.Bindings;
const BindGroup = bindings_.BindGroup;
const FrameUniforms = bindings_.FrameUniforms;
const MaterialKind = bindings_.MaterialKind;

/// A group 1 bind group and the kind of material it is.
pub const BoundMaterial = struct {
    bind_group: c.WGPUBindGroup,
    kind: MaterialKind,
};

const log = std.log.scoped(.gpu_context);

pub const depth_format = c.WGPUTextureFormat_Depth32Float;

/// Samples per pixel in the window pass: 4 with MSAA (`zig build -Dmsaa`, the default),
/// else 1. Fixed per build because every pipeline drawing in the window pass is created
/// with it (`Shader` for `.surface` targets, ImGui). With 4, the window pass draws into
/// 4x color and depth textures, and the color is resolved (averaged) into the frame's
/// single-sample view at the end of the pass. Shadow passes and render targets stay at 1.
pub const window_sample_count: u32 = if (build_options.msaa) 4 else 1;

/// Where a pass draws. Null `color` is a depth-only pass (shadow map); null `depth` a pass
/// without depth (full-screen post-processing). Both are cleared when the pass begins.
/// A multisampled pass draws into multisampled `color` and `depth` and names `resolve`:
/// the single-sample view the color is averaged into when the pass ends. Only the
/// resolved color is kept.
pub const PassTarget = struct {
    label: []const u8,
    color: c.WGPUTextureView = null,
    depth: c.WGPUTextureView = null,
    resolve: c.WGPUTextureView = null,
    clear_color: [4]f64 = .{ 0.0, 0.0, 0.0, 0.0 },
};

/// One frame's GPU objects. Valid between `beginFrame` / `acquireFrame` and `endFrame`.
pub const Frame = struct {
    gpu: *GpuContext,
    /// Null for an offscreen frame.
    surface_texture: c.WGPUTexture,
    color_view: c.WGPUTextureView,
    encoder: c.WGPUCommandEncoder,
    /// The open pass draws record into; null between passes.
    pass: c.WGPURenderPassEncoder = null,

    /// The frame's own color view (the window, or the offscreen target) with the shared
    /// depth texture.
    pub fn beginSurfacePass(self: *Frame, clear_color: [4]f64) void {
        const label = if (self.surface_texture == null) "offscreen pass" else "main pass";
        self.beginPass(self.surfaceTarget(label, clear_color, true));
    }

    /// The window pass's target: the frame's color view, directly or (with MSAA) as the
    /// resolve target of the 4x color texture, and the matching depth texture when
    /// `with_depth`. For window passes that don't use `beginSurfacePass` (a composite
    /// without depth): their pipelines have the window's sample count, so their pass must
    /// too.
    pub fn surfaceTarget(self: *const Frame, label: []const u8, clear_color: [4]f64, with_depth: bool) PassTarget {
        const gpu = self.gpu;
        if (window_sample_count == 1) {
            return .{
                .label = label,
                .color = self.color_view,
                .depth = if (with_depth) gpu.depth_view else null,
                .clear_color = clear_color,
            };
        }
        return .{
            .label = label,
            .color = gpu.msaa_color_view,
            .depth = if (with_depth) gpu.msaa_depth_view else null,
            .resolve = self.color_view,
            .clear_color = clear_color,
        };
    }

    /// Opens a pass with group 0 bound. The previous pass must be ended. Bind groups
    /// don't carry over between passes, so group 3 (a shadow map) is bound after this.
    pub fn beginPass(self: *Frame, target: PassTarget) void {
        std.debug.assert(self.pass == null);

        const clear = target.clear_color;
        // A multisampled pass keeps only the resolved color; its samples and depth are
        // dropped at the end of the pass instead of written back to memory.
        const multisampled = target.resolve != null;
        const store: c.WGPUStoreOp = if (multisampled) c.WGPUStoreOp_Discard else c.WGPUStoreOp_Store;
        const color_attachment: c.WGPURenderPassColorAttachment = .{
            .view = target.color,
            .resolveTarget = target.resolve,
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = store,
            .clearValue = .{ .r = clear[0], .g = clear[1], .b = clear[2], .a = clear[3] },
        };
        const depth_attachment: c.WGPURenderPassDepthStencilAttachment = .{
            .view = target.depth,
            .depthLoadOp = c.WGPULoadOp_Clear,
            .depthStoreOp = store,
            .depthClearValue = 1.0,
        };
        self.pass = c.wgpuCommandEncoderBeginRenderPass(self.encoder, &.{
            .label = stringView(target.label),
            .colorAttachmentCount = if (target.color != null) 1 else 0,
            .colorAttachments = if (target.color != null) &color_attachment else null,
            .depthStencilAttachment = if (target.depth != null) &depth_attachment else null,
        });

        c.wgpuRenderPassEncoderSetBindGroup(self.pass, BindGroup.frame, self.gpu.bindings.frame_bind_group, 0, null);
    }

    pub fn endPass(self: *Frame) void {
        c.wgpuRenderPassEncoderEnd(self.pass);
        c.wgpuRenderPassEncoderRelease(self.pass);
        self.pass = null;
    }
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
    /// Single-sample depth: the window pass without MSAA, and render-target passes.
    depth_texture: c.WGPUTexture = null,
    depth_view: c.WGPUTextureView = null,
    /// The window pass's 4x color and depth with MSAA (`window_sample_count` 4); null
    /// without. Sized to the window, like `depth_texture`.
    msaa_color_texture: c.WGPUTexture = null,
    msaa_color_view: c.WGPUTextureView = null,
    msaa_depth_texture: c.WGPUTexture = null,
    msaa_depth_view: c.WGPUTextureView = null,
    uniform_ring: UniformRing,
    vertex_ring: VertexRing,
    bindings: Bindings,
    samplers: SamplerCache,
    mipmaps: MipmapGenerator,
    default_textures: DefaultTextures = undefined,
    /// The material shape draws use, set by `texture.bind(frame)` or
    /// `PbrMaterial.bind(frame)`. Like GL's bound texture, it survives other draws: each
    /// shape draw sets group 1 from it. Cleared each frame.
    bound_material: ?BoundMaterial = null,
    /// Frame, draw, and material uniforms for debug dumps; off unless enabled.
    uniform_debug: UniformDebug,

    const Self = @This();

    /// `allocator` holds the uniform ring's staging memory until `deinit`.
    pub fn init(allocator: Allocator, window: *zglfw.Window) !Self {
        const instance = c.wgpuCreateInstance(&.{}) orelse return error.NoWebGpuInstance;
        const surface = try createSurface(instance, window);
        const adapter = try requestAdapter(instance, surface);
        const device = try requestDevice(instance, adapter);

        gpu_debug.logAdapterInfo(adapter);

        const uniform_ring = try UniformRing.init(allocator, device);
        const vertex_ring = try VertexRing.init(allocator, device);

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
            .vertex_ring = vertex_ring,
            .bindings = Bindings.init(device, c.wgpuDeviceGetQueue(device), uniform_ring.buffer),
            .samplers = SamplerCache.init(allocator),
            .mipmaps = MipmapGenerator.init(device),
            .uniform_debug = UniformDebug.init(allocator),
        };
        try self.chooseSurfaceFormat();
        self.default_textures = try DefaultTextures.init(allocator, &self);

        const size = window.getFramebufferSize();
        self.configure(@intCast(size[0]), @intCast(size[1]));
        return self;
    }

    /// The window's frame with its main pass open. Returns null when there is nothing to
    /// draw into this frame (minimized window, surface just reconfigured); skip the
    /// frame's rendering in that case.
    pub fn beginFrame(self: *Self, clear_color: [4]f64) ?Frame {
        var frame = self.acquireFrame() orelse return null;
        frame.beginSurfacePass(clear_color);
        return frame;
    }

    /// The window's frame with no pass open, for frames with several passes. Null as
    /// `beginFrame`.
    pub fn acquireFrame(self: *Self) ?Frame {
        const size = self.window.getFramebufferSize();
        const width: u32 = @intCast(size[0]);
        const height: u32 = @intCast(size[1]);
        if (width == 0 or height == 0) {
            return null;
        }
        if (width != self.width or height != self.height) {
            self.configure(width, height);
        }

        var surface_texture: c.WGPUSurfaceTexture = .{};
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        switch (surface_texture.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
            => {},
            c.WGPUSurfaceGetCurrentTextureStatus_Outdated, c.WGPUSurfaceGetCurrentTextureStatus_Lost => {
                if (surface_texture.texture != null) {
                    c.wgpuTextureRelease(surface_texture.texture);
                }
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

        const color_view = c.wgpuTextureCreateView(surface_texture.texture, null);
        return self.startFrame(surface_texture.texture, color_view);
    }

    pub fn endFrame(self: *Self, frame: Frame) void {
        self.submitFrame(frame);

        if (c.wgpuSurfacePresent(self.surface) != c.WGPUStatus_Success) {
            log.warn("surface present failed", .{});
        }

        c.wgpuTextureViewRelease(frame.color_view);
        c.wgpuTextureRelease(frame.surface_texture);
    }

    /// A frame drawn into `color_view` instead of the surface. The target must have the
    /// surface's format and size (pipelines and the depth texture are built for those).
    /// End it with `submitFrame`; the caller keeps the view. Not between another
    /// frame's begin and end: the frames share the uniform and vertex rings.
    pub fn beginOffscreenFrame(self: *Self, color_view: c.WGPUTextureView, clear_color: [4]f64) Frame {
        c.wgpuTextureViewAddRef(color_view);
        var frame = self.startFrame(null, color_view);
        frame.beginSurfacePass(clear_color);
        return frame;
    }

    /// Close the frame's open pass, upload its per-draw data, and submit. `endFrame` also
    /// presents; offscreen frames stop here.
    pub fn submitFrame(self: *Self, frame: Frame) void {
        var last = frame;
        if (last.pass != null) {
            last.endPass();
        }

        const commands = c.wgpuCommandEncoderFinish(frame.encoder, &.{});
        self.uniform_ring.upload(self.queue);
        self.vertex_ring.upload(self.queue);
        c.wgpuQueueSubmit(self.queue, 1, &commands);
        c.wgpuCommandBufferRelease(commands);
        c.wgpuCommandEncoderRelease(frame.encoder);

        if (frame.surface_texture == null) {
            c.wgpuTextureViewRelease(frame.color_view);
        }
    }

    /// Write this frame's camera and time for group 0. Once per frame, before drawing.
    pub fn writeFrameUniforms(self: *Self, uniforms: FrameUniforms) void {
        self.uniform_debug.captureStruct("frame", uniforms);
        c.wgpuQueueWriteBuffer(self.queue, self.bindings.frame_buffer, 0, &uniforms, @sizeOf(FrameUniforms));
    }

    pub fn deinit(self: *Self) void {
        self.uniform_debug.deinit();
        self.default_textures.releaseGpuObjects();
        self.allocator.destroy(self.default_textures.white);
        self.allocator.destroy(self.default_textures.flat_normal);
        self.mipmaps.releaseGpuObjects();
        self.samplers.releaseGpuObjects();
        self.samplers.deinit();
        self.bindings.releaseGpuObjects();
        self.uniform_ring.releaseGpuObjects();
        self.uniform_ring.deinit(self.allocator);
        self.vertex_ring.releaseGpuObjects();
        self.vertex_ring.deinit(self.allocator);
        self.releaseAttachments();
        c.wgpuSurfaceUnconfigure(self.surface);
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuInstanceRelease(self.instance);
    }

    /// Resets the per-frame state and creates the frame's command encoder.
    fn startFrame(self: *Self, surface_texture: c.WGPUTexture, color_view: c.WGPUTextureView) Frame {
        self.uniform_ring.reset();
        self.vertex_ring.reset();
        self.bound_material = null;

        return .{
            .gpu = self,
            .surface_texture = surface_texture,
            .color_view = color_view,
            .encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &.{}),
        };
    }

    /// Prefer an sRGB surface format so shaders write linear color and the hardware
    /// encodes on store.
    fn chooseSurfaceFormat(self: *Self) !void {
        var caps: c.WGPUSurfaceCapabilities = .{};
        if (c.wgpuSurfaceGetCapabilities(self.surface, self.adapter, &caps) != c.WGPUStatus_Success) {
            return error.SurfaceCapabilities;
        }
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
        if (caps.formatCount == 0) {
            return error.NoSurfaceFormats;
        }

        const formats = caps.formats[0..caps.formatCount];
        self.surface_format = for (formats) |format| {
            if (format == c.WGPUTextureFormat_BGRA8UnormSrgb or format == c.WGPUTextureFormat_RGBA8UnormSrgb) {
                break format;
            }
        } else blk: {
            log.warn("no sRGB surface format; colors will be too dark", .{});
            break :blk formats[0];
        };
        if (caps.alphaModeCount > 0) {
            self.alpha_mode = caps.alphaModes[0];
        }

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
        self.createAttachments();
    }

    /// The window-sized attachments: single-sample depth, and with MSAA the window pass's
    /// 4x color and depth.
    fn createAttachments(self: *Self) void {
        self.releaseAttachments();
        self.depth_texture = self.createAttachment("depth", depth_format, 1);
        self.depth_view = c.wgpuTextureCreateView(self.depth_texture, null);
        if (window_sample_count > 1) {
            self.msaa_color_texture = self.createAttachment("msaa color", self.surface_format, window_sample_count);
            self.msaa_color_view = c.wgpuTextureCreateView(self.msaa_color_texture, null);
            self.msaa_depth_texture = self.createAttachment("msaa depth", depth_format, window_sample_count);
            self.msaa_depth_view = c.wgpuTextureCreateView(self.msaa_depth_texture, null);
        }
    }

    fn createAttachment(self: *Self, label: []const u8, format: c.WGPUTextureFormat, sample_count: u32) c.WGPUTexture {
        return c.wgpuDeviceCreateTexture(self.device, &.{
            .label = stringView(label),
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = self.width, .height = self.height, .depthOrArrayLayers = 1 },
            .format = format,
            .mipLevelCount = 1,
            .sampleCount = sample_count,
        });
    }

    fn releaseAttachments(self: *Self) void {
        const views = [_]*c.WGPUTextureView{ &self.depth_view, &self.msaa_color_view, &self.msaa_depth_view };
        for (views) |view| {
            if (view.* != null) {
                c.wgpuTextureViewRelease(view.*);
            }
            view.* = null;
        }
        const textures = [_]*c.WGPUTexture{ &self.depth_texture, &self.msaa_color_texture, &self.msaa_depth_texture };
        for (textures) |texture| {
            if (texture.* != null) {
                c.wgpuTextureRelease(texture.*);
            }
            texture.* = null;
        }
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
    while (!request.done) {
        c.wgpuInstanceProcessEvents(instance);
    }

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
    if (status == c.WGPURequestAdapterStatus_Success) {
        request.result = adapter;
    }
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
    while (!request.done) {
        c.wgpuInstanceProcessEvents(instance);
    }

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
    if (status == c.WGPURequestDeviceStatus_Success) {
        request.result = device;
    }
    request.setMessage(message);
    request.done = true;
}
