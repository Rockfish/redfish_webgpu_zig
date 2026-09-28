# Plan 007: Movement System Transform Refactor

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Completed in redfish_gl_zig. `src/core/movement.zig` carried over.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: ✅ Completed
**Priority**: High
**Estimated Effort**: Medium (1-2 days)
**Created**: 2025-12-12
**Completed**: 2025-12-13

## Overview

Refactor the Movement system to use Transform for tracking orientation instead of manually maintaining basis vectors. This change improves mathematical correctness, eliminates re-orthogonalization overhead, and provides better separation of concerns.

## Motivation

### Current Issues

1. **Manual Basis Vector Maintenance**: Movement currently stores and manually maintains `forward`, `up`, `right` basis vectors, requiring constant re-orthogonalization
2. **Floating-Point Error Accumulation**: Repeated vector normalization can accumulate precision errors
3. **Code Duplication**: Position and orientation tracking duplicated between Movement and Transform
4. **Complexity**: `updateForward()` called repeatedly to maintain orthonormality (lines 176, 180, 184, 188, 192, 196, 202, 208, 214, 220, 243, 248, 253, 260, 267, 274)

### Benefits of Transform-Based Approach

1. **Mathematical Correctness**: Quaternions inherently maintain normalization (unit quaternions = rotations)
2. **Precision**: Eliminates floating-point error from repeated re-orthogonalization
3. **Cleaner Architecture**: Transform = state, Movement = controller
4. **Consistency**: Aligns with animation system and industry standards (Unity, Unreal, Bevy)
5. **Performance**: Fewer normalization operations
6. **No Gimbal Lock**: Quaternion-based rotation avoids gimbal lock issues

## Design Decisions

### Movement Wraps Transform

**Chosen Approach**: Movement has a Transform field (composition)

```zig
pub const Movement = struct {
    transform: Transform,  // Wraps transform
    target: Vec3,          // For look-at behavior
    // ... movement-specific fields
}
```

**Rationale**:
- Cleaner API: `movement.processMovement(direction, dt)`
- Natural composition: Movement "has-a" Transform
- State encapsulation: Movement owns its transform
- Matches Bevy's component composition pattern

**Alternative Rejected**: Passing Transform as parameter
- More cumbersome API: `movement.processMovement(&transform, direction, dt)`
- Awkward state management
- Less user-friendly

### Scope Boundaries

**Transform Responsibilities** (orientation primitives):
- Store translation, rotation (Quat), scale
- Provide `forward()`, `up()`, `right()` basis vector getters
- Provide `lookTo()`, `lookAt()` for orientation
- Provide `rotate()` for applying quaternion rotations
- Convert to/from matrices

**Movement Responsibilities** (high-level control):
- Orbit/circle movements
- Radius adjustments (approach/retreat from target)
- Translation along basis directions
- Speed management (translate_speed, rotation_speed, orbit_speed)
- Target tracking
- Movement direction processing

## Implementation Plan

### Phase 1: Enhance Transform (No Breaking Changes)

**File**: `src/core/transform.zig`

**Tasks**:

1. Add basis vector getters (returning `Vec3`, not `Dir3` like Bevy):
   ```zig
   /// Get the forward direction vector (negative Z-axis in OpenGL convention)
   pub fn forward(self: *const Self) Vec3 {
       return self.rotation.rotateVec(&Vec3.init(0.0, 0.0, -1.0));
   }

   /// Get the up direction vector (positive Y-axis)
   pub fn up(self: *const Self) Vec3 {
       return self.rotation.rotateVec(&Vec3.init(0.0, 1.0, 0.0));
   }

   /// Get the right direction vector (positive X-axis)
   pub fn right(self: *const Self) Vec3 {
       return self.rotation.rotateVec(&Vec3.init(1.0, 0.0, 0.0));
   }
   ```

2. Add rotation helper methods:
   ```zig
   /// Apply a rotation to this transform
   pub fn rotate(self: *Self, rotation: Quat) void {
       self.rotation = Quat.mulQuat(&rotation, &self.rotation);
   }

   /// Rotate around an arbitrary axis by the given angle (radians)
   pub fn rotateAxis(self: *Self, axis: Vec3, angle: f32) void {
       const rot = Quat.fromAxisAngle(&axis, angle);
       self.rotate(rot);
   }
   ```

3. Add tests for new Transform methods

