# Plan 016 - Motion Patterns (motion.zig)

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Active: phases 1-3 done (2026-09-29). See Notes & Decisions at the end.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

## Status: Active (phases 1-3 done, 2026-09-29)

## Context

`src/core/movement.zig` is a solid controller for *instantaneous,
input-driven* motion: every command (`forward`, `orbit_right`, `radius_in`,
…) applies a per-frame step derived from input. What the engine lacks is the
*time-based, goal-seeking* family — motion that pursues a target over many
frames: smooth follow, damped look-at, waypoint paths, shake.

The games are already hand-rolling these:

- `games/level_01/run_app.zig` (click-to-move, ~line 315) — steps the group
  toward the clicked point inline, with snap-on-arrival and overshoot
  clamping. Exactly the primitive that belongs in the engine. (redfish also
  had an unused `moveTowards` helper there; the port dropped it as dead code.)
- `games/angrybot/run_app.zig` (~line 361) — camera-on-a-stick: the game
  camera is `reset` to `player + camera_follow_vec`, looking at the player,
  every frame. Works, but a damped follow would remove the rigid feel and
  model the pattern properly.
- `camera_gimbal.zig` — designed as an orbiting rig (base orbits/circles an
  object, camera gimbals from the mount point) but currently unreferenced and
  half-migrated. It is the natural showcase for these patterns
  (see [movement_usage_review.md](../reviews/movement_usage_review.md), item 4).

Goal: a `src/core/motion.zig` that captures these patterns as small, clearly
documented, individually tested building blocks — same instructive standard
as `movement.zig` (doc tables, invariant tests).

---

## 1. Design Principles

### Compose with Movement, don't extend it

`MovementDirection` stays an enum of instantaneous commands. Motion patterns
are *stateful over time* — they hold their own state (velocity, path
progress, elapsed time) and each frame produce a position/orientation/offset
that is fed to a `Movement` (or `Transform`). Three composition points:

1. **Feed the target** — e.g. damped follow updates `movement.setTarget(...)`
   so orbit/circle/radius stay valid while following.
2. **Feed the pose** — e.g. `moveToward` / path following writes the
   translation via `movement.translate` or directly to a `Transform`.
3. **Post-compose an offset** — e.g. shake adds a transient offset *after*
   the controller runs, never mutating controller state.

### Frame-rate independence is the core lesson

The naive `pos = lerp(pos, goal, k * dt)` converges at different rates for
different frame rates. The instructive core of this whole module is one
function:

```zig
/// Fraction of remaining distance to close this frame, frame-rate independent.
/// rate ≈ "per-second aggressiveness"; higher = snappier.
pub fn dampAlpha(rate: f32, dt: f32) f32 {
    return 1.0 - @exp(-rate * dt);
}
```

Every damped pattern below is `lerp`/`slerp` by `dampAlpha(rate, dt)`. A test
should prove it: stepping 1s as 60×(1/60) and as 10×(1/10) must land within
epsilon of the same place.

### Prior art (for reference while designing)

- **Unity** `Vector3.SmoothDamp` — critically damped spring with explicit
  velocity state; the "cannot overshoot" option if plain damping feels wrong.
- **Godot** — `lerp` + `damp` helpers plus a `PathFollow3D` node (progress
  along a curve); closest match to the shape proposed here.
- **Game Programming Gems** exponential damping — the `1 - exp(-rate*dt)`
  formula above; simplest correct answer, start here.

---

## 2. Candidate Patterns

| Pattern | State it owns | Output | First user |
|---------|--------------|--------|------------|
| `moveToward` | none (pure fn) | new position, clamped, snaps on arrival | level_01 click-to-move |
| `SmoothFollow` | rate, optional offset | damped position (+ damped target) | angrybot / level_01 chase cam |
| `LookAtDamp` | rate | slerped orientation toward a focus | turret aim, camera settle |
| `PathFollow` | waypoints, progress, mode | position (+ tangent for facing) | scripted camera flythrough |
| `Shake` | trauma, frequency, seed | transient position/rotation offset | impacts, explosions |

Notes per pattern:

