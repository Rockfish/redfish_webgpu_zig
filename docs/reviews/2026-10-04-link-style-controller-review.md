# Link-Style Character Control: Review and Spec (2026-10-04)

A review of `temp/Wind_Waker_Link_motion_control.md` (Grok's answer on how Link moves in
The Wind Waker) against what the engine has, written as a spec for plan 012's next work.
The goal: Wind Waker's third-person control (camera-relative analog movement, leash
camera, lock-on) plus a first-person view for aiming and shooting, on the toon soldier
in `examples/bullets`. The animation state machine should be general enough to program
other characters the same way.

Sections: what we have (1), comments on the Grok notes (2), reference units (3), the
architecture (4), the motion spec (5), the camera spec (6), the animation state machine
changes (7), the soldier's clips and their gaps (8), decisions (9), the squad (10),
the target range scene (11), phases (12), open questions (13).

## 1. What We Have

| Piece | Where | State |
|---|---|---|
| Animation FSM | `src/core/animation_fsm.zig` | One clip per state, crossfade, one-shot return, `isInterruptible`. Known gaps: interrupted crossfade pops (012 item 1), no blend states (item 2), no phase matching (item 3) |
| Soldier | `examples/bullets/objects/toon_soldier.zig` | Keyboard (`processInput`) and gamepad (`drive`); actions on number keys / face buttons. Loads `Character_Enemy.gltf` (`path_enemy`), not `Character_Soldier.gltf` |
| Analog drive | `examples/bullets/objects/character_control.zig` | Moves along the **stick** direction at walk or run speed (threshold 0.75), faces it with `dampAngle` (rate 12) |
| Camera | `motion.FollowCamera` (`src/core/motion.zig:83`) | Leash camera, stick turn, optional recenter; used by `scenes/debug_scene.zig` |
| Stick to world | `motion.cameraRelativeMove` | Done |
| Input | `core.Input` | Sticks shaped (dead zone, exponent), triggers 0..1, `buttonPressedOnce` |
| Aim / projectiles | `motion.YawPitchAim`, `core.ballistics`, `projectiles/bullet_system.zig` | Bullets use `GRAVITY = 1.0` (arbitrary units) |

The Wind Waker model is three things working together: a **movement controller**
(speed, acceleration, turning, modes like roll and lock-on), a **camera** that reacts to
those modes, and an **animation layer** that shows them. Today the soldier has a thin
version of the first, a good start on the second, and the third does most of the work.

## 2. Comments on the Grok Notes

Useful, with care on a few points:

- **Units are per frame at 30 fps.** Everything has to become per second and go through
  `core.motion` (`moveToward`, `moveTowardAngle`, `dampAngle`) so it behaves the same at
  any frame rate. 17 u/f is 510 u/s.
- **The ratios matter, not the numbers.** Wind Waker's units have no meaning here. Use
  each speed as a multiple of the run speed (table below) and set the run speed from our
  own animation (section 3).
- **Sidehop is listed twice with different values**: 24.87 measured, 30 in the AR list.
  The AR value is probably the launch speed and 24.87 an average over the hop. Treat it
  as "about 1.5 to 1.8 × run" and tune.
- **The 2-frame roll-chain window is a speedrun technique, not a design target.** For a
  game that feels good, buffer the button: a press in the last ~0.15 s of a roll queues
  the next one.
- **Superswim** (the missing clamp) is a bug to avoid, as Grok says. Generally: clamp
  speeds at zero when decelerating and when a turn subtracts speed.
- **"Slerp facing"** would be exponential easing. The decomp stores turn rates as `s16`
  angle steps per frame: a constant turn rate, i.e. `motion.moveTowardAngle`, not
  `dampAngle`. The difference shows: constant-rate turns read as "running around a
  curve", eased turns as "snapping then settling". Recommend `moveTowardAngle`.
- **Movement follows facing, not the stick.** In Wind Waker, Link runs where he faces and
  his facing turns toward the stick; a hard stick change makes him run in an arc. Our
  `character_control.drive` moves along the stick at once and turns the model after it,
  which reads as sliding. This is the single biggest change toward the Wind Waker feel.
