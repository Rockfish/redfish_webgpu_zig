const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const GpuContext = core.GpuContext;
const Attachment = core.gpu_context.Attachment;
const window_sample_count = core.gpu_context.window_sample_count;
const Frame = core.Frame;
const PassTarget = core.PassTarget;
const PbrMaterial = core.material.PbrMaterial;
const Texture = core.texture.Texture;

pub const BLUR_SCALE: u32 = 2;
pub const SHADOW_SIZE: u32 = 6 * 1024;

/// The render targets behind the window: emission (bright parts), scene, and the two blur
/// passes at half size. `rgba16float` (redfish: RGB8). Sized to the window; `update`
/// recreates them after a resize. The shadow map is separate (`core.ShadowMap`): its size
/// doesn't follow the window.
///
/// With MSAA the emission and scene passes are multisampled: they draw into `msaa_color`
/// with the window's 4x depth and resolve into `emission` / `scene` (`geometryPassTarget`).
/// One 4x texture serves both passes: each clears it and keeps only its resolve. The blur
/// and composite passes read the resolved targets.
pub const FrameBuffers = struct {
    allocator: Allocator,
    width: u32,
    height: u32,
    emission: *Texture,
    scene: *Texture,
    horizontal_blur: *Texture,
    vertical_blur: *Texture,
    /// 4x `rgba16float` for the multisampled passes; empty without MSAA.
    msaa_color: Attachment,
    /// The composite pass's inputs as one pbr-layout material (see texture_merge_shader).
    composite: PbrMaterial,

    const Self = @This();

    pub fn init(allocator: Allocator, gpu: *GpuContext) !Self {
        const width = gpu.width;
        const height = gpu.height;
        const blur_width = @max(width / BLUR_SCALE, 1);
        const blur_height = @max(height / BLUR_SCALE, 1);

        const emission = try core.texture.initRenderTarget(allocator, gpu, width, height, core.texture.hdr_format, "emission");
        const scene = try core.texture.initRenderTarget(allocator, gpu, width, height, core.texture.hdr_format, "scene");
        const horizontal_blur = try core.texture.initRenderTarget(allocator, gpu, blur_width, blur_height, core.texture.hdr_format, "horizontal blur");
        const vertical_blur = try core.texture.initRenderTarget(allocator, gpu, blur_width, blur_height, core.texture.hdr_format, "vertical blur");

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .emission = emission,
            .scene = scene,
            .horizontal_blur = horizontal_blur,
            .vertical_blur = vertical_blur,
            .msaa_color = if (window_sample_count > 1)
                Attachment.init(gpu, width, height, core.texture.hdr_format, window_sample_count, "msaa scene")
            else
                .{},
            // Slots: base color, metallic-roughness, normal, occlusion, emissive
            .composite = try PbrMaterial.initWithTextures(gpu, .{ scene, emission, null, null, vertical_blur }),
        };
    }

    /// Recreate the targets if the window's size changed (redfish's framebufferUpdate).
    pub fn update(self: *Self, gpu: *GpuContext) !void {
        if (self.width == gpu.width and self.height == gpu.height) {
            return;
        }
        self.releaseGpuObjects();
        self.* = try init(self.allocator, gpu);
    }

    /// A pass that draws the scene's geometry into `target` (emission, scene), with depth.
    /// With MSAA it draws 4x and resolves into `target`; its shaders set
    /// `ShaderConfig.multisampled`.
    pub fn geometryPassTarget(self: *const Self, gpu: *const GpuContext, target: *const Texture, label: []const u8, clear_color: [4]f64) PassTarget {
        if (window_sample_count == 1) {
            return .{ .label = label, .color = target.view, .depth = gpu.depth.view, .clear_color = clear_color };
        }
        return .{
            .label = label,
            .color = self.msaa_color.view,
            .depth = gpu.msaa_depth.view,
            .resolve = target.view,
            .clear_color = clear_color,
        };
    }

    /// A full-screen pass into `target` (the blurs): single-sample, no depth. A full-screen
    /// quad has no edges inside the target for MSAA to smooth.
    pub fn quadPassTarget(target: *const Texture, label: []const u8, clear_color: [4]f64) PassTarget {
        return .{ .label = label, .color = target.view, .clear_color = clear_color };
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.composite.releaseGpuObjects();
        self.msaa_color.releaseGpuObjects();
        self.vertical_blur.releaseGpuObjects();
        self.horizontal_blur.releaseGpuObjects();
        self.scene.releaseGpuObjects();
        self.emission.releaseGpuObjects();
    }
};