- **`moveToward`** — promote level_01's implementation nearly as-is (pure
  function, no allocation). This is Phase 1 because it deletes duplicated
  game code immediately.
- **`SmoothFollow`** — position damping via `dampAlpha`; a `Vec3` offset in
  the followed object's local or world space (chase cam sits behind/above).
  Also solves the angrybot stick: damp `movement.target` toward the player
  instead of snapping.
- **`LookAtDamp`** — build desired orientation with `Transform.lookAt` math,
  then `slerp(current, desired, dampAlpha(rate, dt))`. Reuses the
  quaternion experience from the animation system.
- **`PathFollow`** — start with linear waypoints + distance-based progress;
  then Catmull-Rom through the same waypoints (direct tie-in to the glTF
  cubic-spline work — same Hermite basis, different tangent choice).
  Repeat modes can mirror `AnimationClip` (once / loop / ping-pong).
- **`Shake`** — trauma model (add on impact, decay over time, offset scales
  with trauma²) driven by smooth noise or layered sines. Composes as a final
  offset; never touches controller state, which is itself the lesson.

---

## 3. API Sketch

```zig
// src/core/motion.zig
pub fn dampAlpha(rate: f32, dt: f32) f32;
pub fn moveToward(current: Vec3, target: Vec3, max_speed: f32, dt: f32) Vec3;

pub const SmoothFollow = struct {
    rate: f32 = 5.0,
    offset: Vec3 = Vec3.Zero,       // desired camera offset from followee
    pub fn update(self: *SmoothFollow, movement: *Movement, followee: Vec3, dt: f32) void;
};

pub const PathFollow = struct {
    points: []const Vec3,
    speed: f32,
    progress: f32 = 0.0,
    mode: enum { once, loop, ping_pong } = .once,
    interp: enum { linear, catmull_rom } = .linear,
    pub fn update(self: *PathFollow, dt: f32) Vec3;      // position
    pub fn tangent(self: *const PathFollow) Vec3;        // for facing
};

pub const Shake = struct {
    trauma: f32 = 0.0,
    frequency: f32 = 25.0,
    decay: f32 = 1.5,
    pub fn addTrauma(self: *Shake, amount: f32) void;
    pub fn update(self: *Shake, dt: f32) Vec3;           // offset to add post-controller
};
```

Exact shapes to be settled during implementation; the constraint that matters
is the composition boundary (§1), not the field lists.

---

## 4. Phases

### Phase 1 — Foundations
- [x] `motion.zig` with `dampAlpha` + `moveToward` and invariant tests
      (frame-rate independence, no overshoot, snap-on-arrival)
- [x] Replace level_01's inline click-to-move stepping with the engine version
- [x] Export from `core/root.zig`; tests run under `zig build test` (the core
      module tests and `tests/analyze_all.zig`)

### Phase 2 — Follow & aim
- [x] `SmoothFollow` (position + target damping), `LookAtDamp` (as `dampLookAt`)
- [x] Use in angrybot or level_01 chase camera (replaces target snapping)

### Phase 3 — Paths
- [x] Linear waypoint `PathFollow` with repeat modes
- [x] Catmull-Rom interpolation over the same waypoints
- [x] Example: scripted flythrough in an example app (the shadows example)

### Phase 4 — Shake + showcase
- [ ] `Shake` with trauma model, composed as a post-controller offset
- [ ] Revive `CameraGimbal` as the showcase: base orbits/circles a focus via
      `Movement`, `SmoothFollow` damps the base target, gimbal aims on top
      (repair items tracked in movement_usage_review.md, item 4)

## Testing strategy

Same style as `movement.zig`: invariant tests that read as documentation.
Key ones: damping frame-rate independence (two dt series converge), path
loop returns to start, ping-pong reverses, shake offset → 0 as trauma decays,
follow never overshoots a stationary followee.

---

## Notes & Decisions

**2026-09-28** — Imported from redfish_gl_zig and made the active plan. Scope for
now: phases 1-2. `math/easing.zig` has a scalar `smoothDamp` (Unity-style,
velocity state) that nothing uses; `dampAlpha` is the simpler starting point, as
§1 says. `camera_gimbal.zig` is still unreferenced in core; its revival stays in
phase 4.

