# Plan 008: Turret Controller System

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** rewritten for WebGPU and
> the new requirements on 2026-09-30 (see "Review 2026-09-30"). The imported GL-era
> version is in git (`e5010da`).

## Status: Active (phases 1-3 done 2026-10-01)

## Overview

Turrets that swing toward a target and fire, for tower defense games and similar. A
turret's behavior has three parts, kept separate so each can be tested and swapped:

- **Aim**: where the barrel points and how fast it gets there (per-axis slew, limits).
- **Pattern**: what the turret aims at over time: track a target, sweep an arc, lob a
  mortar shell, or a sequence of those.
- **Fire control**: when a shot goes out: while turning, or only once aligned; the
  cadence (rate, bursts).

Requirements (John, 2026-09-30):

1. Swing toward a target, either **firing while turning** or **waiting until aligned**.
2. Programmable **patterns**, such as a **sweeping** fire pattern and **mortar-style**
   launches.
3. Turret types by configuration (speeds, limits, weapon), as in the imported plan.

**Priorities (John, 2026-10-01): looks good, performs well, straightforward calculations.
Precision is not a goal.** Shots get deliberate **jitter** on their aim and speed, and
mortar shells explode on landing, so the blast area absorbs where exactly they come down.
Choose the simplest math that looks right; no iterative solvers, no exact-hit guarantees.

## Review 2026-09-30: what changed for WebGPU

The imported plan was written for redfish_gl_zig. Against this repo:

- **"Each turret owns its shader to prevent crosstalk" no longer applies.** GL uniforms set
  on a shared program leaked between objects; here every draw's values go through the
  uniform ring (`DrawUniforms`, `shape.draw(frame, shader, draw_uniforms)`), so shaders are
  shared, created once through `ResourceManager`. Lights come from `SceneLights` in the
  frame uniforms, not per-shader setters.
- **Shaders** are single `.wgsl` files, not `.vert` / `.frag` pairs; there is no
  `setMat4` / `setVec3` / `bindTextureAuto`. Materials bind with `material.bind(frame)`.
- **Math** is by value: `Quat.fromAxisAngle(axis, angle)`, `a.sub(b)`, `a.dot(b)`.
- **The node system**: the plan built on level_01's `nodes.zig` (allocated `Node`s with
  parent pointers). `examples/bullets/objects/cannon.zig` already has the pattern this
  repo uses for a jointed object: a flat, parent-first node array (glTF-style), one pass
  for world transforms, yaw on the body, pitch on the head, recoil on the barrel, and
  `muzzleTransform()` for spawning projectiles. Turrets start from that. Plan 005's core
  transform hierarchy would later replace both.
- **Aim smoothing**: `Cannon.update` eases with `@min(1, aim_rate * dt)`, which converges
  at different speeds at different frame rates. `core.motion` (plan 016) has the
  frame-rate independent forms (`dampAlpha`, `moveToward`); the turret's aim uses them.
- **Projectiles**: `examples/bullets/projectiles/bullet_system.zig` fires spread groups with
  optional gravity, integrated per frame (v += g·dt, p += v·dt). Good enough for straight
  fire and mortar shells alike (see Mortar).

## Design

### Aim: per-axis slew

A two-axis turret turns its body about the vertical (yaw) and tilts its barrel (pitch).
The axes have their own speeds, and pitch has limits (it can't aim into the ground or
through its own base); yaw wraps around (the shortest way from 170° to -170° is 20°, not
340°), and may have limits for a turret that covers only a sector.

Two slew styles, per turret type:

| Style | Motion | Feels like | Arrives |
|---|---|---|---|
| `rate_limited` | constant angular speed, degrees per second | a motor-driven mount | exactly, in a known time |
| `damped` | exponential approach (`dampAlpha`) | a quick snap that settles | asymptotically (aligned within a tolerance) |

New in `core.motion`, since they're general (a head, a radar dish, a door):

