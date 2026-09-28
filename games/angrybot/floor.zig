const std = @import("std");
const math = @import("math");
const core = @import("core");

const Mat4 = math.Mat4;
const Vec4 = math.Vec4;

const Context = core.Context;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const PbrMaterial = core.material.PbrMaterial;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const TextureConfig = core.texture.TextureConfig;
const TextureFilter = core.texture.TextureFilter;
const TextureWrap = core.texture.TextureWrap;

const FLOOR_SIZE: f32 = 100.0;
const TILE_SIZE: f32 = 1.0;
const NUM_TILE_WRAPS: f32 = FLOOR_SIZE / TILE_SIZE;

const FLOOR_POSITIONS = [_][3]f32{
    .{ -FLOOR_SIZE / 2.0, 0.0, -FLOOR_SIZE / 2.0 },
    .{ -FLOOR_SIZE / 2.0, 0.0, FLOOR_SIZE / 2.0 },
    .{ FLOOR_SIZE / 2.0, 0.0, FLOOR_SIZE / 2.0 },
    .{ -FLOOR_SIZE / 2.0, 0.0, -FLOOR_SIZE / 2.0 },
    .{ FLOOR_SIZE / 2.0, 0.0, FLOOR_SIZE / 2.0 },
    .{ FLOOR_SIZE / 2.0, 0.0, -FLOOR_SIZE / 2.0 },
};

const FLOOR_TEXCOORDS = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ NUM_TILE_WRAPS, 0.0 },
    .{ NUM_TILE_WRAPS, NUM_TILE_WRAPS },
    .{ 0.0, 0.0 },
    .{ NUM_TILE_WRAPS, NUM_TILE_WRAPS },
    .{ 0.0, NUM_TILE_WRAPS },
};

const FLOOR_INDICES = [_]u32{ 0, 1, 2, 3, 4, 5 };

pub const Floor = struct {
    shape: *Shape,
    texture_floor_diffuse: *Texture,
    texture_floor_normal: *Texture,
    texture_floor_spec: *Texture,
    /// floor_shader's pbr-layout material: diffuse, spec, and normal maps.
    material: PbrMaterial,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext) !Self {
        // Unconverted, as every angrybot texture: shaded in gamma space (see run_app)
        const texture_config = TextureConfig{
            .flip_v = false,
            .is_srgb = false,
            .filter = TextureFilter.Linear,
            .wrap = TextureWrap.Repeat,
        };

        const texture_floor_diffuse = try Texture.initFromFile(
            context,
            gpu,
            "assets/textures/Floor/Floor D.png",
            texture_config,
        );
        const texture_floor_normal = try Texture.initFromFile(
            context,
            gpu,
            "assets/textures/Floor/Floor N.png",
            texture_config,
        );
        const texture_floor_spec = try Texture.initFromFile(
            context,
            gpu,
            "assets/textures/Floor/Floor M.png",
            texture_config,
        );

        return .{
            .shape = try core.shapes.initGpuBuffers(context.alloc, gpu, .custom, &FLOOR_POSITIONS, &FLOOR_TEXCOORDS, &.{}, &.{}, &FLOOR_INDICES),
            .texture_floor_diffuse = texture_floor_diffuse,
            .texture_floor_normal = texture_floor_normal,
            .texture_floor_spec = texture_floor_spec,
            // Slots: base color, metallic-roughness, normal, occlusion, emissive. redfish
            // bound the spec map as "texture_spec", a name the shader didn't have.
            .material = try PbrMaterial.initWithTextures(gpu, .{ texture_floor_diffuse, texture_floor_spec, texture_floor_normal, null, null }),
        };
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader) void {
        self.material.bind(frame);
        self.shape.draw(frame, shader, DrawUniforms.init(Mat4.Identity, Vec4.init(1.0, 1.0, 1.0, 1.0)));
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.material.releaseGpuObjects();
        self.shape.releaseGpuObjects();
        self.texture_floor_diffuse.releaseGpuObjects();
        self.texture_floor_normal.releaseGpuObjects();
        self.texture_floor_spec.releaseGpuObjects();
    }
};
