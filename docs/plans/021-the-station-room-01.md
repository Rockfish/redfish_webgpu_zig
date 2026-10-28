# Plan 021 - The Station: Room 01

## Status: Active (started 2026-10-18; phases A-E done, F in progress)

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
- [x] Placeholder robot (stacked boxes) with a facing direction
- [x] Click the floor: walk to the nearest point in the walk area
- [x] Hotspots: hover highlight; click walks to the stand point, turns, runs the action
- [x] Right-wall panel: the action stops the alarm and opens the door

### C. Robot model (Blender)
- [-] Turnaround sheet of the robot from `best_robot_example.png` (skipped: modeled from
      the drawing directly; one view was enough for a rigid robot)
- [x] Model from primitives; rigid part hierarchy; glTF export
      (`the-station/blender/build_robot.py`, headless, or in an open Blender through
      the MCP bridge with `send_to_blender.py`)
- [x] Clips: idle, walk, push button, look around, startle (turning uses walk)
- [x] In the room, live; the push fires the effect on its frame
- [x] Decide live 3D or sprites: live 3D, with the ink shader

### D. Ink shader
- [x] Outlines
- [x] Hatching from lighting
- [ ] Tune on the room and robot together (panel "Ink" section; defaults set from
      screenshots, John to tune)

### E. Saved settings (ZON)
- [x] `core.SettingsFile(Values)`: the panel's settings in a ZON file, only those that
      differ from the defaults in code; tests
- [x] Panel: right-click a setting to save, revert to saved, or reset to default; per
      section save / revert / defaults; `*` on unsaved settings and sections
