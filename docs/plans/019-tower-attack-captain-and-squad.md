# Plan 019 - Tower Attack: Captain and Squad

## Status: Active (started 2026-10-04; phases A-G done)

Grew out of [the Wind Waker review](../reviews/2026-10-04-link-style-controller-review.md)
(Grok's notes on Link's control in The Wind Waker, reviewed against the engine), which
holds the background this plan builds on: units and the soldier's measurements (section
3), the controller / animation / camera architecture (4), the motion spec (5), the camera
spec (6), the animation state machine changes (7), and the toon kit's clips (8). This
plan holds the decisions, the specs as built, and the phases. Plan 012 (the animation
state machine) is parked with its own leftover items.

## Context

The game is **tower attack** (the reverse of tower defense): the player is the captain of
a squad of soldiers attacking a tower. Controlled mayhem, lots happening at once, so
looks and responsiveness matter more than exact animation blending (see
`tower_attack_spec_notes.md`).

The test bed is the **range scene** in `examples/bullets` (`zig build bullets-run -- -s
range`): the captain (the toon Soldier), his squad of six, and turrets of several sizes.

## Decisions (John, 2026-10-04)

- **Third-person control like Link's in The Wind Waker**: camera-relative analog
  movement, the character moving the way it faces and turning toward the stick, a leash
  camera.
- **The squad follows the captain** where he runs, and **shoots where he shoots**.
- **LT switches to first person.** In first person: left stick moves, right stick aims,
  RT fires. After a couple of the captain's shots at one spot, the squad fires at that
  spot too, with jitter. **First person only for shooting**, crosshair only (firing from
  the hip would need a mode switching the right stick from camera to aim; not now).
- **Current animations only** for now; more may come later. **Jump now**
  (animation-only on the flat floor).
- The three toon models (Soldier, Enemy, Hazmat) differ only in appearance: same rig,
  same clips, same measurements. **The captain is the Soldier**; the squad is a mix of
  Enemy and Hazmat, so the player can always pick out the captain.
- **Scale**: 1 unit = 1 m; the soldier is 1.8 m (scale 0.783 from its 2.30 model units).
- **Squad of 6**, undisciplined: loosely clustered near the captain, a bit random, and
  able to **panic and flee**. Steering behaviors (boids style): chase, cluster, flee.
- **Targets are turrets** of different sizes, as basic shapes, in a new scene. They
  react to hits (a tiny explosion at the strike point) and are **destroyable**: health
  shows as the base's color (green, yellow, red), then an explosion.
- **Turrets fire back, slowly and readably**: gun turrets traverse slowly and fire as
  they turn, so the player can react and run; **mortar shells fall slowly enough to give
  warning**, and explosions near the squad make it scatter.
- **Hits on people**: the captain's is a camera shake (`motion.Shake`); a squad member's
  is a flinch (HitReact). No health or death for people yet.
- **Tracers pass through** squad members (no friendly fire).
- **`src/core/gameplay/`**: a folder in core for game building blocks (below). No
  `aim.zig`: `YawPitchAim` and `Sweep` stay in `motion.zig`.
- **Deferred**: lock-on (Z-targeting; the squad's focus fire is the way to concentrate
  on a target for now), the roll (no clip), the root-motion lock for jumps (until there's
  something to jump onto), blend spaces and phase sync in the animation state machine.
- All the numbers are tuned later, live in the ImGui panels.

## Design As Built

### Captain (phases A, B, D)

- **Animation state machine** (`src/core/animation_fsm.zig`): each playing clip is a
  track with its own clock; an interrupted crossfade fades every playing clip out from
  where it is (no pops); `setPlaybackRate` (negative plays backward).
- **Walk and run speeds from the clips**: the clips' measured foot speeds (walk 2.6, run
  4.5 model units per second; review section 3.3) times the scale, with the clip rate
  matched to the actual speed (`toon_soldier.zig`).
- **Motor** (`examples/bullets/objects/character_control.zig`): `direct` and
  `wind_waker` styles, switchable with K. Wind Waker: moves the way it faces; the facing
  turns toward the stick at a set rate (900°/s standing, 540°/s at a run); stick travel
  is the throttle; speed builds in 0.15 s, falls in 0.1 s; sharp turns slow it; a
  reversal at speed skids to a stop first. `strafe` for first person (move along the
  stick, face the view).