- **The scale paragraph** (8.5 mm per unit from a sword-length guess) is a guess on a
  guess; don't build on it. Section 3 is the alternative.
- **Auto-jump off ledges** needs level geometry with edges; bullets has a flat floor.
  Nothing to do until there's a level (see question 5).

Wind Waker's speeds as multiples of the run speed (17 u/f):

| Mode | u/f | × run |
|---|---|---|
| Run (full stick) | 17 | 1.00 |
| Lock-on backward | 15 | 0.88 |
| Lock-on strafe / forward | 12 | 0.71 |
| Swim | 18 | 1.06 |
| Crawl | 5.89 | 0.35 |
| Roll max / min | 26 / 5 | 1.53 / 0.29 |
| Sidehop | 24.87 (30) | 1.46 (1.76) |
| Backflip | 22.5 | 1.32 |
| Jump slash | 18 | 1.06 |

## 3. Reference Units: Model Size, Distances, and Speeds

The question: how to set a unit that ties the model's dimensions to motion distances and
speeds. Recommendation in four parts.

### 3.1 One world unit is one meter

Engine-wide. Gravity is then 9.8 m/s² (`core.ballistics` already documents it that way),
camera distances, jump heights, and weapon ranges are in meters, and asset packs that
follow glTF's convention (meters) drop in at scale 1. Games often use stronger gravity
for jumps (1.5 to 3 × 9.8, so jumps don't float); that is a tuning value, not a different
unit. Bullets' `GRAVITY = 1.0` would change to meters when the soldier shoots in it.

### 3.2 Each character declares its height; the scale follows

The character's tuning holds `height` in meters; the model's scale is
`height / model_height`, where `model_height` is measured from the bind-pose bounds
(the glTF accessors' min/max, no need to pose it). Measured for `Character_Enemy.gltf`:

| Point | Model units (scale 1) |
|---|---|
| Top of head / helmet | 2.27 |
| Head joint | 1.46 |
| Hips (idle) | 0.73 |
| Feet (ankle joints) | 0.02 |

So at today's scale of 1 the soldier is 2.27 m tall. A 1.8 m soldier is scale 0.79.

### 3.3 Locomotion speeds come from the clips, not from the height

The toon proportions (hips at 32% of the height; about 50% for a person) mean that a
speed picked from the height ("a 1.8 m person runs at 5 m/s") makes the feet slide. The
speed that keeps the planted foot still is set by the clip: how fast the foot moves
backward while it is on the ground. Measured from the clips (planted-foot speed, sampled
in a script; noisy because the clips have 23 to 31 keys and the run's feet touch for
only 12-17% of the cycle):

| Clip | Duration | Foot-locked speed (model units/s) | At scale 0.79 (m/s) | Bullets today |
|---|---|---|---|---|
| Walk / Walk_Shoot | 1.0 s | about 2.6 (2.4-3.0) | about 2.1 | `walk_speed` 1.5: feet slide forward |
| Run / Run_Gun / Run_Shoot | 0.733 s | about 4.5 (3.3-5.5) | about 3.5 | `run_speed` 7.5: feet skate |

These are starting values to confirm by eye: a floor grid and a speed slider in ImGui,
adjusted until the planted foot holds still. Wind Waker's Link runs at roughly 3 body
heights per second; the soldier's clip gives about 2. If that feels slow, play the run
faster (1.2 to 1.3 × rate reads fine on a toon) rather than moving faster than the clip.

### 3.4 Gameplay sets the speed; the animation rate follows

Each locomotion state records its clip's authored speed (`authored_speed`, model units
per second, from the measurement above). Each frame:

```
world_speed   = the controller's current speed (m/s)
clip_speed    = authored_speed × character scale
playback_rate = world_speed / clip_speed      (clamped to about 0.7 .. 1.4)
```

Below and above the clamp, blend toward the next clip (idle ↔ walk ↔ run) instead of
stretching one clip. This is what makes analog throttle look right: a half-tilted stick
gives a slower walk with matching steps, not a full-speed walk animation sliding at half
speed. It is review item 2 (blend state) with item 3 (phase sync) and the "animation
speed scaling" from 012's future list.

Action distances (roll length, sidehop, jump height) are either set in meters or as
multiples of run speed from the table in section 2. Recommend the ratios: tune the run
once, and the rest follow.

**The jump clips carry their own lift.** `Jump` raises the hips from 0.73 to 1.27 and
`Jump_Idle` holds the feet 0.86-1.09 above the ground (model units). A physics jump on
top of that would lift the soldier twice. Either the jump stays animation-only (no
landing on things), or the animator locks the root bone's vertical movement during the
jump clips and the controller supplies the height (012 item 6's B2 hook, vertical
instead of horizontal). Recommend the lock, since lock-on hops and ledges will want the
controller to own height.

## 4. Architecture

Two state machines, each with one job:

```
core.Input ─► Character controller (gameplay FSM) ─► Animation FSM ─► Animator
               mode, speed, facing, position           clips, blends,
                         │                             crossfades, rates
                         └──► Camera (mode follows the controller's mode)
```

- **The controller** owns the character's motion: its mode (ground, roll, air, locked-on,
  aiming, action), its speed, facing, and position. It reads input and decides.
  A Zig tagged union with a `switch` per mode: each mode's `update` returns the next
  mode. No framework.
