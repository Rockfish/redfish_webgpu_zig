# Plan 012: Animation Finite State Machine

> Imported from redfish_gl_zig on 2026-09-28. **In this repo:** Phases 1-2 implemented (`src/core/animation_fsm.zig`, used by the spacesuit and toon soldier in bullets); phase 3 open. See the 2026-09-28 review notes at the end.
> File and API references in the body are to redfish_gl_zig (OpenGL) unless noted.

**Where it stands (2026-10-04):** `src/core/animation_fsm.zig` drives the spacesuit and
toon soldier in `examples/bullets`. Review item 5 (sliding through actions) is fixed.
**Redirected 2026-10-04** by the tower attack spec,
`docs/reviews/2026-10-04-link-style-controller-review.md`: Wind Waker-style control for
a captain (the toon soldier) with a squad of 6, first-person aim and shoot, a turret
range. Its phases (section 12) replace the order below: **A** units, scale, FSM fading
list and clip time with rate matching (in progress); **B** ground motor and jump;
**C0** `src/core/gameplay/`; **C** turret range scene; **D** first person; **E-G** squad.
Review item 6 (roll travel) and items 2-3 (blend space, phase sync) are deferred.

**Status**: Active (resumed 2026-10-04; phases 1-2 done, review item 5 fixed; tower attack spec phase A in progress)
**Priority**: High
**Estimated Effort**: Medium (3-4 days)
**Created**: 2026-02-16
**Related**: Plan 004 (Animation System - Phase 2)

## Overview

Implement a reusable Animation State Machine (FSM) for character animation control. The FSM provides a clear, extensible pattern for mapping input to animation states with smooth crossfade transitions. The first consumer is the Spacesuit model in `examples/bullets`, but the design is generic and serves as a template for any animated character.

## Motivation

The project currently has two animation control approaches, neither ideal for general use:

1. **Spacesuit (direct switch)** — Picks an animation enum per frame and calls `playAnimationById()`. Simple but animations pop instantly with no transitions. Hard to handle one-shot actions (punch, roll) that should return to a previous state.

2. **Angrybot (weight blending)** — Computes per-frame weights for 6 animations based on movement direction relative to aim angle. Produces smooth directional locomotion but the weight math is opaque, tightly coupled to one specific setup, and difficult to extend with new animations.

An FSM is the standard indie game approach: easy to understand, easy to extend, and well-documented across the game development community.

## Design

### Core Concept

```
┌─────────────────────────────────────────────────┐
│ AnimationStateMachine(StateEnum)                │
│                                                 │
│  state_configs[] ─── maps enum → animation clip │
│  current_state   ─── what's playing now         │
│  previous_state  ─── what's fading out          │
│  crossfade_timer ─── blend progress             │
│                                                 │
│  requestState()  ─── "I want to be in state X"  │
│  update()        ─── advance time + crossfade   │
└─────────────────────────────────────────────────┘
```

The controller (Spacesuit) evaluates input each frame and calls `requestState(.walk)` or `requestState(.idle)`. The FSM handles:
- Whether the transition is allowed (current state interruptible?)
- Starting a crossfade from the old animation to the new one
- Advancing the crossfade blend over time
- Auto-returning to a default state when a one-shot animation finishes

### State Configuration

Each state is defined by a simple data struct:

```zig
pub const StateConfig = struct {
    animation_id: u32,            // glTF animation index
    repeat: AnimationRepeatMode,  // .Forever for locomotion, .Once for actions
    crossfade_in: f32,            // seconds to blend when entering this state
    interruptible: bool,          // can requestState() override this?
    return_state: ?u8,            // enum index to transition to when .Once completes (null = stay)
};
```

Examples for the Spacesuit:

| State | animation_id | repeat | crossfade_in | interruptible | return_state |
|-------|-------------|--------|-------------|---------------|-------------|
| idle | 4 | Forever | 0.15 | yes | null |
| walk | 22 | Forever | 0.15 | yes | null |
| run | 16 | Forever | 0.15 | yes | null |
| punch_left | 13 | Once | 0.10 | no | idle |
| roll | 15 | Once | 0.10 | no | idle |
| death | 0 | Once | 0.20 | no | null |
| wave | 23 | Once | 0.15 | yes | idle |

### Crossfade Mechanism

Uses the existing `updateWeightedAnimations()` API which already supports:
- Different `animation_index` per WeightedAnimation
- Accumulated `blendTransforms()` with `Vec3.lerp` and `Quat.slerp`
- Looping via `@mod(frame_time + offset, time_range)` when `optional_start` is 0
- One-shot via `@min(time, time_range)` when `optional_start > 0`

During a crossfade between state A (outgoing) and state B (incoming):

