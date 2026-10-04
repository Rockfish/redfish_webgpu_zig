//! Where incoming shells will land (plan 019 phase G): a red ring on the floor the size
//! of the blast, from the moment a shell is fired, filling from the middle and brightening
//! as it nears. The point comes from the shell's own flight (`Projectiles.predictedEnd`),
//! the same prediction the squad reads. Drawn unlit, so it shows in any light.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const Context = core.Context;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Projectiles = core.gameplay.projectiles.Projectiles;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;

/// The ring's width, as a fraction of its radius.
const RING_WIDTH: f32 = 0.1;
const FILL_THICKNESS: f32 = 0.01;
/// Heights above the floor: over the burn marks, the ring over the fill.
const FILL_LIFT: f32 = 0.05;
const RING_LIFT: f32 = 0.07;

const RING_FAR = vec4(0.55, 0.08, 0.04, 1.0);
const RING_NEAR = vec4(1.0, 0.2, 0.08, 1.0);
const FILL_FAR = vec4(0.25, 0.04, 0.02, 1.0);
const FILL_NEAR = vec4(0.75, 0.12, 0.04, 1.0);

pub const ShellWarnings = struct {
    /// A unit ring and a unit disk (radius 1), scaled to each blast.
    ring: *Shape,
    disk: *Shape,

    const Self = @This();

    pub fn init(context: Context, gpu: *const GpuContext) !Self {
        return .{
            .ring = try core.shapes.createRing(context.alloc, gpu, 1.0 - RING_WIDTH, 1.0, 48),
            .disk = try core.shapes.createCylinder(context.alloc, gpu, 1.0, FILL_THICKNESS, 48),
        };
    }

    /// A warning for each shell in `shells`, with `shader` (unlit).
    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, shells: *const Projectiles) void {
        const radius = shells.blast_radius;
        for (0..shells.count) |i| {
            const end = shells.predictedEnd(i);
            const progress = std.math.clamp(1.0 - end.time_left / end.fuse, 0.0, 1.0);
            const ground = vec3(end.position.x, 0.0, end.position.z);

            const ring_model = place(ground.add(vec3(0.0, RING_LIFT, 0.0)), radius);
            self.ring.draw(frame, shader, DrawUniforms.init(ring_model, RING_FAR.lerp(RING_NEAR, progress)));

            const fill_radius = radius * (1.0 - RING_WIDTH) * progress;
            if (fill_radius > 0.0) {
                const fill_model = place(ground.add(vec3(0.0, FILL_LIFT, 0.0)), fill_radius);
                self.disk.draw(frame, shader, DrawUniforms.init(fill_model, FILL_FAR.lerp(FILL_NEAR, progress)));
            }
        }
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.ring.releaseGpuObjects();
        self.disk.releaseGpuObjects();
    }
};

/// A unit shape at `position`, `radius` wide on the floor.
fn place(position: Vec3, radius: f32) Mat4 {
    return Mat4.fromTranslation(position).mulMat4(&Mat4.fromScale(vec3(radius, 1.0, radius)));
}