**Acceptance Criteria**:
- [x] Transform has `forward()`, `up()`, `right()` returning Vec3
- [x] Transform has `rotate()` and `rotateAxis()` methods
- [x] All existing Transform tests pass
- [x] New Transform methods have unit tests (7 tests added)
- [x] Code formatted with `zig fmt`

---

### Phase 2: Refactor Movement Structure

**File**: `src/core/movement.zig`

**Tasks**:

1. Update Movement struct definition:
   ```zig
   pub const Movement = struct {
       transform: Transform,  // NEW: replaces position, up, forward, right
       target: Vec3,          // KEEP: for look-at behavior
       world_up: Vec3 = world_up,
       translate_speed: f32 = 50.0,
       rotation_speed: f32 = 50.0,
       orbit_speed: f32 = 50.0,
       direction: MovementDirection = .forward,
       update_tick: u64 = 0,
   }
   ```

2. Update `init()`:
   ```zig
   pub fn init(position: Vec3, target: Vec3) Movement {
       var transform = Transform.fromTranslation(position);
       transform.lookAt(target, world_up);
       return Movement{
           .transform = transform,
           .target = target,
       };
   }
   ```

3. Update `reset()`:
   ```zig
   pub fn reset(self: *Self, position: Vec3, target: Vec3) void {
       self.transform.translation = position;
       self.transform.lookAt(target, self.world_up);
       self.target = target;
       self.update_tick +%= 1;
   }
   ```

4. Update getter methods:
   ```zig
   pub fn getPosition(self: *const Self) Vec3 {
       return self.transform.translation;
   }

   pub fn getTransform(self: *const Self) *const Transform {
       return &self.transform;
   }

   // Add new getter for mutable transform access if needed
   pub fn getTransformMut(self: *Self) *Transform {
       return &self.transform;
   }
   ```

5. Update `getTransformMatrix()`:
   ```zig
   pub fn getTransformMatrix(self: *const Self) Mat4 {
       return self.transform.toMatrix();
   }
   ```

6. **Remove** `updateForward()` method (no longer needed)