```
blend_factor = crossfade_elapsed / crossfade_duration   (0.0 → 1.0)

weighted_animations[0] = { animation_id_A, weight: 1.0 - blend_factor, ... }
weighted_animations[1] = { animation_id_B, weight: blend_factor, ... }
```

When not crossfading (steady state), a single WeightedAnimation at weight 1.0 is used, keeping the same code path for simplicity.

### Animation Duration Discovery

At init, the FSM queries `model.animator.animations[i].duration` for each state's `animation_id` to populate the `end_time` field of WeightedAnimation. The `Animation` struct already exposes `.duration`.

### One-Shot Return Behavior

When a `.Once` animation completes (tracked by comparing elapsed time against duration), the FSM auto-transitions to `return_state` with a crossfade. If `return_state` is null, the animation holds on its last frame (useful for death).

## File Structure

```
src/core/
└── animation_fsm.zig        # Generic FSM (new file)

examples/bullets/scene/
└── spacesuit.zig             # Updated to use FSM
```

The FSM lives in `src/core/` alongside `animator.zig` so any game or example can use it.

## Implementation Phases

### Phase 1: AnimationStateMachine Generic Struct

**File**: `src/core/animation_fsm.zig`

Create the comptime-generic FSM parameterized on a state enum.

**Public API**:

```zig
pub fn AnimationStateMachine(comptime StateEnum: type) type {
    return struct {
        const Self = @This();
        const state_count = @typeInfo(StateEnum).@"enum".fields.len;

        // Configuration (set at init, immutable after)
        state_configs: [state_count]StateConfig,
        animation_durations: [state_count]f32,

        // Runtime state
        current_state: StateEnum,
        previous_state: ?StateEnum,
        crossfade_elapsed: f32,
        crossfade_duration: f32,
        state_elapsed: f32,          // time in current state (for one-shot tracking)
        transition_frame_time: f32,  // frame_time when current transition started

        pub fn init(
            configs: [state_count]StateConfig,
            initial_state: StateEnum,
            animator: anytype,
        ) Self

        /// Request a state change. Respects interruptibility.
        /// Returns true if the transition was accepted.
        pub fn requestState(self: *Self, new_state: StateEnum) bool

        /// Force a state change, ignoring interruptibility.
        /// Use for death, damage reactions, etc.
        pub fn forceState(self: *Self, new_state: StateEnum) void

        /// Advance the FSM. Call once per frame.
        /// Handles crossfade blending and one-shot return transitions.
        /// Calls model.updateWeightedAnimations() internally.
        pub fn update(self: *Self, model: *core.Model, frame_time: f32, delta_time: f32) !void

        /// Query current state (for movement logic, sound triggers, etc.)
        pub fn getCurrentState(self: *const Self) StateEnum

        /// Is the FSM mid-crossfade?
        pub fn isTransitioning(self: *const Self) bool
    };
}
```

**Internal behavior of `update()`**:

1. Advance `state_elapsed` by `delta_time`
2. If crossfading: advance `crossfade_elapsed`, build 2-element WeightedAnimation array, call `model.updateWeightedAnimations()`
3. If crossfade complete: clear `previous_state`, continue with single animation
4. If steady state: build 1-element WeightedAnimation array, call `model.updateWeightedAnimations()`
5. If current state is `.Once` and `state_elapsed >= duration`: trigger return transition

**Acceptance Criteria**:
- [ ] Generic over any enum type
- [ ] Crossfade blending produces smooth visual transitions
- [ ] One-shot animations auto-return to configured state
- [ ] Non-interruptible states reject `requestState()` calls
- [ ] `forceState()` always works regardless of interruptibility
- [ ] Code formatted with `zig fmt`

### Phase 2: Integrate FSM into Spacesuit

**File**: `examples/bullets/scene/spacesuit.zig`

Replace the current direct-switch `processInput` with FSM-driven control.

**Changes**:

1. **Define state configs** — Map the `Animation` enum values to `StateConfig` entries. Start with a practical subset (idle, walk, run, punch_left, roll, wave, death) rather than all 24 at once. The rest can be added trivially later.

2. **Add FSM field** — Replace `current_animation: Animation` with `fsm: AnimationStateMachine(Animation)`

3. **Init** — Build config array, call `AnimationStateMachine.init()` with the model's animator