- **The animation FSM** stays request-based, as plan 012 decided: the controller asks for
  `.run` with parameter 3.2 m/s; the FSM blends, crossfades, and sets rates. It never
  moves the character.
- **The camera** takes the controller's mode (follow, lock-on, first person).

Today jump is only an animation and roll would be too; in this split, the controller
owns that a roll moves 3 m and the FSM owns how it looks.

**Programming other characters** is then data: a `MoveTuning` struct (height, run speed,
acceleration, turn rates, ratios for each mode, roll and jump values) and a state table
mapping controller modes to clips. The spacesuit gets a second tuning and table; a
character without a roll clip leaves the roll mode out.

**Where the code lives.** The controller starts in `examples/bullets/objects/`
(`character_control.zig` grows into it, and both bullets characters use it), and moves to
`src/core` when a second app (level_01, angrybot) needs it. FSM changes go in core now.

## 5. Motion Spec

All rates per second; everything frame-rate independent through `core.motion`.

### 5.1 Ground (no lock-on)

```
move        = cameraRelativeMove(left_stick, camera.yaw)     // length 0..1
throttle    = |move|
stick_yaw   = heading of move
error       = wrapAngle(stick_yaw - facing)

if throttle == 0:
    target_speed = 0
elif speed > skid_min_speed and |error| > skid_angle (about 135°):
    skid: target_speed = 0 with skid_decel; turn when speed is low      // brake slide
else:
    facing = moveTowardAngle(facing, stick_yaw, turn_rate(speed) * dt)
    target_speed = throttle * run_speed * max(cos(error), 0)            // slow on sharp turns

speed    = moveToward(speed, target_speed, (accel if speeding up else decel) * dt)
position += forward(facing) * speed * dt
```

- `turn_rate` higher when slow than when fast (e.g. 900°/s at a walk, 540°/s at a run,
  to tune), so a standing character pivots and a running one arcs.
- Acceleration short: about 0.15 s from stand to run; deceleration shorter. Wind Waker
  feels responsive, not heavy.
- No skid clip in the toon kit. A skid is a fast deceleration with the run clip slowing
  through the blend, then a turn in place; add a lean (a few degrees of tilt on the model
  transform) if it needs to read as a brake.
- Animation: one blend state over speed: idle (0) ↔ walk ↔ run, rates per section 3.4.

### 5.2 Lock-on (Z-targeting) (deferred, section 9)

- **Hold LT** (question 1) to lock onto the nearest target in a cone in front of the
  camera, within a range (e.g. 25 m). The facing tracks the target (fast `dampAngle`).
