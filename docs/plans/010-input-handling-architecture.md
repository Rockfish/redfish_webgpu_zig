# Plan 010: Input Handling Architecture

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** made active 2026-10-01 after the review at the end; phases there. Paths below refer to redfish; bullets was reorganized in the port.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: Parked 2026-10-04 (phases 1-3 done). Where it stands: `core.Input` has
`isDown` / `pressedOnce`, works with ImGui, and reads gamepads (macOS mappings in
`src/core/gamecontrollerdb_macos.txt`); `motion.FollowCamera` drives the bullets
characters' third-person camera. Next step if resumed: the "Later" items (demo_app /
level_01 / angrybot onto `core.Input`; the capturable-turret game scenario).
**Created**: 2026-02-11

## Context

The `processInput` function in `examples/bullets/scene/scene.zig` currently handles all input in a single switch over keys, with an inner switch on `motion_type` for movement keys. As the game grows to include a player, AI turrets (that can be player-captured), and a camera that switches between player-follow and free-debug modes, the input handling needs a clearer architecture.

### Current Pain Points

1. **Repetitive structure**: Eight movement keys each contain identical inner switches on `motion_type`, differing only in the `MovementDirection` enum value.
2. **Flat dispatch**: Everything lives in one function. Adding a new controllable object means more branches.
3. **Shared state is implicit**: `motion_type` and `motion_object` are scene-level fields that change how keys behave, but the relationship between these flags and the objects they affect isn't structured.

### Game Scenario

- **Player**: Moves through the world and fires at turrets. Always player-controlled.
- **Turret**: AI-controlled enemy that aims and lobs slow projectiles at the player. Can be captured and switched to player control.
- **Camera**: Follows the player during gameplay. Switchable to free camera for debug/development.

## Immediate Cleanup: Switch on Motion Type First

Before choosing a larger architecture, the movement block can be restructured for clarity. Currently the code switches on key, then on motion_type inside each key. Inverting this puts the game concept first:

```zig
// Current: switch key → switch motion_type (repeated 8 times)
.w => {
    switch (self.motion_type) {
        .translate => movement_object.processMovement(.forward, dt),
        .orbit    => movement_object.processMovement(.orbit_up, dt),
        .circle   => movement_object.processMovement(.circle_up, dt),
        ...
    }
},
.s => {
    switch (self.motion_type) {
        .translate => movement_object.processMovement(.backward, dt),
        ...
    }
},
// ... 6 more nearly identical blocks

// Proposed: switch motion_type → map keys to directions (once per mode)
switch (self.motion_type) {
    .translate => {
        switch (k) {
            .w, .up    => movement_object.processMovement(.forward, dt),
            .s, .down  => movement_object.processMovement(.backward, dt),
            .a, .left  => movement_object.processMovement(.left, dt),
            .d, .right => movement_object.processMovement(.right, dt),
            else => {},
        }
    },
    .orbit => {
        switch (k) {
            .w, .up    => movement_object.processMovement(.orbit_up, dt),
            .s, .down  => movement_object.processMovement(.orbit_down, dt),
            .a, .left  => movement_object.processMovement(.orbit_left, dt),
            .d, .right => movement_object.processMovement(.orbit_right, dt),
            else => {},
        }
    },
    .circle => { ... },
    .rotate, .look => { ... },
}
```

**Advantages**: Each motion mode is a self-contained block showing its complete key mapping. Adding a new mode means adding one block, not editing eight key handlers. The key-to-direction mapping for each mode is visible at a glance.

**This is a standalone improvement that works regardless of which larger pattern is chosen below.**

## Approaches to Consider

### 1. Input Context Stack (Mode-Based)

The game defines discrete input modes. Only the active mode's handler runs. Modes can be pushed/popped like a stack.

```
Modes:
  gameplay        → WASD moves player, mouse aims, click fires
  turret_control  → WASD/mouse aims captured turret, click fires
  debug_camera    → WASD moves free camera, no gameplay effect
```

**How it works**:
```zig
const InputMode = enum { gameplay, turret_control, debug_camera };

// Scene holds the active mode
input_mode: InputMode = .gameplay,

fn processInput(self: *Self, input: *core.Input) void {
    switch (self.input_mode) {
        .gameplay => self.processGameplayInput(input),
        .turret_control => self.processTurretInput(input),
        .debug_camera => self.processDebugCameraInput(input),
    }
}
```