- `moveTowardAngle(current, target, max_speed, dt)`: `moveToward` for an angle, the short
  way around, no overshoot, arrives exactly.
- `dampAngle(current, target, rate, dt)`: `dampVec3` for an angle, the short way around.

`TurretAim` (in the turret example) holds yaw, pitch, the desired yaw and pitch, the speeds
and limits, and answers `isAligned(tolerance)` and the aim direction.

**Where `dampLookAt` fits.** `dampLookAt` turns one rotation toward a look-at: right for a
single-body aim, such as a ball turret, a sensor head, or a camera. A two-axis turret needs
the axes separate (the body only yaws, the barrel only pitches, each with its own speed and
limits), so it uses the angle helpers above. The turret example includes a single-body
variant (a sensor or ball turret) as `dampLookAt`'s first user.

### Patterns: what to aim at

A pattern produces, each frame, the desired yaw and pitch and whether it wants to fire.
`TurretAim` moves toward that; fire control decides whether a shot goes out.

- **`track`**: aim at the target. Optional **lead**: aim where the target will be when the
  projectile arrives, with the time of flight estimated once from distance / speed (no
  iteration: jitter and blast radius make a closer estimate pointless).
- **`sweep`**: swing yaw back and forth across an arc while firing: center (the target's
  bearing, or a fixed heading), half-width in degrees, sweep speed, and pitch (the
  target's, or fixed). The swing is the same ping-pong as `PathFollow.Repeat.ping_pong`,
  on an angle.
- **`mortar`**: a high-arc lob. Pitch comes from the ballistic solution (below), not from
  pointing at the target; usually fires only when aligned.
- **`sequence`** (later phase): a program of steps, such as sweep for 3 s, then two mortar
  rounds, then wait 1 s, repeat. Steps are the patterns above plus `wait`.

### Fire control: when to shoot

- **Policy**: `while_turning` (fire at the cadence regardless of aim: suppression, sweeps),
  or `when_aligned` with a tolerance in degrees (hold fire until on target: snipers,
  mortars).
- **Cadence**: a rate (shots per second), or bursts (count, interval between shots, pause
  between bursts). Frame-rate independent: a shot timer that carries over its remainder,
  so 10 shots per second is 10 shots in a second at 30 or 144 fps.
- **Jitter**, per weapon: each shot's direction is turned by a random angle within a
  cone (`aim_jitter`, degrees) and its speed scaled by a random factor
  (`speed_jitter`, e.g. ±5%), from `core.random`. Makes streams of fire and salvos look
  natural instead of laser-straight, and costs a couple of random numbers per shot.
- Shots spawn at `muzzleTransform()` into the turret's projectile system.

### Mortar: pick the flight time

The classic way fixes the launch speed and solves for the angle
(`tan θ = (v² ± √(v⁴ − g·(g·d² + 2·h·v²))) / (g·d)`), which needs a square root, has an
out-of-range case, and gives very different hang times for near and far targets. The
straightforward way fixes the **flight time** `T` instead (e.g. 2.5 s) and computes the
launch velocity directly:

    v0 = (target − muzzle) / T − ½ · g · T        (g = gravity vector, pointing down)

One line, no square root, always a solution, and every lob hangs in the air the same
time, which reads well on screen. Leading a moving target is just aiming at where it will
be in `T` seconds. The barrel points along `v0`; the shell's speed is `|v0|` (a longer
throw is a faster shell). A longer `T` gives a higher arc.

