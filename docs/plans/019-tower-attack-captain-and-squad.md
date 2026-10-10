# Plan 019 - Tower Attack: Captain and Squad

## Status: Active (started 2026-10-04; phases A-J done)

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
- **Tracers pass through** squad members (no friendly fire). Changed 2026-10-06: the
  captain's tracers hit members (phase I).
- **`src/core/gameplay/`**: a folder in core for game building blocks (below). No
  `aim.zig`: `YawPitchAim` and `Sweep` stay in `motion.zig`.
- **Deferred**: lock-on (Z-targeting; the squad's focus fire is the way to concentrate
  on a target for now), the roll (no clip), the root-motion lock for jumps (until there's
  something to jump onto), blend spaces and phase sync in the animation state machine.
  Added 2026-10-06: **squad skill levels** (fire awareness first; others such as aim,
  courage, and reaction time could follow); **animation tuning** (below).
- **Gameplay first, animation good enough** (John, 2026-10-06): animation tuning comes
  later. Wanted then: an aim-only animation (gun raised while aiming without firing;
  standing aimers play Idle now, Idle_Shoot only while firing), and better aiming poses:
  how well the firing clips line up with the aim varies by weapon, from fine to poor.
- All the numbers are tuned later, live in the ImGui panels.

## Decisions (John, 2026-10-06)

- **Third-person aim replaces first person as the shooting mode.** In testing, first
  person felt like a different game: little of the squad is in view. LT now swings the
  camera low behind the captain's right shoulder; the left stick moves, the right stick
  aims, RT fires, all in third person. **First person stays as an option** (a panel
  setting picks what LT does), for later use.
- **Right shoulder**, with the side offset on a slider (0 is centered). The aim camera's
  placement (side, height, distance, pitch, swing time, follow zone, lag) is all on
  sliders, to find what feels best in play.
- **Letting go of LT**: the camera stays behind the captain's new facing and eases back
  up to the follow camera's height and distance (no swing back to its old heading).
  Changed in testing (2026-10-06): it swings back to where it was around the captain
  before aiming, reversing the swing in, at the follow camera's height and distance.
- **Aiming up and down tilts the camera too**, within its own zone and with lag, less
  than across.
- **Friendly fire from the captain only**: his tracers hit squad members; the squad's
  pass through each other and him. The squad tries to step out of his line of fire, with
  jitter: mostly out of the way, now and then in it.
- **Squad skill levels later**: keeping out of the captain's line of fire will be one of
  the skills (as a per-member value now, set at random).

## Decisions (John, 2026-10-07)

- **Try an isometric view** of the range, switched with the number keys: **1** the
  current perspective follow camera, **2** isometric. In the range scene the number
  keys are view keys; the captain's test actions on 1-7 (punch, duck, wave, yes, no,
  Walk_Shoot, Run_Shoot) go there (the gamepad face buttons still do jump, punch, duck,
  wave).
- **Aiming in isometric: both ways, as an option** to compare in play: twin-stick (the
  right stick points the aim on the ground, RT fires, the view stays isometric) or LT
  swinging into the over-the-shoulder view while held and back on release.
- **The isometric view is fixed** at one 45° angle (no rotating it).

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

- **Stay out of the line of fire**: now phase I, with friendly fire.

## Phase H Spec: Third-Person Aim (Over the Shoulder)

### Camera

- **LT held** (or F): the camera eases (about 0.3 s, smooth step) from the follow camera
  to the **aim camera**: low behind the captain, offset to his right shoulder, looking
  along his forward. Settings, all sliders: side offset (about 0.5 m right; 0 centered),
  height above the feet (about 1.7 m), distance behind (about 2.5 m), and swing time.
- **Follow zone**: the camera keeps its heading and pitch while the aim stays within a
  zone around them (about ±15° across, ±10° up and down; sliders). Past the zone's edge
  it follows the aim with lag (`dampAngle`), so small corrections move the aim on
  screen and bigger turns bring the camera around. Pitch follows like yaw, with its own,
  smaller zone and range.
- **LT released**: the camera eases back up to the follow camera's distance and pitch,
  and swings back to where it was around the captain (see the as-built notes).

### Aim and movement