Each handler function is focused and short. Mode switching happens on specific keys (e.g., Tab to toggle debug camera, E to take/release turret control).

**Pros**:
- Clean separation. Each mode is easy to understand in isolation.
- Maps directly to player intent. "What can I do right now?" has one clear answer.
- Natural fit for the capture-turret mechanic: entering turret_control mode changes everything about what keys do.
- Common pattern in indie games (Godot's InputMap, Unity's Input Action Maps).

**Cons**:
- Some keys need to work across modes (Escape, F12 screenshot, debug toggles). These either go in a shared pre-pass or are duplicated.
- Mode transitions need care: what happens to the player when you switch to turret control? Does the player stop moving, or keep their last velocity?

### 2. Two-Phase Flag Dispatch

The scene runs a first pass to set flags on objects, then each object processes input based on its flags. This is what the `is_visible` pattern already does for rendering.

**How it works**:
```zig
fn processInput(self: *Self, input: *core.Input) void {
    // Phase 1: Scene decides object states based on game logic
    self.player.accepting_movement = (self.control_target == .player);
    self.player.can_fire = true;
    self.turret.player_controlled = (self.control_target == .turret);
    self.camera.free_mode = self.debug_camera_active;

    // Phase 2: Objects process input based on their flags
    self.player.processInput(input);
    self.turret.processInput(input);
    self.camera.processInput(input);
}

// In Player:
fn processInput(self: *Player, input: *core.Input) void {
    if (self.accepting_movement) {
        // handle WASD
    }
    if (self.can_fire and input.mouse_left_button) {
        // fire
    }
}
```

**Pros**:
- Objects own their input logic. Adding a new object means adding `processInput` to that object.
- Flags are explicit and inspectable. You can print the flag state to debug "why isn't the player moving?"
- Flexible: multiple objects can respond to the same input simultaneously if flags allow it.
- Scene stays in control of the rules without knowing the details of each object's input handling.

**Cons**:
- Objects need to agree on which keys they use. Two objects both responding to WASD requires the flags to be mutually exclusive, and the scene must enforce that.
- The flag-setting phase can grow complex as objects and rules increase.
- Input conflicts are resolved implicitly by flag combinations rather than explicitly by mode.

### 3. Central Dispatcher with Lookup Table

Rather than a big switch, use a data-driven mapping from (mode, key) to action. The dispatcher is generic; behavior is defined by tables.

**How it works**:
```zig
const Action = union(enum) {
    move: MovementDirection,
    fire,
    toggle_mode: InputMode,
    toggle_floor,
    toggle_animation,
    screenshot,
    none,
};

// Table per mode
const gameplay_bindings = [_]KeyBinding{
    .{ .key = .w,     .action = .{ .move = .forward } },
    .{ .key = .s,     .action = .{ .move = .backward } },
    .{ .key = .space, .action = .fire, .one_shot = true },
    .{ .key = .tab,   .action = .{ .toggle_mode = .debug_camera }, .one_shot = true },
};

fn processInput(self: *Self, input: *core.Input) void {
    const bindings = self.getBindingsForMode(self.input_mode);
    var iterator = input.key_presses.iterator();
    while (iterator.next()) |k| {
        const action = lookupAction(bindings, k) orelse continue;
        if (action.one_shot and input.key_processed.contains(k)) continue;
        self.executeAction(action, input.delta_time);
        if (action.one_shot) input.key_processed.insert(k);
    }
}
```

**Pros**:
- Key bindings are data, not code. Easy to add, remove, or remap.
- The continuous vs one-shot distinction is part of the binding, not the handler.
- Could eventually support rebindable keys or loading bindings from a config.

**Cons**:
- More infrastructure to build upfront (Action enum, binding tables, executor).
- The `executeAction` function can become its own big switch.
- May be over-engineered for a game with a small, stable set of controls.

### 4. Per-Object Input Interfaces

Objects implement an input interface. The scene iterates through "input receivers" in priority order.

**How it works**:
```zig
const InputReceiver = struct {
    processInputFn: *const fn (*anyopaque, *core.Input) bool,
    context: *anyopaque,
};

fn processInput(self: *Self, input: *core.Input) void {
    for (self.input_receivers) |receiver| {
        const consumed = receiver.processInputFn(receiver.context, input);
        if (consumed) break;  // first handler that claims input wins
    }
}
```

