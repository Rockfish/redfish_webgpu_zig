//! Sprites drawn over the frame in screen space (plan 022, phase B3): the cursor first,
//! later phase F's inventory bar and remarks. Each is a rectangle of a sprite sheet drawn
//! at a rectangle of the window, alpha blended, last in the window pass (before ImGui).
//! And a fill of the whole window in one color, for a fade (phase E2).
//!
//! Positions and sizes are in window units, as the mouse is (`Input.mouse_x`), with the
//! origin at the top-left; `draw` turns them into the framebuffer's clip space.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const Mat4 = math.Mat4;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

/// A rectangle, x right and y down from the top-left.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Overlay = struct {
    shader: *Shader,
    fill_shader: *Shader,
    quad: *Shape,

    const Self = @This();

    pub fn init(context: core.Context, gpu: *GpuContext) !Self {
        const shader = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/overlay.wgsl", .{
            .vertex_buffers = &Shape.vertex_buffer_layouts,
            .material = .texture,
        });
        const fill_shader = try Shader.init(context.io, context.alloc, gpu, "games/the_station/shaders/overlay_fill.wgsl", .{
            .vertex_buffers = &Shape.vertex_buffer_layouts,
        });

        // Over everything in the window pass, blended
        const quad = try core.shapes.createSquare(context.alloc, gpu);
        quad.is_double_sided = true;
        quad.is_depth_test = false;
        quad.is_depth_write = false;
        quad.is_transparent = true;

        return .{ .shader = shader, .fill_shader = fill_shader, .quad = quad };
    }

    /// Draws `sprite` (in the sheet's uv, 0..1 from its top-left) of `sheet` at `place` in
    /// the window, `window_width` x `window_height` units, tinted by `color`.
    pub fn draw(
        self: *const Self,
        frame: *const Frame,
        sheet: *const Texture,
        sprite: Rect,
        place: Rect,
        window_width: f32,
        window_height: f32,
        color: Vec4,
    ) void {
        // The square's -0.5..0.5 to the place's rectangle in clip space (y up)
        const center_x = (place.x + place.width / 2.0) / window_width * 2.0 - 1.0;
        const center_y = 1.0 - (place.y + place.height / 2.0) / window_height * 2.0;
        const scale = vec3(place.width / window_width * 2.0, place.height / window_height * 2.0, 1.0);
        const model = Mat4.fromTranslation(vec3(center_x, center_y, 0.0)).mulMat4(&Mat4.fromScale(scale));

        var uniforms = DrawUniforms.init(model, color);
        uniforms.params = vec4(sprite.x, sprite.y, sprite.width, sprite.height);
        sheet.bind(frame);
        self.quad.draw(frame, self.shader, uniforms);
    }

    /// The whole window in `color`, blended by its alpha.
    pub fn fill(self: *const Self, frame: *const Frame, color: Vec4) void {
        // The square's -0.5..0.5 to clip space's -1..1
        const model = Mat4.fromScale(vec3(2.0, 2.0, 1.0));
        self.quad.draw(frame, self.fill_shader, DrawUniforms.init(model, color));
    }

    pub fn releaseGpuObjects(self: *const Self) void {
        self.quad.releaseGpuObjects();
        self.fill_shader.releaseGpuObjects();
        self.shader.releaseGpuObjects();
    }
};
