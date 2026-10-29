//! The placeholder robot (plan 021, phase B): stacked boxes in the shape of the drawing
//! (box head with two round eyes, box body, thin arms and legs, flat feet), drawn where
//! the robot is and posed by what it is doing. Drawn without the Blender model
//! (`robot_model.zig`), or with the panel's "placeholder robot".
//!
//! The parts are rigid, each turned about a joint (hips, shoulders), as the model's are;
//! the robot's space is `robot.zig`'s.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const robot_module = @import("robot.zig");
const Robot = robot_module.Robot;
const Frame = core.Frame;
const Shader = core.Shader;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// Leg swing either way, in radians.
const LEG_SWING: f32 = 0.45;

pub fn draw(robot: *const Robot, frame: *const Frame, shader: *const Shader, shapes: room_kit.PartBuilder, hatching: room_kit.Hatching) void {
    const root = Mat4.fromTranslation(robot.position).mulMat4(&Mat4.fromRotationY(robot.yaw));
    const leg_angle = @sin(robot.walk_phase) * LEG_SWING;
    const bob = @abs(@sin(robot.walk_phase)) * 0.03;
    const arm_angle = robot.armAngle();
    const is_left_arm = switch (robot.task) {
        .act => |act| robot_module.usesLeftArm(act.use.facing),
        .idle, .walk, .turn, .mount, .ladder, .dismount => false,
    };
    const left_raise: f32 = if (is_left_arm) arm_angle else 0.0;
    const right_raise: f32 = if (is_left_arm) 0.0 else arm_angle;

    const body = room_kit.grey(0.72);
    const limbs = room_kit.grey(0.35);
    const parts = [_]room_kit.Part{
        .{ .shape = shapes.cube, .model = limb(root, vec3(0.12, 0.6, 0.0), leg_angle, vec3(0.08, 0.6, 0.08)), .color = limbs },
        .{ .shape = shapes.cube, .model = limb(root, vec3(-0.12, 0.6, 0.0), -leg_angle, vec3(0.08, 0.6, 0.08)), .color = limbs },
        .{ .shape = shapes.cube, .model = foot(root, vec3(0.12, 0.6, 0.0), leg_angle), .color = limbs },
        .{ .shape = shapes.cube, .model = foot(root, vec3(-0.12, 0.6, 0.0), -leg_angle), .color = limbs },
        .{ .shape = shapes.cube, .model = part(root, vec3(0.0, 0.84 + bob, 0.0), vec3(0.5, 0.45, 0.38)), .color = body },
        .{ .shape = shapes.cube, .model = part(root, vec3(0.0, 1.1 + bob, 0.0), vec3(0.08, 0.08, 0.08)), .color = limbs },
        .{ .shape = shapes.cube, .model = part(root, vec3(0.0, 1.28 + bob, 0.0), vec3(0.46, 0.3, 0.34)), .color = body },
        .{ .shape = shapes.cylinder, .model = eye(root, vec3(0.1, 1.29 + bob, 0.16)), .color = room_kit.grey(0.95), .emissive = 0.8 },
        .{ .shape = shapes.cylinder, .model = eye(root, vec3(-0.1, 1.29 + bob, 0.16)), .color = room_kit.grey(0.95), .emissive = 0.8 },
        // Each arm swings opposite its leg; the one nearer the camera pushes
        .{ .shape = shapes.cube, .model = limb(root, vec3(0.3, 1.0 + bob, 0.0), -leg_angle * 0.6 - left_raise, vec3(0.07, 0.45, 0.07)), .color = limbs },
        .{ .shape = shapes.cube, .model = limb(root, vec3(-0.3, 1.0 + bob, 0.0), leg_angle * 0.6 - right_raise, vec3(0.07, 0.45, 0.07)), .color = limbs },
    };
    for (parts) |robot_part| {
        room_kit.drawPart(frame, shader, robot_part, hatching);
    }
}

/// A box centered at `center` in the robot's space.
fn part(root: Mat4, center: Vec3, size: Vec3) Mat4 {
    return root.mulMat4(&room_kit.box(center, size));
}

/// A box hanging from `joint`, turned about x by `angle` (positive swings it backward,
/// negative forward and up).
fn limb(root: Mat4, joint: Vec3, angle: f32, size: Vec3) Mat4 {
    const hang = room_kit.box(vec3(0.0, -size.y / 2.0, 0.0), size);
    return root.mulMat4(&Mat4.fromTranslation(joint)).mulMat4(&Mat4.fromRotationX(angle)).mulMat4(&hang);
}

/// A flat foot at the bottom of the leg hanging from `hip`, a little forward.
fn foot(root: Mat4, hip: Vec3, angle: f32) Mat4 {
    const sole = room_kit.box(vec3(0.0, -0.57, 0.04), vec3(0.14, 0.06, 0.24));
    return root.mulMat4(&Mat4.fromTranslation(hip)).mulMat4(&Mat4.fromRotationX(angle)).mulMat4(&sole);
}

/// A round eye on the head's front, looking along +z.
fn eye(root: Mat4, base: Vec3) Mat4 {
    return root.mulMat4(&room_kit.cylinderModel(base, .z, 0.12, 0.04));
}