**Pros**:
- Fully decoupled. Objects don't know about each other.
- Priority ordering handles conflicts naturally.
- Easy to add/remove receivers dynamically (e.g., when capturing a turret, insert it at the front).

**Cons**:
- `*anyopaque` and function pointers lose type safety. Zig's comptime interfaces or tagged unions would be better but add complexity.
- "Who consumed the input?" is harder to debug than explicit mode-based dispatch.
- Shared keys (WASD used by both player and camera) require careful priority management.

## Recommendation

**Start with Approach 1 (Input Context Stack), using elements of Approach 2 (flags) for cross-cutting concerns.**

Here's why this fits the game scenario:

1. **The modes map directly to game states**: The player is either controlling themselves, controlling a captured turret, or in debug camera mode. These are mutually exclusive — you can't move the player and aim the turret simultaneously. A mode enum captures this exactly.

2. **Flags handle the edges**: Some things span modes. The AI turret keeps firing regardless of what mode the player is in. The player's health still decrements. These aren't input concerns — they're update-loop concerns. The turret's AI runs in `update()`, not `processInput()`. Flags like `turret.player_controlled` tell the turret's update whether to run AI targeting or wait for player input.

3. **It scales to the target complexity**: Player + turret + camera with three modes is 3 focused handler functions of ~30 lines each, versus one 200-line function. Each mode is independently testable and readable.

4. **The capture mechanic is clean**: Player walks up to turret, presses E → mode switches to `turret_control`. The turret gets `player_controlled = true`, its AI stops, and the turret input handler reads WASD/mouse. Press E again → mode returns to `gameplay`, turret goes back to AI.

### Suggested Structure

```zig
const InputMode = enum {
    gameplay,
    turret_control,
    debug_camera,
};

fn processInput(self: *Self, input: *core.Input) void {
    // Global one-shot keys (work in all modes)
    self.processGlobalKeys(input);

    // Mode-specific input
    switch (self.input_mode) {
        .gameplay => self.processGameplayInput(input),
        .turret_control => self.processTurretInput(input),
        .debug_camera => self.processDebugCameraInput(input),
    }
}

fn processGlobalKeys(self: *Self, input: *core.Input) void {
    var iterator = input.key_presses.iterator();
    while (iterator.next()) |k| {
        if (input.key_processed.contains(k)) continue;
        switch (k) {
            .F12 => { /* screenshot */ },
            .f => { /* toggle floor */ },
            .tab => {
                self.input_mode = if (self.input_mode == .debug_camera)
                    .gameplay
                else
                    .debug_camera;
            },
            else => {},
        }
        input.key_processed.insert(k);
    }
}

fn processGameplayInput(self: *Self, input: *core.Input) void {
    // Player movement (continuous)
    // Player firing (one-shot or continuous)
    // E to capture turret → switch to turret_control
}

fn processTurretInput(self: *Self, input: *core.Input) void {
    // Turret aiming (continuous)
    // Turret firing (one-shot)
    // E to release turret → switch back to gameplay
}

fn processDebugCameraInput(self: *Self, input: *core.Input) void {
    // Free camera movement (continuous)
}
```

### What the AI Turret Does

The turret's AI doesn't live in input handling at all. It lives in `update()`:

```zig
// In turret.update():
fn update(self: *Turret, delta_time: f32, player_position: Vec3) void {
    if (!self.player_controlled) {
        // AI: track and fire at player
        self.controller.setTarget(player_position);
        self.controller.update(delta_time);
        if (self.controller.isOnTarget(5.0)) {
            self.fire();
        }
    }
    // else: player controls via processTurretInput, AI is idle
}
```

This separates the concerns cleanly: input handling decides *what the player wants to do*, update logic decides *what happens this frame*.

## When to Revisit

This approach works well for the initial scenario (player + 1-2 turrets + camera). Signs it's time to evolve:

- **More than 4-5 modes**: The mode switch gets unwieldy. Consider the lookup table approach (3) at that point.
- **Multiple simultaneous player-controlled objects**: Modes assume mutual exclusivity. If the player needs to control two things at once, the flag approach (2) fits better.
- **Rebindable keys**: The data-driven approach (3) becomes necessary.
- **Large numbers of input-receiving objects**: The interface approach (4) with priority ordering starts to make sense.