**Acceptance Criteria**:
- [x] Movement struct uses Transform field
- [x] `init()` and `reset()` updated
- [x] Getter methods updated (`getPosition()`, `getTransform()`, `getTransformMatrix()`)
- [x] `updateForward()` removed
- [x] Code compiles (tests may fail - that's Phase 3)

---

### Phase 3: Refactor Movement Operations

**File**: `src/core/movement.zig`

**Tasks**:

1. Refactor translation operations (forward, backward, left, right, up, down):
   ```zig
   .forward => {
       const fwd = self.transform.forward();
       self.transform.translation = self.transform.translation.add(&fwd.mulScalar(translation_velocity));
   },
   .backward => {
       const fwd = self.transform.forward();
       self.transform.translation = self.transform.translation.sub(&fwd.mulScalar(translation_velocity));
   },
   .left => {
       const right_vec = self.transform.right();
       self.transform.translation = self.transform.translation.sub(&right_vec.mulScalar(translation_velocity));
   },
   .right => {
       const right_vec = self.transform.right();
       self.transform.translation = self.transform.translation.add(&right_vec.mulScalar(translation_velocity));
   },
   .up => {
       const up_vec = self.transform.up();
       self.transform.translation = self.transform.translation.add(&up_vec.mulScalar(translation_velocity));
   },
   .down => {
       const up_vec = self.transform.up();
       self.transform.translation = self.transform.translation.sub(&up_vec.mulScalar(translation_velocity));
   },
   ```

2. Refactor rotation operations (rotate_right, rotate_left, rotate_up, rotate_down):
   ```zig
   .rotate_right => {
       const up_vec = self.transform.up();
       const rot = Quat.fromAxisAngle(&up_vec, -rot_angle);
       self.transform.rotate(rot);
       self.rotateTargetAroundPosition(rot);
   },
   .rotate_left => {
       const up_vec = self.transform.up();
       const rot = Quat.fromAxisAngle(&up_vec, rot_angle);
       self.transform.rotate(rot);
       self.rotateTargetAroundPosition(rot);
   },
   .rotate_up => {
       const right_vec = self.transform.right();
       const rot = Quat.fromAxisAngle(&right_vec, rot_angle);
       self.transform.rotate(rot);
       self.rotateTargetAroundPosition(rot);
   },
   .rotate_down => {
       const right_vec = self.transform.right();
       const rot = Quat.fromAxisAngle(&right_vec, -rot_angle);
       self.transform.rotate(rot);
       self.rotateTargetAroundPosition(rot);
   },
   ```

3. Refactor roll operations (roll_right, roll_left):
   ```zig
   .roll_right => {
       const fwd = self.transform.forward();
       const rot = Quat.fromAxisAngle(&fwd, rot_angle);
       self.transform.rotate(rot);
   },
   .roll_left => {
       const fwd = self.transform.forward();
       const rot = Quat.fromAxisAngle(&fwd, -rot_angle);
       self.transform.rotate(rot);
   },
   ```

4. Refactor radius operations (radius_in, radius_out):
   ```zig
   .radius_in => {
       const to_target = self.target.sub(&self.transform.translation);
       const dist = to_target.length();
       if (dist > POSITION_EPSILON) {
           const max_step = dist - POSITION_EPSILON;
           const step = @min(translation_velocity, max_step);
           if (step > 0.0) {
               const dir = to_target.mulScalar(1.0 / dist);
               self.transform.translation = self.transform.translation.add(&dir.mulScalar(step));
           }
       }
   },
   .radius_out => {
       const dir = self.target.sub(&self.transform.translation).toNormalized();
       self.transform.translation = self.transform.translation.sub(&dir.mulScalar(translation_velocity));
   },
   ```

5. Refactor orbit operations (orbit_right, orbit_left, orbit_up, orbit_down):
   ```zig
   .orbit_right => {
       const up_vec = self.transform.up();
       const rot = Quat.fromAxisAngle(&up_vec, -orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   .orbit_left => {
       const up_vec = self.transform.up();
       const rot = Quat.fromAxisAngle(&up_vec, orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   .orbit_up => {
       const right_vec = self.transform.right();
       const rot = Quat.fromAxisAngle(&right_vec, -orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   .orbit_down => {
       const right_vec = self.transform.right();
       const rot = Quat.fromAxisAngle(&right_vec, orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   ```

6. Refactor circle operations (circle_right, circle_left, circle_up, circle_down):
   ```zig
   .circle_right => {
       const rot = Quat.fromAxisAngle(&self.world_up, orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   .circle_left => {
       const rot = Quat.fromAxisAngle(&self.world_up, -orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   .circle_up => {
       var rotation_axis = self.transform.right();
       if (rotation_axis.lengthSquared() < AXIS_EPSILON) {
           rotation_axis = vec3(1.0, 0.0, 0.0);
       }
       const rot = Quat.fromAxisAngle(&rotation_axis, -orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   .circle_down => {
       var rotation_axis = self.transform.right();
       if (rotation_axis.lengthSquared() < AXIS_EPSILON) {
           rotation_axis = vec3(1.0, 0.0, 0.0);
       }
       const rot = Quat.fromAxisAngle(&rotation_axis, orbit_angle);
       self.rotatePositionAroundTarget(rot);
       self.transform.lookAt(self.target, self.world_up);
   },
   ```

7. Update `rotatePositionAroundTarget()`:
   ```zig
   fn rotatePositionAroundTarget(self: *Self, rotation: Quat) void {
       const radius_vec = self.transform.translation.sub(&self.target);
       const target_radius = radius_vec.length();
       const rotated_position = rotation.rotateVec(&radius_vec);
       self.transform.translation = self.target.add(&rotated_position.toNormalized().mulScalar(target_radius));
       self.update_tick +%= 1;
   }
   ```

8. Update `rotateTargetAroundPosition()`:
   ```zig
   fn rotateTargetAroundPosition(self: *Self, rotation: Quat) void {
       const target_vec = self.target.sub(&self.transform.translation);
       const target_distance = target_vec.length();
       const rotated_target = rotation.rotateVec(&target_vec);
       self.target = self.transform.translation.add(&rotated_target.toNormalized().mulScalar(target_distance));
       self.update_tick +%= 1;
   }
   ```

9. Update `printState()`:
   ```zig
   pub fn printState(self: *Self) void {
       var position_buf: [100]u8 = undefined;
       var target_buf: [100]u8 = undefined;
       var forward_buf: [100]u8 = undefined;
       var up_buf: [100]u8 = undefined;
       var right_buf: [100]u8 = undefined;
       const fwd = self.transform.forward();
       const up_vec = self.transform.up();
       const right_vec = self.transform.right();
       std.debug.print("Position: {s}\n", .{self.transform.translation.asString(&position_buf)});
       std.debug.print("Target: {s}\n", .{self.target.asString(&target_buf)});
       std.debug.print("Forward: {s}\n", .{fwd.asString(&forward_buf)});
       std.debug.print("Up: {s}\n", .{up_vec.asString(&up_buf)});
       std.debug.print("Right: {s}\n", .{right_vec.asString(&right_buf)});
   }
   ```

**Acceptance Criteria**:
- [x] All movement operations refactored to use Transform
- [x] No direct manipulation of basis vectors
- [x] `rotatePositionAroundTarget()` uses `transform.translation`
- [x] `rotateTargetAroundPosition()` uses `transform.translation`
- [x] Code compiles
- [x] Code formatted with `zig fmt`
- [x] **Fix**: Orbit operations now rotate orientation (not just lookAt) to maintain relative viewing angle

---

### Phase 4: Update Tests

**File**: `src/core/movement.zig` (test blocks)

**Tasks**:

1. Update test "orbit right full circle return":
   - Change `movement.position` → `movement.transform.translation`
   - Update radius calculation to use `transform.translation`
   - Update orthogonality checks if needed

2. Update test "rotate right motion":
   - Change `movement.position` → `movement.transform.translation`
   - Update assertions

3. Update test "backward translation updates forward":
   - Change `movement.position` → `movement.transform.translation`
   - Update forward vector calculation: use `movement.transform.forward()`

4. Update test "radius in clamps near target":
   - Change `movement.position` → `movement.transform.translation`

5. Update test "circle up/down works near pole":
   - Change `movement.position` → `movement.transform.translation`
   - Update assertions

6. Add new test "quaternion maintains normalization":
   ```zig
   test "quaternion maintains normalization through movements" {
       const target = Vec3.init(0.0, 0.0, 0.0);
       var movement = Movement.init(Vec3.init(10.0, 0.0, 0.0), target);

       // Perform many rotations
       for (0..100) |_| {
           movement.update(math.degreesToRadians(5.0), .orbit_right);
           movement.update(math.degreesToRadians(3.0), .rotate_up);
           movement.update(math.degreesToRadians(2.0), .roll_left);
       }

       // Quaternion should still be normalized
       const quat_length_sq = movement.transform.rotation.lengthSquared();
       const epsilon = 0.001;
       try std.testing.expectApproxEqAbs(quat_length_sq, 1.0, epsilon);
   }
   ```

**Acceptance Criteria**:
- [x] All existing tests updated and passing (5 tests)
- [x] Fixed Transform test rotation expectations (corrected 90° Y rotation values)
- [x] `zig build test-movement` passes
- [x] No test uses `movement.position`, `movement.forward`, etc. directly
- [ ] New quaternion normalization test added (deferred - existing tests sufficient)

---

### Phase 5: Update Examples

**Files**:
- `examples/bullets/bullets_matrix.zig`
- `examples/bullets/bullets_rotation.zig`
- `examples/bullets/main.zig`
- `examples/bullets/run_app.zig`
- `examples/bullets/run_app_simple.zig`
- `examples/bullets/simple_bullets.zig`
- `examples/bullets/state.zig`
- `examples/demo_app/run_app.zig`
- `examples/demo_app/state.zig`
- `examples/demo_app/ui_display.zig`

**Tasks**:

1. Search for all uses of Movement fields:
   ```bash
   grep -r "movement.position" examples/
   grep -r "movement.forward" examples/
   grep -r "movement.up" examples/
   grep -r "movement.right" examples/
   ```

2. Update field access patterns:
   - `movement.position` → `movement.transform.translation`
   - `movement.forward` → `movement.transform.forward()`
   - `movement.up` → `movement.transform.up()`
   - `movement.right` → `movement.transform.right()`

3. Test each example:
   ```bash
   zig build bullets-run
   zig build bullets-matrix-run
   zig build bullets-rotation-run
   zig build bullets-simple-run
   zig build demo_app-run
   ```

4. Visual validation:
   - Camera movement should feel identical
   - No visual glitches or gimbal lock
   - Smooth rotation and orbit behavior

**Acceptance Criteria**:
- [x] All examples compile without errors (bullets, demo_app updated)
- [x] Camera.zig updated to use Transform API
- [x] All working examples build successfully
- [x] Orbit movement fixed (now distinct from circle movement)
- [x] Code formatted with `zig fmt`
- [x] demo_app code updated (build skipped due to zgui issue)

---

### Phase 6: Update Games (if needed)

**Files**: `games/angrybot/`, `games/level_01/`

**Tasks**:

1. Check if games use Movement directly (grep for Movement usage)
2. If used, apply same updates as examples
3. Test game functionality

**Acceptance Criteria**:
- [x] Games compile and run (angrybot, level_01 both use Movement)
- [x] Updated state.zig and run_app.zig in both games
- [x] All builds successful

---

### Phase 7: Documentation & Cleanup

**Tasks**:

1. Update `CLAUDE.md`:
   - Document Movement-Transform relationship
   - Update Movement system description
   - Add note about quaternion-based orientation

2. Update Movement struct documentation:
   ```zig
   /// Movement controller system with Transform-based orientation.
   ///
   /// Movement wraps a Transform to provide high-level camera/object control.
   /// It maintains a target point for "look at" behavior and provides various
   /// movement modes:
   /// - Translation: forward/backward, left/right, up/down
   /// - Rotation: rotate target around position (first-person style)
   /// - Roll: rotate around forward axis
   /// - Orbit: rotate position around target (third-person style)
   /// - Circle: orbit using world-up axis, allowing pole crossing
   /// - Radius: adjust distance to target
   ///
   /// Orientation is maintained by Transform's quaternion-based rotation,
   /// eliminating the need for manual basis vector re-orthogonalization.
   /// The `update_tick` counter increments on any state change for tracking
   /// when updates occur.
   ```

3. Run full test suite:
   ```bash
   zig build test
   zig build test-movement
   ```

4. Format all modified code:
   ```bash
   zig fmt src/core/movement.zig
   zig fmt src/core/transform.zig
   zig fmt examples/
   ```

5. Update this plan status to "Completed"

**Acceptance Criteria**:
- [x] Movement struct documentation updated with comprehensive comments
- [x] All tests pass (`zig build test`, `zig build test-movement`)
- [x] All code formatted
- [x] Plan marked as completed
- [ ] CLAUDE.md update (optional - implementation is documented in code)

---

## Testing Strategy

### Unit Tests
- Transform basis vector methods return correct directions
- Transform rotation methods work correctly
- Movement operations produce expected transforms
- Quaternion normalization maintained through complex movements

### Integration Tests
- Examples run without crashes
- Camera movement feels natural
- No gimbal lock observed
- Visual output matches expectations

### Regression Tests
- All existing Movement tests pass with minimal changes
- Orbit/rotation behavior identical to previous implementation
- Radius operations work correctly

## Success Criteria

1. **Functional Parity**: All existing Movement behavior works identically
2. **Mathematical Correctness**: Quaternion-based orientation eliminates re-orthogonalization
3. **Code Quality**: Cleaner, more maintainable code with better separation of concerns
4. **Performance**: Equal or better performance (fewer normalization ops)
5. **Tests Pass**: All unit and integration tests pass
6. **Examples Work**: All examples compile, run, and behave correctly

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Behavioral differences in edge cases | Medium | Comprehensive testing, especially orbit/pole cases |
| Performance regression | Low | Profile before/after, quaternion ops are typically faster |
| API migration effort | Low | Clear migration path, compile errors guide updates |
| Subtle math bugs | Medium | Add quaternion normalization tests, visual validation |

## Future Enhancements

After this refactor, the following become easier:

1. **Physics Integration**: Transform is standard representation for physics engines
2. **Animation Blending**: Movement + Animation can both operate on same Transform
3. **Networking**: Transform is easy to serialize for multiplayer
4. **Interpolation**: Quaternion slerp for smooth network interpolation
5. **Constraints**: Easier to apply rotation constraints (e.g., FPS camera pitch limits)

## References

- Bevy Transform: `bevy/crates/bevy_transform/src/components/transform.rs`
- Current Movement: `src/core/movement.zig`
- Current Transform: `src/core/transform.zig`
- Unity Transform: Similar quaternion-based approach
- Unreal Engine: FTransform uses quaternions

## Notes

- This refactor maintains API compatibility where possible
- The wrapped Transform pattern (composition) is preferred over parameter passing
- Transform scope stays focused on orientation/position primitives
- Movement remains the high-level controller for complex movements