- The **right stick** (or arrows) moves the aim (yaw, pitch within limits) at set
  speeds, as first person's; the captain **faces the aim** and raises his gun
  (`ToonSoldier.strafe`: Idle / Walk_Shoot / Run_Shoot); the **left stick** moves
  relative to the aim (strafing, as in first person).
- **What the aim is on**: the ray from the captain's eye along the aim, cast against the
  turrets' hit spheres and the floor (`crosshairAim`, as now). Shots leave the captain's gun and fly to that point, so
  they land on it at any distance; focus fire works as now (`Squad.reportShot`).
- **RT** (or the left mouse button) fires only while LT is held.

### Indicator

- A **faint line** from the captain's gun to the aim point.
- A **decal** where the aim is on something: a small ring on the floor, or a ring facing
  the camera on a turret's hit sphere.
- A **screen crosshair** at the aim point's projected screen position (not the screen
  center, since the aim moves within the zone). Each of the three can be turned off in
  the panel, to see which ones are needed.

### Modes

- A panel setting picks what LT does: **over the shoulder** (default) or **first
  person** (as built in phase D, unchanged).

### As built (2026-10-06)

- `objects/shoulder_aim.zig` (`ShoulderAim`, the same shape as `FirstPerson`: `update`,
  `direction`, `view`). Defaults (John's picks in testing): side 0 (centered), height
  2.0 m, distance 6.0 m, swing and turn swing 0.9 s; zone ±15° across and ±10° up and
  down, follow rate 6, camera tilt within ±30°, aim within ±60°.
- The swing goes around the captain: heading, pitch, distance, and pivot are eased
  separately, the heading on its own swing (`turn_swing_time`), easing in and out.
  While aiming, the follow camera keeps its heading; on letting go it's put at
  `returnYaw` (where it was around the captain, turned as he turned while aiming), and
  the same swings run backward. (First built as a straight blend between the two camera
  positions, with the follow camera put behind the captain on the first aiming frame,
  so the horizontal swing snapped; then letting go only rose back, behind his facing.)
- The range scene runs both modes; the one not picked eases out. Shots leave the
  captain's gun (1.2 m up, 0.25 m right, 0.5 m ahead along the aim) for what the aim is
  on, found from his eye along the aim as before.
- Indicator: khaki dashes (0.35 m on, 0.35 m off; the line shader has no blending, so
  dashes make it faint), a yellow ring (0.2 m plus 1.2 cm per meter from the camera)
  facing the camera on a turret (not on the floor), and the crosshair at the aim point's
  screen position. The aim panel: LT's mode, the three indicator checkboxes, the camera,
  zone, and aim sliders.

## Phase I Spec: Friendly Fire and the Line of Fire

### Friendly fire

- The captain's tracers are tested against the squad members' hit spheres (0.45 m,
  1 m up, as the turrets use); a tracer that strikes a member ends there. The squad's
  tracers still pass through members and the captain.
- A member hit by the captain **flinches** (`ToonSoldier.flinch`, with the flinch
  interval). No health or death. **No fear**: fear points a member away from the threat,
  and running from the captain would fight regrouping. Instead the hit makes it **extra
  careful** of the line of fire for a few seconds (no lapses, quickest reaction).
- The range panel counts friendly hits.

### Stepping out of the line of fire

- While the captain aims (either mode), his **line of fire** is a corridor from his gun
  to the aim point, about 1 m either side (each member its own width, jittered).
- A member inside it gets a **sideways push** out of it, toward the nearer side, and its
  **spot** near the captain is moved out of it too, so arriving there doesn't walk it
  back in. Scattering members ignore the corridor.

### Jitter (the skill, later)

- Each member has a **fire awareness** (0 to 1), picked at random in a high range (about
  0.8-0.95) for now; squad skill levels will set it later.
- **Late reaction**: awareness sets how soon a member notices it's in the corridor
  (about 0.2 s for the best, 0.8 s for the worst).
- **Lapses**: every couple of seconds each member rolls against its awareness; a miss
  means it ignores the corridor for 1-2 s. Rolls happen on a timer, not per frame, so the
  odds are the same at any frame rate. This gives "mostly out of the way, occasionally
  in it".
- Panel: corridor width, reaction range, lapse interval and length, each member's
  awareness; debug lines: the corridor's edges, and a mark on members in a lapse.

### As built (2026-10-06)

- `squad.zig`: `LineOfFire` (from the captain's gun to the aim point, last frame's: the
  aim is found when firing, after the squad moves), `Squad.update` takes it,
  `keepOutOfLine` per member (not while scattering), `rollLapse`, `friendlyHit`. Members
  beside or behind the gun aren't in the line. A spot inside the corridor moves to
  0.5 m past its edge; a settled member in the line unsettles.
- Defaults: corridor 1 m either side (±0.25 per member), awareness 0.8-0.95, reaction
  0.2 s (awareness 1) to 0.8 s (0), a lapse roll every 2 s (give or take half), lapses
  1-2 s, careful 3 s after a hit, step-aside push at the running speed.
- Range scene: the captain's tracers are tested against the members after the turrets;
  a hit puffs, and `friendlyHit` (flinch within the flinch interval, careful, no fear).
- **A flinch no longer stops a member** (`ToonSoldier.steer` / `steerAiming` keep
  moving through HitReact). Found in testing: a member hit in the line froze for the
  0.43 s clip plus its reaction, in a stream of 6 shots per second, and took 4-5 hits in
  a row; moving, a hit sends it out. Applies to turret hits too. Measured with fast
  half-turns while firing (80 s): 16 entries into the line, 6 hits, about 0.65 s in the
  line each time.
- Panels: the squad's "line of fire" section (friendly hits, each member's awareness as
  a slider with lapse / careful / in line, every setting); debug lines add the
  corridor's edges (orange) and a bar across the head (red in the line, white in a
  lapse). The range panel counts the captain's hits on the squad.

