const std = @import("std");
const core = @import("core");
const math = @import("math");

const ResourceManager = core.ResourceManager;

const vec4 = math.vec4;

const Frame = core.Frame;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const PbrMaterial = core.material.PbrMaterial;

pub const Cube = struct {
    shape: *Shape,
    shader: *Shader,
    texture: *Texture,
    material: *PbrMaterial,
    transform: core.Transform = core.Transform.identity(),

    const Self = @This();

    pub fn init(rm: *ResourceManager) !Self {
        const cube = try rm.createCube(.{
            .width = 1.0,
            .height = 1.0,
            .depth = 1.0,
            .num_tiles_x = 1.0,
            .num_tiles_y = 1.0,
            .num_tiles_z = 1.0,
            .texture_mapping = .Cubemap2x3,
        });

        const cubemap_texture = try rm.createTexture(
            "assets/Textures/cubemap_template_2x3.png",
            .{
                .flip_v = false,
                .filter = .Linear,
                .wrap = .Clamp,
            },
        );

        const texture_shader = try rm.createShader("examples/bullets/shaders/basic_texture.wgsl", .{
            .vertex_buffers = &Shape.vertex_buffer_layouts,
            .material = .pbr,
        });

        return .{
            .shape = cube,
            .shader = texture_shader,
            .texture = cubemap_texture,
            .material = try rm.createMaterial(.{ cubemap_texture, null, null, null, null }),
        };
    }

    pub fn draw(self: *Self, frame: *const Frame) void {
        self.material.bind(frame);
        self.shape.draw(frame, self.shader, core.DrawUniforms.init(self.transform.toMatrix(), vec4(1.0, 1.0, 1.0, 1.0)));
    }
};