For now, keep it simple. Three focused functions beat one generic system.

## Review 2026-10-01: plan vs. bullets and `core.Input`

### What bullets does now

Three layers, each a pass over `input.key_presses`, with `input.key_processed` marking a
one-shot key as used until it's released:

1. **App** (`run_app.zig`): Page Up / Page Down switch scenes.
2. **Mode** (`SceneDebug.processInput`): a switch on `motion_object` (camera, cannon,
   turret, spacesuit, soldier) calls that object's own `processInput`. The object owns its
   keys (arrows aim the cannon, W/A/S/D walk the soldier, ...).
3. **Global** (the same function, after the mode): one-shot keys that work in every mode:
   C / N / T / M / Z pick the mode, B skybox, F floor, L level the camera, R fire the
   turret, -/= projection, Space pause the animation.

That is the plan's recommendation (approach 1, a mode switch, with objects owning their
input as in approach 2) in all but name. The "immediate cleanup" is moot: the
`motion_type` × key switch from redfish is gone, left behind only as commented-out code.

### Problems found

- **Dead code** in `debug_scene.zig`: the commented-out `motion_type` block (~35 lines),
  the commented bodies of keys 3-7 and 0, the `MotionType` enum and `motion_type` field
  (only printed), and the `base`, `gimbal`, `enemy` members of `MotionObject`.
  `FreeCamera.processInput` ends with a one-shot check that does nothing.
- **Mode and global keys collide, resolved only by call order.** A mode handler that
  doesn't mark its key processed lets the global pass act on it too:
  - Soldier mode: Space makes the soldier jump *and* pauses the turret's animation.
  - Turret mode: one R press fires twice in the first frame (`Turret.processInput` fires
    without marking R, then the global `.r` fires again). Harmless only because
    `createBullets` replaces the group.
  - Cannon mode works because `Cannon.processInput` marks R first.
- **The one-shot pattern is repeated by hand**: `contains(k) and !key_processed.contains(k)`
  then `insert(k)`, in run_app, the scene, cannon, turret, soldier, and demo_app's copy.
  Forgetting the `insert` is how the double-fire happens.
- **`core.Input` itself**:
  - The mouse handler sets both button flags from each event, so any button event
    overwrites the other button (pressing or releasing right clears a held left).
  - `scroll_xoffset` / `scroll_yoffset` are never cleared (consumers watch `update_tick`).
  - `key_shift` / `key_alt` only change on key events.
  - Policy in core: the key callback closes the window on Escape, and `init` resets the
    GLFW clock (`glfw.setTime(0)`).
  - A single global (`pub var input`), and its GLFW callbacks replace ImGui's, so an app
    with a panel can't use it.

### Input across the repo

Three styles, none shared:

| Style | Apps |
|---|---|
| `core.Input` (callbacks, `key_presses` / `key_processed`) | bullets, animation_example, scene_tree, skybox |
| Their own copy of the same pattern in `state.zig` | demo_app, level_01, angrybot (from redfish) |
| Polling `window.getKey` with `zgui.io.getWantCaptureKeyboard()`, edge-detecting by hand (`space_was_down`) | camera_rig, shadows, turrets |

### Recommendation

The plan's direction holds; what's missing is small and mostly cleanup, not architecture:

1. **`core.Input` helpers**: `isDown(key)` and `pressedOnce(key)` (true on the first frame
   of a press, and marks it processed), so one-shot handling is one call and can't be half
   done. Then fix the mouse buttons (one set of held buttons), clear scroll each frame,
   take Shift / Alt from the key set, and move Escape-to-close to the apps.
2. **bullets debug scene**: delete the dead code; rename `motion_object` to an
   `InputMode`-style name; split `processInput` into `processModeInput` and
   `processGlobalKeys` as the plan sketches; have every handler use `pressedOnce`, which
   fixes the double fire and the Space collision (or move pause off Space).
3. **ImGui**: let `core.Input` either chain to ImGui's callbacks or poll
   (`window.getKey`) and skip keys ImGui wants, so the panel apps can use it too. Moving
   demo_app / level_01 / angrybot onto `core.Input` can wait; their copies work and match
   redfish.

