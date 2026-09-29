//! Shadow maps for several lights: one depth texture with a layer per light. Each layer is
//! drawn by its own depth-only pass, and receivers sample every layer through one
//! `texture_depth_2d_array` at group 3 (`PassKind.shadow_layers`). `ShadowMap` is the
//! single-light form.
//!
//! A frame with shadows from `n` lights:
//!
//!     for each layer: shadow_maps.setLightSpace(gpu, layer, light_space)
//!     for each layer:
//!         frame.beginPass(shadow_maps.passTarget(layer))
//!         shadow_maps.bindCaster(&frame, layer)   // casters: PassKind.shadow_caster
//!         ...draw the casters...
//!         frame.endPass()
//!     frame.beginSurfacePass(...)
//!     shadow_maps.bind(&frame)                    // receivers: PassKind.shadow_layers
//!
//! Receivers read layer `i`'s matrix as `shadow_layers[i].light_space` and compare with
//! `textureSampleCompareLevel(shadow_maps, shadow_sampler, uv, i, depth)`.

const std = @import("std");
const math = @import("math");
const wgpu = @import("wgpu");
const bindings = @import("bindings.zig");
const gpu_context = @import("gpu_context.zig");
const shadow_map = @import("shadow_map.zig");

const c = wgpu.c;
const stringView = wgpu.stringView;
const Mat4 = math.Mat4;
const BindGroup = bindings.BindGroup;
const ShadowLayerUniforms = bindings.ShadowLayerUniforms;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;
const PassTarget = gpu_context.PassTarget;

pub const MAX_LAYERS = bindings.MAX_SHADOW_LAYERS;

/// Pass labels, one per layer, for GPU debuggers.
const pass_labels = blk: {
    var labels: [MAX_LAYERS][]const u8 = undefined;
    for (&labels, 0..) |*label, i| {
        label.* = std.fmt.comptimePrint("shadow pass {d}", .{i});
    }
    break :blk labels;
};

