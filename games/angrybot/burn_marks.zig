const std = @import("std");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");
const world = @import("state.zig");

const ManagedArrayList = containers.ManagedArrayList;

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const Mat4 = math.Mat4;

const Context = core.Context;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const TextureConfig = core.texture.TextureConfig;

pub const BurnMark = struct {
    position: Vec3,
    time_left: f32,
};

pub const BurnMarks = struct {
    unit_square: *Shape,
    mark_texture: *Texture,
    marks: ManagedArrayList(?BurnMark),

    const Self = @This();

    /// Draws with `unit_square`'s render state (transparent, no depth write, both sides).
    pub fn init(context: Context, gpu: *GpuContext, unit_square: *Shape) !*Self {
        const texture_config = TextureConfig{
            .filter = .Linear,
            .wrap = .Repeat,
            .flip_v = false,
            .is_srgb = false, // gamma-space shading, see run_app
        };

        const mark_texture = try Texture.initFromFile(
            context,
            gpu,
            "assets/angrybots_assets/Textures/Bullet/burn_mark.png",
            texture_config,
        );

        const burn_marks = try context.alloc.create(BurnMarks);
        burn_marks.* = .{
            .unit_square = unit_square,
            .mark_texture = mark_texture,
            .marks = ManagedArrayList(?BurnMark).init(context.alloc),
        };
        return burn_marks;
    }

    pub fn addMark(self: *Self, position: Vec3) !void {
        const burn_mark = BurnMark{
            .position = position,
            .time_left = world.BURN_MARK_TIME,
        };
        try self.marks.append(burn_mark);
    }

    pub fn drawMarks(self: *Self, frame: *const Frame, shader: *const Shader, delta_time: f32) void {
        if (self.marks.list.items.len == 0) {
            return;
        }

        self.mark_texture.bind(frame);

        for (self.marks.list.items) |*mark| {
            const scale: f32 = 0.5 * mark.*.?.time_left;
            mark.*.?.time_left -= delta_time;

            var model = Mat4.fromTranslation(mark.*.?.position);

            model = model.mulMat4(&Mat4.fromRotationX(math.degreesToRadians(-90.0)));
            model = model.mulMat4(&Mat4.fromScale(vec3(scale, scale, scale)));

            self.unit_square.draw(frame, shader, DrawUniforms.init(model, Vec4.init(1.0, 1.0, 1.0, 1.0)));
        }

        const tester = Tester{};

        core.utils.retain(
            BurnMark,
            Tester,
            &self.marks,
            tester,
        );
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.mark_texture.releaseGpuObjects();
    }

    const Tester = struct {
        pub fn predicate(self: *const Tester, m: BurnMark) bool {
            _ = self;
            return m.time_left > 0.0;
        }
    };
};