Approaches 3 (binding tables) and 4 (receivers) stay unneeded: bullets has five modes and
fixed keys. The game scenario's capturable turret now has a natural shape from plan 008:
AI is the turret's pattern in `update`; capturing it would swap in a manual pattern whose
target yaw and pitch come from input, with the mode switch deciding who gets the keys.

## Phases (2026-10-01)

### Phase 1: `core.Input` helpers and the bullets debug scene (done 2026-10-01)
- [x] `Input.isDown(key)`, `Input.pressedOnce(key)` (true on a press's first ask, marks the
      key processed until release)
- [x] Mouse buttons: each event changes only its own button
- [x] Scroll: callbacks add up into `pending_scroll`; `update` hands out the frame's
      scroll and clears it
- [x] `key_shift` / `key_alt` from the held keys (either side), not the event's mods
- [x] Escape no longer closes the window in core: bullets, skybox, and scene_tree check
      `isDown(.escape)` in their loops (animation_example has its own key callback that
      already did)
- [x] bullets debug scene: dead code deleted (`MotionType`, `motion_type`, the
      commented-out blocks, `printMotionViewState`); `MotionObject` → `InputMode` with only
      the five modes used; `processInput` = `processModeInput` then `processGlobalKeys`,
      the global keys as `pressedOnce` calls grouped by purpose
- [x] Objects' one-shot keys through `pressedOnce`: turret and cannon R, soldier and
      spacesuit actions; held keys through `isDown`. `FreeCamera`'s no-op one-shot check
      deleted; run_app's Page Up / Down use `pressedOnce`
- [x] Tests: `pressedOnce` and `isDown` across press, hold, release; Shift / Alt from
      either side; one mouse button released leaves the other held

### Phase 2: ImGui (done 2026-10-02)
- [x] `core.Input` alongside ImGui: `Input.init` before `gui.init`, so ImGui's GLFW
      backend chains to Input's callbacks; `update` reads ImGui's want-capture flags
      (when an ImGui context exists), and `isDown` / `pressedOnce` see no keys while ImGui
      wants the keyboard, `isMouseDown` no buttons and the scroll is zero while it wants
      the mouse
- [x] camera_rig, shadows, turrets on `core.Input`: no more `window.getKey` polling,
      hand-made edge detection (`space_was_down`), or capture checks; frame time from
      `input.update`

