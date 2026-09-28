# Movement Review — Working Notes

Status: open checklist  
Source: peer review of `src/core/movement.zig` (2026-07-11)  
Rule: **code wins over docs** when they disagree; docs are often stale.

Goal: make `Movement` a solid motion library and a clear personal reference for
3D motion math, covering free camera, camera-on-a-stick, orbit, and circle, with
the ability to switch modes freely.

---

## Design intent (from discussion)

### What `target` is for

| Use | Role of `target` |
|-----|------------------|
| **Camera on a stick** (character follow) | Client (or higher layer) updates `target` as the character moves; orbit/circle/radius work relative to that point |
| **Orbit / circle a planet (or any focus)** | `target` is the fixed or slowly moving focus; position moves on a sphere/shell around it |
| **Free camera** | Translation and rotate often ignore `target`; it remains available if you later switch into orbit/circle/radius |

### Mode switching

Intention: switch motion modes freely without rebuilding the controller.

**Ambiguity:** after free-look (`rotate_*`), `target` may no longer lie along
`forward`. Then dolly (`radius_*`) or orbit uses a *stale* focus. That is not a
math bug; it is a policy question.

**Ownership options (undecided — see item M1):**

1. **Client-owned target** — app/scene always decides when to `setTarget` /
   move target (including after mode changes).
2. **Optional sync on rotate** — flag such as `sync_target_on_rotate` so free-look
   keeps `target` at a fixed distance along `forward` (or preserves current
   distance). Useful default for “always ready to orbit what I’m looking at.”
3. **Hybrid** — flag off by default (client owns); enable when you want stick-like
   coupling without external code.

No code change until M1 is decided.

---

## Motion mode map (as implemented — code is truth)

| Family | Moves position? | Changes orientation? | Moves target? | Notes |
|--------|-----------------|----------------------|---------------|-------|
| **Translate** | yes, local axes | no | no | fly / free walk |
| **Turn** | no | yaw about world up | only if `sync_target_on_rotate` | |
| **Rotate** | no | local free-look | only if `sync_target_on_rotate` | default: orientation only |
| **Roll** | no | bank about forward | no | |
| **Orbit** | around target | same quat as position (continuous) | no | local up/right axes |
| **Circle** | around target | same quat as position (continuous) | no | world up / world-right; re-level via `levelTowardTarget` |
| **Radius** | along line to target | no | no | dolly; `radius_in` clamps before target |

---

## Checklist

Work top-down. Check off when done. Capture decisions under each item.

### M1 — Target policy (design decision first)

**Status:** done (2026-07-11)  

**Topic:** Who updates `target` when switching free camera ↔ orbit/circle/radius?

**Decision: C — hybrid**

- [x] C. Hybrid: `sync_target_on_rotate` default **false** (client owns target)
- Flag true: turn/rotate free-look repositions target along forward at preserved distance
- Public `syncTargetFromForward()` for explicit use on mode switches even when flag is off
- Roll does not sync (forward unchanged)
- `default_focus_distance` used if position ≈ target

**Notes / decision:**

Option C is easy to try in-engine; feel may or may not be satisfying — play with it.
Default preserves stick-camera and planet-orbit ownership in client code.

---

### M2 — Align docs with code

**Status:** done (2026-07-11)  

**Topic:** Module-level and enum comments still describe rotate as “rotate target
around position.” Code only rotates orientation. Stale comments elsewhere
(orbit/circle wording can be tightened).

**Actions when taken:**

- [x] Rewrite top-of-file doc to match the mode map above
- [x] Document speed units: translate = units/sec; rotation/orbit = **degrees**/sec
- [x] Document −Z forward, Y up (OpenGL / Godot / Bevy aligned)
- [x] Remove or rewrite any “rotate target” language unless M1 chooses that behavior
- [x] Enum family comments + orbit vs circle; note `rotateTarget` unused; mouse stub

**Notes:**