4. **Rewrite processInput** — Evaluate input and call `fsm.requestState()`:
    ```zig
    pub fn processInput(self: *Self, input: *core.Input) void {
        // One-shot actions (check first, higher priority)
        if (input.key_presses.contains(.space)) {
            _ = self.fsm.requestState(.roll);
        }

        // Locomotion
        if (input.key_presses.contains(.w)) {
            const fwd = self.transform.forward();
            self.transform.translation = self.transform.translation.add(
                fwd.mulScalar(self.translation_speed),
            );
            _ = self.fsm.requestState(.walk);
        } else if (input.key_presses.contains(.s)) {
            const fwd = self.transform.forward();
            self.transform.translation = self.transform.translation.sub(
                fwd.mulScalar(self.translation_speed),
            );
            _ = self.fsm.requestState(.walk);
        } else {
            _ = self.fsm.requestState(.idle);
        }
    }
    ```

5. **Update** — Replace `model.updateAnimation(delta_time)` with `fsm.update(model, total_time, delta_time)`

6. **Remove old animation switch logic** — The `if (self.current_animation != animation)` block goes away entirely

**Acceptance Criteria**:
- [ ] Spacesuit walks/idles with smooth crossfade transitions
- [ ] Roll plays once then returns to idle
- [ ] Wave plays once then returns to idle
- [ ] Movement still works (W/S translate correctly)
- [ ] No animation popping between states
- [ ] Code formatted with `zig fmt`

### Phase 3: Add Rotation and More States

**File**: `examples/bullets/scene/spacesuit.zig`

Extend the controller with turning and additional animation states.

**Changes**:

1. **A/D rotation** — Use `transform.rotateAxis()` on Y-axis for turning:
    ```zig
    .a => {
        self.transform.rotateAxis(vec3(0, 1, 0), rotation_speed * input.delta_time);
    },
    .d => {
        self.transform.rotateAxis(vec3(0, 1, 0), -rotation_speed * input.delta_time);
    },
    ```

2. **Run state** — Hold shift + W to run:
    ```zig
    if (input.key_presses.contains(.w)) {
        if (input.key_shift) {
            _ = self.fsm.requestState(.run);
            speed = self.run_speed;
        } else {
            _ = self.fsm.requestState(.walk);
            speed = self.translation_speed;
        }
        // translate...
    }
    ```

3. **Add remaining combat states** — Map number keys or mouse buttons to attacks:
    - `1` → punch_left
    - `2` → punch_right
    - `3` → kick_left
    - `4` → kick_right
    - `5` → sword_slash
    - `6` → gun_shoot

4. **Add all state configs** for the remaining Animation enum values

**Acceptance Criteria**:
- [ ] A/D rotates the character smoothly
- [ ] Shift+W triggers run animation
- [ ] Number keys trigger combat animations that return to idle
- [ ] All 24 animations are accessible and configured
- [ ] Code formatted with `zig fmt`

### Phase 4: Export FSM from Core Module

**File**: `src/core.zig` (or equivalent module root)

Make the FSM importable as `core.AnimationStateMachine`.

**Changes**:
1. Add `pub const AnimationStateMachine = @import("animation_fsm.zig").AnimationStateMachine` to the core module exports
2. Add `pub const StateConfig = @import("animation_fsm.zig").StateConfig` to the core module exports

**Acceptance Criteria**:
- [ ] `const FSM = core.AnimationStateMachine(MyEnum)` works from any game/example
- [ ] No circular dependencies
- [ ] Code formatted with `zig fmt`

## Design Decisions

### Why comptime generic over the state enum?

Zig's comptime generics let us:
- Use the game's own enum directly (no string-based states, no runtime enum mapping)
- Get compile-time errors for missing state configs (array size = enum field count)
- Zero runtime overhead for state lookups (array index = `@intFromEnum`)
- Type-safe `requestState()` calls

### Why `requestState()` returns bool instead of error?

Denied transitions (non-interruptible state) are a normal game logic outcome, not an error. The controller can check the return value to decide whether to suppress movement, play a "can't do that" sound, etc. Most of the time it will be ignored.

### Why `forceState()` exists separately?

Death and damage reactions must always work regardless of what animation is playing. Rather than making the controller check interruptibility manually, `forceState()` provides a clean override path.

### Why use `updateWeightedAnimations()` even for single animations?

Keeping one code path (weighted) simplifies the FSM. A single animation at weight 1.0 through `updateWeightedAnimations()` behaves identically to `updateAnimation()` but avoids needing to switch between two different update mechanisms when crossfading starts/stops.

### Why not define explicit transition edges?

A full transition graph (state A → state B requires condition C) is common in engine tools (Unity Animator, Godot AnimationTree) but adds complexity without proportional benefit in code. The "request-based" model where the controller says "I want state X" and the FSM decides whether to allow it is simpler, covers the same use cases, and is easier to debug. If explicit transitions are needed later, they can be layered on top.

## Extending to Other Characters

To use the FSM for a new character:

