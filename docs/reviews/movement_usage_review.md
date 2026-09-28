# Movement & Consumers Review — 2026-07-12

Scope: `src/core/movement.zig` plus every consumer (`camera.zig`,
`camera_gimbal.zig`, examples, games). Companion to
[movement_review.md](movement_review.md) (2026-07-11 working notes on the
module internals); this report focuses on cross-cutting issues and how the
module is used.

Verified during review: `zig build test-movement` and `zig build check` pass.

---

## Overall assessment

The module is in strong shape and does its job as an instructive reference:

- **Documentation tables** — the motion-family table, "Orbit vs circle"
  comparison, and the sign-convention table (with the warning not to "fix"
  signs for RHS purity without re-checking product feel) capture knowledge
  that usually gets lost.
- **Tests as executable spec** — "orbit right full circle return", "radius
  out then in restores distance", "circle travels over pole with continuous
  orientation" document the invariants better than prose.
- **Careful numerics** — soft pole band in `getWorldRight` with
  hemisphere-continuity to prevent frame-to-frame axis flips; pitch clamp
  computed from current elevation instead of accumulated yaw/pitch state;
  `radius_in` clamps short of the target.
- **Clean layering** — `Movement` owns pose + target; `Camera` adds
  projection and caches the view keyed on `update_tick`.

The issues found were almost all at the edges: one axis inconsistency, one
NaN edge case, and stale code in consumers that only compiles because Zig's
lazy analysis never looks at it.

---

## Findings and status

### 1. `turn_*` used hardcoded `Vec3.World_Up` instead of `self.world_up`
**Status: FIXED (John, 2026-07-12)**

`movement.zig` turn handlers rotated about the hardcoded constant while the
struct doc said the configurable `world_up` field applied to turn, and
`circle_*` honored it. Both handlers now use `self.world_up`.

Follow-up idea: a test that sets a tilted `world_up` and verifies turn/circle
agree would lock this in.

### 2. `radius_out` produced NaN when position == target
**Status: FIXED (2026-07-12)**

`radius_in` guarded against the degenerate distance but `radius_out` called
`toNormalized()` on a possibly zero vector. Now falls back to dollying out
along `-forward` (target ends up in front of the camera). Regression test:
`"radius out at target falls back to forward"`.

### 3. `update()` test helper was a trap
**Status: FIXED (2026-07-12)**

It was `pub`, innocently named, and converted angle→dt via `orbit_speed` even
for rotate directions (correct only because both speeds default to 50).
Decision: scenario-specific conversion belongs in the caller, not in
`Movement`. Removed from the struct; tests now use a file-local `stepAngle`
helper that calls `applyMovement(direction, 0, angle, angle)` — exact, with
no speed coupling.

### 4. `camera_gimbal.zig` contains code that cannot compile
**Status: OPEN — keep and repair (decision: John)**

- `processMovement` switches on `.look_left/.look_right/.look_up/.look_down`
  (`camera_gimbal.zig:330-333`) — these variants do not exist in
  `MovementDirection`.
- `getCameraForward` calls `rotateVec(&gimbal_forward)`
  (`camera_gimbal.zig:452`) — old pointer API; `Quat.rotateVec` takes `Vec3`
  by value. Its tests use `dot(&…)` the same way.
- Nothing references `CameraGimbal` and its tests are not wired into any test
  step, so lazy analysis hides all of this. It would break the moment someone
  used it.

**Design intent (worth preserving):** originally an orbiting camera — the
*base* orbits/circles an object while the *camera* gimbals from that mount
point. This is how real camera rigs and most engine follow-cams work, and it
is a natural showcase for the motion-patterns plan
([016-motion-patterns.md](../plans/016-motion-patterns.md)).

Repair checklist:
- [ ] Remove or properly add the `look_*` variants (map to `rotate_*`?)
- [ ] Update `rotateVec` / `dot` calls to the by-value math API
- [ ] Wire its tests into a test step
- [ ] Add a usage example (orbit base + gimbal aim) in an example app

### 5. Stale example code (same lazy-analysis category)
**Status: OPEN**

- `examples/picker/` uses the pre-Movement camera API (`.Forward`,
  `camera.zoom`, `getLookToView`) and is not in `build.zig`'s target list.
  Known-old example, pending update or removal.
- `examples/bullets/scene/axis_lines.zig` `drawLocalAxis` uses the old
  pointer-style `rotateVec` and is commented out of `draw()`.

Guard idea so rot can't hide again: add a test that does
`std.testing.refAllDeclsRecursive(@import("core"))` (or a
`zig build check-all` that compiles every example) so lazy analysis is forced
over exported decls.

### 6. angrybot writes `movement.target` directly
**Status: ACKNOWLEDGED — legacy port, low priority**

`games/angrybot/run_app.zig:363-364` assigns `movement.target` instead of
calling `setTarget()`, skipping the tick bump. Harmless today (the view
matrix doesn't depend on target) but bypasses the dirty-tracking API.
angrybot is a port of a C++ example project and carries some legacy bits;
fix opportunistically.

### 7. Smaller observations (no decision needed yet)
**Status: OPEN / notes**

- **Pitch constraint asymmetry** — `processMouseMovement` clamps to ±89° but
  keyboard `rotate_up/down` can flip over the pole. If deliberate (keyboard
  free-look = full 6DOF, mouse = FPS-style), a one-line doc note would keep
  someone from "fixing" it.
- **`Camera.init` silently overrides Movement speed defaults**
  (10/50/50 → 100/100/200). Exposing speeds in `Camera.Config` would make it
  visible.
- **`Camera` / `CameraGimbal` duplicate the projection + caching block.**
  When CameraGimbal is revived, consider extracting a shared `Projection`
  struct.
- **View-matrix paths differ** — `Camera.getView` uses `Mat4.lookToRhGl`
  while CameraGimbal uses `Transform.toViewMatrix()`. Unify when convenient.

---

## Motion patterns direction

The current enum covers *instantaneous, input-driven* motion. The missing
family for "cameras and other objects in different game scenarios" is
*time-based, goal-seeking* motion: smooth follow / damped chase, `moveToward`
(already hand-rolled in `games/level_01/run_app.zig:460`), waypoint/spline
path following, and camera shake. These are stateful over time, so they
belong in a companion module layered on `Movement` rather than in the enum.

See [Plan 016 — Motion Patterns](../plans/016-motion-patterns.md).
