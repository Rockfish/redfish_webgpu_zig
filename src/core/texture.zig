const std = @import("std");
const zstbi = @import("zstbi");
const wgpu = @import("wgpu");
const bindings = @import("bindings.zig");
const mipmaps = @import("mipmaps.zig");
const gpu_context = @import("gpu_context.zig");
const Context = @import("context.zig").Context;

const c = wgpu.c;
const stringView = wgpu.stringView;
const Allocator = std.mem.Allocator;
const BindGroup = bindings.BindGroup;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;

const log = std.log.scoped(.texture);

pub const TextureConfig = struct {
    filter: TextureFilter = .Linear,
    wrap: TextureWrap = .Clamp,
    /// Flip rows on load so texcoord v = 0 is the image's bottom row. Shapes use v-up
    /// texcoords, so they want this; glTF images (v-down) don't. Same meaning as in GL:
    /// both APIs sample v = 0 from the first uploaded row.
    flip_v: bool = true,
    /// Color data (base color, emissive, UI) is sRGB and sampled as linear. Data textures
    /// (normals, metallic-roughness, occlusion) set this false.
    is_srgb: bool = true,
};

pub const TextureFilter = enum {
    Linear,
    Nearest,
};

pub const TextureWrap = enum {
    Clamp,
    Repeat,
};

pub const Texture = struct {
    gltf_texture_id: usize,
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    /// Owned by `GpuContext.samplers`.
    sampler: c.WGPUSampler,
    /// Group 1 for `MaterialKind.texture` shaders.
    bind_group: c.WGPUBindGroup,
    width: u32,
    height: u32,

    const Self = @This();

    /// Initialize from custom file path with configuration (for manual texture assignment)
    pub fn initFromFile(
        context: Context,
        gpu: *GpuContext,
        file_path: [:0]const u8,
        config: TextureConfig,
    ) !*Texture {
        zstbi.init(context.io, context.temp_alloc);
        defer zstbi.deinit();

        zstbi.setFlipVerticallyOnLoad(config.flip_v);

        // Always 4 channels: WebGPU has no RGB8 format, and grey / grey-alpha images
        // should read as color, not red.
        var image = zstbi.Image.loadFromFile(file_path, 4) catch |err| {
            log.err("loadFromFile error: {any}  filepath: {s}", .{ err, file_path });
            return err;
        };
        defer image.deinit();

        const sampler = try gpu.samplers.get(gpu.device, SamplerKey.fromConfig(config));
        const texture = try initFromImage(context.alloc, gpu, image, config.is_srgb, sampler, file_path);

        log.debug("Texture loaded: {s}, dimensions: {d}x{d}", .{ file_path, texture.width, texture.height });
        return texture;
    }

    /// Bind as group 1 for the draws that follow. Replaces redfish's
    /// `shader.bindTextureAuto(...)`; bind group changes are recorded in draw order.
    pub fn bind(self: *const Self, frame: *const Frame) void {
        c.wgpuRenderPassEncoderSetBindGroup(frame.pass, BindGroup.material, self.bind_group, 0, null);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuTextureViewRelease(self.view);
        c.wgpuTextureRelease(self.texture);
    }
};