1. Define an enum for the character's animations
2. Build a `StateConfig` array mapping each enum value to animation parameters
3. Create the FSM: `AnimationStateMachine(MyAnimEnum).init(configs, .idle, animator)`
4. Call `requestState()` from your input handler
5. Call `update()` each frame

The pattern is identical regardless of whether the character has 5 animations or 50.

## Testing Strategy

### Manual Visual Testing
- Walk ↔ idle transitions are smooth (no popping)
- Roll plays fully before returning to idle
- Pressing walk during roll is ignored (non-interruptible)
- Death holds on last frame
- Rapid state switching doesn't cause visual glitches

### Debug Output
- Add optional debug print on state transitions: `"FSM: idle → walk (crossfade 0.15s)"`
- Print when one-shot completes: `"FSM: roll complete → idle"`
- Print when request denied: `"FSM: walk denied (roll not interruptible)"`

## Future Enhancements (Out of Scope)

- **Animation layers** — Upper body + lower body FSMs blended together
- **Blend trees** — Weight-based directional blending within a single FSM state
- **Animation events** — Callbacks at specific animation times (footstep sounds, damage frames)
- **Transition conditions** — Explicit edge-based transitions for complex AI behaviors
- **Animation speed scaling** — Walk/run speed affecting playback rate

## References

- Plan 004 (Animation System) — Phase 2 outlines state management goals
- `src/core/animator.zig` — Core animation system, WeightedAnimation API
- `src/core/transform.zig` — Transform blending with lerp/slerp
- `examples/bullets/scene/spacesuit.zig` — First consumer
- `games/angrybot/player.zig` — Weight blending reference (alternative approach)

---

## Review Notes (2026-09-28)

A read of `src/core/animation_fsm.zig` in the WebGPU port. It is small and table-driven
(comptime state enum, one config row per state, crossfades, one-shot auto-return,
interruptible flag). Gaps, roughly in order of value:

1. **Interrupting a crossfade pops.** A request during a fade (walk -> run -> idle quickly)
   drops the fading-out clip at once. Keep the fading clips as a small weighted list that
   decays, instead of one `previous_state`.
2. **One clip per state.** angrybot's directional locomotion blends five clips by aim vs.
   move direction, which a state can't express. A blend-space state (several clips
   weighted by a parameter) would let angrybot replace its hand-written weights with the
   FSM: a good test of the design.
3. **Looping clips aren't phase-matched** when switching (walk/run foot timing).
4. Smaller: no transition rules beyond `interruptible` (fine at this size); takes only
   `ModelInstance` (angrybot uses `Model`); logs with `std.debug.print` instead of a scoped
   log (STYLE section 7).
5. **Characters slide through stationary actions** (John, 2026-10-03). In bullets, holding
   W or the move stick while kicking, punching, or rolling keeps moving the soldier or
   spacesuit. Not the animation (their roots stay put: at most 0.2 model units, back where
   they started) but the callers: `requestState` returns false while a non-interruptible
   action plays, and both `processInput` (keyboard) and `drive` (gamepad,
   `character_control.zig`) move and turn the character regardless. Fix: an
   `isInterruptible()` on the state machine, and the characters skip movement and turning
   (taking only action buttons) while it's false. **Fixed 2026-10-03**: checked with the
   stick held through a kick, the spacesuit stays put for the kick and runs on after.
6. **Actions that should travel** (John, 2026-10-03): the spacesuit's roll should carry it
   forward. The clip is animated in place: the `Body` bone (its local Z is forward once
   the armature's rotations cancel; 1 bone unit = 2 world units with the armature's 100×
   and the model's 0.02 scale) dips 0.84 in Y and lunges up to 0.33 forward, then returns
   (first Z -0.05, last -0.04); kick has a 0.2 lunge that returns. So root-motion
   extraction would give a roll forward and a slide back. Options: (A) root motion
   extraction (a named root bone's horizontal movement moved from the pose to the
   transform), right for assets with real travel; (B) authored travel per action state
   (distance and ease over the clip, along the character's facing), (B1) alone, leaving
   the clip's own lunge as a small overshoot, or (B2) with the root bone's horizontal
   movement locked during that clip (an animator hook). Recommended: B1, then B2 if the
   overshoot shows; A when an asset has real root motion. **Decided 2026-10-04 (John):
   start with B1.**
7. **Toon Walk clip: the front of the foot sinks into the floor** (John, 2026-10-04).
   Seen from the side at floor level: as the planted foot travels back, its front half
   goes below the floor instead of the foot rolling up onto the toes. Run is fine. A
   quirk of the Walk / Walk_Shoot clips in the toon kit, not the FSM or the scale (not
   a constant offset, so a height adjustment wouldn't fix it). To be fixed in the
   animation itself if it matters; just a note for now.