Docs only — dead symbols left for M4 cleanup.

---

### M3 — Pole crossing / circle orientation flip

**Status:** done (2026-07-11)  

**Decision: continuous circle + explicit `levelTowardTarget(?Vec3)`**

Original `lookAt` on every circle step was intentional for **re-leveling** after
orbit (restore right ≈ ∥ XZ) in multi-mode test apps, but it was also a heavy
hidden reset that flipped at poles.

**Implemented:**

- [x] Circle uses same continuous orientation path as orbit (world axes only)
- [x] `levelTowardTarget(up: ?Vec3)` — explicit reframe
  - `null`: forward → target, right ∥ XZ, preserve bank hemisphere
  - non-null: `lookAt(target, up)` (e.g. `world_up` forces upright / may flip)
- [x] `levelUpright()` → `levelTowardTarget(self.world_up)`
- [x] `getWorldRight` pole fallback (current right, then arbitrary)
- [x] Tests: circle over pole continuous; level upright; level null → right.y ≈ 0
- [x] Docs updated (mode map / orbit vs circle)

**Notes:**

Client binds level to a key in bullets when desired. No lookAt per circle step.

**Pole jitter fix (2026-07-11):** Jitter was not the zero-axis early-out. Near the
pole `to_target × world_up` is tiny and its *direction* is unstable → pitch axis
flips each frame. Soft pole band (`POLE_SOFT_SIN_SQ`) uses camera-right axis;
sign is aligned with camera right. Zero-axis check remains as a safety only.

---

### M4 — Dead code cleanup + mouse look

**Status:** done (2026-07-11)  

**Implemented:**

- [x] `processMouseMovement(x, y, constrain_pitch)` — free-look via rotate L/R/U/D
  - `mouse_sensitivity` degrees/pixel (default 0.1)
  - `constrain_pitch` clamps elevation to ±89° from XZ
- [x] Removed `LookMode`, `rotateTarget`, `half_pi`, module `var buf`
- [x] Kept `AXIS_EPSILON` (still used)
- [x] Tests: mouse rotates; pitch constrained

**Notes:**

_…_

---

### M5 — `update_tick` consistency

**Status:** done (2026-07-11)  

**Topic:** `applyMovement` always increments tick; `rotatePosition` increments
again for orbit/circle. Fine for dirty flags; wrong if tick means “logical steps.”

**Actions when taken:**

- [x] Tick once at public entry (`applyMovement`, mouse, level, setTarget, …)
- [x] Helpers do not bump (`rotatePosition`, `syncTargetFromForwardNoTick`)
- [x] `processMouseMovement` ticks once for yaw+pitch (not twice)
- [x] Tests: orbit/circle and mouse tick counts

**Notes:**

`processMovement` → `applyMovement` → one tick. Orbit/circle no longer double.

---

### M6 — Small API consistency bugs

**Status:** done (2026-07-11)  

| Issue | Detail |
|-------|--------|
| `translate` | already value-style `add(offset)` (fixed earlier) |
| `init` vs `reset` | both use `self.world_up` (field default) |
| `Camera.frameTarget` / gimbal | value-style `sub` / `mulScalar` |

**Actions when taken:**

- [x] Fix `translate` to value API
- [x] `init` should use the same up convention as `reset` / field default
- [x] Fix `frameTarget` when touching camera

---

### M7 — Test suite as executable reference

**Status:** done (2026-07-11)  

Movement tests encode invariants for each motion family (quiet by default).

**Actions when taken:**

- [x] Fix “backward translation updates forward” → `translate does not reorient`
- [x] Strengthen rotate: `rotate 90 degrees about up changes forward`
- [x] Add: orbit vs circle diverge when pitched
- [x] Add: circle right full circle about world up returns
- [x] Add: radius out then in restores distance
- [x] Quiet default test run (removed printState spam from orbit test)
- [x] Sync flag: target along forward after rotate (existing + kept)