- Stick axes in the target frame: forward/back moves toward/away at 0.71 / 0.88 × run;
  left/right orbits the target at 0.71 × run (move tangentially, then correct the radius
  so the circle doesn't spiral out).
- **No target**: LT still recenters the camera behind the character and keeps the facing
  fixed, so the stick strafes ("parallel" mode). That is the Wind Waker behavior that
  makes LT useful everywhere.
- Actions while locked: A + left/right is a sidehop, A + back a backflip (if clips allow,
  section 8), A + forward a roll toward the target.
- Animation: forward = Walk_Shoot / Run_Shoot (gun raised, facing the target), backward
  = the walk clip at a negative rate, sideways = see section 8.

### 5.3 Roll (deferred, section 9)

- A while moving above walking speed: speed jumps to 1.53 × run, eases to 0.29 × run over
  the roll, direction = facing (a little steering, e.g. 90°/s).
- Not interruptible; a press in the last ~0.15 s queues another roll (input buffer).
- No roll clip in the toon kit (section 8, question 2).

### 5.4 Jump and air

- Jump button (question 5): vertical speed for a set jump height (meters), gravity from
  the tuning, horizontal speed kept, small air control. `Jump` on takeoff, `Jump_Idle`
  while airborne, `Jump_Land` on touching the ground: the landing is a condition (ground
  contact), not the end of a clip, so the controller requests it.
- With the root-height lock from section 3.4.

### 5.5 First-person aim

- Enter: LT (section 9). The camera eases from the follow
  position to the eye (about 0.2 s, `dampVec3`), and the character model is hidden once
  the camera is inside the head.
- Aim: right stick yaws and pitches the view (`YawPitchAim`, limits about ±80° pitch);
  the character's facing follows the view's yaw.
- Moving: Wind Waker stands Link still while aiming; a shooter usually allows a slow walk
  (question 4).
- Fire: RT, along the view's center from the eye; a crosshair drawn with ImGui. Bullets
  from `bullet_system.zig`.
- Exit: the same button, or B; the camera returns behind the character.

### 5.6 Input buffering and priorities

Every action button press is held for ~0.15 s; if the action is not allowed yet (mid
punch, mid roll), it fires as soon as it is. This one rule covers roll chains,
punch-into-roll, and pressing jump just before landing. Ordering per frame: damage /
death (`forceState`), then actions, then movement.

## 6. Camera Spec

`motion.FollowCamera` covers the first mode. The others are additions:

| Mode | Behavior |
|---|---|
| Follow (default) | The current leash. The camera is dragged by the character and doesn't swing behind on its own; right stick turns it. Distance about 3.5 × height. |
| Recenter | Tap LT with no target: swing behind the facing (exists as `recenter_yaw`), quick (about 0.25 s). |
| Lock-on | Focus between the character and the target (about a third of the way), camera behind the character on the line to the target, a little wider; right stick ignored. |
| First person | At the eye, yaw and pitch from the aim; the transition in and out damped. |

The camera reads the controller's mode; the controller doesn't move the camera. Camera
collision with walls is out of scope until there are walls.

## 7. Animation FSM Changes

In order of need. Items 1 to 4 are plan 012's open review items.

1. **Fading list** (item 1): keep a small array of fading-out clips (each with its weight
   and its decay) instead of one `previous_state`, so a request mid-crossfade doesn't pop.
   Required before anything else: lock-on, rolls, and skids switch states quickly.
2. **The FSM owns each clip's time.** Today the clip time comes from
   `frame_time - state_start`, so a clip can't play faster or slower. Advance each active
   clip's time by `dt × rate`, and pass it to the animator (through `offset` /
   `optional_start`, or a direct time on `WeightedAnimation`). This enables rates,
   negative rates (walking backward), and phase sync.
3. **Blend state** (item 2): a state with several clips placed along one parameter
   (speed): `blend_1d: []const BlendPoint` where a point is `{ clip, at, authored_speed }`.
   `setParameter(speed)` picks the two neighbors and their weights and sets the rate
   (section 3.4).
4. **Phase sync** (item 3): clips in a blend (and walk ↔ run crossfades) share a
   normalized phase (0..1 over the cycle), so the feet stay in step when walk (1.0 s)
   blends into run (0.733 s). Requires the clips to start on the same foot; checked for
   the toon kit when implemented.