**2026-09-28** — Phases 1-2 done.
- `src/core/motion.zig`: `SmoothFollow`, `dampLookAt`, `moveToward`, `dampVec3`,
  `dampQuat`, `dampAlpha`, with invariant tests (the same second at 10, 60, and 144 fps
  lands in the same place; `moveToward` never overshoots and stays at the goal;
  `SmoothFollow` never moves away from a stationary followee; `dampLookAt` settles on the
  focus). Exported as `core.motion` and `core.SmoothFollow`.
- `LookAtDamp` became a function, `dampLookAt(rotation, position, focus, up, rate, dt)`:
  it needs no state beyond the rotation the caller already holds.
- `SmoothFollow.offset` is in world space (angrybot's `camera_follow_vec`); a
  followee-local offset (chase cam behind a turning player) can come when needed.
- **Bug found:** `Quat.lookAtOrientation` built right = forward x up, a mirrored basis
  that doesn't convert to a quaternion (it returned identity for a +X focus). Fixed to the
  `Transform.lookTo` basis (right = up x back), with a test. It had no other callers.
- level_01: click-to-move is one `moveToward` call per frame; the `moving` flag is gone
  (moveToward is idempotent at the goal). redfish's 0.1-unit snap threshold is gone too.
- angrybot: the game camera follows the player through `SmoothFollow` at rate 8 (about
  0.6 units of lag at run speed) instead of being snapped every frame.
- No first user for `dampLookAt` yet; plan 008's turret aim is the natural one.

**2026-09-29**: Parked for plan 017 (shadows).
- **Where it stands:** phases 1-2 done and committed (`a2a7546`): `core.motion`, used by
  level_01's click-to-move and angrybot's follow camera. Nothing half-finished.
- **Next step:** phase 3, a linear waypoint `PathFollow` with repeat modes in `motion.zig`,
  then Catmull-Rom over the same waypoints and a flythrough example. `dampLookAt` still
  has no user; plan 008's turret aim is the likely first one.

**2026-09-29**: Resumed; phase 3 done.
- `PathFollow` in `motion.zig`: `points` (caller-owned, at least two), `speed` (units per
  second), `shape` (`.linear` / `.catmull_rom`), `repeat` (`.once` / `.loop` /
  `.ping_pong`), and state `distance`, `heading`, `finished`. `update(dt)` returns the
  position; `position()`, `tangent()` (unit direction of travel, reversed when heading
  back), `length()`.
- Progress is distance along the path, so speed is steady however the waypoints are
  spaced. No allocation: segment lengths are recomputed per call (cheap for tens of
  points).
- Its own `Repeat` enum instead of `AnimationRepeatMode` (`Once` / `Count` / `Forever`),
  which doesn't have loop-closing or ping-pong.
- Catmull-Rom: each segment is a cubic Hermite curve with tangent `(next - previous) / 2`
  at each point, the same basis as the glTF cubic-spline code in animator.zig (whose
  functions are private and keyframe-specific, so `motion.zig` has its own small
  `hermite` / `hermiteDerivative`). Open paths mirror a phantom point past each end; loops
  wrap. Curve segment lengths are the sum of 16 chords, and distance maps linearly to the
  curve parameter within a segment, so speed is steady between segments and close to
  steady within one.
- Tests (74 pass): once passes each point at its distance and stops; loop returns to the
  start after one length; ping-pong turns back and its tangent turns with it; one second
  lands in the same place at 10, 60, and 144 fps (both shapes); the Catmull-Rom curve
  goes through every point without the linear path's corner.
- Example: the shadows example's "Camera path" panel section flies the camera around a
  closed loop of six waypoints (off, linear, or Catmull-Rom; speed; look at the center or
  ahead along `tangent()`), and draws the path with `core.shapes.Lines` (a copy of the
  bullets example's line shader). The path is sampled from a copy of the `PathFollow`, so
  drawing doesn't move the camera.
- Next: phase 4 (`Shake`, `CameraGimbal` revival), or park the plan.