Shells use the projectile system's per-frame gravity. Its small frame-rate dependent drift,
the shot jitter, and a moving target all end up inside the blast radius, so nothing needs
an exact parabola (plan 009 phase 2 is not a dependency). On landing (height at or below
the ground, or the shell's time is up): an explosion: flash or sprite, a burn mark, and
damage to anything within the blast radius.

The formula is general (thrown objects, AI lobs), so it goes in core as a small function,
`core.ballistics.launchVelocity(from, to, flight_time, gravity)`, with tests.

### Projectiles: bullets and finned rockets

Two looks, both from the projectile system (instanced: per-shot rotation and position
through the vertex ring, one draw per kind):

- **Bullets / tracers**: the existing quads.
- **Toy rockets, bombs with fins**: a small mesh (body, nose, fins). They arc correctly
  with what `BulletSystem.update` already does: each frame gravity is added to the
  velocity and the rotation is rebuilt from the velocity's direction
  (`Quat.fromDirectionWithRight(forward, right)`), so the nose follows the arc like a
  finned bomb turning into its path (pitched up on launch, level at the top, nose down
  coming in). The `right` vector stored at launch holds the roll steady; without wind the
  arc stays in the launch's vertical plane, so the velocity never lines up with `right`.
  Optional: a slow spin about the nose, added on top, as finned rockets often have.

Mortar shells can use either look.

### Where it lives

A new `examples/turrets` (a turret test bed, as the shadows and camera_rig examples are
for theirs): a floor, targets moving on `PathFollow` loops, a few turrets of different
types, a panel to pick each turret's pattern, policy, and slew style, and debug lines for
the aim ray and the predicted mortar arc. Turret parts follow `Cannon`'s node array. A
tower defense game (level_01, or a new one) uses the pieces once they're settled.

## Phases

### Phase 1: Aim
- [x] `motion.moveTowardAngle` and `motion.dampAngle`, with invariant tests (the short way
      across ±180°, no overshoot, arrives exactly, frame-rate independent)
- [x] `TurretAim`: yaw and pitch toward desired angles, `rate_limited` or `damped`, pitch
      limits, optional yaw limits, `isAligned(tolerance)`, aim direction; tests. Done as
      `core.motion.YawPitchAim` (see the phase 1 note)
- [x] `Cannon` (bullets example) eases its aim with `dampAngle` instead of
      `@min(1, rate * dt)`

### Phase 2: Turret test bed and fire control
- [x] `examples/turrets`: floor, a target on a `PathFollow` loop, two turrets built like
      `Cannon`, straight-fire projectiles, aim-ray lines, panel
- [x] Fire control: `while_turning` / `when_aligned(tolerance)`, rate and bursts with a
      carry-over shot timer, aim and speed jitter; tests (no shot before aligned under
      `when_aligned`; the same number of shots per second at 30 and 144 fps; jittered
      shots stay within the cone and speed range). Done as `core.FireControl` and
      `core.fire_control.ShotJitter` (see the phase 2 note)
- [x] `track` pattern, with and without lead (`core.ballistics.leadPoint`)

### Phase 3: Sweep
- [x] `sweep` pattern (center on the target's bearing or a fixed heading, half-width,
      speed, pitch); tests (stays within the arc, reverses at the ends). The swing is
      `core.motion.Sweep` (see the phase 3 note)

### Phase 4: Mortar
- [ ] `core.ballistics.launchVelocity(from, to, flight_time, gravity)`; tests (with
      per-frame gravity and no jitter, a shell lands within a small distance of the target
      at 30 and 144 fps)
- [ ] `mortar` pattern (flight time, lead by `T`); shells with gravity; predicted-arc lines
- [ ] Finned rocket mesh, drawn instanced and oriented along the velocity (as
      `BulletSystem` already does); optional spin about the nose
- [ ] Explosion on landing: flash or sprite, burn mark, blast radius

### Phase 5: Programs and types
- [ ] `sequence` pattern (steps with durations, repeat)
- [ ] Turret types by configuration (slew style and speeds, limits, weapon, default
      pattern)
- [ ] A single-body turret (sensor or ball turret) aimed with `dampLookAt`

Each phase ends with a `CHANGELOG.md` entry and a commit, `zig build test` passing.

## Testing strategy

Invariant tests in the style of `motion.zig`, checking behavior rather than precision:
angles take the short way and never overshoot; the same result at 10, 60, and 144 fps;
`when_aligned` fires nothing before alignment; a sweep stays within its arc; jitter stays
within its range; a mortar shell lands well within its blast radius. The test bed shows
what matters most (how slew styles, patterns, jitter, and explosions look), with
screenshots before hand-off.

## Open questions

- Turret models: basic shapes as `Cannon` (enough for the test bed), or glTF models later?
- ~~Sweep center: follow the target's bearing, a fixed sector, or both?~~ Both, and the
  same for pitch (phase 3).
- Game integration: level_01, or a new tower defense game, after plan 005's transform
  hierarchy?

## Notes & Decisions

**2026-09-30**: `core.motion.dampLookAt(rotation, position, focus, up, rate, dt)` exists
for aiming: it turns a rotation part way toward looking at a focus each frame, frame-rate
independent (plan 016). Turret aim is its intended first user (confirmed by John).

**2026-09-30**: Plan rewritten for WebGPU and John's requirements (fire while turning or
when aligned; sweep and mortar patterns). Structure: aim / pattern / fire control. Starts
from `Cannon`'s node array in the bullets example instead of level_01's `nodes.zig`. A
two-axis turret aims per axis (`moveTowardAngle` / `dampAngle`), since the body only yaws
and the barrel only pitches, with separate speeds and pitch limits; `dampLookAt` goes to a
single-body turret variant. The mortar needs exact parabolas: depends on plan 009 phase 2
(superseded 2026-10-01, below).

