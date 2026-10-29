# Plan 022 - The Station: Structure for the Whole Game

## Status: Active (written 2026-10-29; phases A-B done; B2 done but the outline option; B3, C done; next: phase D)

## Context

Plan 021 built Room 01 and Room 02 end to end: the cutaway camera, walking and clicking,
the ink look, the robot from Blender, power out with emergency lights, the ladder down.
The game ahead has many rooms, an inventory, and puzzles on industrial panels (switches,
gauges, valves, indicator lights), with machinery whose state changes with the robot's
actions and shows in other rooms: climb down to the generator room, fix it, and the
control room's panels show it.

A review of `games/the_station` on 2026-10-29 (see Notes) found the code works and
mostly follows `docs/STYLE.md`, but "a room" isn't a concept in it yet. `room_01.zig`
doubles as the library every room is drawn with, `deck.zig` names each room by hand in
several places, and the game's state is a few booleans in `Game`. Adding Room 03 means
copying and editing six places, and a room below the deck doesn't fit `roomAt`'s split
on x.

Scope: the structure the rest of the game is built on, carried through to one example of
each piece: rooms as data, the station's state, room transitions, the generator room
(stub) below the ladder, an inventory with counts, and one 3D puzzle panel whose result
shows in the control room. Content beyond that (more rooms, more puzzles) is later plans.

## Decisions (John, 2026-10-29)

1. **Every room is reached by a transition.** No stacked multi-floor view (plan 021
   deferred it; now dropped). The camera shows one room; moving to another is a
   transition (pan, cut, or fade).
2. **Room sizes are multiples of one base size.** Room 01 is 3 x 1 (three bases wide,
   one high). May change later; assumed for now.
3. **Puzzle panels are 3D close-ups** (Blender models in ink), not 2D overlays.
4. **The inventory has counts** (three fuses, not just "a fuse").
5. **STYLE.md gets two exceptions**: data written one row per item (a room's parts,
   its hotspots) stays one item per line, however long; and a short `if` in a switch
   arm stays on one line without braces (`.top => if (is_lower_part) self.robot.climb(true),`).
6. **The cell is 2.8 x 3.4 m** (confirmed), and **the generator room is 6 x 2**.
7. **Two rooms below Room 02** on the ladder; the generator room is entered through a
   doorway from the lower one, so it lines up with them (see "The station so far").

## Design

### Room grid

A base cell measured wall center to wall center: **2.8 m wide, 3.4 m high**. A room
`w` x `h` cells has an inside `w * 2.8 - WALL` wide and `h * 3.4 - WALL` high, with
`WALL` = 0.4 m. Room 01, 3 x 1: 8.0 x 3.0 m, its size today, and Room 02's center 8.4 m
from Room 01's is one room-width of cells, as now. Depth stays 4 m for every room.
The generator room, 6 x 2: 16.4 x 6.4 m inside.

Why cells: rooms built from them line up (shared walls, doorways at the same heights,
a shaft from one room's floor lands in the ceiling of the room below), the Blender kit
can snap to them, and the robot is the same size in every room as long as the camera
shows the same amount of room.

### Framing large rooms

`RoomCamera` fits the whole opening to the screen. Room 01's framing (9.4 x 4.4 m with
the margin) is limited by its width at 16:9, so it shows about 5.3 m of height and the
1.35 m robot is about a quarter of the screen's height. The generator room's framing
(17.8 x 7.8 m) would show it at about half that size, and its hotspots as small.

So the camera frames **a window of the room, at most 3 x 1 cells' worth**, and pans it
within a larger room to follow the robot (the pan already eases `camera_x`; a room 2
high pans on y too, by floor level or by the robot's height). Entering a large room can
first show all of it, then move in. The whole-room framing stays as an option, to
compare on screen. To check when the room exists: the 3 x 1 window may need to grow a
little for a 2-high room so its floors read as one space.

Depth fixed at 4 m makes a 16 m wide room shallow, like a stage. Fine for the cutaway
look; if a hall needs more, depth becomes a room setting later (not cells).

A room's place on the station is its cell (`col`, `row`, deck). Since rooms are reached
by transitions, the grid doesn't need rooms to touch; it keeps the station's layout
consistent (side-by-side rooms can still pan, a map screen later can draw it) and gives
each room's origin.

### The station so far

Cells by column and row, a room's `cell` its lower-left one; Room 01 at column 0, row 0:

```
            col -3 .. -1        col 0 .. 5
row  0    [ Room 02     ]     [ Room 01     ]
row -1    [ Room 03     ]     [                            ]
row -2    [ Room 04     ] ==> [ Generator room (6 x 2)     ]
```

- **Room 02's ladder goes down two floors.** The shaft passes through Room 03 (a hole in
  its ceiling and in its floor, the ladder running through) and ends in Room 04 (a hole
  in its ceiling). The robot can step off in Room 03 or go on to Room 04. Two ladder
  connections: Room 02 to 03, Room 03 to 04. Climbing out of sight through a floor or
  ceiling is the transition, as the robot climbs out of sight in Room 02 now.
