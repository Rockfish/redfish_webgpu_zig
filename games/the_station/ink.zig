//! The ink look (plan 021, phase D): hatching and outlines, as in the robot drawing.
//!
//! - Hatching is in `room.wgsl`: lines laid over each part in its own space, more layers
//!   the darker the lit surface, so shade reads as ink. `Style.hatching` gives the
//!   strength and spacing each draw passes.
//! - Outlines take two passes. First the scene is drawn into `normal_depth` (room.wgsl
//!   with `NORMAL_DEPTH`): view-space normals and depth. Then, in the window pass after
//!   the scene, a full-screen quad (ink_edges.wgsl) draws ink where neighboring pixels of
//!   that target differ: silhouettes (depth jumps) and creases (normal turns). Edges come
//!   from geometry, so anything added to a room is outlined without extra work.
//!
//! A frame: `beginNormalDepthPass`, draw the scene with `normal_depth_shaders`, `endPass`;
//! the window pass with the scene; `drawOutlines`.
//!
//! The room's and the models' shaders share ink_common.wgsl (`INCLUDES`).

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const PassTarget = core.PassTarget;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;

/// Depth written where nothing is drawn: far beyond the room, so its silhouette is an edge.
const EMPTY_DEPTH = 1000.0;

/// The lighting and hatching the room's and the models' shaders share.
pub const INCLUDES: []const []const u8 = &.{"games/the_station/shaders/ink_common.wgsl"};

/// The shaders one pass draws the scene with: the room's shapes, and the glTF models
/// (the robot, the room's equipment).
pub const SceneShaders = struct {
    room: *Shader,
    model: *Shader,

    /// The color shaders (window pass), or with `normal_depth` their variants writing the
    /// outline pass's input.
    pub fn init(context: core.Context, gpu: *GpuContext, normal_depth: bool) !SceneShaders {
        const normal_depth_constants: []const core.pipeline.OverrideConstant = &.{.{ .key = "NORMAL_DEPTH", .value = 1.0 }};
        const color_target: core.pipeline.ColorTarget = if (normal_depth) .{ .format = core.texture.hdr_format } else .surface;
        const constants = if (normal_depth) normal_depth_constants else &.{};
        return .{
            .room = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/room.wgsl", .{
                .vertex_buffers = &Shape.vertex_buffer_layouts,
                .color_target = color_target,
                .constants = constants,
                .includes = INCLUDES,
            }),
            .model = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/model.wgsl", .{
                .vertex_buffers = &core.MeshPrimitive.vertex_buffer_layouts,
                .material = .pbr,
                .color_target = color_target,
                .constants = constants,
                .includes = INCLUDES,
            }),
        };
    }

    pub fn releaseGpuObjects(self: *const SceneShaders) void {
        self.model.releaseGpuObjects();
        self.room.releaseGpuObjects();
    }
};

pub const Style = struct {
    show_outlines: bool = true,
    /// Radius in pixels of the neighbors compared (rounded); a line is about twice this wide.
    line_width: f32 = 2.0,
    /// A depth jump of this fraction of the depth is a silhouette.
    depth_threshold: f32 = 0.04,
    /// 1 - cos(angle) between neighboring normals for a crease: 0.3 is about 45°.
    normal_threshold: f32 = 0.3,
    /// Linear ink color and opacity of the outlines.
    ink_color: Vec3 = vec3(0.01, 0.01, 0.012),
    ink_opacity: f32 = 0.9,
    show_hatching: bool = true,
    hatch_strength: f32 = 0.8,
    /// Meters between hatch lines.
    hatch_spacing: f32 = 0.14,
    /// How strongly the hovered control lights up (ink_common.wgsl `highlighted`): 1 is
    /// the shader's amber tint, rim, and thinned hatching in full.
    highlight_strength: f32 = 1.0,

    pub fn hatching(self: Style) room_kit.Hatching {
        return .{
            .strength = if (self.show_hatching) self.hatch_strength else 0.0,
            .spacing = self.hatch_spacing,
        };
    }
};

pub const Ink = struct {
    /// View-space normal (xyz) and depth (w) of the frame's scene, the window's size.
    normal_depth: *Texture,
    /// The scene's shaders drawing into `normal_depth`.
    normal_depth_shaders: SceneShaders,
    /// ink_edges.wgsl, in the window pass.
    outline_shader: *Shader,
    quad: *Shape,

    const Self = @This();

    pub fn init(context: core.Context, gpu: *GpuContext) !Self {
        const outline_shader = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/ink_edges.wgsl", .{
            .vertex_buffers = &Shape.vertex_buffer_layouts,
            .material = .texture,
        });

        // Over everything in the window pass, blended
        const quad = try core.shapes.createSquare(context.alloc, gpu);
        quad.is_double_sided = true;
        quad.is_depth_test = false;
        quad.is_depth_write = false;
        quad.is_transparent = true;

        return .{
            .normal_depth = try createNormalDepth(context.alloc, gpu),
            .normal_depth_shaders = try SceneShaders.init(context, gpu, true),
            .outline_shader = outline_shader,
            .quad = quad,
        };
    }

    /// Recreates the normal-depth target if the window's size changed.
    pub fn update(self: *Self, allocator: std.mem.Allocator, gpu: *GpuContext) !void {
        if (self.normal_depth.width == gpu.width and self.normal_depth.height == gpu.height) {
            return;
        }
        self.normal_depth.releaseGpuObjects();
        self.normal_depth = try createNormalDepth(allocator, gpu);
    }

    /// The pass that draws the scene's normals and depth: single-sample, with the
    /// window-sized single-sample depth.
    pub fn beginNormalDepthPass(self: *const Self, frame: *Frame) void {
        frame.beginPass(.{
            .label = "normal depth",
            .color = self.normal_depth.view,
            .depth = frame.gpu.depth.view,
            .clear_color = .{ 0.0, 0.0, 0.0, EMPTY_DEPTH },
        });
    }

    /// In the window pass, after the scene.
    pub fn drawOutlines(self: *const Self, frame: *const Frame, style: Style) void {
        if (!style.show_outlines) {
            return;
        }
        self.normal_depth.bind(frame);
        var uniforms = DrawUniforms.init(Mat4.Identity, vec4(style.ink_color.x, style.ink_color.y, style.ink_color.z, style.ink_opacity));
        uniforms.params = vec4(style.line_width, style.depth_threshold, style.normal_threshold, 0.0);
        self.quad.draw(frame, self.outline_shader, uniforms);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.quad.releaseGpuObjects();
        self.outline_shader.releaseGpuObjects();
        self.normal_depth_shaders.releaseGpuObjects();
        self.normal_depth.releaseGpuObjects();
    }
};

fn createNormalDepth(allocator: std.mem.Allocator, gpu: *GpuContext) !*Texture {
    return core.texture.initRenderTarget(allocator, gpu, gpu.width, gpu.height, core.texture.hdr_format, "normal depth");
}