**2026-10-01**: Priorities from John: looks good, performs well, straightforward
calculations; precision is not a goal. Shots get aim and speed jitter, and mortar shells
explode, so the blast area absorbs landing variation. Changes: the mortar fixes the
flight time and computes the launch velocity in one line (no square root, no out of range,
the same hang time for every lob) instead of solving for the angle at a fixed speed; lead
is a single estimate; shells use the existing per-frame gravity, so plan 009 phase 2 is no
longer a dependency; jitter (aim cone, speed factor) is part of each weapon; tests check
behavior (within the blast radius, within the jitter range) instead of exact hits.

**2026-10-01**: Some projectiles look like toy rockets, bombs with fins (John). They need
no new math: `BulletSystem.update` already rebuilds each projectile's rotation from its
velocity every frame, so the nose follows the gravity arc, with the roll held by the
launch `right` vector. Added: a finned rocket mesh drawn instanced, optional spin.

**2026-10-01**: Phase 1 done.
- `core.motion`: `wrapAngle` (to -π..π), `moveTowardAngle` (at most `max_speed * dt`, the
  short way, arrives exactly), `dampAngle` (frame-rate independent, the short way).
  Radians throughout, like the math module and `Cannon`.
- The plan's `TurretAim` became `core.motion.YawPitchAim`: `zig build test` only runs core,
  math, and containers tests, so in the example its tests wouldn't run, and two-axis aim
  is general (turrets, radar dishes, heads). The turret example will wrap it. Fields:
  `yaw`, `pitch`, `target_yaw`, `target_pitch`, `slew` (`rate_limited` speeds or `damped`
  rates, per axis), `min_pitch` / `max_pitch`, optional `yaw_limits`. `aimAt(toward)` takes
  a direction in the turret's own space (`Cannon`'s conventions: -Z forward, positive yaw
  turns left, positive pitch raises the aim); `setTarget(yaw, pitch)` clamps;
  `direction()`; `isAligned(tolerance)` compares the current and target directions.
- Sector turrets: with `yaw_limits`, yaw is a plain angle inside the limits instead of
  wrapping, since the short way around could cross the part the turret can't turn
  through (a test turns from -160° to 160° in a -170°..170° sector the long way, through
  0).
- `Cannon.update` eases aim with `dampAngle` and recoil with `dampAlpha` (both had the
  frame-rate dependent `@min(1, rate * dt)`).
