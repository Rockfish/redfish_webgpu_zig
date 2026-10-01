//! Shell explosions: a fireball that swells to the blast radius and burns out, and, for
//! bursts at or near the ground, a burn mark on the floor that fades over several seconds.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const MAX_FLASHES = 32;
/// Burn marks kept; the oldest is replaced by the next.
const MAX_MARKS = 48;
/// Seconds a fireball lasts.
const FLASH_TIME: f32 = 0.6;
/// Seconds a fireball takes to swell to full size.
const FLASH_GROW_TIME: f32 = 0.08;
/// Seconds a burn mark takes to fade into the floor.
const MARK_TIME: f32 = 10.0;
/// Bursts lower than this fraction of the blast radius leave a burn mark.
const MARK_HEIGHT_FRACTION: f32 = 0.5;
const MARK_THICKNESS: f32 = 0.02;

const FLASH_HOT = vec4(1.0, 0.95, 0.6, 1.0);
const FLASH_BURNING = vec4(1.0, 0.4, 0.08, 1.0);
const FLASH_SMOKE = vec4(0.25, 0.06, 0.03, 1.0);
const MARK_COLOR = vec4(0.06, 0.05, 0.05, 1.0);

const Flash = struct {
    position: Vec3,
    radius: f32,
    age: f32,
};

const Mark = struct {
    position: Vec3,
    radius: f32,
    age: f32,
};

/// The meshes explosions draw with: a unit sphere and a unit disk, scaled per draw.
pub const ExplosionShapes = struct {
    sphere: *Shape,
    disk: *Shape,

    pub fn init(context: core.Context, gpu: *const GpuContext) !ExplosionShapes {
        return .{
            .sphere = try core.shapes.createSphere(context.alloc, gpu, 1.0, 20, 20),
            .disk = try core.shapes.createCylinder(context.alloc, gpu, 1.0, MARK_THICKNESS, 24),
        };
    }

    pub fn releaseGpuObjects(self: *ExplosionShapes) void {
        self.sphere.releaseGpuObjects();
        self.disk.releaseGpuObjects();
    }
};

pub const Explosions = struct {
    flashes: [MAX_FLASHES]Flash = undefined,
    flash_count: usize = 0,
    marks: [MAX_MARKS]Mark = undefined,
    mark_count: usize = 0,
    /// Where the next burn mark goes once all slots are used: the oldest.
    next_mark: usize = 0,
    /// The color burn marks fade into.
    floor_color: Vec4,

    const Self = @This();

    /// A blast of `radius` at `position`.
    pub fn add(self: *Self, position: Vec3, radius: f32) void {
        if (self.flash_count < MAX_FLASHES) {
            self.flashes[self.flash_count] = .{ .position = position, .radius = radius, .age = 0.0 };
            self.flash_count += 1;
        }
        if (position.y <= radius * MARK_HEIGHT_FRACTION) {
            self.addMark(vec3(position.x, 0.0, position.z), radius);
        }
    }

    pub fn update(self: *Self, dt: f32) void {
        var i: usize = 0;
        while (i < self.flash_count) {
            self.flashes[i].age += dt;
            if (self.flashes[i].age >= FLASH_TIME) {
                self.flash_count -= 1;
                self.flashes[i] = self.flashes[self.flash_count];
                continue;
            }
            i += 1;
        }
        for (self.marks[0..self.mark_count]) |*mark| {
            mark.age += dt;
        }
    }

    /// Fireballs with `flash_shader` (unlit), burn marks with `mark_shader`.
    pub fn draw(self: *const Self, frame: *const Frame, flash_shader: *const Shader, mark_shader: *const Shader, shapes: *const ExplosionShapes) void {
        for (self.marks[0..self.mark_count], 0..) |mark, slot| {
            const fade = @min(mark.age / MARK_TIME, 1.0);
            const color = MARK_COLOR.lerp(self.floor_color, fade * fade);
            // Each slot a hair higher, so overlapping marks don't fight over depth
            const lift = 0.0005 * @as(f32, @floatFromInt(slot));
            const model = place(mark.position.add(vec3(0.0, lift, 0.0)), vec3(mark.radius, 1.0, mark.radius));
            shapes.disk.draw(frame, mark_shader, DrawUniforms.init(model, color));
        }
        for (self.flashes[0..self.flash_count]) |flash| {
            const look = flashLook(flash.age);
            const model = place(flash.position, Vec3.splat(flash.radius * look.size));
            shapes.sphere.draw(frame, flash_shader, DrawUniforms.init(model, look.color));
        }
    }

    fn addMark(self: *Self, position: Vec3, radius: f32) void {
        const mark: Mark = .{ .position = position, .radius = radius * 0.8, .age = 0.0 };
        if (self.mark_count < MAX_MARKS) {
            self.marks[self.mark_count] = mark;
            self.mark_count += 1;
            return;
        }
        self.marks[self.next_mark] = mark;
        self.next_mark = (self.next_mark + 1) % MAX_MARKS;
    }
};

/// A fireball's size (a fraction of the blast radius) and color at `age`: it swells fast,
/// goes from white-hot through orange to dark red, and shrinks as it burns out.
fn flashLook(age: f32) struct { size: f32, color: Vec4 } {
    const grow = @min(age / FLASH_GROW_TIME, 1.0);
    const fade = std.math.clamp((age - FLASH_GROW_TIME) / (FLASH_TIME - FLASH_GROW_TIME), 0.0, 1.0);
    const color = if (fade < 0.5)
        FLASH_HOT.lerp(FLASH_BURNING, fade * 2.0)
    else
        FLASH_BURNING.lerp(FLASH_SMOKE, fade * 2.0 - 1.0);
    return .{ .size = grow * (1.0 - fade * fade), .color = color };
}

fn place(position: Vec3, scale: Vec3) Mat4 {
    return Mat4.fromTranslation(position).mulMat4(&Mat4.fromScale(scale));
}
