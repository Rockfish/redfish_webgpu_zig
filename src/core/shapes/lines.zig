const std = @import("std");
const math = @import("math");
const wgpu = @import("wgpu");
const bindings = @import("../bindings.zig");
const colors = @import("../colors.zig");
const gpu_context = @import("../gpu_context.zig");
const Shader = @import("../shader.zig").Shader;

const c = wgpu.c;
const Allocator = std.mem.Allocator;
const BindGroup = bindings.BindGroup;
const DrawUniforms = bindings.DrawUniforms;
const Color = colors.Color;
const Frame = gpu_context.Frame;

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const log = std.log.scoped(.lines);

pub const LineSegment = struct {
    start: Vec3,
    end: Vec3,
    color: Color,
    alpha: ?f32 = null, // If null, uses Lines.default_alpha
};

/// Interleaved position and color, as redfish's line VBO.
const LineVertex = extern struct {
    position: [3]f32,
    color: [4]f32,
};

const vertex_attributes = [_]c.WGPUVertexAttribute{
    .{ .format = c.WGPUVertexFormat_Float32x3, .offset = 0, .shaderLocation = bindings.VertexAttr.position },
    .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(LineVertex, "color"), .shaderLocation = bindings.VertexAttr.color },
};

/// Colored line segments. Each `draw` appends its vertices to the frame's vertex ring, so
/// several draws per frame each keep their own lines (redfish rewrote one VBO per draw).
/// Lines are 1 px: WebGPU has no line width.
pub const Lines = struct {
    shader: *Shader,
    thickness: f32,
    default_alpha: f32,
    max_lines: usize,
    vertices: []LineVertex,

    const Self = @This();

    /// Line shaders are created with this layout and `.topology = .line_list`.
    pub const vertex_buffer_layouts = [_]c.WGPUVertexBufferLayout{.{
        .stepMode = c.WGPUVertexStepMode_Vertex,
        .arrayStride = @sizeOf(LineVertex),
        .attributeCount = vertex_attributes.len,
        .attributes = &vertex_attributes,
    }};

    /// `thickness` is kept for redfish's call shape; lines draw 1 px wide.
    pub fn init(allocator: Allocator, shader: *Shader, thickness: f32, default_alpha: f32, max_lines: usize) !Self {
        return .{
            .shader = shader,
            .thickness = thickness,
            .default_alpha = default_alpha,
            .max_lines = max_lines,
            .vertices = try allocator.alloc(LineVertex, max_lines * 2),
        };
    }

    pub fn draw(self: *Self, frame: *const Frame, segments: []const LineSegment) void {
        if (segments.len == 0) return;
        if (segments.len > self.max_lines) {
            log.warn("drawing {d} lines but max is {d}; drawing the first {d}", .{ segments.len, self.max_lines, self.max_lines });
        }
        const num_lines = @min(segments.len, self.max_lines);

        for (segments[0..num_lines], 0..) |segment, i| {
            const color = linearColor(segment.color, segment.alpha orelse self.default_alpha);
            self.vertices[2 * i] = .{ .position = segment.start.asArray(), .color = color };
            self.vertices[2 * i + 1] = .{ .position = segment.end.asArray(), .color = color };
        }

        const gpu = frame.gpu;
        const pass = frame.pass;
        const bytes = std.mem.sliceAsBytes(self.vertices[0 .. num_lines * 2]);
        const vertex_offset = gpu.vertex_ring.allocateBytes(bytes);
        const draw_offset = gpu.uniform_ring.allocate(DrawUniforms, DrawUniforms.init(Mat4.Identity, math.vec4(1.0, 1.0, 1.0, 1.0)));

        c.wgpuRenderPassEncoderSetPipeline(pass, self.shader.getPipeline(.{ .double_sided = true }));
        c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.material, gpu.bindings.empty_bind_group, 0, null);
        c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.object, gpu.bindings.object_bind_group, 1, &draw_offset);
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, gpu.vertex_ring.buffer, vertex_offset, bytes.len);
        c.wgpuRenderPassEncoderDraw(pass, @intCast(num_lines * 2), 1, 0, 0);
    }
};

/// The named colors were chosen for GL, which displayed them as-is; convert so they look
/// the same on the sRGB surface.
fn linearColor(color: Color, alpha: f32) [4]f32 {
    const rgb = color.toRgb();
    return .{ colors.srgbToLinear(rgb[0]), colors.srgbToLinear(rgb[1]), colors.srgbToLinear(rgb[2]), alpha };
}