- **The generator room is entered through a doorway from Room 04**, a door connection
  like Room 01 to Room 02. Its floor lines up with Room 04's and its top with Room 03's
  ceiling, so it sits beside them on the grid.
- **It is under Room 01**, the control room over its generator; the mimic board above
  the machinery it shows.
- Room 03 is a place for content on the way down (an item, a small panel).
- Later, if wanted: a second, upper entrance from Room 03 onto a catwalk along the
  generator room's upper half.
- Room 03 and 04 are 3 x 1, greybox in this plan; what they are is open.

### Rooms as data

New `room_kit.zig` (mirrors `the-station/blender/room_kit.py`) takes from `room_01.zig`
what every room uses: `Part`, `PartBuilder`, `box`, `cylinderModel`, `grey`, `bounds`,
`Hatching`, the `FACE_*` facings, door sizes, `WALL`, the cell size. Plus one shell
builder for any room: `addShell(builder, size, openings)`, where openings are doors in a
side wall (open, sliding, locked) and holes in the floor. It replaces
`room_01.addShell` / `addDoorway` and `room_02.addRoomBox` / `addLockedDoor` /
`addShaft`, which are near copies.

Each room file exports one descriptor, its contents in **room-local coordinates** (origin
at the opening's floor center, as Room 01 now):

```zig
pub const room: Room = .{
    .name = "Control room",
    .cells = .{ .w = 3, .h = 1 },
    .cell = .{ .col = 0, .row = 0 },
    .model_path = "the-station/models/room_01/room_01.glb",
    .walk_areas = &walk_areas,
    .hotspots = &hotspots,
    .lights = &lights,
    .openings = &openings,
    .addGreybox = addGreybox,
};
```

`station.zig` (what `deck.zig` becomes) holds the table of rooms (`RoomId` an enum
indexing it) and loops over it: building, drawing, `roomAt` by containment, framing,
lights. Only the shown room is drawn and lit (plus the next one during a pan): the
engine has 4 point lights (`MAX_POINT_LIGHTS`). The Blender scripts export each room at
its own origin, so room_02's world numbers (`-11.4`, `-7.1`) become local ones.

### Hotspot highlight

As an ink drawing would show it: the hovered control looks as if a small lamp caught it.
Its hatching thins, it takes an **amber** tint (red is kept for dramatic things: the
alarm, danger), and its edges turned from the camera brighten a little, so it glows at
its outline without a box. It eases in and out over about 0.15 s (`motion.dampAlpha`)
with a faint pulse. Only controls highlight (buttons, the lever, the keypad, later the
panels' switches and valves); doors, the ladder, and things looked at show the name and
a hand cursor.

A control is its own mesh in the room's model, named for the hotspot, so it can be drawn
with its own params (`ModelInstance.drawWithMeshParams`). Meshes keep their origin at
the room's, which models drawn without an animator need. This is the first slice of
phase G's part lookup and per-part params; the panels use the same.

The greybox doesn't highlight: `room.wgsl`'s four params are all used (emissive, cut,
hatch strength and spacing), and the greybox is a fallback.

### Game cursor

Drawn by the game rather than the OS: GLFW can make an OS cursor from an image, but on
macOS only at 1x (blurry on a Retina screen), fixed, and ImGui's backend sets the cursor
every frame. A game-drawn cursor is sharp at any size, matches the ink look, can animate,
and in phase F becomes the held item's icon, as in SCUMM games. Its cost is a frame of
lag, fine for pointing and clicking. The OS cursor is hidden over the game and shown
over the panel; ImGui does both (`setMouseCursor(.none)` hides it).

The cursor says what a click will do: an arrow over the floor (walk), a hand over
controls (push), an eye over things looked at, an exit arrow over an open door pointing
to the next room, a ladder over the ladder from the floor, down and up arrows on it.
Drawn in the-station by a script as SVG (ink lines on a light fill, so they read on dark
and light walls), rendered at 2x into one sheet.

### Connections

A door, a ladder, or a hatch joins two rooms: `Connection` with an end in each room
(stand point, facing), how it's crossed (walk through, climb), and a gate (a condition on
the station's state: the door is open, the hatch is unlocked). Crossing one starts a
transition. Replaces `navigation.Area.needs_open_door` (areas belong to one room; the
path never leaves it), `Game.otherSideOfDoor`, and the ladder's dead end
(`LadderPlace.below`): climbing down out of sight in Room 02 arrives on the ladder at
Room 03's ceiling (see "The station so far"). A ladder that runs through a room has
stops: off at the floor, or on down.

### The station's state

One plain-data struct, typed, with no pointers:

```zig
pub const Station = struct {
    power: Power = .{},          // generator, buses, breakers: enums, not flags
    alarm: Alarm = .on,
    doors: std.EnumArray(DoorId, DoorState) = ...,
    inventory: Inventory = .{},
    generator_panel: GeneratorPanel = .{},
    ...
};
```

- What's on screen is **derived** from it by functions (`power.isBusLive(.b)`,
  `mimicLamp(...)`, a needle's angle), never stored twice, so the control room's lamps,
  the mimic board, the lights, and the door's power can't disagree. `DrawState` is the
  start of this; it widens to the whole state.
- Typed Zig rather than a table of named flags: the compiler checks every use, switches
  stay exhaustive.
- Plain data, so a **snapshot** is a copy: restore on death (the outline has many ways to
  die) and, later, a save game in ZON.
- `Game` keeps the robot, the shown room, the mode, and a `Station`.

### Hotspots by room

Each room has its own `HotspotKind` and a `use(station: *Station, kind, item: ?Item)`
function; the station sends a use to its room. `Hotspot(Kind)` is already generic; only
`deck.hotspots = room_01.hotspots ++ room_02.hotspots` forces one shared enum. Hotspot
indices stay per room. `Game.use`'s switch splits into the rooms' files.

Lua stays deferred (plan 021, phase E): typed Zig plus a `use` per room may be all the
game needs. If editing remarks gets slow, their text moves to a ZON file first.

### Modes

```zig
const Mode = union(enum) { explore, transition: Transition, panel: PanelId };
```

Input goes to the active mode only. `explore` is today's loop. `transition` runs a
room change (pan for side-by-side rooms, as now; a fade otherwise) with no input. `panel`
is a puzzle close-up; the robot waits at the panel's stand point.

### Inventory

`Item` an enum; `Inventory` counts per item (`std.EnumArray(Item, u8)`), `add`, `take`,
`count`. Picking up is a hotspot effect; whether an item still lies in a room is derived
(`fuse_on_shelf` until taken), not a separate flag. Using an item: select it in the
inventory bar, then click a hotspot; the room's `use` gets `item`. The bar and remarks
need a screen-space overlay that isn't ImGui (which looks like the debug panel): an
orthographic pass of textured quads with hit tests in pixels, in the game first.

### 3D puzzle panels

A panel is a Blender glb with **named nodes** (`switch_1`, `valve_a`, `needle_bus_b`,
`lamp_3`). Opening it cuts the camera to a framing of the panel; a click picks a node;
the panel's logic changes state; nodes turn and lamps light from that state. The same
devices seen in the room read the same state.

Each puzzle's logic is a struct apart from drawing (`toggle(switch)`, `turn(valve)`,
`readings()`, `isSolved()`), unit-tested.

Engine work this needs (`src/core`, `ModelInstance`):
- find a node by name;
- a transform override per node for models drawn without an animator (today they draw
  every mesh at the identity, `model_instance.zig:164`);
- params per node (a lamp's emissive), where `drawWithParams` now gives one for the model;
- a ray pick against node bounds.

### Tests

`zig build test` doesn't run game files (plan 021, phase A notes). Add a test step for
`games/the_station`'s logic: navigation, the station's state and derived values, the
inventory, puzzle logic.

## Phases

### A. Style fixes
- [x] STYLE.md: the two exceptions (decision 5)
- [x] Rename leftovers in comments ("the robot's room_01.", `main.zig:5`, `deck.zig:4`,
      `game.zig:48`, `game.zig:186`, `room_01.zig:72`)
- [x] `game.zig:103` `else => {}` over `HotspotKind`: list the cases
- [x] `deck.zig:194` `self.model.?` becomes `if (self.model) |model|`
- [x] `deck.zig` constants above the types; `game.zig:20` the inline `@import`; a scoped
      log in `deck.zig`
- [x] `ink.zig`: `Ink` doesn't store an allocator (resize takes the context)
- [x] Settings file and panel named for the game, not Room 01
      (`settings/the_station.zon`, moving the saved values)
- [x] Test step for the game's logic; `navigation.zig` tests first

### B. Room kit
- [x] `room_kit.zig` with the shared pieces from `room_01.zig`; room_02, robot, ink
      import it, not room_01
- [x] The cell size and `roomSize(cells)`
- [x] `addShell(builder, size, openings)` for any room; Rooms 01 and 02 built through it
- [x] Check: both rooms look the same as before (captures before and after)

### B2. Hotspot highlight (added 2026-10-29)
The hovered hotspot showed as a white box, out of place in the ink look. Controls now
light up themselves instead (Design, "Hotspot highlight").
- [x] Engine: `ModelInstance.findMesh(name)`, `drawWithMeshParams` (one mesh's params in
      place of the model's; live, baked, and no animator)
- [x] `the-station`: controls are their own meshes, named for the hotspot (`red_button`,
      `door_button`, `lights_button`, `lever`; Room 02's `keypad`); every joined mesh
      takes its group's name; both rooms re-exported
- [x] `Hotspot.mesh`: the room model's mesh that lights up, or null (doors, the ladder,
      the hole, cabinets looked at)
- [x] Shader: the highlight in `model.wgsl` (`params.x`): amber tint, lighter hatching,
      a rim on edges turned from the camera; eased in and out, a faint pulse
- [x] Hand cursor over any hotspot (`zgui.setMouseCursor`); the white box only with the
      panel's "hotspot bounds"
- [ ] Option to compare, if the tint isn't right on screen: an amber ink outline around
      the hovered control only (a mask pass the outline pass reads, a second texture in
      ink_edges.wgsl); keep the one John picks, the other as a setting
- [x] Check: captures hovering each control; the rooms otherwise unchanged

### B3. Game cursor (added 2026-10-29)
Our own cursors, drawn by the game, saying what a click does (Design, "Game cursor").
- [x] `the-station/ui/build_cursors.py`: the cursors as SVG in ink, a 2x sheet
      (`ui/cursors.png`, `rsvg-convert`)
- [x] `overlay.zig`, `shaders/overlay.wgsl`: textured quads in screen pixels, alpha
      blended, last in the window pass (phase F's inventory bar and remarks use it too)
- [x] `cursor.zig`: the sheet, each cursor's click point, drawn at the mouse; the OS
      cursor hidden over the game (`zgui.setMouseCursor(.none)`), shown over the panel;
      without the sheet, the OS cursor as now
- [x] `Game.cursor()`: what's under the mouse picks it (walk, use, look, exits, ladder)
- [x] Check: captures of each cursor over its hotspots

### C. Rooms as data
- [x] `Room` descriptor; `room_01.room`, `room_02.room` in room-local coordinates
- [x] `station.zig` (from `deck.zig`): the table of rooms; build, draw, `roomAt` by
      containment, framing, lights from the rooms
- [x] Draw and light only the shown room (and the next during a pan)
- [x] `the-station`: room scripts export at the room's own origin; Room 02's glb
      re-exported
- [x] `robot.zig` split: the task state machine, and the placeholder's drawing
      (`robot_placeholder.zig`)

### D. The station's state
- [ ] `Station` struct: power, alarm, lights, doors; `Game` holds one
- [ ] Derived values for drawing (`DrawState` from `Station`), the lights from it
- [ ] Per-room `HotspotKind` and `use`; the station routes a use to its room
- [ ] Snapshot and restore (the panel's "restart" restores the start; a room-entry
      snapshot for later deaths)
- [ ] Tests: power, doors, derived values

### E. Connections, transitions, the generator room
- [ ] `Connection` (door, ladder) with a gate; navigation stays inside a room
- [ ] `Mode` with `explore` and `transition`; the pan between Rooms 01 and 02 becomes
      a transition; a fade for the rest
- [ ] Rooms 03 and 04 (greybox, 3 x 1) below Room 02: the shaft through Room 03,
      ending in Room 04's ceiling; a ladder with a stop at Room 03's floor
- [ ] The generator room (greybox, 6 x 2, under Room 01), entered through a doorway
      from Room 04
- [ ] Camera in a large room: a window of at most 3 x 1 cells following the robot
      (x and y); the whole-room framing kept as an option; compare on screen
- [ ] Check with a scripted run: down two floors, through the doorway into the
      generator room, and back up to Room 02

### F. Inventory
- [ ] `Item`, `Inventory` with counts; tests
- [ ] Pick-up action (a gesture, a clip in `build_robot.py`), items in rooms derived
      from the state
- [ ] Screen-space overlay: inventory bar, remarks moved off ImGui
- [ ] Use an item on a hotspot: select, then click; the room's `use` gets it
- [ ] First use: fuses for the generator room (count shown)

### G. Engine: model nodes
- [ ] `ModelInstance`: node by name, per-node transform override without an animator,
      per-node params, ray pick against node bounds; tests
- [ ] `examples/draw_test` and angrybot still right

### H. The first puzzle panel
- [ ] `Mode.panel`: camera to the panel's framing and back, input to the panel
- [ ] The generator panel: logic struct with tests (switches, a valve, gauges, lamps;
      solved state brings main power)
- [ ] `the-station/blender/build_panel_generator.py`: the panel glb with named nodes
- [ ] In the game: clicks on nodes, nodes posed and lit from the state
- [ ] The result elsewhere: main power on lights the control room, the mimic board's
      lamps, the screen's message

## Notes & Decisions

- 2026-10-29: written after a review of `games/the_station` (in conversation, John).
  Findings that shaped it:
  - Working well and kept: `Hotspot` (stand point, facing, action) and the robot's tasks
    (walk, turn, act, effect at a time in the gesture, `pending`); drawing reads state
    each frame (`deck.DrawState`); `navigation.zig`'s rectangles; logic apart from GPU
    code.
  - `room_01.zig` is both Room 01 and the shared kit: room_02, robot, ink, and deck
    import it for `Part`, `box`, `grey`, `Hatching`, facings, door sizes.
  - A room is named by hand in `RoomId`, `roomCenterX`, `equipment: [2]`, the doorway
    walk area, `roomAt`, `deckLights`'s loop, `otherSideOfDoor`.
  - `roomAt` splits on x; a room below doesn't fit. Room 02's contents use world x.
  - State is `Game.is_alarm_on`, `lights`, `is_door_open`; effects are one switch over
    one `HotspotKind` for every room.
  - Style: rename leftovers in comments, an `else` branch over `HotspotKind`, an `if`
    without braces in a switch arm (made an exception, John), a `.?`, constants after
    functions, `Ink` storing an allocator, 97 lines over 120 columns (mostly part
    tables; hence decision 5).
- 2026-10-29: plan 021 parked for this one (its open items: ink tuning, the lighter
  look).
- 2026-10-29 (John): a short `if` in a switch arm is fine on one line (second STYLE.md
  exception); the cell reading (2.8 x 3.4 m, depth 4 m) is right; the generator room is
  6 x 2. At the same framing as Room 01 the robot would be half as large there, hence
  the camera window (Design, "Framing large rooms").
- 2026-10-29 (John): two rooms under Room 02, joined by the ladder; the player goes
  down two floors and enters the generator room through a doorway, so the generator
  room lines up with the other rooms. Agreed: its floor and top match the stacked rooms,
  the entrance is the door connection already planned, and no 6.4 m climb in view.
  Placed under Room 01 (Claude's suggestion, the control room over its generator).
- 2026-10-29, phase A, as built: STYLE.md's two exceptions (sections 5 and 11); the
  rename leftovers; `sendToHotspot` lists every `HotspotKind`; `Equipment.draw` unwraps
  the model with `if`; deck's constants above its types and a scoped log; `Ink.update`
  takes the allocator (each resize still allocates the new target's struct in the
  arena, freed when the arena resets); the settings file is
  `the-station/settings/the_station.zon` (moved with `git mv`, values kept) and the panel
  is "the station" (ImGui forgets its position once). Tests:
  `games/the_station/tests.zig`, run by `zig build test`, imports the logic files;
  `navigation.zig` has six (one area, clamping, the doorway open and shut, around the
  hole, edges). Two expectations were wrong at first, not the code: the test doorway
  also touched the strip beside the hole, and a crossing is the shared edge's point
  nearest the next point (straight above the target, not the strip's corner).
- 2026-10-29, phase B, as built: `room_kit.zig` holds the grid (`CELL_WIDTH` 2.8,
  `CELL_HEIGHT` 3.4, `insideWidth` / `insideHeight` from cells, exact at compile time:
  3 cells give 8.0), `DEPTH`, `WALL`, the door sizes and place, the deck below, the
  facings, `Part`, `drawPart`, `Hatching`, `box`, `cylinderModel`, `grey`, `bounds`, and
  `PartBuilder` with `addShell(shell)` and `addCeilingLights` (now given the room's
  height). A `Shell` is the room's center, inside size, each side (`solid`, `doorway`
  with its door `separate` or `locked` and whether it is framed outside, or `neighbor`:
  the room beside builds the wall, and floor, ceiling, and back wall stop at it), and an
  optional hole with its shaft. `room_01.shell` and `room_02.shell` replace
  `addShell` / `addDoorway` and `addRoomBox` / `addLockedDoor` / `addShaft`; each room's
  greybox is its `addGreybox`. robot, ink, deck, and main use the kit; room_02 still
  imports room_01 for `HotspotKind` until phase D. The kit is in `tests.zig`
  (`refAllDecls`, and a test of the grid).
  Checked: captures of both rooms, models and greybox, before and after (temporary
  edit: alarm off, emergency lights, door open, placeholder robot): identical except
  the hover outline under wherever the mouse sat.
- 2026-10-29 (John): the hotspots' white boxes are out of place; controls should light
  up themselves, subtly, in a way that fits them; doorways and the ladder need no
  highlight. Amber, saving red for dramatic things. Added as phase B2, before C.
- 2026-10-29, phase B2, as built:
  - Engine: `core.MeshParams` and `ModelInstance.drawWithMeshParams` (the meshes listed
    get their own params; live, baked, and no animator; `drawWithParams` passes none),
    `ModelInstance.findMesh(name)` by glTF mesh name; test of `meshParams`. draw_test and
    angrybot checked on screen.
  - the-station: `room_kit.join_groups` names each joined mesh for its group; the console's
    buttons (`lights_button`, `door_button`, `red_button`) and `lever` are groups of their
    own in `build_room.py`; Room 02's `keypad` already was. Both rooms re-exported.
  - Game: `Hotspot.mesh` (the four console controls, the keypad); `Deck` finds each at
    init (`highlight_meshes`, a warning for a missing name) and draws the hovered one with
    `params.x` = the highlight; `Game.highlighted` / `highlight` ease in and out
    (`HIGHLIGHT_RATE` 20, `motion.dampAlpha`), a hotspot newly under the mouse starts
    unlit; the highlight breathes 20% at 0.8 Hz (`main.highlight`).
  - Shader (`ink_common.wgsl`): `highlighted` adds amber (1.0, 0.55, 0.12 linear) at 0.12
    over the control plus 0.5 times a rim (`(1 - n.v)^2`); `highlightedInk` thins its
    hatching by up to 70%. Panel: Ink "highlight" (strength, 0..2, default 1), Room
    "hotspot bounds" (the old white box, off).
  - Hand cursor over every hotspot through ImGui (`zgui.setMouseCursor`; its GLFW backend
    sets the cursor each frame, so a GLFW cursor would be overwritten).
  - Checked with captures (temporary edit forcing the highlight): the red button turns
    amber-orange, the black lever amber-tan, the keypad amber. Strong on dark parts; the
    strength slider is for tuning it.
- 2026-10-29 (John): cursors of our own that fit the game. Drawn by the game (sharp on
  Retina, animated, an item's icon later), not GLFW image cursors (1x on macOS). Added
  as phase B3, the first user of phase F's overlay.
- 2026-10-29, phase B3, as built:
  - `the-station/ui/build_cursors.py` writes `ui/cursors.svg` (64 px cells: walk arrow,
    pointing hand, eye, exit left and right, ladder, climb down and up; ink outline 6 on a
    light fill, shapes outlined first and filled after so overlaps read as one) and
    `ui/cursors.png` through `rsvg-convert`. The first hand, one finger up from a closed
    hand, read as a rude gesture; redrawn with the finger at the side and a thumb.
  - `overlay.zig` (`Overlay.draw`: a sheet's uv rectangle at a window rectangle, window
    units from the top-left, the square placed in clip space) and `shaders/overlay.wgsl`
    (`.texture` material, uv from `params`); the sheet loads with `flip_v = false`.
  - `cursor.zig`: `Cursor` (in the sheet's order; click points: the arrow's tip, the
    finger's tip, the others' middle), `CursorSheet` drawn 32 units at the mouse,
    rounded to whole units. Drawn after the lines, before ImGui, not over the panel.
    `main.setOsCursor`: `.none` over the game with the sheet (ImGui's backend hides the
    OS cursor), the hand as before without it.
  - `Game.cursor`: floor and nothing walk; an open door the exit toward the other room
    (Room 02 is left of Room 01), closed its action; the ladder and the hole: climb from
    the floor, down from the top (the hole), up from below; the ladder's upper part at
    the top does nothing, so the arrow; others by action (push: hand, look: eye). Tests
    in game.zig (`tests.zig` imports it).
  - Checked with captures (temporary edit setting the mouse): hand on the red button (lit
    amber), eye on the screen, left arrow on Room 01's open door, right on Room 02's,
    ladder on the ladder, arrow on the floor.
- 2026-10-29, phase C, as built:
  - `station.zig` (was `deck.zig`): `Room` (name, lower-left cell, size in cells, model
    path, shell, walk areas, hotspots, `addGreybox`; `origin`, `width`, `height`), `RoomId`,
    `rooms`, `place(id, point)`. Built at compile time from the rooms: `hotspots` and the
    room each is in, `walk_areas` (with the doorway between Rooms 01 and 02 until phase
    E), `ladder`. `roomAt(position)`: inside a room's walls (to their middles) from the
    deck below to its ceiling, else the nearest. `framing(id)`, `interior(id)`,
    `isVisible` (the room's opening, or its back seen from the eye, overlaps the view;
    `RoomCamera.depthScale`), `emergencyLightPosition`. `HotspotKind` and `Hotspot` live
    here until phase D.
  - A room's origin is on the grid: x `(column + cells_wide / 2) * 2.8`, y `row * 3.4`,
    so Room 01's center is x 4.2 and Room 02's -4.2 (they were 0 and -8.4); nothing on
    screen changes, as the camera follows the rooms. `room_kit.insideWidth` takes a
    runtime count, in f64 first so 3 cells are exactly 8 m. `Shell` lost its center;
    `placeParts` moves a room's parts onto the station; the models draw at the room's
    origin.
  - Rooms 01 and 02 export `room` in their own coordinates; Room 02's numbers moved by
    +8.4 (`build_room_02.py` too: `CENTER_X` 0; every mesh's bounds moved by exactly 8.4).
  - Drawing and lighting: only the visible rooms (`DrawState.visible`); point light 0 the
    alarm (Room 01 visible), then one emergency light per visible room, up to 4.
  - The camera pans a `Framing` (`main.panTo`, center x and y), so a room on another
    row will pan too. The floor grid follows the robot's room (it was Room 01's always).
  - `robot_placeholder.zig`: the box robot's drawing, out of `robot.zig` (now the tasks
    only; `Robot.armAngle` public for it).
  - Tests: the rooms' origins, `roomAt` (the shared wall, the ladder's bottom), placed
    hotspots in their rooms, `isVisible` (the neighbor at the edge; a far view).
  - Checked with captures of both rooms before and after (models and greybox): Room 01
    the same but the cursor and label under the real mouse; Room 02 the grid (now its
    own) and its equipment's hatch lines shifted a little: the model hatches in its
    mesh's coordinates, which moved 8.4 m.

