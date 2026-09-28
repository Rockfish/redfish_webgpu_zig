//! A directional light's shadow map: a depth texture drawn in a depth-only pass from the
//! light (`FrameUniforms.light_space`), then sampled by shadow-receiving shaders at
//! group 3 (`PassKind.shadow`). Replaces redfish's depth-map framebuffer.
//!
//! Shaders compare with `textureSampleCompareLevel(shadow_map, shadow_sampler, uv, depth)`,
//! which returns 1 where the fragment is lit; `shadowCoords` in common.wgsl maps a
//! light-space position to uv and depth.

const std = @import("std");
const wgpu = @import("wgpu");
const gpu_context = @import("gpu_context.zig");
const BindGroup = @import("bindings.zig").BindGroup;

const c = wgpu.c;
const stringView = wgpu.stringView;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;
const PassTarget = gpu_context.PassTarget;

pub const ShadowMap = struct {
    size: u32,
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    /// `LessEqual` comparison, nearest (redfish's single-sample test), clamp to edge.
    sampler: c.WGPUSampler,
    bind_group: c.WGPUBindGroup,

    const Self = @This();

    /// `size` × `size` texels. Fixed for the map's lifetime (not tied to the window).
    pub fn init(gpu: *const GpuContext, size: u32) Self {
        const texture = c.wgpuDeviceCreateTexture(gpu.device, &.{
            .label = stringView("shadow map"),
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = size, .height = size, .depthOrArrayLayers = 1 },
            .format = gpu_context.depth_format,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        const view = c.wgpuTextureCreateView(texture, null);
        const sampler = c.wgpuDeviceCreateSampler(gpu.device, &.{
            .label = stringView("shadow comparison"),
            .addressModeU = c.WGPUAddressMode_ClampToEdge,
            .addressModeV = c.WGPUAddressMode_ClampToEdge,
            .addressModeW = c.WGPUAddressMode_ClampToEdge,
            .magFilter = c.WGPUFilterMode_Nearest,
            .minFilter = c.WGPUFilterMode_Nearest,
            .mipmapFilter = c.WGPUMipmapFilterMode_Nearest,
            .lodMaxClamp = 32.0,
            .compare = c.WGPUCompareFunction_LessEqual,
            .maxAnisotropy = 1,
        });

        const entries = [_]c.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = view },
            .{ .binding = 1, .sampler = sampler },
        };
        return .{
            .size = size,
            .texture = texture,
            .view = view,
            .sampler = sampler,
            .bind_group = c.wgpuDeviceCreateBindGroup(gpu.device, &.{
                .label = stringView("shadow map"),
                .layout = gpu.bindings.shadow_layout,
                .entryCount = entries.len,
                .entries = &entries,
            }),
        };
    }

    /// The depth-only pass that draws the shadow casters (shaders with
    /// `.color_target = .none`).
    pub fn passTarget(self: *const Self) PassTarget {
        return .{ .label = "shadow pass", .depth = self.view };
    }

    /// Group 3 for the pass's shadow receivers. After `frame.beginPass`, before drawing.
    pub fn bind(self: *const Self, frame: *const Frame) void {
        c.wgpuRenderPassEncoderSetBindGroup(frame.pass, BindGroup.pass, self.bind_group, 0, null);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuSamplerRelease(self.sampler);
        c.wgpuTextureViewRelease(self.view);
        c.wgpuTextureRelease(self.texture);
    }
};