- Tests: 85 pass (6 new). The bullets example runs without errors.
- Next: phase 2, `examples/turrets` with fire control and `track`.

**2026-10-01**: Phase 2 done.
- `core.FireControl` (`src/core/fire_control.zig`), in core for the same reason as
  `YawPitchAim`: its tests run there, and any weapon can use it. `update(dt, trigger,
  aim_error)` advances the shot timer; `while (nextShot()) |age|` hands out the shots due
  this frame, each with its age (seconds since it should have gone out), so a stream is
  evenly spaced at any frame rate (the shot is moved on by `velocity * age`). While fire
  is held the timer stops at zero, so held shots don't pile up into a volley. Policy
  `while_turning` or `when_aligned` (radians); cadence `rate` or `bursts` (count,
  interval, pause; a burst cut short goes on where it left off).
- `core.fire_control.ShotJitter`: direction turned by up to `aim` radians (filling the
  cone's disk evenly), speed scaled by up to ±`speed`, from `core.Random`.
- `core.ballistics.leadPoint(from, target, target_velocity, speed)`: the target's position
  after a flight time estimated once from the distance. `core.ballistics` is where phase
  4's `launchVelocity` goes.
- `YawPitchAim.aimError()`: the angle between the aim and its target, for fire control.
- `examples/turrets` (`zig build turrets-run`): `turret.zig` (parts in a parent-first node
  array as `Cannon`; aim, pattern, fire control), `projectiles.zig` (a fixed pool of
  tracers per turret, drawn instanced; hits tested against the frame's whole step, so fast
  shots can't skip the target). Two turrets: "gatling" (rate-limited, fires while
  turning, steady rate, wide jitter, no lead) and "cannon" (damped, when aligned, bursts,
  tight jitter, lead). The panel changes all of it per turret; the target flashes on
  hits.
- Found: a damped aim trails a moving target by about (angular speed / rate) radians, so
  a damped `when_aligned` turret with a tight tolerance rarely fires (rate 4, 2°: 2 hits
  in 7 s). The cannon's defaults are rate 8 and 4°. A rate-limited aim catches up
  exactly while the target turns slower than its speed. If a damped turret needs to sit
  on a moving target, feed the target's angular velocity forward; not needed yet.
- Without lead the gatling's stream passes behind the target (0 hits); with lead, about
  110 of 120 shots hit in 12 s.
- Tests: 92 pass (7 new).
- Next: phase 3, the `sweep` pattern.

**2026-10-01**: Phase 3 done.
- `core.motion.Sweep`: an offset swinging across -`half_width`..`half_width` at a steady
  `speed`, turning back at each end (`PathFollow`'s ping-pong fold, on an angle). In core
  for its tests, and general (searchlights, radar dishes). Narrowing the arc brings the
  offset back inside at once; a zero width holds it at 0. Tests: stays within the arc,
  turns back at the ends, the same offset at 10, 60, and 144 fps.
- `core.motion.yawPitchOf(toward)` and `yawPitchDirection(yaw, pitch)` are public now
  (`YawPitchAim.aimAt` uses the first), so a pattern can work in angles.
- The turret's `Pattern.sweep`: a `motion.Sweep`, plus the center (a fixed yaw, or the
  target's bearing when null) and the pitch (fixed, or the target's when null). The swept
  point is as far out as the target and goes through `aimAt` like a tracked one, so the
  slew style, limits, and fire control all apply unchanged. The panel keeps the swing's
  position while its width and speed change.
- `examples/turrets`: a third turret, "sweeper" (rate-limited at 180°/s, fires while
  turning, 15 shots/s, a 20° half-width at 40°/s around the target's bearing); any turret
  can switch pattern in the panel. Cyan lines show the arc's ends.
- The sweep is a triangle wave (constant speed, sharp turns); the aim's slew rounds the
  turns. If a softer swing looks better, a sine is an option to add next to it.
- Tests: 95 pass (3 new).
- Next: phase 4, the mortar.