Also kept: orbit closed loop, radius clamp, circle poles, level, mouse look.

---

### M8 — Document orbit vs circle as first-class teaching content

**Status:** done (2026-07-11)  

**Topic:** Best learning value in the file; easy to forget six months later.

Updated to match continuous circle (no per-step lookAt):

| | Orbit | Circle |
|---|--------|--------|
| Axes | local up / local right | world up / world-right (`getWorldRight`) |
| Orientation after move | same quat as position | same quat as position |
| Feel | view-relative tumble | world turntable / lat-long |
| Re-level | explicit `levelTowardTarget` | same (not baked into circle) |
| Poles | usually fine | soft-band pitch axis near poles |

**Actions when taken:**

- [x] In-file teaching block on `Movement` + shared `rotateAboutAxisContinuous`
- [x] Review mode map / M8 table match code
- [x] No diagram (not needed)

**Notes:**

Diagram deferred indefinitely; table + code comments are enough.

---

### M9 — Sign conventions table

**Status:** done (2026-07-11)  

**Topic:** Several paths use negative angles for “right” / “up.”

**Decision:** Document only. Behavior in **bullets** and **level_01** is correct
for the intended feel — do **not** flip signs for theoretical purity.

**Actions when taken:**

- [x] Table in `movement.zig` module doc (turn / rotate / roll / orbit / circle + mouse)
- [x] Verified against product feel (owner: bullets + level_01)
- [x] No sign changes

**Notes:**

Negatives on some “right/up” cases are intentional mapping from positive
`rot_angle`/`orbit_angle` magnitudes to RH axis rotation that matches WASD /
arrow / mouse conventions in the apps.

---

### M10 — Optional structure (later, not urgent)

**Status:** done (2026-07-11) — **keep a single file**

**Decision:** Stay with `src/core/movement.zig` (controller + tests together).
Comments and module docs are enough; no split into enum/docs modules unless the
file becomes genuinely unwieldy later.

---

## Suggested order of work

All items M1–M10 closed.

---

## Session log

| Date | Item | Outcome |
|------|------|---------|
| 2026-07-11 | Review written | Checklist created; M1 left open; code wins over docs |
| 2026-07-11 | M1 | Chose C: `sync_target_on_rotate` default off + `syncTargetFromForward()` |
| 2026-07-11 | M2 | Docs aligned with code (mode map, conventions, speeds, orbit vs circle) |
| 2026-07-11 | M3 | Continuous circle + `levelTowardTarget(?Vec3)` / `levelUpright` |
| 2026-07-11 | M4 | Mouse look implemented; dead LookMode/rotateTarget/buf removed |
| 2026-07-11 | M6 | init/reset world_up; frameTarget value math (camera + gimbal) |
| 2026-07-11 | M7 | Expanded quiet invariant tests (orbit/circle/radius/rotate/translate) |
| 2026-07-11 | M8 | Orbit vs circle docs match continuous circle; no diagram |
| 2026-07-11 | M9 | Sign table documented; negatives intentional (bullets/level_01 feel) |
| 2026-07-11 | M10 | Single-file structure kept (`movement.zig` + tests) |
| 2026-07-11 | M5 | update_tick once per public call; helpers no longer double-bump |
| | | |

---

## Quick reference: public surface today

```text
init(position, target) / reset(position, target)
setTarget / getTarget / getPosition / getTransform / getTransformMatrix
getUpdateTick
processMovement(direction, delta_time)   // speeds × dt
applyMovement(direction, translation_vel, rot_angle, orbit_angle)  // raw
translate(offset)
getWorldRight()   // for circle pitch axis; singular at poles
update(angle, direction)   // test helper; dt derived from orbit_speed
printState()
processMouseMovement(...)  // stub
```

Speeds (as coded):

- `translate_speed` — world units per second  
- `rotation_speed` — degrees per second (via `degreesToRadians(speed * dt)`)  
- `orbit_speed` — degrees per second (same pattern)