5. **Time queries and events**: `normalizedTime()` and `passed(0.4)` ("crossed 40% of the
   clip this frame") for a punch's hit frame, a shot's muzzle flash, footsteps. A query,
   not callbacks.
6. **Root lock** per state: `root_lock: { .horizontal, .vertical }` on a named root bone,
   applied by the animator (012 item 6 B2, and the jump lift in section 3.4).
7. Scoped log instead of `std.debug.print` (item 4, STYLE section 7).

Not needed yet: transition graphs (the controller decides), animation layers (upper /
lower body). Layers would become needed for "shoot while strafing" with clips that don't
exist as full-body clips; the toon kit has the full-body shooting clips we need.

Sketch of a state after 2 to 6:

```zig
pub const StateConfig = struct {
    motion: Motion, // .{ .clip = 13 } or .{ .blend_1d = &locomotion_points }
    repeat: AnimationRepeatMode,
    crossfade_in: f32,
    interruptible: bool,
    return_state: ?StateEnum,
    rate: f32 = 1.0,
    sync: bool = false,
    root_lock: RootLock = .{},
};
```

## 8. The Soldier's Clips and the Gaps

`Character_Enemy.gltf` and `Character_Soldier.gltf` have the same 17 clips:

| Need | Clip | Fit |
|---|---|---|
| Idle, walk, run | Idle, Walk, Run (and Run_Gun with the gun held) | Good |
| Lock-on forward | Walk_Shoot, Run_Shoot | Good: gun up, facing forward |
| Lock-on backward | Walk at a negative rate | Fine for a toon |
| Lock-on strafe | none | **Gap** |
| Roll | none | **Gap** |
| Sidehop / backflip | none (Jump could stand in for a sidehop) | **Gap** |
| Jump / air / land | Jump, Jump_Idle, Jump_Land | Good, with the root lock |
| Melee | Punch | Good (Knife / Shovel weapons exist as nodes) |
| Aim / shoot standing | Idle_Shoot (0.37 s, loops as automatic fire) | Good |
| Crouch | Duck (one-shot 1.67 s: down and up) | One-shot only; a held crouch needs it frozen at its low point |
| Hit, death | HitReact, Death | Good |
| Skid | none | Procedural (section 5.1) |

Ways to cover the gaps without new art, cheapest first:

- **Strafe**: play Walk_Shoot with the model yawed up to 45° toward the move direction
  while the gun points at the target ("crab walk"); reads fine on a chunky toon at
  strafe speed. Or angrybot's approach (blend directional clips), which needs the clips.
- **Roll**: a dash (Run at 1.5 × rate with a forward lean) or a cartoon roll (Duck's low
  pose held while the model spins 360° about its right axis over 0.5 s, the controller
  moving it). The spin is Wind Waker's look; worth a quick try.
- **Sidehop**: Jump's takeoff + Jump_Land with the controller moving sideways.

New clips (Mixamo, Quaternius) would need retargeting onto this rig, which the engine
doesn't do; that's a separate project (question 2).

## 9. Decisions (John, 2026-10-04)

The game is **tower attack** (the reverse of tower defense): the player is the captain of
a squad of soldiers attacking a tower. Controlled mayhem, lots happening at once, so
looks and responsiveness matter more than exact animation blending (see
`docs/plans/tower_attack_spec_notes.md`).

- **The squad follows the captain** where he runs, and **shoots where he shoots**.
- **LT switches to first person.** In first person: left stick moves, right stick aims,
  RT fires. After a couple of the captain's shots at one spot, the squad starts firing at
  that spot too, with jitter.
- **Current animations only** for now; more may come later.
- **Jump now.**
- The three toon models (Soldier, Enemy, Hazmat) differ only in appearance: same rig,
  same clips, same measurements.
- **Targets are turrets** of different sizes in a **new scene**; they react to hits,
  starting with tiny explosions where a bullet strikes.
- **Scale**: the recommendation (1 unit = 1 m, the soldier 1.8 m, scale 0.79).

Second round (John, 2026-10-04):

- **Squad of 6**, undisciplined: they loosely cluster near the captain, move a bit
  randomly, and can **panic and flee**. Steering behaviors (boids style): sensing each
  other, with chase, cluster, and flee.
- **Mortar shells fall slowly enough to give warning**; explosions near the squad make
  them scatter.
- **Shooting turrets traverse slowly, firing as they turn**, so the player has time to
  react and run.
- **First person only for shooting**, crosshair only. Firing from the hip would need a
  mode switching the right stick from camera to aim; not now.
- **The captain is the Soldier model**; the squad is a mix of Enemy and Hazmat, so the
  player can always pick out the captain.
- All the numbers are tuned later.

What changes in the spec:

| Section | Change |
|---|---|
| 5.2 Lock-on | **Deferred.** LT is first person; the squad's focus fire replaces lock-on as the way to concentrate on a target. Lock-on can come back on another button if wanted. |
| 5.3 Roll | Deferred (no clip, not asked for). |
| 5.4 Jump | Now. Animation-only on the flat floor (the clips carry the 0.7 m lift at scale 0.79); the root lock waits until there is something to jump onto. |
| 5.5 First person | Moving allowed: left stick strafes relative to the view (walk / run clips under the hidden model, so the squad sees the captain move normally). Crosshair only, no weapon in view. No firing outside first person. |
| 6 Camera | Follow and first person only; no lock-on mode. |
| 7 FSM | Keep 1 (fading list: pops show even in mayhem, and squads switch states constantly), 2 (FSM-owned clip time and rate: rate matching is cheap and keeps a dozen soldiers from skating), 5 (time queries, for the shot frame). **Drop for now**: 3 (blend state) and 4 (phase sync); walk / run by a stick threshold with a crossfade and a matched rate is enough. 6 (root lock) waits with the jump. |
| 10 Squad | Formation slots replaced by steering behaviors and a mood per member. |

## 10. Squad Spec

### 10.1 Steering behaviors, not formation slots

Boids (Craig Reynolds, 1987) is three rules for a flock: separation, alignment,
cohesion. His later "Steering Behaviors for Autonomous Characters" (GDC 1999) adds the
ones a squad needs: seek, arrive, flee, evade, wander. Each behavior returns a desired
velocity; a member adds them up with weights. Six members and a captain is 42 pairs a
frame, so no spatial structure is needed.

Behaviors per member, with what each one does here:

| Behavior | Pulls toward / away from | Notes |
|---|---|---|
| **Arrive** (chase) | Its own spot near the captain | The spot is the captain's position plus a personal offset that wanders slowly (2-4 m, mostly behind), so the cluster is loose and shifting. Arrive slows down inside a radius, so members drift to a stop instead of orbiting the spot. |
| **Separation** | Away from members closer than ~1 m | Strength grows as they get closer. Includes the captain. |
| **Cohesion** | Toward the squad's center | Weak; keeps strays from wandering off. |
| **Alignment** | The neighbors' average heading | Weak or off; a disciplined squad has it, this one barely. |
| **Wander** | A slowly drifting direction | The randomness. A heading that drifts smoothly (a random target angle every second or two, approached with `dampAngle`), not new noise each frame, which would jitter and depend on the frame rate. |
| **Flee** | Away from a threat point | Explosions, incoming shells' predicted impact points (`ballistics.positionAt`), turret fire landing nearby. Strength falls off with distance. |
| **Stay out of the line of fire** | Out of a corridor in front of the captain's aim | Only in first person: members step out of the lane the captain is shooting down. Without it, the cluster behind and around him walks into his shots. |

The sum is a desired velocity. It does **not** move the member directly: it goes into
the same ground motor as the captain (section 5.1), as the "stick" (direction and
throttle). The motor's turn rate and acceleration turn a twitchy sum into a character
who turns, arcs, and picks walk or run, and the animation follows. This is the step
that makes boids look like people instead of a swarm. The desired velocity is also
damped (`dampVec3`, short) before the motor, since weighted sums can flip from frame to
frame when two behaviors pull against each other.

### 10.2 Mood: the members' state machine

Each member has a **fear** value (0 to 1) and a mode. The mode sets the behavior
weights:

| Mode | Weights | Enter when | Leave when |
|---|---|---|---|
| **Follow** | arrive, separation, cohesion, wander | default | |
| **Engage** | arrive (weak), separation; face and fire at the focus point | the captain sets a focus point (10.3) | focus point gone |
| **Scatter** | flee strong, separation; run | fear above the member's own threshold | fear back below about half the threshold |
| **Regroup** | arrive strong, run | leaving scatter | close to the captain again: follow |

- **Fear rises** with explosions nearby (more for closer and bigger), incoming shells
  aimed near the member (the warning: they react to the predicted impact before it
  lands), and turret fire hitting close. **Fear decays** steadily (frame-rate
  independent, `motion`), faster when near the captain: he steadies them.
- **Each member has a random courage** (its scatter threshold) and random reaction
  delays, so a blast makes the jumpy ones run first and the steady ones hold; that's
  the undisciplined look. Fear also spreads a little: a member near a fleeing member
  gains some fear.
- Scatter is directional: away from the threat, plus a random angle (±40°), so they fan
  out instead of running in a line.

### 10.3 Focus fire

- The captain's shot hits a point (the ray from the eye, section 11.2). Shots within
  ~2 m of each other within ~1.5 s count as **one focus point** (their average).
- After **2 shots** on a focus point, members in **follow** switch to **engage**: each
  turns to it, waits its own delay (0.2 to 0.8 s, so they open up raggedly), and fires
  bursts with `core.ShotJitter` at a random rate. Scattering members don't shoot.
- The squad stops when the captain hasn't fired at the point for ~3 s, or the target is
  destroyed, or the captain is far from them (back to follow).
- Animation: Idle_Shoot when still, Walk_Shoot / Run_Shoot when moving.

### 10.4 Code

- `src/core/steering.zig`: the behaviors as plain functions (`seek`, `arrive`, `flee`,
  `separation`, `cohesion`, `alignment`, `Wander`), each returning a desired velocity.
  Testable on their own, like `core.motion`; reusable for enemies and civilians later.
- The squad in bullets: `Squad` owns 6 members (`ModelInstance` each, Enemy and Hazmat
  mixed), their motors, moods, animation state machines, and the focus point; a tuning
  struct holds the weights, radii, fear rates, and delays. Moves to a game when there is
  one.
- An ImGui panel for tuning: the weights and radii live, plus debug lines (each member's
  desired velocity, its spot, its fear as color).

## 11. Target Range Scene

A new scene in bullets (next to the debug and gallery scenes): a field with turrets of
several sizes at different distances, the captain and the squad at one end.

### 11.1 Turrets

- Reuse `examples/turrets`' turret shapes and types (`turret_types.zig`: gatling,
  cannon, sweeper, mortar, battery) at three or four sizes (scale 0.5 to 3).