pub const ShadowMapArray = struct {
    size: u32,
    layers: u32,
    filter: Filter,
    texture: c.WGPUTexture,
    /// All layers, for sampling.
    array_view: c.WGPUTextureView,
    /// One layer each, as the depth attachment of that layer's shadow pass.
    layer_views: [MAX_LAYERS]c.WGPUTextureView,
    sampler: c.WGPUSampler,
    /// One `ShadowLayerUniforms` (a 256-byte slot) per layer, `MAX_LAYERS` slots.
    light_buffer: c.WGPUBuffer,
    /// Group 3 for receivers: all layers, the sampler, every slot of `light_buffer`.
    bind_group: c.WGPUBindGroup,
    /// Group 3 for each layer's shadow pass: that layer's slot of `light_buffer` only.
    caster_bind_groups: [MAX_LAYERS]c.WGPUBindGroup,

    const Self = @This();

    pub const Filter = shadow_map.ShadowMap.Filter;

    pub const Config = struct {
        /// `size` × `size` texels per layer.
        size: u32,
        /// 1 to `MAX_LAYERS` lights.
        layers: u32,
        filter: Filter = .nearest,
    };

    pub fn init(gpu: *const GpuContext, config: Config) Self {
        std.debug.assert(config.layers >= 1 and config.layers <= MAX_LAYERS);

        const texture = c.wgpuDeviceCreateTexture(gpu.device, &.{
            .label = stringView("shadow map array"),
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = config.size, .height = config.size, .depthOrArrayLayers = config.layers },
            .format = gpu_context.depth_format,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        const array_view = c.wgpuTextureCreateView(texture, &.{
            .label = stringView("shadow map array"),
            .dimension = c.WGPUTextureViewDimension_2DArray,
            .mipLevelCount = 1,
            .arrayLayerCount = config.layers,
            .aspect = c.WGPUTextureAspect_All,
        });

        // A render pass attachment must be a single layer, so each shadow pass gets a 2D
        // view of its own layer.
        var layer_views: [MAX_LAYERS]c.WGPUTextureView = @splat(null);
        for (layer_views[0..config.layers], 0..) |*view, layer| {
            view.* = c.wgpuTextureCreateView(texture, &.{
                .label = stringView(pass_labels[layer]),
                .dimension = c.WGPUTextureViewDimension_2D,
                .mipLevelCount = 1,
                .baseArrayLayer = @intCast(layer),
                .arrayLayerCount = 1,
                .aspect = c.WGPUTextureAspect_All,
            });
        }

        const sampler = shadow_map.createComparisonSampler(gpu.device, config.filter);

        const light_buffer = c.wgpuDeviceCreateBuffer(gpu.device, &.{
            .label = stringView("shadow layer lights"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = MAX_LAYERS * @sizeOf(ShadowLayerUniforms),
        });

        const receiver_entries = [_]c.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = array_view },
            .{ .binding = 1, .sampler = sampler },
            .{ .binding = 2, .buffer = light_buffer, .size = MAX_LAYERS * @sizeOf(ShadowLayerUniforms) },
        };
        const bind_group = c.wgpuDeviceCreateBindGroup(gpu.device, &.{
            .label = stringView("shadow map array"),
            .layout = gpu.bindings.shadow_layers_layout,
            .entryCount = receiver_entries.len,
            .entries = &receiver_entries,
        });

        // Why one bind group per layer instead of one matrix rewritten before each shadow
        // pass: `wgpuQueueWriteBuffer` doesn't happen where it's called in the frame. Every
        // write queued this frame runs before any of the frame's commands, so if one
        // buffer were rewritten between two shadow passes, both passes would read the
        // last value, and every layer would hold the last light's shadows. Instead each
        // layer's matrix has its own slot, written once per frame (`setLightSpace`), and
        // each shadow pass binds a group that points at its own slot. Nothing is rewritten
        // while the frame is recorded. `uniform_ring.zig` applies the same rule to draws.
        var caster_bind_groups: [MAX_LAYERS]c.WGPUBindGroup = @splat(null);
        for (caster_bind_groups[0..config.layers], 0..) |*group, layer| {
            const entry: c.WGPUBindGroupEntry = .{
                .binding = 0,
                .buffer = light_buffer,
                .offset = layer * @sizeOf(ShadowLayerUniforms),
                .size = @sizeOf(Mat4),
            };
            group.* = c.wgpuDeviceCreateBindGroup(gpu.device, &.{
                .label = stringView(pass_labels[layer]),
                .layout = gpu.bindings.shadow_caster_layout,
                .entryCount = 1,
                .entries = &entry,
            });
        }

        return .{
            .size = config.size,
            .layers = config.layers,
            .filter = config.filter,
            .texture = texture,
            .array_view = array_view,
            .layer_views = layer_views,
            .sampler = sampler,
            .light_buffer = light_buffer,
            .bind_group = bind_group,
            .caster_bind_groups = caster_bind_groups,
        };
    }

    /// Layer `layer`'s light: projection x view. Once per frame for each layer, before
    /// recording its shadow pass (see the note in `init`).
    pub fn setLightSpace(self: *const Self, gpu: *const GpuContext, layer: u32, light_space: Mat4) void {
        std.debug.assert(layer < self.layers);
        const uniforms: ShadowLayerUniforms = .{ .light_space = light_space };
        c.wgpuQueueWriteBuffer(gpu.queue, self.light_buffer, layer * @sizeOf(ShadowLayerUniforms), &uniforms, @sizeOf(ShadowLayerUniforms));
    }

    /// The depth-only pass that draws layer `layer`'s shadow casters.
    pub fn passTarget(self: *const Self, layer: u32) PassTarget {
        std.debug.assert(layer < self.layers);
        return .{ .label = pass_labels[layer], .depth = self.layer_views[layer] };
    }

    /// Group 3 for layer `layer`'s shadow pass. After `frame.beginPass`, before drawing.
    pub fn bindCaster(self: *const Self, frame: *const Frame, layer: u32) void {
        std.debug.assert(layer < self.layers);
        c.wgpuRenderPassEncoderSetBindGroup(frame.pass, BindGroup.pass, self.caster_bind_groups[layer], 0, null);
    }

    /// Group 3 for the pass's shadow receivers. After `frame.beginPass`, before drawing.
    pub fn bind(self: *const Self, frame: *const Frame) void {
        c.wgpuRenderPassEncoderSetBindGroup(frame.pass, BindGroup.pass, self.bind_group, 0, null);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        for (self.caster_bind_groups[0..self.layers]) |group| {
            c.wgpuBindGroupRelease(group);
        }
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuBufferRelease(self.light_buffer);
        c.wgpuSamplerRelease(self.sampler);
        for (self.layer_views[0..self.layers]) |view| {
            c.wgpuTextureViewRelease(view);
        }
        c.wgpuTextureViewRelease(self.array_view);
        c.wgpuTextureRelease(self.texture);
    }
};