- [x] File: `the-station/settings/room_01.zon` (with the room's art)
- [ ] Lua, later, for game scripting (hotspot effects, puzzles, dialogue) once the
      logic in `game.zig` repeats across rooms; our own binding to Lua's C source

### F. Room art
After `the-station/images/10 GeV Dubna Synchro-Phasotron.jpeg` (John, 2026-10-28): a
Soviet accelerator control hall; the feel wanted is its equipment, especially the mimic
board in the upper left.
- [x] `the-station/blender/build_room.py`: Room 01's equipment from primitives, written to
      `models/room_01/room_01.glb`; shared primitives with `build_robot.py`
      (`blender/primitives.py`)
- [x] Back wall: a continuous row of instrument cabinets (the gauges, screen, and
      breakers are cabinets in it) under a mimic board across the wall
- [x] Right-wall console restyled to match: instrument hood, wall panel, mushroom
      buttons, a lever; pipes moved off the back wall
- [x] Greyscale textures for printed detail (seams, scales, labels, the board's
      diagram), generated as SVG by `build_room.py` and turned into PNG by `rsvg-convert`
- [x] In the game: the model drawn in ink with its textures; hotspots moved onto the
      cabinets; the greybox kept as an option and as the fallback without the model
- [ ] Later (separate step): a lighter look after
      `images/grey-tones-red-highlites-hatching-shader-example.jpg`

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
- 2026-10-18, phase B, as built:
  - `interaction.zig`: `Hotspot(Kind)` (name, bounds, stand point, facing yaw, action
    `push` or `look`), `WalkArea` (one rectangle; clicks clamp into it), `pick` (nearest
    hotspot the mouse ray hits, else the floor point), `outline` (hover box).
  - `robot.zig`: the placeholder robot after the drawing (box head with two round eyes,
    body, thin arms and legs, flat feet), rigid parts turned at hips and shoulders. Tasks:
    `walk` (turns toward travel, 1.2 m/s, legs and arms swing), `turn` (to the hotspot's
    facing), `act` (the gesture: push raises the right arm, 1 s; look pauses, 0.6 s). The
    effect fires at a set time in the gesture (push: 0.45 s, hand at the button), the
    smallest version of animation events. Clicks during a gesture are ignored, so a use
    isn't cut off before its effect.
  - `game.zig`: the room's state and each hotspot's effect. The red button stops the alarm
    and opens the door (slides into the wall, 1.2 s); the door, buttons, lever, gauges,
    screen, and breakers give remarks. The left wall is three pieces around the doorway,
    with a dark recess beyond.
  - On screen: the hovered hotspot's outline and its name next to the cursor; the robot's
    remark at the top for 4 s. The panel starts collapsed (it covered the door), and has
    "reset room"; the floor grid is off by default.
  - Checked with temporary edits: each hotspot's center, projected to the screen and cast
    back as a mouse ray, picks that hotspot; a scripted run (button, then door) on screen.
- 2026-10-18, phase D, as built (`ink.zig`, `shaders/room.wgsl`, `shaders/ink_edges.wgsl`):
  - **Outlines from a normal-depth pass.** The engine's passes have one color attachment,
    so the scene is drawn twice: first into an `rgba16float` target (view-space normal,
    distance in front of the camera) by room.wgsl with the `NORMAL_DEPTH` override, single
    sample with the single-sample depth; then lit in the window pass. A full-screen quad
    (the engine's square, doubled) reads the target with `textureLoad` and draws ink
    where a neighbor `line width` pixels away differs: a depth jump over 4% is a
    silhouette, a normal turn over about 45° a crease. Edges come from geometry, so
    anything added is outlined without textures. The target is recreated on resize.
    Defaults: 2 px, ink at 90%.
  - **Hatching in room.wgsl.** Up to three layers of lines (diagonal, crossed, horizontal)
    that start at tones 0.8, 0.5, 0.25 and thicken below them. Lines are laid out on the
    face's plane in the part's own space (position minus its model origin), so they move
    with a part instead of sliding across it; turning parts (the robot's legs) still
    shift under them. Spacing 0.14 m (0.06 read as a texture, not strokes).
  - **Tone comes from the light, not the surface color**: the first version hatched every
    mid-grey wall even in full light. As in an ink drawing, hatching shows shading: a
    lit floor stays clear, walls facing away from the light are cross-hatched. The
    light's brightest channel, so red alarm light counts as light.
  - **Cut faces** get one set of diagonal lines whatever their light, as a section
    drawing's poché.
  - Panel "Ink": outlines on/off, line width, depth and crease thresholds, ink opacity,
    hatching on/off, strength, spacing, reset.
- 2026-10-20, phase C, as built:
  - **Driving Blender** (John: both routes). `the-station/blender/build_robot.py` builds
    the robot from primitives (bmesh boxes with bevels, cylinders, spheres) and writes
    `models/robot/robot.blend` and `robot.glb`; run headless with `--preview DIR` for
    front, three-quarter, side, push-contact, and walk renders. The installed add-on is
    Blender Lab's official MCP (Blender 5.2, extension `mcp`): a bridge in Blender on
    localhost:9876 that runs Python sent as null-terminated JSON. Claude Code has no MCP
    server registered for it; `send_to_blender.py` talks to the bridge directly, so the
    same script rebuilds the robot in an open Blender. Tried 2026-10-20: about 3 s, the
    same .glb as headless. The add-on's server autostarts when Blender launches, and only
    if "Allow Online Access" is on then; turned on later, the server needs a restart of
    Blender or the add-on's "Start MCP Bridge Server" button.
  - **Rigid parts, no armature.** Joints are empties (hips, knees, body, neck, shoulders,
    elbows) with mesh parts parented to them; the engine poses unskinned nodes already
    (`Mesh.drawAt` folds the node matrix into the draw). The robot faces -Y in Blender,
    +Z in glTF (the engine robot's forward). 1.35 m to the top of the head.
  - **Clips** (24 fps): idle 2 s, walk 1 s (one stride, matching 1.2 m/s), push 1 s
    (hand at the button at frame 11, 0.46 s; the gesture's effect fires at 0.45 s),
    look_around 3 s (the opening, as if woken by the alarm), startle 0.75 s (not used
    yet). One action per joint per clip on NLA tracks named after the clip; the
    exporter merges same-named tracks (`NLA_TRACKS`) into one animation per clip.
  - **Every clip keys every animated joint** (`hold_rest`), at rest where it doesn't move
    it: the engine leaves a joint the playing clip doesn't animate where the last clip
    put it, and the robot stood mid-stride after walking to the console. The exporter's
    size optimizer drops constant channels, so `export_optimize_animation_keep_anim_object`
    is on.
  - **In the game** (`robot_model.zig`): a `ModelInstance` with a live animator and the
    animation state machine; the task picks the clip (idle, walk also while turning,
    push; look uses idle), crossfades 0.2 s (push 0.1 s, not interruptible). Loaded from
    `the-station/models/robot/robot.glb`; without it (no the-station checkout) the box
    placeholder draws, and the panel's "placeholder robot" switches to it.
  - **Ink on the model**: robot.wgsl, a `.pbr` shader (mesh draws bind their glTF material
    at group 1), using the material's base color and emissive (the eye lenses). Shared
    with room.wgsl through `ink_common.wgsl`.
  - **Engine changes**: `ShaderConfig.includes` (WGSL files placed after common.wgsl, for
    an app's shared shader code; error line offsets include them); `Mesh.drawAt` takes
    `params`, and `ModelInstance.drawWithParams` passes them to `DrawUniforms.params`
    (`draw` passes zero; `Model` and `BakedAnimator` too).
  - Zig: the `zig` on PATH is 0.17 since 2026-10-20; the engine builds with 0.16
    (`~/zig/zig-aarch64-macos-0.16.0/zig`) until plan 020.
- 2026-10-20, leaving the room (John): clicking the open door sends the robot to the
  door's stand point; it looks, then walks out through the doorway to a point inside the
  dark recess beyond the wall (`room.doorway.outside`), which hides it, and waits there
  (`Task.outside`, idle clip). Any click in the room (floor or hotspot) brings it back:
  a walk from the doorway or beyond goes through the inside point first (`Task.walk.via`),
  so it never cuts through the wall. A walk ends in `Arrival` (stand, use, step out).
- 2026-10-20, from testing (John): clicks on the back-wall panels sometimes need a second
  click, and the robot's hatching flickers and shifts, most visibly in idle. Causes:
  1. **Short clicks are lost.** `core.Input` keeps only whether a button is down
     (`mouseHandler` sets `mouse_left_button`); the game sees a click when it's down this
     frame and wasn't last frame. A press and release that both arrive between two frames
     (a trackpad tap) leave it up both times, so there's no click. Fix: `Input` latches
     each press in the callback and reports it once (`mousePressedOnce`), as `pressedOnce`
     does for keys.
  2. **Clicks during a gesture are ignored** (`Robot.startWalk` returns while acting):
     look is 0.6 s, push 1 s. At the back wall the next panel is often clicked while the
     robot still looks at the last one. Fix: keep the last click made during a gesture
     and carry it out when the gesture ends.
  3. **Hatching in world axes.** `ink_common.inked` lays the lines on the world-axis
     plane a surface mostly faces, relative to the part's origin. When a part turns (idle:
     neck 3-4°, shoulders 2-3°) its surfaces turn under lines that stay in world axes, so
     the lines shift; on cylinders and bevels the plane choice flips where the normal
     crosses 45°, so bands flicker. Fix: the robot hatches in its parts' own coordinates
     (the mesh's vertex positions and normals, in meters), which turn with the parts. The
     room's parts don't move, and their models are scaled unit shapes, so they keep world
     axes.
  Fixed the same day (John: all three now): `Input.mousePressed` (presses latched in
  the callback, handed to the frame by `update`; test), used for the game's clicks;
  `Robot.pending` keeps the last walk asked for during a gesture and starts it when the
  gesture ends (checked: the screen asked for during the look at the gauges, used 2.4 s
  later); robot.wgsl hatches in the mesh's own positions and normals (checked: the lines
  hold still on the robot in idle; their thickness still follows the alarm's pulse, as
  shading should).
- 2026-10-20, from testing (John, `temp/shader_gliches`): specks still showed at the
  robot's neck and waist. Captures with each effect off placed them in the outline pass,
  not the hatching. The edge test compared each pixel with four pixels exactly
  `line width` (2) away, all or nothing; the robot is about 200 px tall, so the collar,
  the chest port's rim, and bevels are 2-4 px wide, and the 2 px steps sometimes went
  over them: dotted lines, switching on and off as idle moved the parts by fractions of
  a pixel. Fixed in ink_edges.wgsl: every pixel within the radius is compared
  (diagonals and nearest included), both thresholds are soft (`smoothstep` over the
  threshold to 1.5 times it), and pixels at the radius's rim count partly. Checked: the
  rim is a solid ring, the specks are gone, and the lines hold still in idle.
- 2026-10-20, from testing (John, second set of screenshots): dashes still came and
  went along the torso's top edge, ticks at the band's ends, a dot at a heel. All on
  features under a few pixels (about 6.5 mm per pixel at the console): the bevels (the
  torso's 3.5 cm, about 5 px) were three flat facets 30° apart, so whether the edge test
  spanned one facet boundary (30°, no line) or two (60°, a line) depended on where the
  pixels fell; and the band stood only 5 mm proud, under a pixel, with small square-ish
  corners leaving slivers. Fixed in the model (`build_robot.py`): bevel faces are
  smooth-shaded (the six sides stay flat), so the normal turns evenly across a bevel;
  the band stands 1.5 cm proud with its bevel following the torso's corners, in the
  body's grey, so its two outlined edges draw the seam as in the drawing. Checked over
  idle frames: no dashes or ticks; the bevelled edges inside a part are now shading,
  not lines (the parts' silhouettes are still outlined).
- 2026-10-20, from testing (John): the band lit up red with the alarm while facing away
  from it. The band's bevel (5 cm, to follow the torso's corners) was larger than half
  its 3 cm height, so the bevel folded the surface over itself: the band measured 7 cm
  tall, and the folded faces seen from the front pointed back toward the light. Fixed in
  `build_robot.py`: `box` can round only the vertical edges (`vertical_bevel_only`, used
  for the band: 3 cm, 18 faces, none facing inward), and every bevel clamps overlaps.
  Checked in the alarm: the band lights as the torso around it does.
- 2026-10-20, from testing (John): the belt flickered in idle. A fast capture (every
  0.08 s) showed a thin red line along its top in some frames and not others: the top of
  the 1.5 cm ledge faces up toward the alarm light, and seen from the camera's eye
  height (about 10° above it) it is 0.4 px tall, so as the body bobs 8 mm it covers a
  pixel or doesn't. Any ledge that small does this. Fixed in `build_robot.py`: no band;
  the seam is a dark stripe on the torso's own surface (`box(..., stripe=...)` cuts the
  mesh and gives the faces between a second material), 1.2 cm, about 2 px. Nothing
  stands out, so nothing catches light or outlines. Checked over 12 frames: the seam
  holds still. `vertical_bevel_only` went with the band.
- 2026-10-28, saving settings (John: ZON for now; "I think we'll end up with both ZON and
  Lua"). Options weighed:
  - **ZON** (`std.zon`, in Zig 0.16): no dependency, reads into the settings structs
    with their types checked (a wrong field names its line), allows comments, Zig syntax.
    Comments are lost when the program rewrites the file.
  - **JSON** (`std.json`): no dependency, every tool reads it; no comments, noisier.
  - **Lua through ziglua**: real scripting, proven in adventure games (Grim Fandango's
    logic was Lua); but a dependency that follows Zig releases, as zglfw and zgui do
    now (plan 020 waits on them), and far more than settings need.
  - **Lua through our own binding**: compile Lua's C files (MIT) in `build.zig`, translate
    `lua.h` as with `webgpu.h`; the stack API and errors are real work.
  - TOML / INI / our own format: a parser to write or depend on, nothing gained over ZON.
  The deciding point: settings saved from the panel are rewritten by the program, and a
  program can rewrite data but not logic, so saved settings are data whatever else is
  scripted. Lua's place is game scripting (see phase E's last item).
- 2026-10-28, phase F decisions (John): the back wall becomes a Dubna-style wall, a row
  of cabinets under a mimic board, with the hotspots kept where they are; the lighter
  look of the kitchen example is a separate step afterward. Approach:
  - **The shell stays in code** (floor, walls, doorway, door, alarm lamp): its cut faces,
    the sliding door, and the pulsing lamp are driven per draw. The equipment comes from
    Blender as one model drawn with one set of params.
  - **Detail by size**: features a few centimeters and up (dials, lamps, switches,
    buttons) are geometry, so they get outlines; anything smaller (seams between
    cabinets, scale marks, labels, the board's diagram lines) is texture. Phase C showed
    that features under a few pixels (the belt's ledge) flicker in the outline pass;
    textures are mipmapped instead.
- 2026-10-28, phase E, as built:
  - `src/core/settings_file.zig`: `SettingsFile(Values)`, where `Values` is a struct of
    sections, each a struct of settings with defaults. The file's type is made at
    compile time (`@Struct`): each section with every setting optional and null. Saving a
    setting stores its value, or null if it equals the default, so the file holds only
    what differs and a default changed in code still applies to the rest. Written one
    setting per line (`std.zon.Serializer`), sections with nothing saved left out:
    ```
    .{
        .camera = .{
            .distance = 6.5,
        },
    }
    ```
    Settings in the file the program no longer has are skipped (and dropped on the next
    save); a file that isn't readable as these settings is reported and never written
    over. Reset and revert change only the value in memory; the file changes on save.
  - `games/the_station/settings.zig`: `Settings` (camera, ink, room, alarm; the room and
    alarm settings are their own structs now) and `Panel`, the panel's widgets with the
    right-click menu and the `*`. "reset room" (restarts the game) is now "restart room",
    apart from the settings' "defaults".
  - Checked with a temporary edit: saved the camera distance and the ink section, the
    file held only the two changed values, a second run loaded them, and the panel
    marked an unsaved line width. The test file was removed afterwards.
- 2026-10-28, phase F, as built:
  - **`the-station/blender/build_room.py`** builds the equipment (not the shell) in the
    game's coordinates (`at` and `extent` turn them into Blender's) and writes
    `models/room_01/room_01.glb` and `.blend`; headless or through the MCP bridge, as the
    robot. Its primitives moved to `blender/primitives.py`, shared with
    `build_robot.py` (the robot rebuilt through it gave the same vertices and
    animation).
  - **Back wall**: ten 0.8 m bays, 1.85 m tall, 0.35 m deep. Single bays: meters
    (square meters, lamps, toggle switches, knobs) at each end, the ring (lamps in a
    circle around a meter, as the photo's), keys (a grid of push keys). Two-bay
    cabinets are the hotspots: gauges (three dials with printed faces and needles),
    the screen (an oscilloscope in a hooded bezel, its glass glowing with a graticule
    and a trace), breakers (two rows of handles and a main lever). Above them the mimic
    board, 7.7 x 0.64 m: the station's ring, two buses with switches, lamps, and units
    (pumps, vacuum, airlock, oxygen, heat, comms) in light lines on a dark board, labels
    in Russian as on the photo; the alarm lamp sits over its middle.
  - **Console**: desk with plinth and top, an instrument hood leaning to the wall, a
    wall panel with three meters and lamps, mushroom buttons (red for the alarm) and a
    lever with a ball knob, in the hotspots' places. Pipes run along the tops of the
    side walls (the back wall is the board's).
  - **Textures** are drawn in meters as SVG by the same script (`Svg`), so printed and
    modeled parts share coordinates, and turned into PNGs with `rsvg-convert`: the
    cabinets' fronts (seams, doors, label plates, printed lines and knob scales), the
    board, dial and meter faces, the screen. The board is about 11 mm a pixel in the
    game: its lines are 12-20 mm and labels 50-80 mm, or they vanish.
  - **Draws**: each group (cabinets, board, console, pipes) is joined into one mesh with
    its origin at the room's: about a dozen draws instead of hundreds. Every mesh's
    node is at the origin because `ModelInstance` without an animator draws meshes at
    the identity (node transforms unused): the board, a single unjoined mesh with its
    own node translation, first drew at the floor in front of the room.
  - **In the game**: `shaders/robot.wgsl` is now `model.wgsl` (any glTF model in ink)
    and multiplies the base color by the base color texture (white without one). `Room`
    loads the model (`room.MODEL_PATH`); the shell stays boxes; the greybox equipment
    draws without the model or with the panel's "greybox room" (`settings.room
    .use_greybox`). Hotspots for the gauges, screen, and breakers moved onto their
    cabinets (stand points x -2.4, 0, 2.4); the walk area's back edge is z -3.25.
  - Checked on screen: alarm on and off, the board's labels legible, every hotspot's box
    over its fittings (temporary edit drawing all of them).
- 2026-10-28, the console's buttons (John): the red button only stops the alarm; the
  middle button (`HotspotKind.door_button`, still named "Button") opens the door. They
  were one action before (the red button did both).
- 2026-10-28 (John): the middle button also closes the door when it is open.