## Phase J Spec: Isometric View

### Views

- **1**: the follow camera, as now (LT aims over the shoulder or first person, per the
  aim panel). **2**: isometric. Switching eases between the two views (as the aim
  camera's swing) rather than cutting; the view in use shows in the range panel.
- The view keys replace the captain's number-key test actions in the range scene only.

### Isometric camera

- **Orthographic** (`core.Camera`'s `ProjectionType.Orthographic`, `ortho_scale`):
  looking 45° around and about 35° down (true isometric is 35.26°, the 2:1 pixel-art
  look 30°). Fixed heading; no rotation.
- **Perspective from a high angle** as an alternative setting (a narrow field of view),
  to compare with orthographic.
- **Follows the captain** with a little lag (`motion` damping), the view centered on
  him or shifted a little ahead of where he's going.
- Sliders: pitch, view size (`ortho_scale`; zoom), projection (orthographic /
  perspective), field of view for perspective, follow lag, look-ahead. Zoom maybe also
  on the d-pad or mouse wheel.
- Check: near / far planes with a camera far above the floor, the floor plane's edges
  in view, the detection rings and warnings reading from above, the squad debug lines.

### Moving

- The left stick moves relative to the screen (stick up moves up the screen, diagonally
  in the world): the existing camera-relative movement with the isometric camera's fixed
  heading. The Wind Waker motor as now.

### Aiming: two modes, picked in the aim panel

- **Twin-stick** (default to try first): the right stick points the aim on the ground
  around the captain (a direction; its length is not used, a dead zone keeps the last
  aim), the captain faces it and strafes (`ToonSoldier.strafe`), RT fires. Holding
  LT is not needed: the right stick past its dead zone aims; RT fires along the last
  aim. What the aim is on comes from the captain's eye along the aim direction, level
  (the turrets' hit spheres and the floor, as `crosshairAim`); keyboard: the arrows
  turn the aim, the mouse could point it later. The aim line, the ring on a turret, and
  the crosshair (at the aim point's screen position) work as now; the squad's focus fire
  and line of fire need nothing new.
- **Over the shoulder**: LT swings from the isometric view into the aim camera (as
  from the follow camera), and back on release.
- First person stays available through the aim panel, as now.

### As built (2026-10-07)

- `objects/iso_view.zig`: `Orbit` (heading, pitch, distance, focus, field of view; the
  follow camera's terms) and `IsoView`. Defaults: heading 45°, pitch 35.26° down, view
  half height 12 m, orthographic from 80 m back, follow rate 5, look ahead 0.4 s of the
  captain's (smoothed) travel, switch 0.9 s; perspective option with a 30° lens.
- The range scene eases the follow camera's orbit into the isometric one (`baseOrbit`),
  each term on its own, and the aim views swing in from that (`Orbit.toFollow`), so LT
  works from either view. The orthographic cut happens only when fully isometric and not
  aiming with LT; during the swing the lens narrows (75° to about 17°) so the captain is
  framed the same size as the orthographic view, and the cut doesn't jump. The follow
  camera's field of view (the scroll wheel's) is kept for the follow view.
- In the isometric view the follow camera keeps following without the stick turning
  it. `core.Camera` gained `setFov` and `setOrthoScale`.
- Twin-stick, changed in testing (2026-10-07): the right stick turns the aim relative
  to the captain's forward instead of pointing it (pointing relative to the screen felt
  unintuitive and jumped about with every wobble of the stick). Left / right turns it
  (2 rad/s at full stick), up / down raises or lowers it (0.6 rad/s, within -35° to
  +15°; starts at -6°, landing about 15 m ahead, and is kept between aims); it stays
  put when the stick is let go. He aims while the stick is pushed (past 0.15) or RT is
  held; a new aim starts from his facing. The aim ray runs from his eye, as in the other
  modes, out to 35 m when it meets nothing; shots leave the gun as over the shoulder.
  Sliders for the turn and raise rates and the pitch range.
- Up / down, changed again in testing (2026-10-07): moving the angle at a steady rate
  was very sensitive, slow up close and fast far out (the landing distance is eye height
  / tan(angle), so near level each degree moves it many meters). Now up / down moves the
  landing distance along the floor at a steady speed (12 m/s at full stick, 2-40 m,
  starting at 15 m) and the angle follows from it; in the orthographic view the aim
  point moves across the screen at a steady speed too. The angle control stays as an
  option ("up / down moves": distance / angle).
- **Cursor aim** (added in testing, 2026-10-07, now the default): turning the aim from
  the captain's forward works but means watching both him and the target to coordinate.
  With the cursor, the right stick moves the crosshair across the screen (up the screen,
  right on it, the same on-screen speed both ways: along the floor away from the camera
  is sped up by 1 / sin(pitch)); what's under it (the line of sight from the camera
  through it, against the turrets and the floor) is the target, and the captain faces
  it. The cursor is a spot on the floor that stays put in the world (holds on a turret
  while he walks), or travels with him (a checkbox); within 40 m of him and 1 m inside
  the view's edges, so a cursor left behind is pushed along by the edge. The crosshair
  and the ring on a turret show it always; the aim line while he aims (stick pushed or
  RT held). The modes: cursor, twin_stick (turning), lt_aims.
- Cursor, changed in testing: aiming again snapped the captain back to face the old
  cursor spot. Now, while he isn't aiming, the cursor waits straight ahead of him at the
  last aim's distance (turning and moving with him), so a new aim starts from his
  current forward; while aiming it stays put in the world as before.
- Cursor, fixed in testing: over a turret, letting go of the stick made the cursor jump
  a little to the side (not over the floor). The captain faced the point where the line
  of sight meets the turret's hit sphere, which sits nearer the camera and higher than
  the cursor's spot on the floor, so from him it lies at a slightly different bearing;
  letting go put the cursor straight ahead along that facing. Now he faces the cursor's
  floor spot; shots still go to the point on the turret.
- `ToonSoldier.number_key_actions` (off for the captain in the range).
- The aim panel: the view (1 / 2), and in the isometric view the aim mode, projection,
  size, pitch, heading, lens, follow rate, look ahead, switch time.
- Noticed: LT from the isometric view is a long swoop (from about 47 m up down to the
  shoulder) in 0.9 s; the aim camera's swing sliders set it.

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
| H | Third-person aim: LT swings the camera over the right shoulder; aim, move, shoot; follow zone with lag; aim line, decal, crosshair; first person kept as an option | ✅ 2026-10-06 |
| I | Friendly fire from the captain; the squad steps out of his line of fire, with late reactions and lapses (awareness, a future skill) | ✅ 2026-10-06 |
| J | Isometric view (keys 1 / 2): orthographic follow camera at a fixed 45°, screen-relative movement; aiming by cursor, twin-stick, or over the shoulder, as an option | ✅ 2026-10-10 |

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