- **Jump**: Jump (takeoff), Jump_Idle (0.2 s in the air), Jump_Land, carrying the speed it
  had. Animation only: the clips carry the lift.
- **First person** (`first_person.zig`): LT or F held; the camera eases to the eye in
  0.2 s, the model hides past 60% of the way, the right stick or arrows aim (pitch
  ±80°), the captain faces the view. RT or the left mouse button fires tracers (6 per
  second, slight jitter) from below right of the eye, **aimed at what the crosshair is
  on** (the view's ray cast against the turrets' hit spheres and the floor), so they land
  on it at any distance. ImGui crosshair.

### Turret range (phases C0, C, D)

- **`src/core/gameplay/`**: `ballistics`, `fire_control` (`FireControl`, `ShotJitter`),
  and from `examples/turrets`: `explosions`, `projectiles`, `turret` (now with a `size`
  and `setPartColor`), `turret_types`; shaders in `src/core/shaders/`. The turret files
  moved too because an app can't import another app's files. The rule: `gameplay` may
  use the rest of core; nothing outside it in core imports it.
- **`Projectiles.updateTargets`**: shots against several sphere targets, reporting each
  ended shot (where, which target, into the floor).
- **The range** (`scenes/range_scene.zig`): six turrets (gatling, cannon, sweeper,
  mortar, battery) at sizes 0.6 to 3, 10 to 48 m out; they watch the captain but hold
  fire for now. `TargetTurret` (`objects/target_turret.zig`): health 10 per unit of size
  shown on the base, a strike explosion, flash, and shake per hit, a blast at zero.
  R resets.

### Squad (phases E, F)

`examples/bullets/objects/squad.zig`, steering in `src/core/gameplay/steering.zig`.

- **Steering behaviors, not formation slots** (Reynolds, GDC 1999; boids, 1987): each
  behavior returns a desired velocity, a member sums them with weights:
  - **Arrive** at its own spot: behind the captain to one side, 30-110° from straight
    behind (the gap keeps the lane behind him clear for the follow camera), 2-4.5 m out.
    Spots drift to new random places every few seconds, only while the captain moves.
  - **Reaction time**: where a member thinks the captain is trails him by its own
    0.15-0.6 s.
  - **Separation** (by rank, below), weak **cohesion** toward the middle, **wander**
    (a heading that drifts smoothly) while moving.
- **The sum steers the member's motor like a stick**, damped first, with a dead zone and
  a minimum throttle, so members turn, arc, and walk or run like the captain instead of
  sliding.
- **Settling** (added 2026-10-04 when a halted squad twitched): a member that reaches its
  spot and slows below 0.3 m/s settles, and stays until its spot is 1.5 m away; settled,
  it steps aside only for someone within 0.7 m. **Members yield by rank** (captain,
  then member 1, 2, ...): each keeps apart only from those ranked above it, so pushes go
  one way and can't bounce back and forth (a checkbox brings back pushing both ways).
- **Focus fire**: each captain shot reports what the crosshair is on (not the sky);
  shots within 2 m of each other, each within 1.5 s of the last, make a focus point
  (their average). After 2, every member keeps following but faces the point (gun up:
  Idle_Shoot, Walk_Shoot, Run_Shoot), waits its own 0.2-0.8 s, and fires bursts at its
  own cadence; they stop 3 s after the captain's last shot at it, or when its turret is
  destroyed. Squad tracers are redder and hurt turrets.
- Panels: the soldier (control, speeds, motor), the squad (every tuning value, the
  focus, settled count, debug lines: spot yellow, steering cyan, aim red), the range
  (turret health, shots and hits).

### Turrets fire back (phase G1)

- **Range turret types** (`objects/range_turret_types.zig`): the core types slowed down.
  Gun turrets (gatling, cannon, sweeper) slew at 18-30°/s, fire while turning, no lead,
  3° spray (cannon 2°), in bursts (gatling 6 every 1.2 s, cannon 3 every 1.6 s) or a
  slow 12°/s sweep at 8 shots per second. The mortar fires a shell every 4 s with a
  3.5 s flight time and a 2.5 m blast; the battery sweeps 4 s, lobs two shells, waits
  2 s.
