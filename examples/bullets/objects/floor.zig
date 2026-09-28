const std = @import("std");
const core = @import("core");
const math = @import("math");

const ResourceManager = core.ResourceManager;

const Mat4 = math.Mat4;
const vec4 = math.vec4;

const Frame = core.Frame;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Plane = core.shapes.Plane;
const PbrMaterial = core.material.PbrMaterial;

pub const Floor = struct {
    plane: Plane,
    shader: *Shader,
    material: *PbrMaterial,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !Self {
        var floor = try core.shapes.Plane.init(
            rm.context,
            rm.gpu,
            .{
                .plane_size = 100.0,
                .tile_size = 1.0,
                .diffuse_texture = "assets/Textures/Floor/Floor D.png",
                .normal_texture = "assets/Textures/Floor/Floor N.png",
                .specular_texture = "assets/Textures/Floor/Floor M.png",
            },
        );
        floor.shape.is_transparent = true;
        floor.shape.is_depth_write = false;
        floor.shape.is_visible = false;

        const texture_shader = try rm.createShader("examples/bullets/shaders/basic_texture.wgsl", .{
            .vertex_buffers = &Shape.vertex_buffer_layouts,
            .material = .pbr,
        });

        // basic_texture reads diffuse / specular / normal from the pbr material slots
        const material = try rm.createMaterial(.{ floor.texture_diffuse, floor.texture_spec, floor.texture_normal, null, null });

        return .{
            .plane = floor,
            .shader = texture_shader,
            .material = material,
        };
    }

    /// redfish's `colorAlpha` 0.8, now the draw color's alpha.
    pub fn draw(self: *Self, frame: *const Frame) void {
        self.material.bind(frame);
        self.plane.shape.draw(frame, self.shader, core.DrawUniforms.init(Mat4.Identity, vec4(1.0, 1.0, 1.0, 0.8)));
    }

    /// The plane's shape and textures (the ResourceManager doesn't track them).
    pub fn cleanUp(self: *Self) void {
        self.plane.cleanUp();
    }
};
