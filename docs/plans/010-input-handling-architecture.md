# Plan 010: Input Handling Architecture

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Discussion. Paths below refer to redfish; bullets was reorganized in the port.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Status**: Discussion / Design Exploration
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