- Each turret has a hit volume (a sphere or two, or a box) in meters, sized with it.
- On a hit: a tiny explosion at the strike point, a brief flash, a small recoil / shake
  of the turret (a damped offset, `core.motion`).
- **They shoot back, slowly and readably:**
  - **Gun turrets** traverse slowly (low `YawPitchAim` speeds) toward the squad's
    center or a chosen member and **fire while turning**, so the stream walks toward the
    squad and the player can see it coming and run. `FireControl` with no "on target"
    requirement, jittered.
  - **Mortars** fire high arcs with long flight times (`ballistics.launchVelocity` with
    a flight time of 3-4 s), and the predicted impact point gets a **warning marker** on
    the floor (a ring that grows or darkens as the shell nears). The squad reads the same
    prediction (10.2).
- **Health and destruction**: health shows as the base's color (green, yellow, red);
  at zero the turret explodes (a big `explosions.add`) and is gone.
- Hits on people: the captain's is a camera shake, a squad member's a flinch
  (HitReact); no health for people yet.

### 11.2 Shots

- The captain's shot: a ray from the eye along the view center. **Visible tracers**
  (fast projectiles, ~80 m/s, stepped with `core.ballistics.step`, tested against hit
  volumes and the floor each frame, segment by segment) read better in mayhem than
  hitscan and cost little. Tracers for the captain, the squad, and the gun turrets.