- **Detection ranges** (added 2026-10-04 after testing: every turret within 45 m fired
  on the squad all the time, so there was no way to avoid being hit): each turret
  watches the ground within its own range (gatling 0.6: 14 m, cannon and gatling 1.0:
  16, sweeper 18, mortar and battery 24; the captain starts outside all of them), picks
  someone inside at random every 4-9 s, keeps on them until they're 10% past the edge,
  and holds fire with nobody inside. A thin ring on the floor shows each range, brighter
  while it has someone. Panel: show ranges, a scale for all of them; T toggles fire.
  People are spheres 0.45 m in radius, 1 m up.
- **`Turret.updateAim` / `fireDueShots`**: `update` split so the range moves each
  turret's shots itself against everyone (`Projectiles.updateTargets`).
  `TargetTurret.update` reports `Strikes`: a tracer on someone, or any shell's blast.
- **Warnings** (`objects/shell_warnings.zig`): a red ring the size of the blast where
  each shell will burst, from launch, filling from the middle and brightening as it
  nears; the point from `Projectiles.predictedEnd` (exact under constant gravity).
  `core.shapes.createRing` (a flat annulus) added for it.
- **Hits**: a tracer on the captain adds 0.3 trauma to the camera shake (`motion.Shake`
  on the frame's view), a blast 0.8, a near miss up to half that out to two blast radii
  past its edge. A member hit flinches (`ToonSoldier.flinch`: HitReact, `forceState`),
  standing and holding fire until it's over. The range panel counts hits on the captain
  and the squad.

### Fear, scatter, regroup (phase G2)

As the spec below, in `objects/squad.zig`: each member has a fear (0 to 1), a courage
(0.35-0.85, picked at start), and a mood (follow, scatter, regroup; engaging is follow
with a focus).

- **Fear rises** with a blast (0.9 at its center, to zero at 3 blast radii), a hit
  (0.35, with the flinch), a tracer into the floor within 2 m (0.08), standing under an
  incoming shell's warning (0.8 per second at its center, out to 1.5 blast radii), and a
  member running away within 3 m (0.25 per second, only to those not scattering). **It falls** 0.15 per second, 2.5
  times faster within 5 m of the captain.
- **What a member runs from** is the source of its biggest recent fright and how far
  that reaches: the blast point (3 blast radii), the predicted burst (1.5), or the
  turret that fired the tracer (its detection range).
- **Scatter** above its courage: runs away from the threat, turned by its own angle
  (±40°), until 3 m past its reach, holding fire. A scattering member doesn't flinch;
  a following one flinches at most once every 2 s. **Regroup** below half its courage: runs
  back to its spot; within 2 m of it, follows again.
- Debug lines: a fear bar over each head (green follow, red scatter, magenta regroup),
  orange to the threat while scattering. The squad panel lists each member's mood, fear,
  and courage, and every fear setting.
- **Cylinder fix** (same step): `createCylinder` halved the radius it was given (from
  redfish_gl_zig); it now builds the radius asked for, and every caller passes half its
  old value, so nothing changed size. The turret's rocket nose keeps its own radius
  (twice the body's).

## Phase G Spec: Turrets Fire Back, Fear and Scatter

### Turrets

- **Gun turrets** traverse slowly (low `YawPitchAim` speeds) toward the squad's center
  or a chosen member and **fire while turning**, so the stream walks toward the squad
  and the player can see it coming and run. `FireControl` with `while_turning`,
  jittered. Their tracers test against the captain and the members (spheres).
- **Mortars** fire high arcs with long flight times (`ballistics.launchVelocity` with a
  flight time of 3-4 s), and the predicted impact point gets a **warning marker** on the
  floor (a ring that grows or darkens as the shell nears). The squad reads the same
  prediction.
- **Hits on people**: the captain's is a camera shake (`motion.Shake`), a member's a
  flinch (HitReact, `forceState`).

### Mood: the members' state machine

Each member has a **fear** value (0 to 1) and a mode; the mode sets the behavior weights:

| Mode | Weights | Enter when | Leave when |
|---|---|---|---|
| **Follow** | arrive, separation, cohesion, wander | default | |
| **Engage** | as follow; face and fire at the focus point | the captain sets a focus point | focus point gone |
| **Scatter** | flee strong, separation; run | fear above the member's own threshold | fear back below about half the threshold |
| **Regroup** | arrive strong, run | leaving scatter | close to the captain again: follow |

- **Fear rises** with explosions nearby (more for closer and bigger), incoming shells
  aimed near the member (the warning: they react to the predicted impact before it
  lands), and turret fire hitting close. **Fear decays** steadily (frame-rate
  independent), faster when near the captain: he steadies them.
- **Each member has a random courage** (its scatter threshold), so a blast makes the
  jumpy ones run first and the steady ones hold. Fear spreads a little: a member near a
  fleeing member gains some.
- Scatter is directional: away from the threat (`steering.flee`), plus a random angle
  (±40°), so they fan out instead of running in a line. Scattering members don't shoot.
- Debug lines: fear as color.

### Not yet built from the squad spec

- **Stay out of the line of fire**: in first person, members step out of a corridor in
  front of the captain's aim. With tracers passing through people it's cosmetic; worth
  adding if members standing in the stream looks wrong.

## Phases

Each phase ends with a CHANGELOG entry and a commit.

| Phase | Work | Status |
|---|---|---|
| A | Units and scale: 1 m per unit, soldier height and scale, measured walk / run speeds; FSM fading tracks, FSM-owned clip time, rate matching; the captain loads `Character_Soldier.gltf` | ✅ 2026-10-04 |
| B | Wind Waker ground motor (switchable with the old control); jump (animation only) | ✅ 2026-10-04 |
| C0 | `src/core/gameplay/`: ballistics, fire control, explosions, projectiles, turret, turret types; no behavior change | ✅ 2026-10-04 |
| C | Range scene: turrets at several sizes, hit spheres, health colors, hit reactions, destruction | ✅ 2026-10-04 |
| D | First person: LT / F, eased camera, hidden model, aim, crosshair, tracers aimed at the crosshair's target | ✅ 2026-10-04 |
| E | `core.gameplay.steering`; squad of 6 following, settling, rank yielding; tuning panel, debug lines | ✅ 2026-10-04 |
| F | Squad focus fire | ✅ 2026-10-04 |
| G1 | Turrets fire back (slow traverse, slow mortars with warning rings); hits on people (shake, flinch); detection ranges | ✅ 2026-10-04 |
| G2 | Fear, scatter, regroup | ✅ 2026-10-04 |

## Notes

**2026-10-04**: Plan started from the review's sections 9-13 (moved here). Phases A-F
done the same day; each tested by John on the controller. Tuning notes from testing:
the halted squad twitched until settling and rank yielding were added (E); close-up
shots landed low and right until shots aimed at the crosshair's target instead of a
fixed 25 m point (D).

**2026-10-04 (G2 testing)**: scattering members froze inside a turret's range, hit over
and over, fear stuck at 1. Two causes: they ran only 10 m from the threat, and for a
tracer the threat is the turret, whose range is 14-24 m, so they stopped inside it; and
each hit forced a flinch, during which a member can't move. Fixed: a threat carries its
reach (detection range, blast or warning reach) and members run until 3 m past it;
scattering members don't flinch, following ones at most once every 2 s. Checked with a
40 s run: every scatter ended outside the threat's reach; the slow moments left are the
one flinch from the hit that starts a scatter, then the first steps.

**2026-10-04 (G2 testing)**: two members stayed out after fleeing, standing together
past the ranges, even with the captain nearby and back. Fear spread: every scattering
member frightened everyone within 3 m at 0.25 per second, more than the 0.15 decay, so
two scattered members standing together kept each other afraid and never fell below
half their courage. Fixed: fear spreads only from a member running away (above walking
speed), and only to members not scattering. Checked with a run where the turrets stop
after 15 s: all six back to following by 30 s.
