In your setup — **3D third-person**, camera-relative WASD movement, character **always faces movement direction** (no fixed facing like shooters), **Shift** for run, and the available animations — here's a realistic, player-expectation-friendly approach for indie-style controls and animation state machine.

Your animation list has **walk**, **run**, **idle** as core locomotion, plus variants like **walk_shoot**, **run_shoot**, **run_gun** (suggesting possible armed states later). For now, we'll focus on basic unarmed locomotion: **idle**, **walk**, **run**.

### Key Design Decisions (Typical Indie 3rd-Person Behavior)
- **Movement is camera-relative**: W = forward (camera look direction), S = backward, A/D = strafe left/right.
- **Character rotation**: Smoothly rotates to face the **intended movement direction** (derived from input vector + camera). No "true" backward walking or strafing without turning — the character turns to make the forward animation match the direction. This is the most common choice for non-tactical/non-shooter 3rd-person games (e.g. many action-adventure, exploration, or Zelda-like indies).
- **No backward/strafe animations used** (you don't have dedicated backward or strafe anims anyway — walk/run are forward-facing).
- **Run** = hold Shift (increases max speed + switches animation).
- **Locomotion states** driven mostly by **speed magnitude** + **armed state** (if you expand to shooting later).
- **Quick direction changes** (W → S): The character decelerates → turns ~180° → accelerates in new direction while playing **forward walk/run** animation. Feels responsive, avoids needing backward anim.

This matches behavior in many Unity/Godot indie third-person prototypes and lighter action games (not heavy shooters like Gears or cover-based titles that keep facing camera and strafe/backpedal).

### Recommended Animation Selection Logic
Use an **AnimationTree** (or your own state machine + playback) with parameters like:
- `locomotion_blend` : float 0..1 (0 = idle, 0.3–0.7 ≈ walk, 0.8–1.5 ≈ run) — controls playback speed or blend position
- `speed` : float (actual velocity magnitude) — for blend spaces if you expand
- `is_running` : bool (Shift held and moving)
- Later: `is_armed` : bool → switches to walk_shoot / run_shoot / run_gun variants

Simple selection rules (pseudo-Zig):
```zig
fn get_animation(state: LocomotionState, is_running: bool, has_gun: bool) -> Animation {
    if velocity.magnitude < 0.2 {
        return .idle;  // or .idle_shoot if armed
    }

    const base = if (has_gun) "_shoot" else "";  // or "_gun" for run sometimes

    if is_running {
        if (has_gun) return .run_gun;  // or .run_shoot depending on logic
        return .run;
    } else {
        if (has_gun) return .@"walk" ++ base;  // walk_shoot
        return .walk;
    }
}
```

### State Machine / Update Logic (Case-by-Case)

Use an enum + struct like:
```zig
const LocomotionState = enum { Idle, Moving };

struct Player {
    state: LocomotionState = .Idle,
    velocity: Vec3 = Vec3.zero,
    facing_quat: Quat = Quat.identity,
    // ... other fields
}
```

Every frame (~ dt = 1/60 or fixed timestep):

1. **Gather input**
   ```zig
   var input_vec = Vec2{
       .x = if (input.d) 1 else if (input.a) -1 else 0,
       .y = if (input.w) 1 else if (input.s) -1 else 0,
   };
   if (input_vec.length() > 1.0) input_vec = input_vec.normalized();
   ```

2. **Camera-relative direction**
   ```zig
   const cam_forward = camera.transform.forward.xz.normalized();  // ignore y
   const cam_right   = camera.transform.right.xz.normalized();
   var move_dir = (cam_forward * input_vec.y + cam_right * input_vec.x).normalized();
   ```

3. **Target speed**
   ```zig
   const walk_speed = 5.0;   // units/sec
   const run_speed  = 9.0;
   const max_speed = if (input.shift and input_vec.length() > 0.1) run_speed else walk_speed;
   ```

4. **Accelerate / decelerate velocity**
   ```zig
   const accel      = 15.0;   // high = snappy
   const decel      = 25.0;   // higher than accel for quick stops
   const target_vel = move_dir * max_speed * input_vec.length();  // scale by stick strength analog-like

   if (target_vel.lengthSq() > 0.01) {
       velocity = velocity.lerp(target_vel, accel * dt);
   } else {
       velocity = velocity.mul(1.0 - decel * dt);  // or exponential decay
   }
   ```

5. **Rotate to face movement (only when moving)**
   ```zig
   if (velocity.xz.length() > 0.5) {  // small threshold
       const target_quat = Quat.fromTo(Vec3.forward, velocity.normalized().xz.to3());
       facing_quat = facing_quat.slerp(target_quat, 12.0 * dt);  // ~0.2-0.4 sec full turn
   }
   ```

6. **Determine state & animation**
   ```zig
   const moving = velocity.length() > 0.4;
   player.state = if (moving) .Moving else .Idle;

   const is_running = input.shift and moving and velocity.length() > walk_speed * 0.7;

   const anim = get_animation(player.state, is_running, has_gun);
   animator.play(anim, 0.15);  // crossfade time
   animator.set_speed(1.0 + (velocity.length() / run_speed) * 0.4);  // slight speed-up at full run
   ```

### Specific Cases (W → S switch etc.)

| Input Change                  | Expected Behavior (Most Players)                          | How It Happens in Above Logic                                                                 |
|-------------------------------|------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| Idle → W                      | Accelerate forward, turn to camera forward, play walk/run | move_dir = cam_forward, velocity → target, rotation slerps, anim = walk or run                |
| Hold W, press Shift           | Speed up, switch to run anim, slight speed blend          | max_speed jumps, is_running = true, anim switches, playback speed slightly higher             |
| Hold W → release all          | Decelerate to stop (~0.4–0.8 sec), stay facing last dir   | target_vel=0, velocity decays, state → Idle when <0.4, anim → idle                            |
| Hold W → hold S               | Slow → stop moment → turn 180° → accelerate backward, forward anim | input_vec.y flips -1, move_dir flips, velocity reverses over ~0.3–0.6 sec, rotation slerps 180° |
| Hold S → hold W               | Same as above, just opposite flip                         | Symmetric                                                                                      |
| Diagonal (W+A)                | Move diagonal, smoothly turn to diagonal, forward anim    | move_dir = normalized sum, rotation follows, looks natural                                    |
| Quick W tap then S            | Brief forward → quick reverse turn + move                 | Velocity goes near zero briefly → full reverse turn, snappy if accel/decel high               |
| Only A or D (pure strafe)     | Turn 90°, move sideways using forward anim                | Most common compromise — feels ok for exploration games                                       |

### Tuning Tips for "Feels Good"
- Turn rate (slerp factor): 8–15 → ~0.15–0.4 sec for 180° (too fast = twitchy, too slow = unresponsive)
- Acceleration: 12–25 (higher = more responsive, less floaty)
- Deceleration: 1.5–2.5× accel (quick stops without ice-skating)
- Thresholds: Use small deadzones (0.2–0.4) to avoid idle ↔ walk flicker
- Optional: Add very brief **pivot/turn-in-place** anim if angle change >120° and speed <1 (but you don't have one, so skip)

This should feel intuitive like many indie 3rd-person games without dedicated strafe/backward anims. If you later add shooting, you can lock rotation to camera (strafe mode) and switch to walk_shoot / run_shoot while keeping velocity camera-relative.

Let me know which part feels off or if you want code sketches for specific Zig bits (velocity integration, quat s