- Strike: on a turret, a tiny explosion and the turret's reaction; on the floor, a puff
  and a small mark.
- Explosions: `examples/turrets/explosions.zig` (fireball, burn mark) already does this
  at any radius. It moves to `src/core/gameplay/` (11.3) so bullets and turrets share
  one copy; a strike is `explosions.add(point, 0.15)`.

### 11.3 `src/core/gameplay/`: game building blocks

John's suggestion (2026-10-04): a folder in core for game-type pieces, apart from the
engine (rendering, assets, animation, input). Reached as `core.gameplay.<file>`
through `gameplay/root.zig` (with `refAllDecls` so its tests run, as `utils/root.zig`).

| File | From | Contents |
|---|---|---|
| `ballistics.zig` | `src/core/ballistics.zig` | `step`, `positionAt`, `launchVelocity`, `leadPoint` |
| `fire_control.zig` | `src/core/fire_control.zig` | `FireControl`, `ShotJitter` |
| `explosions.zig` | `examples/turrets/explosions.zig` | Fireballs and burn marks; its shader (`basic_shape.wgsl`) moves to `src/core/shaders/` |
| `projectiles.zig`, `turret.zig`, `turret_types.zig` | `examples/turrets/` | Tracers and shells, `Turret` (now with a `size`), the turret types; `projectiles.wgsl` to `src/core/shaders/` (moved in C0 so bullets can use the turrets: an app can't import another app's files) |
| `steering.zig` | new (10.4) | Seek, arrive, flee, separation, cohesion, alignment, wander |
| later | new | Tracers / projectiles with hit tests, hit volumes, fear and morale if it outgrows the squad |

