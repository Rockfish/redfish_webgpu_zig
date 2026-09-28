const std = @import("std");
const zstbi = @import("zstbi");
const wgpu = @import("wgpu");
const bindings = @import("bindings.zig");
const mipmaps = @import("mipmaps.zig");
const gpu_context = @import("gpu_context.zig");
const utils = @import("utils/root.zig");
const gltf_types = @import("gltf/gltf.zig");
const Context = @import("context.zig").Context;
const GltfAsset = @import("gltf_asset.zig").GltfAsset;

const c = wgpu.c;
const stringView = wgpu.stringView;
const Allocator = std.mem.Allocator;
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
    is_srgb: bool,

    const Self = @This();

    /// Initialize from glTF texture reference. `is_srgb` comes from how the material uses
    /// it: base color and emissive are sRGB, the other maps linear.
    pub fn initFromGltf(
        context: Context,
        gpu: *GpuContext,
        gltf_asset: *GltfAsset,
        directory: []const u8,
        texture_index: usize,
        is_srgb: bool,
    ) !*Texture {
        const gltf_texture = gltf_asset.gltf.textures.?[texture_index];
        const source_id = gltf_texture.source orelse std.debug.panic("texture.source null not supported.", .{});
        const gltf_image = gltf_asset.gltf.images.?[source_id];

        zstbi.init(context.io, context.temp_alloc);
        defer zstbi.deinit();

        // glTF texcoords have a top-left origin, matching the image rows as loaded: no flip.
        var image = loadImage(context, gltf_asset, gltf_image, directory);
        defer image.deinit();

        const sampler_info = if (gltf_texture.sampler) |sampler_id|
            gltf_asset.gltf.samplers.?[sampler_id]
        else
            gltf_types.Sampler{};
        const sampler = try gpu.samplers.get(gpu.device, samplerKeyFromGltf(sampler_info));

        const label = gltf_image.name orelse gltf_image.uri orelse "gltf texture";
        const texture = try initFromPixels(context.alloc, gpu, RawImage.fromImage(image), is_srgb, sampler, label);
        texture.gltf_texture_id = texture_index;

        log.debug("Texture loaded: {s} {d}x{d} srgb={}", .{ label, texture.width, texture.height, is_srgb });
        return texture;
    }

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
        const texture = try initFromPixels(context.alloc, gpu, RawImage.fromImage(image), config.is_srgb, sampler, file_path);

        log.debug("Texture loaded: {s}, dimensions: {d}x{d}", .{ file_path, texture.width, texture.height });
        return texture;
    }

    /// The texture `MaterialKind.texture` draws use from here on, this frame. Replaces
    /// redfish's `shader.bindTextureAuto(...)`; each shape draw sets group 1 from it, so
    /// draws with other materials in between don't disturb it.
    pub fn bind(self: *const Self, frame: *const Frame) void {
        frame.gpu.bound_material = .{ .bind_group = self.bind_group, .kind = .texture };
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuTextureViewRelease(self.view);
        c.wgpuTextureRelease(self.texture);
    }
};

/// Load a glTF image from a data URI, a file next to the asset, or a buffer view.
/// Always 4 channels (see `initFromFile`).
pub fn loadImage(context: Context, gltf_asset: *GltfAsset, gltf_image: gltf_types.Image, directory: []const u8) zstbi.Image {
    if (gltf_image.uri) |uri| {
        if (std.mem.startsWith(u8, uri, "data:")) {
            const comma = utils.strchr(uri, ',') orelse std.debug.panic("Texture uri malformed. uri: {s}", .{uri[0..@min(uri.len, 32)]});
            const encoded = uri[comma + 1 ..];
            const decoder = std.base64.standard.Decoder;
            const decoded_length = decoder.calcSizeForSlice(encoded) catch |err| {
                std.debug.panic("Texture base64 decoder error: {any}", .{err});
            };
            const data_buffer = context.temp_alloc.alloc(u8, decoded_length) catch |err| {
                std.debug.panic("Texture allocator error: {any}", .{err});
            };
            defer context.temp_alloc.free(data_buffer);
            decoder.decode(data_buffer, encoded) catch |err| {
                std.debug.panic("Texture base64 decoder error: {any}", .{err});
            };
            return zstbi.Image.loadFromMemory(data_buffer, 4) catch |err| {
                std.debug.panic("Texture loadFromMemory error: {any} (data uri)", .{err});
            };
        }

        const c_path = std.fs.path.joinZ(context.temp_alloc, &[_][]const u8{ directory, uri }) catch |err| {
            std.debug.panic("Texture allocator error: {any}", .{err});
        };
        defer context.temp_alloc.free(c_path);
        log.debug("Loading texture from file: {s}", .{c_path});
        return zstbi.Image.loadFromFile(c_path, 4) catch |err| {
            std.debug.panic("Texture loadFromFile error: {any}  filepath: {s}", .{ err, c_path });
        };
    } else if (gltf_image.buffer_view) |buffer_view_id| {
        const buffer_view = gltf_asset.gltf.buffer_views.?[buffer_view_id];
        const buffer = gltf_asset.buffer_data.list.items[buffer_view.buffer];
        const data = buffer[buffer_view.byte_offset .. buffer_view.byte_offset + buffer_view.byte_length];
        return zstbi.Image.loadFromMemory(data, 4) catch |err| {
            std.debug.panic("Texture loadFromMemory error: {any}  bufferview: {d}", .{ err, buffer_view_id });
        };
    }
    std.debug.panic("Gltf Image needs either a uri or a bufferview.", .{});
}