/// Upload an RGBA8 image with a full mip chain.
pub fn initFromImage(
    allocator: Allocator,
    gpu: *GpuContext,
    image: zstbi.Image,
    is_srgb: bool,
    sampler: c.WGPUSampler,
    label: []const u8,
) !*Texture {
    std.debug.assert(image.num_components == 4 and image.bytes_per_component == 1);

    const format: c.WGPUTextureFormat = if (is_srgb) c.WGPUTextureFormat_RGBA8UnormSrgb else c.WGPUTextureFormat_RGBA8Unorm;
    const level_count = mipmaps.levelCount(image.width, image.height);
    const size: c.WGPUExtent3D = .{ .width = image.width, .height = image.height, .depthOrArrayLayers = 1 };

    const gpu_texture = c.wgpuDeviceCreateTexture(gpu.device, &.{
        .label = stringView(label),
        .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst | c.WGPUTextureUsage_RenderAttachment,
        .dimension = c.WGPUTextureDimension_2D,
        .size = size,
        .format = format,
        .mipLevelCount = level_count,
        .sampleCount = 1,
    });

    c.wgpuQueueWriteTexture(
        gpu.queue,
        &.{ .texture = gpu_texture, .mipLevel = 0, .aspect = c.WGPUTextureAspect_All },
        image.data.ptr,
        image.data.len,
        &.{ .bytesPerRow = image.width * 4, .rowsPerImage = image.height },
        &size,
    );
    gpu.mipmaps.generate(gpu.device, gpu.queue, gpu_texture, format, level_count);

    const view = c.wgpuTextureCreateView(gpu_texture, null);
    const entries = [_]c.WGPUBindGroupEntry{
        .{ .binding = 0, .textureView = view },
        .{ .binding = 1, .sampler = sampler },
    };

    const texture = try allocator.create(Texture);
    texture.* = .{
        .gltf_texture_id = 0,
        .texture = gpu_texture,
        .view = view,
        .sampler = sampler,
        .bind_group = c.wgpuDeviceCreateBindGroup(gpu.device, &.{
            .label = stringView(label),
            .layout = gpu.bindings.texture_layout,
            .entryCount = entries.len,
            .entries = &entries,
        }),
        .width = image.width,
        .height = image.height,
    };
    return texture;
}

/// Sampler state; equal keys share one sampler.
pub const SamplerKey = struct {
    mag_filter: c.WGPUFilterMode,
    min_filter: c.WGPUFilterMode,
    mipmap_filter: c.WGPUMipmapFilterMode,
    wrap_u: c.WGPUAddressMode,
    wrap_v: c.WGPUAddressMode,
    use_mipmaps: bool,

    /// Matches redfish: Linear is trilinear, Nearest samples level 0 only.
    pub fn fromConfig(config: TextureConfig) SamplerKey {
        const wrap: c.WGPUAddressMode = switch (config.wrap) {
            .Clamp => c.WGPUAddressMode_ClampToEdge,
            .Repeat => c.WGPUAddressMode_Repeat,
        };
        return switch (config.filter) {
            .Linear => .{
                .mag_filter = c.WGPUFilterMode_Linear,
                .min_filter = c.WGPUFilterMode_Linear,
                .mipmap_filter = c.WGPUMipmapFilterMode_Linear,
                .wrap_u = wrap,
                .wrap_v = wrap,
                .use_mipmaps = true,
            },
            .Nearest => .{
                .mag_filter = c.WGPUFilterMode_Nearest,
                .min_filter = c.WGPUFilterMode_Nearest,
                .mipmap_filter = c.WGPUMipmapFilterMode_Nearest,
                .wrap_u = wrap,
                .wrap_v = wrap,
                .use_mipmaps = false,
            },
        };
    }
};

/// Samplers created on first request and kept until `GpuContext.deinit`.
pub const SamplerCache = struct {
    samplers: std.AutoHashMap(SamplerKey, c.WGPUSampler),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .samplers = std.AutoHashMap(SamplerKey, c.WGPUSampler).init(allocator) };
    }

    pub fn get(self: *Self, device: c.WGPUDevice, key: SamplerKey) !c.WGPUSampler {
        const entry = try self.samplers.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = createSampler(device, key);
        return entry.value_ptr.*;
    }

    pub fn releaseGpuObjects(self: *Self) void {
        var it = self.samplers.valueIterator();
        while (it.next()) |sampler| c.wgpuSamplerRelease(sampler.*);
    }

    pub fn deinit(self: *Self) void {
        self.samplers.deinit();
    }
};

/// Zero defaults that would be wrong are set: `lodMaxClamp` 0 would pin sampling to level
/// 0, `maxAnisotropy` 0 is invalid.
fn createSampler(device: c.WGPUDevice, key: SamplerKey) c.WGPUSampler {
    return c.wgpuDeviceCreateSampler(device, &.{
        .addressModeU = key.wrap_u,
        .addressModeV = key.wrap_v,
        .addressModeW = c.WGPUAddressMode_ClampToEdge,
        .magFilter = key.mag_filter,
        .minFilter = key.min_filter,
        .mipmapFilter = key.mipmap_filter,
        .lodMinClamp = 0.0,
        .lodMaxClamp = if (key.use_mipmaps) 32.0 else 0.0,
        .maxAnisotropy = 1,
    });
}
