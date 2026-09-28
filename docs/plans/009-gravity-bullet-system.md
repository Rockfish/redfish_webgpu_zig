# Plan 009: Gravity Bullet System

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Phase 1 (gravity) carried over in `examples/bullets/projectiles/bullet_system.zig`; phase 2 planned.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: Phase 1 Complete, Phase 2 Planned
**Created**: 2026-01-11
**Updated**: 2026-02-11

## Goal
Modify the bullet system in `examples/bullets/projectiles/bullet_system.zig` so that:
1. Bullets follow parabolic trajectories (affected by gravity)
2. Bullet orientations rotate to follow the tangent of the parabola (forward direction = velocity direction)
3. Trajectory lines can be drawn ahead of time for aiming

## Completed Work (Phase 1)

- Added `fromDirectionWithRight()` to `src/math/quat.zig`
- Implemented gravity in `bullet_system.zig` using semi-implicit Euler integration
- Bullets arc and orient along their velocity using preserved right vectors
- Working but has limitations (see Phase 2)

## Physics Concept

For projectile motion with gravity:
- **Velocity changes over time**: `velocity(t) = initial_velocity + gravity * t`
- **Position at time t**: `position(t) = start_pos + initial_velocity * t + 0.5 * gravity * t²`
- **Tangent = normalized velocity**: The instantaneous direction of travel is the velocity vector

The key insight is that the velocity vector at any point IS the tangent to the parabola, so we orient the bullet to face along its velocity.

### Why Preserve the Right Vector

A bullet under gravity follows a parabola that lies entirely in a **constant vertical plane**. This plane is defined by:
- The initial velocity direction
- The gravity vector (always downward)

