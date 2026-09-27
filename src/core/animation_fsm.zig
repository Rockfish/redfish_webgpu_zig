const std = @import("std");
const animator_mod = @import("animator.zig");
const ModelInstance = @import("model_instance.zig").ModelInstance;

const WeightedAnimation = animator_mod.WeightedAnimation;
const AnimationRepeatMode = animator_mod.AnimationRepeatMode;
const Animation = animator_mod.Animation;

/// A comptime-generic finite state machine for animation control.
///
/// Parameterized on a state enum whose values must be contiguous starting from 0.
/// Each enum value maps to a Config entry that defines which glTF animation to play,
/// whether it loops, crossfade duration, interruptibility, and optional auto-return.
///
/// Usage:
///   const FSM = AnimationStateMachine(MyAnimEnum);
///   var fsm = FSM.init(configs, .idle, model.animator.animations);
///   fsm.requestState(.walk);          // from input handler
///   try fsm.update(model, frame_time, delta_time);  // once per frame
pub fn AnimationStateMachine(comptime StateEnum: type) type {
    const state_count = @typeInfo(StateEnum).@"enum".fields.len;

    return struct {
        const Self = @This();
        pub const count = state_count;

        pub const StateConfig = struct {
            animation_id: u32,
            repeat: AnimationRepeatMode,
            crossfade_in: f32,
            interruptible: bool,
            return_state: ?StateEnum,
        };

        state_configs: [state_count]StateConfig,
        animation_durations: [state_count]f32,

        current_state: StateEnum,
        previous_state: ?StateEnum,
        crossfade_elapsed: f32,
        crossfade_duration: f32,
        current_state_start: f32,
        previous_state_start: f32,
        last_frame_time: f32,
        debug: bool,

        pub fn init(
            state_configs: [state_count]StateConfig,
            initial_state: StateEnum,
            model: *ModelInstance,
        ) Self {
            const num_animations = model.getAnimationCount();
            var durations: [state_count]f32 = undefined;

            for (state_configs, 0..) |config, i| {
                if (config.animation_id < num_animations) {
                    durations[i] = model.getAnimationDuration(config.animation_id);
                } else {
                    std.debug.print("FSM: animation_id {d} out of range (max {d})\n", .{
                        config.animation_id,
                        num_animations,
                    });
                    durations[i] = 1.0;
                }
            }

            return .{
                .state_configs = state_configs,
                .animation_durations = durations,
                .current_state = initial_state,
                .previous_state = null,
                .crossfade_elapsed = 0.0,
                .crossfade_duration = 0.0,
                .current_state_start = 0.0,
                .previous_state_start = 0.0,
                .last_frame_time = 0.0,
                .debug = false,
            };
        }

        /// Request a state change. Respects interruptibility of the current state.
        /// Returns true if the transition was accepted or the FSM is already in that state.
        pub fn requestState(self: *Self, new_state: StateEnum) bool {
            if (new_state == self.current_state) {
                return true;
            }

            const current_config = self.state_configs[@intFromEnum(self.current_state)];
            if (!current_config.interruptible) {
                if (self.debug) {
                    std.debug.print("FSM: {s} denied ({s} not interruptible)\n", .{
                        @tagName(new_state),
                        @tagName(self.current_state),
                    });
                }
                return false;
            }

            self.transitionTo(new_state);
            return true;
        }

        /// Force a state change, ignoring interruptibility.
        /// Use for death, damage reactions, or other mandatory transitions.
        pub fn forceState(self: *Self, new_state: StateEnum) void {
            if (new_state == self.current_state) {
                return;
            }
            self.transitionTo(new_state);
        }

        fn transitionTo(self: *Self, new_state: StateEnum) void {
            const new_config = self.state_configs[@intFromEnum(new_state)];

            if (self.debug) {
                std.debug.print("FSM: {s} -> {s} (crossfade {d:.2}s)\n", .{
                    @tagName(self.current_state),
                    @tagName(new_state),
                    new_config.crossfade_in,
                });
            }

            if (new_config.crossfade_in <= 0.0) {
                // Instant transition, no crossfade
                self.previous_state = null;
                self.current_state = new_state;
                self.current_state_start = self.last_frame_time;
                self.crossfade_elapsed = 0.0;
                self.crossfade_duration = 0.0;
                return;
            }

            self.previous_state = self.current_state;
            self.previous_state_start = self.current_state_start;
            self.current_state = new_state;
            self.current_state_start = self.last_frame_time;
            self.crossfade_elapsed = 0.0;
            self.crossfade_duration = new_config.crossfade_in;
        }

        /// Advance the FSM by one frame. Handles crossfade blending and one-shot
        /// auto-return transitions. Calls model.updateWeightedAnimations() internally.
        pub fn update(self: *Self, model: *ModelInstance, frame_time: f32, delta_time: f32) !void {
            self.last_frame_time = frame_time;

            // Check one-shot completion
            const current_idx = @intFromEnum(self.current_state);
            const current_config = self.state_configs[current_idx];
            if (current_config.repeat == .Once) {
                const elapsed = frame_time - self.current_state_start;
                if (elapsed >= self.animation_durations[current_idx]) {
                    if (current_config.return_state) |return_state| {
                        if (self.debug) {
                            std.debug.print("FSM: {s} complete -> {s}\n", .{
                                @tagName(self.current_state),
                                @tagName(return_state),
                            });
                        }
                        self.transitionTo(return_state);
                    }
                }
            }

            // Advance crossfade
            if (self.previous_state != null) {
                self.crossfade_elapsed += delta_time;
                if (self.crossfade_elapsed >= self.crossfade_duration) {
                    self.previous_state = null;
                }
            }

            // Build weighted animations and update model
            if (self.previous_state) |prev| {
                const blend = @min(self.crossfade_elapsed / self.crossfade_duration, 1.0);
                const prev_idx = @intFromEnum(prev);
                const weighted = [2]WeightedAnimation{
                    self.buildWeightedAnim(prev_idx, self.previous_state_start, 1.0 - blend),
                    self.buildWeightedAnim(current_idx, self.current_state_start, blend),
                };
                try model.updateWeightedAnimations(&weighted, frame_time);
            } else {
                const weighted = [1]WeightedAnimation{
                    self.buildWeightedAnim(current_idx, self.current_state_start, 1.0),
                };
                try model.updateWeightedAnimations(&weighted, frame_time);
            }
        }

        fn buildWeightedAnim(
            self: *const Self,
            state_idx: usize,
            state_start: f32,
            weight: f32,
        ) WeightedAnimation {
            const config = self.state_configs[state_idx];
            const duration = self.animation_durations[state_idx];
            const optional_start: f32 = if (config.repeat == .Once) state_start else 0.0;

            return WeightedAnimation.init(
                config.animation_id,
                weight,
                0.0,
                duration,
                0.0,
                optional_start,
            );
        }

        pub fn getCurrentState(self: *const Self) StateEnum {
            return self.current_state;
        }

        pub fn isTransitioning(self: *const Self) bool {
            return self.previous_state != null;
        }
    };
}