/// Tightly packed RGBA8 pixels, top row first.
pub const RawImage = struct {
    data: []const u8,
    width: u32,
    height: u32,

    pub fn fromImage(image: zstbi.Image) RawImage {
        std.debug.assert(image.num_components == 4 and image.bytes_per_component == 1);
        return .{ .data = image.data, .width = image.width, .height = image.height };
    }
};

/// `rgba16float`: linear color with headroom above 1, for render targets that later passes
/// sample (bloom). Also for `ShaderConfig.color_target` of shaders that draw into them.
pub const hdr_format = c.WGPUTextureFormat_RGBA16Float;

/// A texture passes draw into and later passes sample (bloom, post-processing): a render
/// attachment with one mip level, a linear clamped sampler, and a `.texture` bind group,
/// so `bind(frame)` works as for loaded textures. Recreate it to change its size.
pub fn initRenderTarget(
    allocator: Allocator,
    gpu: *GpuContext,
    width: u32,
    height: u32,
    format: c.WGPUTextureFormat,
    label: []const u8,
) !*Texture {
    const gpu_texture = c.wgpuDeviceCreateTexture(gpu.device, &.{
        .label = stringView(label),
        .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding,
        .dimension = c.WGPUTextureDimension_2D,
        .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
        .format = format,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    const view = c.wgpuTextureCreateView(gpu_texture, null);
    const sampler = try gpu.samplers.get(gpu.device, SamplerKey.fromConfig(.{ .filter = .Linear, .wrap = .Clamp }));

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
        .width = width,
        .height = height,
        .is_srgb = false,
    };
    return texture;
}

/// Upload RGBA8 pixels with a full mip chain.
pub fn initFromPixels(
    allocator: Allocator,
    gpu: *GpuContext,
    image: RawImage,
    is_srgb: bool,
    sampler: c.WGPUSampler,
    label: []const u8,
) !*Texture {
    std.debug.assert(image.data.len == @as(usize, image.width) * image.height * 4);

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
        .is_srgb = is_srgb,
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

/// Unset filters default to trilinear (glTF leaves the choice to the implementation;
/// redfish used plain LINEAR, which skips mipmaps).
pub fn samplerKeyFromGltf(sampler: gltf_types.Sampler) SamplerKey {
    const min_filter = sampler.min_filter orelse .linear_mipmap_linear;
    return .{
        .mag_filter = switch (sampler.mag_filter orelse .linear) {
            .nearest => c.WGPUFilterMode_Nearest,
            .linear => c.WGPUFilterMode_Linear,
        },
        .min_filter = switch (min_filter) {
            .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear => c.WGPUFilterMode_Nearest,
            .linear, .linear_mipmap_nearest, .linear_mipmap_linear => c.WGPUFilterMode_Linear,
        },
        .mipmap_filter = switch (min_filter) {
            .nearest_mipmap_linear, .linear_mipmap_linear => c.WGPUMipmapFilterMode_Linear,
            else => c.WGPUMipmapFilterMode_Nearest,
        },
        .wrap_u = addressMode(sampler.wrap_s),
        .wrap_v = addressMode(sampler.wrap_t),
        .use_mipmaps = min_filter != .nearest and min_filter != .linear,
    };
}

fn addressMode(wrap: gltf_types.WrapMode) c.WGPUAddressMode {
    return switch (wrap) {
        .repeat => c.WGPUAddressMode_Repeat,
        .clamp_to_edge => c.WGPUAddressMode_ClampToEdge,
        .mirrored_repeat => c.WGPUAddressMode_MirrorRepeat,
    };
}

/// Samplers created on first request and kept until `GpuContext.deinit`.
pub const SamplerCache = struct {
    samplers: std.AutoHashMap(SamplerKey, c.WGPUSampler),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .samplers = std.AutoHashMap(SamplerKey, c.WGPUSampler).init(allocator) };
    }

    pub fn get(self: *Self, device: c.WGPUDevice, key: SamplerKey) !c.WGPUSampler {
        const entry = try self.samplers.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = createSampler(device, key);
        }
        return entry.value_ptr.*;
    }

    pub fn releaseGpuObjects(self: *Self) void {
        var it = self.samplers.valueIterator();
        while (it.next()) |sampler| {
            c.wgpuSamplerRelease(sampler.*);
        }
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