The rule: `gameplay` may use the rest of core; nothing outside `gameplay` in core imports
it. Callers change from `core.ballistics` to `core.gameplay.ballistics` (turrets,
bullets, shadows, camera_rig, level_01 as they use them), and CLAUDE.md's references with
them. Done as its own step before phase C, with no behavior change: the turrets example
is the check.

## 12. Phases

Each phase ends with a CHANGELOG entry and a commit.

| Phase | Work | Result |
|---|---|---|
| A | Units and scale: 1 m per unit, soldier height and scale, measured walk / run speeds; FSM fading list, FSM-owned clip time with rate matching; the captain loads `Character_Soldier.gltf` | Soldier at 1.8 m, feet don't skate, no pops |
| B | Ground motor (section 5.1) replaces `character_control.drive`; jump (animation-only) | The Wind Waker ground feel |
| C0 | `src/core/gameplay/` (11.3): move ballistics, fire control, explosions; no behavior change | Turrets example unchanged |
| C | Target range scene: turrets at several sizes, hit volumes | A place to shoot |
| D | First person: LT, camera transition, hidden model, aim, crosshair, tracers, strike explosions, turret reactions | The captain shoots and hits |
| E | `core.steering`; squad of 6 following (follow mode), tuning panel and debug lines | The squad runs with the captain |
| F | Squad focus fire (engage mode) | The squad shoots where the captain shoots |
| G | Turrets fire back (slow traverse, slow mortars with markers); fear, scatter, regroup | Mayhem |

## 13. Questions Answered (John, 2026-10-04)

- **Gameplay folder**: `src/core/gameplay/` as a folder in core. No `aim.zig`:
  `YawPitchAim` and `Sweep` stay in `motion.zig`.
- **Hits on people**: the captain hit is a camera shake (`motion.Shake`); a squad member
  hit is a flinch (HitReact). No health or death for people yet.
- **Turrets are destroyable.** Health shows as the base's color: green, yellow, red,
  then an explosion.
- **Tracers pass through** squad members (no friendly fire).
- **Turrets are basic shapes** at different sizes.
- Phase A started 2026-10-04.