### Phase 3: Game controller
Driving the soldier and the spacesuit (bullets) with a gamepad: one stick moves the
character, the other turns a third-person camera that follows it, in the style of Zelda:
The Wind Waker (and Halo's).

- [x] **Gamepad in `core.Input`**: GLFW's gamepad API (`glfwGetGamepadState`, standard
      mappings from SDL's GameControllerDB), polled in `update`: sticks as `Vec2` with a
      radial dead zone and a response curve (fine control near the center), triggers
      0..1, buttons with `isButtonDown` / `buttonPressedOnce` like keys, connect /
      disconnect.
- [x] **Camera-relative movement**: the move stick's direction is turned by the camera's
      yaw (`motion.cameraRelativeMove`), so pushing up always moves away from the camera;
      the character turns toward its move direction (`dampAngle`), walks or runs by how
      far the stick is pushed.
- [x] **Follow camera** (`motion.FollowCamera`): orbits the character at a distance and
      height; the camera stick turns it around the character (yaw) and up / down (pitch,
      limited); it follows with lag (`dampVec3`); a button recenters it behind the
      character. Swinging behind the moving character came out as a leash rather than an
      auto-recenter (see the phase 3 note).
- [x] Keyboard and gamepad drive the same characters: the stick while it's pushed, the
      keyboard otherwise; arrow keys turn the follow camera too.
- [ ] Later, with plan 012's blend space: walk / run blending by stick magnitude.

Sticks (decided 2026-10-02, John): as Wind Waker and Halo, the left stick moves the
character and the right stick turns the camera.

### Later
- demo_app / level_01 / angrybot onto `core.Input` (their `state.zig` copies work and match
  redfish)
- The game scenario: a player, and a turret the player can capture (a manual turret
  pattern fed by input; see the review)

## Notes & Decisions

**2026-10-01**: Phase 1 done.
- Fixed by `pressedOnce`: in turret mode one R fired twice in a frame; in soldier mode
  Space jumped and also paused the turret. A mode's handler now claims its keys before the
  global pass, so Space is jump / roll in the soldier and spacesuit modes and pause in the
  others.
- One-shot actions of the soldier and spacesuit used to re-request their state every
  frame the key was held (until the global pass marked it); now once per press.
- Kept: `Input.init` still resets the GLFW clock to 0; scene_tree and animation_example
  take their first frame's delta from it.
- Tests: 101 pass (3 new). bullets, skybox, scene_tree, and animation_example start
  without errors. (animation_example logs "Invalid animation id 4, max is 0": its
  starting `animation_index` is 4 for a model with one baked animation; not an input
  issue, left as is.)
- Next: phase 2.

**2026-10-02**: Phase 2 done.
- ImGui chains to callbacks installed before it, and passes every key and click on, even
  while a text field has focus; so the capture check lives in `Input.update` (ImGui's
  want-capture flags), and every reader of keys goes through `isDown` / `pressedOnce`.
  The flags come from the previous frame's ImGui frame, as ImGui intends.
- `key_shift` / `key_alt` read the held-key set directly, so they work while ImGui has
  the keyboard (ImGui's own shortcuts).
- Typing a value into an ImGui slider takes Cmd+click (ImGui's Ctrl is Cmd on macOS) or
  Tab first; a plain click drags. Unchanged by this phase: ImGui gets every event.
- camera_rig's C (recenter) is now once per press; it was every frame while held, with
  the same result.
- Tests: 102 pass (1 new: no keys while ImGui wants the keyboard, the held key counting
  once ImGui lets go). camera_rig, shadows, and turrets start without errors.
- Next: phase 3, game controller.

**2026-10-03**: Phase 3 done (not yet tried with a real controller here).
- `core.Input`: `gamepad` (`GamepadInput`: `is_connected`, `left_stick` / `right_stick`
  with +y up, `left_trigger` / `right_trigger` 0..1, buttons), read from the first
  joystick GLFW recognizes as a gamepad, each `update`. `shapeStick(x, y, dead_zone,
  exponent)`: radial dead zone (0.15), the rest of the travel stretched to 0..1 and bent
  by an exponent (1.5), so small pushes give fine control; tested. Button names are
  GLFW's Xbox names (`.a` is the bottom face button, cross on a PlayStation pad).
- `motion.cameraRelativeMove(stick, camera_yaw)`: the stick as a world direction on the
  ground, relative to the camera; tested.
- `motion.FollowCamera`: the camera keeps its place each frame and turns to face the
  character's (damped) look-at point, then steps to its distance: a leash. Walking
  sideways swings it around, walking toward it pushes it back, walking away pulls it
  along behind. That gives the Wind Waker feel without an auto-recenter rule (which would
  spin the camera around a character running toward it). The stick turns it (+x turns the
  view right, +y up, at `yaw_speed` / `pitch_speed` per second), pitch is limited,
  `recenter_yaw` swings it behind the character. Tests: still with a still character;
  the same turn at 10, 60, and 144 fps; pulled behind and swung around; pitch limits;
  recenter.
- bullets: `objects/character_control.zig` drives a character along the stick's
  direction (turning its +Z, the glTF front, toward it; walk below 75% stick, run above)
  and gives the camera yaw behind it. The soldier and the spacesuit get `drive(move,
  input)` and their actions on the face buttons (A jump / roll, X, B, Y the others). In
  their modes the debug scene puts the follow camera on the character (reset behind it
  on switching): left stick moves, right stick or arrow keys turn the camera, left
  trigger or Q recenter, V switches to the free camera and back.
- Checked with a temporary edit faking the left stick: the spacesuit turns and runs where
  the stick points, with the run animation, and the camera swings after it.
- Tests: 109 pass (7 new).
- Fix (same day): John's Bluetooth Xbox controller wasn't read. GLFW listed it (GUID
  `030000005e040000130b000009050000`: Xbox Series controller, firmware 5.x) but not as a
  gamepad: GLFW's built-in copy of SDL_GameControllerDB predates that firmware. Now
  `src/core/gamecontrollerdb_macos.txt` (the database's macOS lines, 325 controllers,
  zlib license, how to refresh in its header) is embedded and given to GLFW in
  `Input.init` (`updateGamepadMappings`), and a joystick that's connected without a
  mapping is logged once with its GUID.
