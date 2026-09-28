const std = @import("std");
const vec = @import("vec.zig");
const mat4_ = @import("mat4.zig");
const utils = @import("utils.zig");

const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;
const Mat4 = mat4_.Mat4;
pub const Versor = [4]f32;

pub const asCF32 = utils.asCF32;

pub fn quat(x: f32, y: f32, z: f32, w: f32) Quat {
    return Quat{ .data = .{ x, y, z, w } };
}

pub const Quat = extern struct {
    data: [4]f32,

    const Self = @This();

    pub const Identity = Quat{ .data = .{ 0.0, 0.0, 0.0, 1.0 } };

    pub inline fn init(x: f32, y: f32, z: f32, w: f32) Self {
        return Quat{ .data = .{ x, y, z, w } };
    }

    pub inline fn clone(self: Self) Quat {
        return Quat{ .data = self.data };
    }

    pub inline fn fromArray(val: [4]f32) Self {
        return init(val[0], val[1], val[2], val[3]);
    }

    pub fn fromMat4(mat4: Mat4) Quat {
        return mat4.toQuat();
    }

    /// angle in radians
    pub inline fn fromAxisAngle(axis: Vec3, radians: f32) Quat {
        const normalized_axis = axis.toNormalized();
        const s = std.math.sin(radians * 0.5);
        const c = std.math.cos(radians * 0.5);
        const v = normalized_axis.mulScalar(s);
        return init(v.x, v.y, v.z, c);
    }

    /// Creates a quaternion that orients an object so its local -Z axis points
    /// along the given direction. Uses World_Up as the default up vector.
    ///
    /// Fallback behavior:
    /// - If direction is zero length, returns identity quaternion
    /// - If direction is parallel to up, uses an arbitrary perpendicular vector
    pub fn fromDirection(direction: Vec3) Quat {
        return fromDirectionWithUp(direction, Vec3.World_Up);
    }

    /// Creates a quaternion that orients an object so its local -Z axis points
    /// along the given direction.
    ///
    /// Fallback behavior:
    /// - If direction is zero length, returns identity quaternion
    /// - If direction is parallel to up, uses an arbitrary perpendicular vector
    pub fn fromDirectionWithUp(direction: Vec3, up_dir: Vec3) Quat {
        const forward_vec = blk: {
            const normalized = direction.toNormalized();
            if (normalized.lengthSquared() == 0.0) {
                return Quat.Identity;
            }
            break :blk normalized;
        };

        // Back is opposite of forward (-Z forward convention)
        const back_dir = forward_vec.mulScalar(-1.0);

        const up_norm = blk: {
            const normalized = up_dir.toNormalized();
            if (normalized.lengthSquared() == 0.0) {
                break :blk Vec3.init(0.0, 1.0, 0.0);
            }
            break :blk normalized;
        };

        // Compute right vector (perpendicular to both up and back)
        const right_norm = blk: {
            const right_vec = up_norm.cross(back_dir);
            const normalized = right_vec.toNormalized();
            if (normalized.lengthSquared() == 0.0) {
                // If up and back are parallel, find any orthonormal vector
                const arbitrary = if (@abs(up_norm.y) < 0.9)
                    Vec3.init(0.0, 1.0, 0.0)
                else
                    Vec3.init(1.0, 0.0, 0.0);
                const ortho = up_norm.cross(arbitrary);
                break :blk ortho.toNormalized();
            }
            break :blk normalized;
        };

        // Recompute up to ensure orthogonality
        const final_up = back_dir.cross(right_norm);

        // Create rotation matrix from basis vectors (column-major format)
        // Columns are [right, up, back] matching -Z forward convention
        const rotation_matrix = Mat4{ .data = .{
            .{ right_norm.x, right_norm.y, right_norm.z, 0.0 },
            .{ final_up.x, final_up.y, final_up.z, 0.0 },
            .{ back_dir.x, back_dir.y, back_dir.z, 0.0 },
            .{ 0.0, 0.0, 0.0, 1.0 },
        } };

        return rotation_matrix.toQuat();
    }

    /// Creates a quaternion that orients an object so its local -Z axis points
    /// along the given direction, using a specified right vector to constrain the roll.
    ///
    /// This is useful for projectiles following parabolic trajectories where the
    /// trajectory plane (and thus the right vector) remains constant.
    ///
    /// Fallback behavior:
    /// - If direction is zero length, returns identity quaternion
    pub fn fromDirectionWithRight(forward_dir: Vec3, right_dir: Vec3) Quat {
        const forward_vec = blk: {
            const normalized = forward_dir.toNormalized();
            if (normalized.lengthSquared() == 0.0) {
                return Quat.Identity;
            }
            break :blk normalized;
        };

        // Back is opposite of forward (-Z forward convention)
        const back_dir = forward_vec.mulScalar(-1.0);

        const right_vec = right_dir.toNormalized();

        // Compute up to ensure orthogonality
        const up_vec = back_dir.cross(right_vec).toNormalized();

        // Create rotation matrix from basis vectors (column-major format)
        // Columns are [right, up, back] matching -Z forward convention
        const rotation_matrix = Mat4{ .data = .{
            .{ right_vec.x, right_vec.y, right_vec.z, 0.0 },
            .{ up_vec.x, up_vec.y, up_vec.z, 0.0 },
            .{ back_dir.x, back_dir.y, back_dir.z, 0.0 },
            .{ 0.0, 0.0, 0.0, 1.0 },
        } };

        return rotation_matrix.toQuat();
    }

    pub fn asArray(self: Quat) [4]f32 {
        return self.data;
    }

    // for working with cglm
    pub inline fn asCPtrF32(q: *const Quat) [*c]f32 {
        return @as([*c]f32, @ptrCast(@constCast(q)));
    }

    pub fn normalize(self: *Self) void {
        const length_squared = self.data[0] * self.data[0] + self.data[1] * self.data[1] + self.data[2] * self.data[2] + self.data[3] * self.data[3];

        if (length_squared == 0.0) {
            // Set to identity quaternion if zero length
            self.data = .{ 0.0, 0.0, 0.0, 1.0 };
            return;
        }

        const inv_length = 1.0 / std.math.sqrt(length_squared);
        self.data[0] *= inv_length;
        self.data[1] *= inv_length;
        self.data[2] *= inv_length;
        self.data[3] *= inv_length;
    }

    pub fn toNormalized(q: Quat) Quat {
        const length_squared = q.data[0] * q.data[0] + q.data[1] * q.data[1] + q.data[2] * q.data[2] + q.data[3] * q.data[3];

        if (length_squared == 0.0) {
            // Return identity quaternion if zero length
            return Quat{ .data = .{ 0.0, 0.0, 0.0, 1.0 } };
        }

        const inv_length = 1.0 / std.math.sqrt(length_squared);
        return Quat{ .data = .{
            q.data[0] * inv_length,
            q.data[1] * inv_length,
            q.data[2] * inv_length,
            q.data[3] * inv_length,
        } };
    }

    pub fn mulQuat(p: Quat, q: Quat) Quat {
        // Quaternion multiplication: (p * q)
        // Formula: result = [pw*qx + px*qw + py*qz - pz*qy,
        //                   pw*qy - px*qz + py*qw + pz*qx,
        //                   pw*qz + px*qy - py*qx + pz*qw,
        //                   pw*qw - px*qx - py*qy - pz*qz]
        // Where p = [px, py, pz, pw] and q = [qx, qy, qz, qw]
        const px = p.data[0];
        const py = p.data[1];
        const pz = p.data[2];
        const pw = p.data[3];
        const qx = q.data[0];
        const qy = q.data[1];
        const qz = q.data[2];
        const qw = q.data[3];

        return Quat{
            .data = .{
                pw * qx + px * qw + py * qz - pz * qy, // x
                pw * qy - px * qz + py * qw + pz * qx, // y
                pw * qz + px * qy - py * qx + pz * qw, // z
                pw * qw - px * qx - py * qy - pz * qz, // w
            },
        };
    }

    pub fn mulByQuat(self: *Self, other: Quat) void {
        const temp = self.*.mulQuat(other);
        self.data = temp.data;
    }

    pub fn rotateVec(self: Quat, v: Vec3) Vec3 {
        // Rotate vector v by quaternion self using the formula:
        // v' = q * (0, v) * q^-1
        // Optimized version: v' = v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v)
        const qx = self.data[0];
        const qy = self.data[1];
        const qz = self.data[2];
        const qw = self.data[3];
        const vx = v.x;
        const vy = v.y;
        const vz = v.z;

        // First cross product: cross(q.xyz, v) + q.w * v
        const cx1 = qy * vz - qz * vy + qw * vx;
        const cy1 = qz * vx - qx * vz + qw * vy;
        const cz1 = qx * vy - qy * vx + qw * vz;

        // Second cross product: cross(q.xyz, cross(q.xyz, v) + q.w * v)
        const cx2 = qy * cz1 - qz * cy1;
        const cy2 = qz * cx1 - qx * cz1;
        const cz2 = qx * cy1 - qy * cx1;

        // Final result: v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v)
        return Vec3{
            .x = vx + 2.0 * cx2,
            .y = vy + 2.0 * cy2,
            .z = vz + 2.0 * cz2,
        };
    }

    pub fn slerp(self: Quat, rot: Quat, t: f32) Quat {
        const clamped_t = @max(0.0, @min(1.0, t));

        // Compute dot product
        var dot = self.data[0] * rot.data[0] + self.data[1] * rot.data[1] + self.data[2] * rot.data[2] + self.data[3] * rot.data[3];

        // Take the shorter path by flipping one quaternion if dot product is negative
        var q2 = rot;
        if (dot < 0.0) {
            q2.data[0] = -q2.data[0];
            q2.data[1] = -q2.data[1];
            q2.data[2] = -q2.data[2];
            q2.data[3] = -q2.data[3];
            dot = -dot;
        }

        // If quaternions are very close, use linear interpolation to avoid division by zero
        if (dot > 0.9995) {
            const lerp_result = Quat{ .data = .{
                self.data[0] + clamped_t * (q2.data[0] - self.data[0]),
                self.data[1] + clamped_t * (q2.data[1] - self.data[1]),
                self.data[2] + clamped_t * (q2.data[2] - self.data[2]),
                self.data[3] + clamped_t * (q2.data[3] - self.data[3]),
            } };
            return lerp_result.toNormalized();
        }

        // Spherical interpolation
        const theta_0 = std.math.acos(@max(-1.0, @min(1.0, dot)));
        const sin_theta_0 = std.math.sin(theta_0);
        const theta = theta_0 * clamped_t;
        const sin_theta = std.math.sin(theta);

        const s0 = std.math.cos(theta) - dot * sin_theta / sin_theta_0;
        const s1 = sin_theta / sin_theta_0;

        return Quat{ .data = .{
            s0 * self.data[0] + s1 * q2.data[0],
            s0 * self.data[1] + s1 * q2.data[1],
            s0 * self.data[2] + s1 * q2.data[2],
            s0 * self.data[3] + s1 * q2.data[3],
        } };
    }

    /// Converts a quaternion rotation to three orthonormal basis vectors.
    ///
    /// Returns a tuple of three Vec3 representing the coordinate axes:
    /// - right: right vector (local X-axis, quat i axis)
    /// - up: up vector (local Y-axis, quat j axis)
    /// - forward: forward vector (local Z-axis, quat k axis)
    ///
    /// The quaternion is automatically normalized before conversion.
    /// The returned vectors form an orthonormal basis suitable for constructing
    /// transformation matrices via Mat4.fromAxes().
    pub fn toAxes(rotation: Quat) struct { right: Vec3, up: Vec3, forward: Vec3 } {
        // glam_assert!(rotation.is_normalized());
        const normalized_rotation = rotation.toNormalized();
        const x = normalized_rotation.data[0];
        const y = normalized_rotation.data[1];
        const z = normalized_rotation.data[2];
        const w = normalized_rotation.data[3];
        const x2 = x + x;
        const y2 = y + y;
        const z2 = z + z;
        const xx = x * x2;
        const xy = x * y2;
        const xz = x * z2;
        const yy = y * y2;
        const yz = y * z2;
        const zz = z * z2;
        const wx = w * x2;
        const wy = w * y2;
        const wz = w * z2;

        const right_vec: Vec3 = Vec3.init(1.0 - (yy + zz), xy + wz, xz - wy);
        const up_vec: Vec3 = Vec3.init(xy - wz, 1.0 - (xx + zz), yz + wx);
        const forward_vec: Vec3 = Vec3.init(xz + wy, yz - wx, 1.0 - (xx + yy));
        return .{ .right = right_vec, .up = up_vec, .forward = forward_vec };
    }

    /// Get the right direction vector (rotated +X axis, quat i axis).
    /// This represents the local right direction after applying this rotation.
    pub fn right(self: Quat) Vec3 {
        return self.rotateVec(Vec3.init(1.0, 0.0, 0.0));
    }

    /// Get the up direction vector (rotated +Y axis, quat j axis).
    /// This represents the local up direction after applying this rotation.
    pub fn up(self: Quat) Vec3 {
        return self.rotateVec(Vec3.init(0.0, 1.0, 0.0));
    }

    /// Get the forward direction vector (rotated -Z axis, OpenGL convention).
    /// This represents the local forward direction after applying this rotation.
    /// In OpenGL convention, forward is the negative Z-axis.
    pub fn forward(self: Quat) Vec3 {
        return self.rotateVec(Vec3.init(0.0, 0.0, -1.0));
    }

    /// Get the back direction vector (rotated +Z axis, quat k axis).
    /// This represents the local back direction after applying this rotation.
    pub fn back(self: Quat) Vec3 {
        return self.rotateVec(Vec3.init(0.0, 0.0, 1.0));
    }

    /// Rotation that looks from `position` at `target` down its −Z axis, with `up_dir` as
    /// up (the same convention as `Transform.lookAt`). Identity when the two points coincide.
    /// The basis is right = up × back, up = back × right, a proper rotation; redfish built
    /// right = forward × up, a mirrored basis that doesn't convert to a quaternion.
    pub fn lookAtOrientation(position: Vec3, target: Vec3, up_dir: Vec3) Quat {
        const direction = target.sub(position);
        if (direction.lengthSquared() == 0.0) {
            return Quat.Identity;
        }

        const back_dir = direction.mulScalar(-1.0).toNormalized();
        const right_vec = up_dir.crossNormalized(back_dir);
        const new_up = back_dir.cross(right_vec);

        const rotation_matrix = Mat4{ .data = .{
            .{ right_vec.x, right_vec.y, right_vec.z, 0.0 },
            .{ new_up.x, new_up.y, new_up.z, 0.0 },
            .{ back_dir.x, back_dir.y, back_dir.z, 0.0 },
            .{ 0.0, 0.0, 0.0, 1.0 },
        } };
        return rotation_matrix.toQuat();
    }

    /// Create quaternion from Euler angles (yaw, pitch, roll) in radians
    /// Input Vec3 where:
    /// - x = yaw (rotation around Y axis)
    /// - y = pitch (rotation around X axis)
    /// - z = roll (rotation around Z axis)
    /// Uses ZYX rotation order (yaw-pitch-roll)
    pub fn fromEulerAngles(euler: Vec3) Self {
        const yaw = euler.x;
        const pitch = euler.y;
        const roll = euler.z;

        const cy = @cos(yaw * 0.5);
        const sy = @sin(yaw * 0.5);
        const cp = @cos(pitch * 0.5);
        const sp = @sin(pitch * 0.5);
        const cr = @cos(roll * 0.5);
        const sr = @sin(roll * 0.5);

        const w = cr * cp * cy + sr * sp * sy;
        const x = sr * cp * cy - cr * sp * sy;
        const y = cr * sp * cy + sr * cp * sy;
        const z = cr * cp * sy - sr * sp * cy;

        return Self{ .data = .{ x, y, z, w } };
    }
};

test "lookAtOrientation: forward (-Z) points at the target, up stays up" {
    const position = Vec3.init(1.0, 2.0, 3.0);
    const up = Vec3.init(0.0, 1.0, 0.0);
    const targets = [_]Vec3{
        Vec3.init(6.0, 2.0, 3.0), // +X
        Vec3.init(1.0, 2.0, -7.0), // -Z
        Vec3.init(-4.0, 5.0, 8.0), // off-axis
    };
    for (targets) |target| {
        const rotation = Quat.lookAtOrientation(position, target, up);
        const expected = target.sub(position).toNormalized();
        const forward = rotation.forward();
        try std.testing.expectApproxEqAbs(expected.x, forward.x, 1e-5);
        try std.testing.expectApproxEqAbs(expected.y, forward.y, 1e-5);
        try std.testing.expectApproxEqAbs(expected.z, forward.z, 1e-5);
        try std.testing.expect(rotation.up().y > 0.0);
    }
}