The normal to this plane (the bullet's "right" vector) remains constant throughout the flight. This gives us a more robust orientation approach:

1. **No singularities**: Using `World_Up` breaks down when the bullet points nearly straight up or down (velocity parallel to up). Preserving the right vector has no such issue.

2. **Physically realistic**: A real projectile pitches around its lateral axis while maintaining its roll orientation - exactly what preserving the right vector achieves.

3. **Simpler per-frame math**: Instead of reconstructing the full orientation from scratch, we compute:
   - `forward = velocity.normalized()` (changes each frame)
   - `right` is constant (stored at spawn)
   - `up = forward.cross(right)` (recomputed for orthogonality)

## Implementation Approach

### Changes to `BulletSystem` struct

**Add new fields:**
```zig
bullet_velocities: ManagedArrayList(Vec3),
bullet_right_vectors: ManagedArrayList(Vec3),  // Constant per bullet
```

**Add configurable gravity field to struct:**
```zig
gravity: f32 = 3.0,  // Default gentle gravity, configurable
```

### Changes to `createBullets()`

Initialize velocity and compute the constant right vector:
```zig
const velocity = direction.mulScalar(Bullet_Speed);
self.bullet_velocities.items()[index] = velocity;

// Compute right vector: direction × down (normal to the trajectory plane)
// This vector stays constant throughout the bullet's flight
const down = vec3(0.0, -1.0, 0.0);
const right = blk: {
    const r = direction.cross(down).toNormalized();
    // Handle edge case: firing straight up or down
    if (r.lengthSquared() < 0.001) {
        break :blk vec3(1.0, 0.0, 0.0);  // Arbitrary right for vertical shots
    }
    break :blk r;
};
self.bullet_right_vectors.items()[index] = right;
```

### Changes to `update()`

Replace the current linear movement with physics-based update:

```zig
pub fn update(self: *Self, delta_time: f32) void {
    const gravity_vec = vec3(0.0, -self.gravity, 0.0);
    const gravity_delta = gravity_vec.mulScalar(delta_time);

    for (0..self.bullet_positions.items().len) |i| {
        // Get current velocity
        var velocity = self.bullet_velocities.items()[i];

        // Apply gravity to velocity
        velocity = velocity.add(gravity_delta);
        self.bullet_velocities.items()[i] = velocity;

        // Update position
        const position = self.bullet_positions.items()[i];
        self.bullet_positions.items()[i] = position.add(velocity.mulScalar(delta_time));

        // Update rotation to follow velocity tangent
        const forward = velocity.toNormalized();
        if (forward.lengthSquared() > 0.001) {
            const right = self.bullet_right_vectors.items()[i];
            self.bullet_rotations.items()[i] = Quat.fromDirectionWithRight(forward, right);
        }
    }
}
```

### New Function in `src/math/quat.zig`

Add a new method that builds orientation from forward direction and a preserved right vector:

```zig
/// Creates a quaternion that orients an object so its local +Z axis points
/// along the given direction, using a specified right vector to constrain the roll.
/// Produces a right-handed coordinate system.
///
/// This is useful for projectiles following parabolic trajectories where the
/// trajectory plane (and thus the right vector) remains constant.
///
/// The basis is computed as:
/// - up = forward × right
///
/// Parameters:
/// - forward_dir: The direction the object should face (e.g., velocity direction)
/// - right_dir: The right vector to preserve (should be perpendicular to trajectory plane)
pub fn fromDirectionWithRight(forward_dir: Vec3, right_dir: Vec3) Quat {
    const forward_vec = blk: {
        const normalized = forward_dir.toNormalized();
        if (normalized.lengthSquared() == 0.0) {
            return Quat.Identity;
        }
        break :blk normalized;
    };

    const right_vec = right_dir.toNormalized();

    // Compute up to ensure orthogonality
    const up_vec = forward_vec.cross(right_vec).toNormalized();

    // Build rotation matrix: columns are [right, up, forward]
    // This maps local +X to right, local +Y to up, local +Z to forward
    const rotation_matrix = Mat4{ .data = .{
        .{ right_vec.x, right_vec.y, right_vec.z, 0.0 },
        .{ up_vec.x, up_vec.y, up_vec.z, 0.0 },
        .{ forward_vec.x, forward_vec.y, forward_vec.z, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    } };

    return rotation_matrix.toQuat();
}
```

## Files to Modify

1. **`src/math/quat.zig`** ✅ Done
   - Added `fromDirectionWithRight()` method to `Quat` struct
   - Fixed `fromDirectionWithUp()` to not negate the direction

2. **`examples/bullets/projectiles/bullet_system.zig`**
   - Add `gravity` field to struct
   - Add `bullet_velocities` field
   - Add `bullet_right_vectors` field
   - Initialize both in `init()`
   - Modify `createBullets()` to set initial velocity and compute right vector
   - Rewrite `update()` to apply gravity and use preserved right vector for orientation

## Verification

1. Run `zig build bullets-run`
2. Observe bullets following parabolic arcs
3. Verify bullet orientations rotate smoothly to follow the arc (nose pointing in direction of travel)
4. Test steep trajectories (nearly vertical) - should work without gimbal lock issues
5. Test different gravity values by modifying `bullet_system.gravity` (e.g., 1.0 for slow arcs, 9.81 for realistic)

## Phase 2: Switch to Analytical Trajectories

### Problem with Current Euler Integration

The current `update()` accumulates velocity and position each frame:
```zig
velocity += gravity * dt
position += velocity * dt
```

This is physically correct (semi-implicit Euler) and the bullets arc properly. However:

1. **No trajectory prediction**: To draw a prediction line showing where bullets will go, you'd have to simulate forward N steps. The predicted path drifts from the actual path if timesteps vary.
2. **No time-based queries**: Can't answer "where is this bullet at t=3.0?" without replaying all frames.
3. **AI aiming is harder**: The turret AI needs to solve for launch angle to hit a target. With integration, this requires iterative simulation. With analytical equations, it's a closed-form quadratic.

### Analytical Approach (Kinematic Equations)

Store initial conditions per bullet and compute position directly from elapsed time:

```
position(t) = start_pos + initial_velocity * t + 0.5 * gravity * t²
velocity(t) = initial_velocity + gravity * t
```

No integration loop. Each frame, compute `t = current_time - spawn_time` and evaluate the formula. The trajectory is exact and reproducible regardless of timestep.

### Why Analytical Works Here

The kinematic equations are a closed-form solution to constant-acceleration motion. They produce the exact same parabola that Euler integration approximates. The key requirement is that the only force is gravity (constant acceleration). This holds for the turret-vs-player scenario.

If variable forces are needed later (drag, wind, homing), those specific projectile types would use Euler integration instead. The two approaches can coexist — gravity-only projectiles use analytical, complex projectiles use integration.

### Data Structure Changes

**Remove** (no longer needed):
```zig
bullet_velocities: ManagedArrayList(Vec3),    // velocity is computed from formula
bullet_directions: ManagedArrayList(Vec3),    // redundant with initial_velocity
```

**Add**:
```zig
bullet_spawn_times: ManagedArrayList(f32),        // when each bullet was created
bullet_start_positions: ManagedArrayList(Vec3),    // position at spawn
bullet_initial_velocities: ManagedArrayList(Vec3), // velocity at spawn
```

**Keep**:
```zig
bullet_positions: ManagedArrayList(Vec3),      // computed each frame for rendering
bullet_rotations: ManagedArrayList(Quat),      // computed each frame for rendering
bullet_right_vectors: ManagedArrayList(Vec3),  // constant per bullet (trajectory plane normal)
```

### New `update()` Implementation

```zig
pub fn update(self: *Self, current_time: f32) void {
    const gravity_vec = vec3(0.0, -self.gravity, 0.0);

    for (0..self.bullet_start_positions.items().len) |i| {
        const t = current_time - self.bullet_spawn_times.items()[i];
        const start_pos = self.bullet_start_positions.items()[i];
        const initial_vel = self.bullet_initial_velocities.items()[i];

        // p(t) = p0 + v0*t + 0.5*g*t²
        self.bullet_positions.items()[i] = start_pos
            .add(initial_vel.mulScalar(t))
            .add(gravity_vec.mulScalar(0.5 * t * t));

        // v(t) = v0 + g*t  (for orientation only)
        const vel = initial_vel.add(gravity_vec.mulScalar(t));
        const forward = vel.toNormalized();
        if (forward.lengthSquared() > 0.001) {
            const right = self.bullet_right_vectors.items()[i];
            self.bullet_rotations.items()[i] = Quat.fromDirectionWithRight(forward, right);
        }
    }
}
```

**Note**: `update()` now takes `current_time` (total elapsed time) instead of `delta_time`. The caller passes `input.total_time`.

### New `createBullets()` Changes

```zig
// Per bullet, store initial conditions instead of mutable velocity:
self.bullet_spawn_times.items()[index] = current_time;
self.bullet_start_positions.items()[index] = aim_transform.translation;
self.bullet_initial_velocities.items()[index] = direction.mulScalar(Bullet_Speed);
```

### Trajectory Prediction

Drawing a trajectory line becomes a simple loop sampling the same formula:

```zig
pub fn sampleTrajectory(
    self: *Self,
    bullet_index: usize,
    points: []Vec3,
    time_step: f32,
) void {
    const start_pos = self.bullet_start_positions.items()[bullet_index];
    const initial_vel = self.bullet_initial_velocities.items()[bullet_index];
    const gravity_vec = vec3(0.0, -self.gravity, 0.0);

    for (points, 0..) |*point, step| {
        const t = @as(f32, @floatFromInt(step)) * time_step;
        point.* = start_pos
            .add(initial_vel.mulScalar(t))
            .add(gravity_vec.mulScalar(0.5 * t * t));
    }
}
```

The predicted line and actual bullet path are identical because they use the same equation. No drift, no timestep sensitivity.

### AI Aiming (Future)

With analytical trajectories, the turret can solve for the launch angle to hit a known target position. For a target at horizontal distance `d` and height difference `h`, the launch angle `theta` satisfies:

```
h = d * tan(theta) - (g * d²) / (2 * v² * cos²(theta))
```

This is a quadratic in `tan(theta)` with a closed-form solution. Two solutions exist (high arc and low arc) when the target is in range, zero when it's out of range. The turret chooses the low arc for fast shots or the high arc for lobbed bombs.

### Files to Modify

1. **`examples/bullets/projectiles/bullet_system.zig`**
   - Replace `bullet_velocities` and `bullet_directions` with `bullet_spawn_times`, `bullet_start_positions`, `bullet_initial_velocities`
   - Rewrite `update()` to use kinematic equations with `current_time`
   - Rewrite `createBullets()` to store initial conditions
   - Add `sampleTrajectory()` for prediction lines
   - Update `resetBullets()` to reset initial conditions

2. **`examples/bullets/scene/scene.zig`**
   - Pass `input.total_time` to `bullet_system.update()` instead of `input.delta_time`
   - Pass `input.total_time` to `createBullets()` for spawn timestamps

### Verification

1. Run `zig build bullets-run`
2. Bullets should arc identically to the Euler version
3. Trajectory prediction lines (when drawn) match actual bullet paths exactly
4. Resetting bullets works correctly with new initial conditions
5. Varying frame rate does not affect bullet trajectories

## Approach Comparison Summary

| | Euler Integration (Phase 1) | Analytical (Phase 2) |
|---|---|---|
| **Accuracy** | Approximation, small error accumulates | Exact closed-form solution |
| **Trajectory preview** | Requires simulating forward N steps | Sample the formula at any t |
| **AI aiming** | Iterative search for launch angle | Closed-form quadratic solution |
| **Variable forces** | Easy to add drag, wind, homing | Only works for constant acceleration |
| **Per-bullet data** | Mutable velocity (changes each frame) | Immutable initial conditions |
| **Frame rate independence** | Sensitive to timestep variation | Identical result regardless of dt |

**Decision**: Use analytical for gravity-only projectiles (turret bombs, artillery). If drag or homing projectiles are needed later, those specific types use Euler integration. Both can coexist in the same system.