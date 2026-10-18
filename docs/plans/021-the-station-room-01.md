# Plan 021 - The Station: Room 01

## Status: Active (started 2026-10-18; phase A done)

## Context

The Station is a new point-and-click game: a maintenance robot on a space station, rooms
seen as one-point perspective cutaways in shades of grey, drawn with ink and hatching. The
game design, look, camera, and art workflow are in
`the-station/docs/game_notes/the_station_design.md`; docs and art live in `the-station/`
(its own repo), game code in `games/the_station/`.

Scope of this plan: **one room** (Room 01, the control room) working end to end. A
greybox room, the cutaway camera, a robot that walks across the room and pushes a control,
a door that opens. Multi-floor views and further rooms are later plans.

## Decisions (John, 2026-10-18)

- Game code in `games/the_station`; docs and art in `the-station/`.
- Blender with Blender MCP for the robot, rooms, and animation.
- Moving between floors is a **transition** first; a **multi-floor view** comes later
  (per-room cameras with off-axis projection).
- The ink and hatching look is a **shader in the engine**, so objects can be added
  without making textures for them.
- The robot is a **3D model of rigid parts**; whether it renders live or as sprites from
  Blender is decided once the model exists. Both kept as options.
- **Movement is not limited to a line**: stand points can be at different depths. Depth
  comes from the rooms being 3D, not from scaling the model by screen position.

## Design

### Existing engine pieces

- Mouse picking: `math.getWorldRayFromMouse` and `math.getRayPlaneIntersection`
  (`src/math/utils.zig`), `AABB.rayIntersects` (`src/core/aabb.zig`); used in
  `games/level_01/run_app.zig` (`pickNode`).
- Camera: `core.Camera` with perspective and orthographic projections
  (`src/core/camera.zig`); `Mat4.perspectiveRhZo` (`src/math/mat4.zig`).
- glTF models with node animation, `animation_fsm.zig` for clips with fades.
- Time-based motion: `core.motion` (`moveToward`, `dampAngle`, `PathFollow`).
- ImGui (`core.gui`) for tuning panels.

### New pieces

- **Off-axis projection**: `Mat4.frustumRhZo(left, right, bottom, top, near, far)` and a
  lens-shift option on `Camera`, so the vanishing point can sit off screen center. Needed
  for the per-room multi-floor view; useful now for framing.
- **Ink shader**: outlines from depth and normal edges (a post pass on a depth/normal
  target) or inverted hulls, plus hatching from light intensity. A pass after the scene,
  so it needs a normal/depth target; see `docs/designs/009-angrybot.md` for the
  multi-pass frame.
- **Interaction** (game code first, moved to `src/core/gameplay/` if a second game uses
  it): `Hotspot` (bounds, stand point, facing, action clip, effect frame), walk area,
  and a robot controller: walk to point, turn, play action, fire the effect.
- **Animation events**: an effect fires at a set time in a clip. Plan 012 lists "time
  queries / events" as a leftover; the smallest version is a check for a clip time being
  crossed this frame.
- **Billboard sprites** only if the sprite option is chosen: a Y-axis billboard quad with
  sprite-sheet frames.

## Phases

### A. Room and camera (placeholders)
- [x] `games/the_station` app: window, camera, ImGui, build steps `the_station` /
      `the_station-run`
- [x] Greybox room from shapes: floor, back wall, side walls, door, right-wall panel,
      three back-wall panels; 1 unit = 1 m
- [x] Camera panel: view (shifted, aimed, orthographic), distance, eye height, eye x;
      field of view shown
- [x] Settle on starting camera values and record them here: shifted view, distance
      6 m, eye height 1.9 m, eye x 0 (John, 2026-10-18)
- [x] Grey palette and a pulsing red alarm light

### B. Walking and clicking (placeholder robot)
- [ ] Placeholder robot (stacked boxes) with a facing direction
- [ ] Click the floor: walk to the nearest point in the walk area
- [ ] Hotspots: hover highlight; click walks to the stand point, turns, runs the action
- [ ] Right-wall panel: the action stops the alarm and opens the door

### C. Robot model (Blender)
- [ ] Turnaround sheet of the robot from `best_robot_example.png`
- [ ] Model from primitives with Blender MCP; rigid part hierarchy; glTF export
- [ ] Clips: idle, walk, turn, push button, look around, startle
- [ ] In the room, live; the push fires the effect on its frame
- [ ] Decide live 3D or sprites

### D. Ink shader
- [ ] Outlines
- [ ] Hatching from lighting
- [ ] Tune on the room and robot together

### E. Room art
- [ ] Room modeled in Blender with detail (pipes, vents, panel faces), glTF
- [ ] Greyscale textures for surface detail

## Notes & Decisions

- 2026-10-18: written from the first discussion of the game (see Decisions).
- 2026-10-18, phase A: the camera is set by where the eye is, not by a field of view.
  `RoomCamera` (`games/the_station/room_camera.zig`) always frames the opening (plus the
  cut edges) to fill the screen, so the free values are the eye's distance from the
  opening, its height, and its x. Its default `shifted` view keeps the camera level and
  moves the picture with an off-center frustum (`Mat4.frustumRhZo`): verticals stay
  vertical and the vanishing point sits at the eye, as in the cutaway illustrations. An
  `aimed` camera (turned to look at the opening) leans the verticals as soon as the eye is
  above or below the opening's middle; kept as a view for comparison. Distance sets the
  splay: 7 m gives a 41° vertical field of view, 4 m gives 67° and a strong splay. The
  field of view follows from the distance and is shown in the panel. Lens shift is in the
  game, not in `core.Camera`, until a second user needs it. No game tests: `zig build
  test` doesn't run app files; the framing was checked on screen.
- 2026-10-18, phase A: the shell's faces at the opening (floor, ceiling, side walls) are
  drawn at 35% of their color, the cut through the station filled in solid as in a
  section drawing (`room.wgsl`, `draw.params.y`).
