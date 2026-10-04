const std = @import("std");
const animator_mod = @import("animator.zig");
const ModelInstance = @import("model_instance.zig").ModelInstance;

const WeightedAnimation = animator_mod.WeightedAnimation;
const AnimationRepeatMode = animator_mod.AnimationRepeatMode;
const Animation = animator_mod.Animation;

const log = std.log.scoped(.animation_fsm);

/// Clips blending at once: the current state plus the ones still fading out. A request
/// with this many already playing drops the oldest (by then nearly faded).
const MAX_TRACKS = 4;
/// A fading clip below this weight is dropped.
const MIN_TRACK_WEIGHT: f32 = 0.01;

/// A comptime-generic finite state machine for animation control.
///
/// Parameterized on a state enum whose values must be contiguous starting from 0.
/// Each enum value maps to a Config entry that defines which glTF animation to play,
/// whether it loops, crossfade duration, interruptibility, and optional auto-return.
///
/// Each playing clip is a track with its own clock, so a state can play faster, slower,
/// or backward (`setPlaybackRate`). A request in the middle of a crossfade fades out
/// every clip still playing from where it is, instead of dropping the oldest at once.
///
/// Usage:
///   const FSM = AnimationStateMachine(MyAnimEnum);
///   var fsm = FSM.init(configs, .idle, model);
///   _ = fsm.requestState(.walk);            // from input handler
///   fsm.setPlaybackRate(speed / clip_speed); // optional, each frame
///   try fsm.update(model, delta_time);      // once per frame
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
            /// Playback rate (1 = as authored); `setPlaybackRate` scales it.
            rate: f32 = 1.0,
        };

        /// A playing clip. The last track is the current state; the others fade out.
        const Track = struct {
            state: StateEnum,
            /// Seconds into the clip.
            time: f32,
            rate: f32,
            /// The track's weight when the current crossfade began; it falls to zero as
            /// the crossfade completes. Unused for the current track.
            fade_from: f32,
        };

        state_configs: [state_count]StateConfig,
        animation_durations: [state_count]f32,

        tracks: [MAX_TRACKS]Track,
        track_count: usize,
        /// The current track's weight, 0 to 1 over the crossfade; the fading tracks share
        /// the rest.
        blend: f32,
        crossfade_duration: f32,
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
                    log.err("animation_id {d} out of range (max {d})", .{ config.animation_id, num_animations });
                    durations[i] = 1.0;
                }
            }

            var self: Self = .{
                .state_configs = state_configs,
                .animation_durations = durations,
                .tracks = undefined,
                .track_count = 1,
                .blend = 1.0,
                .crossfade_duration = 0.0,
                .debug = false,
            };
            self.tracks[0] = self.startTrack(initial_state);
            return self;
        }

        /// Request a state change. Respects interruptibility of the current state.
        /// Returns true if the transition was accepted or the FSM is already in that state.
        pub fn requestState(self: *Self, new_state: StateEnum) bool {
            if (new_state == self.getCurrentState()) {
                return true;
            }

            if (!self.isInterruptible()) {
                if (self.debug) {
                    log.info("{s} denied ({s} not interruptible)", .{ @tagName(new_state), @tagName(self.getCurrentState()) });
                }
                return false;
            }

            self.transitionTo(new_state);
            return true;
        }

        /// True when a request can change the current state; false while a one-shot action
        /// that can't be interrupted (a kick, a roll) plays. A character skips movement
        /// then, or it slides through the action.
        pub fn isInterruptible(self: *const Self) bool {
            return self.state_configs[@intFromEnum(self.getCurrentState())].interruptible;
        }

        /// Force a state change, ignoring interruptibility.
        /// Use for death, damage reactions, or other mandatory transitions.
        pub fn forceState(self: *Self, new_state: StateEnum) void {
            if (new_state == self.getCurrentState()) {
                return;
            }
            self.transitionTo(new_state);
        }

        /// Plays the current state at `rate` times its configured rate (negative plays it
        /// backward), e.g. a walk matched to the character's speed. A new state starts at
        /// its configured rate.
        pub fn setPlaybackRate(self: *Self, rate: f32) void {
            const current = self.currentTrack();
            current.rate = self.state_configs[@intFromEnum(current.state)].rate * rate;
        }

        /// Advance the FSM by one frame: moves each clip's clock, the crossfade, and a
        /// finished one-shot to its return state, then poses the model.
        pub fn update(self: *Self, model: *ModelInstance, delta_time: f32) !void {
            self.advanceClocks(delta_time);
            self.returnFromFinishedOneShot();
            self.advanceCrossfade(delta_time);

            var weighted: [MAX_TRACKS]WeightedAnimation = undefined;
            const n = self.buildWeightedAnimations(&weighted);
            try model.updateWeightedAnimations(weighted[0..n], 0.0);
        }

        pub fn getCurrentState(self: *const Self) StateEnum {
            return self.tracks[self.track_count - 1].state;
        }

        pub fn isTransitioning(self: *const Self) bool {
            return self.track_count > 1;
        }

        /// The new state becomes the current track. Every playing track keeps its present
        /// weight as where it fades from, so nothing jumps when a crossfade is interrupted.
        fn transitionTo(self: *Self, new_state: StateEnum) void {
            const new_config = self.state_configs[@intFromEnum(new_state)];

            if (self.debug) {
                log.info("{s} -> {s} (crossfade {d:.2}s)", .{ @tagName(self.getCurrentState()), @tagName(new_state), new_config.crossfade_in });
            }

            var track = self.startTrack(new_state);
            // A looping state still fading out picks up where it is, so walk -> idle ->
            // walk doesn't restart the walk cycle.
            if (new_config.repeat != .Once) {
                for (self.tracks[0..self.track_count]) |old| {
                    if (old.state == new_state) {
                        track.time = old.time;
                    }
                }
            }

            if (new_config.crossfade_in <= 0.0) {
                self.tracks[0] = track;
                self.track_count = 1;
                self.blend = 1.0;
                return;
            }

            for (self.tracks[0..self.track_count]) |*old| {
                old.fade_from = self.trackWeight(old);
            }
            if (self.track_count == MAX_TRACKS) {
                std.mem.copyForwards(Track, self.tracks[0 .. MAX_TRACKS - 1], self.tracks[1..MAX_TRACKS]);
                self.track_count -= 1;
            }
            self.tracks[self.track_count] = track;
            self.track_count += 1;
            self.blend = 0.0;
            self.crossfade_duration = new_config.crossfade_in;
        }

        fn startTrack(self: *const Self, state: StateEnum) Track {
            const index = @intFromEnum(state);
            const rate = self.state_configs[index].rate;
            return .{
                .state = state,
                .time = if (rate < 0.0) self.animation_durations[index] else 0.0,
                .rate = rate,
                .fade_from = 0.0,
            };
        }

        /// Loops wrap; one-shots stop at their ends.
        fn advanceClocks(self: *Self, delta_time: f32) void {
            for (self.tracks[0..self.track_count]) |*track| {
                const index = @intFromEnum(track.state);
                const duration = self.animation_durations[index];
                const time = track.time + delta_time * track.rate;
                track.time = if (self.state_configs[index].repeat == .Once)
                    std.math.clamp(time, 0.0, duration)
                else
                    @mod(time, duration);
            }
        }

        fn returnFromFinishedOneShot(self: *Self) void {
            const current = self.currentTrack().*;
            const index = @intFromEnum(current.state);
            const config = self.state_configs[index];
            if (config.repeat != .Once) {
                return;
            }

            const finished = if (current.rate >= 0.0) current.time >= self.animation_durations[index] else current.time <= 0.0;
            if (!finished) {
                return;
            }
            if (config.return_state) |return_state| {
                if (self.debug) {
                    log.info("{s} complete -> {s}", .{ @tagName(current.state), @tagName(return_state) });
                }
                self.transitionTo(return_state);
            }
        }

        /// Raises the current track's weight; fading tracks too light to see are dropped.
        fn advanceCrossfade(self: *Self, delta_time: f32) void {
            if (self.track_count == 1) {
                return;
            }

            self.blend = @min(self.blend + delta_time / self.crossfade_duration, 1.0);

            var kept: usize = 0;
            for (self.tracks[0 .. self.track_count - 1]) |track| {
                if (self.trackWeight(&track) >= MIN_TRACK_WEIGHT) {
                    self.tracks[kept] = track;
                    kept += 1;
                }
            }
            self.tracks[kept] = self.tracks[self.track_count - 1];
            self.track_count = kept + 1;
            if (self.track_count == 1) {
                self.blend = 1.0;
            }
        }

        /// The animator blends each clip into the pose so far (a lerp by its weight), so
        /// a track's lerp factor is its weight over the weights blended so far, oldest
        /// first: the result is the weighted average of the tracks.
        fn buildWeightedAnimations(self: *const Self, weighted: *[MAX_TRACKS]WeightedAnimation) usize {
            var total: f32 = 0.0;
            for (self.tracks[0..self.track_count], 0..) |*track, i| {
                const weight = self.trackWeight(track);
                total += weight;
                const factor = if (total > 0.0) weight / total else 1.0;

                const config = self.state_configs[@intFromEnum(track.state)];
                weighted[i] = .{
                    .animation_index = config.animation_id,
                    .start_time = 0.0,
                    .end_time = self.animation_durations[@intFromEnum(track.state)],
                    .weight = factor,
                    .offset = 0.0,
                    .clip_time = track.time,
                };
            }
            return self.track_count;
        }

        fn trackWeight(self: *const Self, track: *const Track) f32 {
            if (track == &self.tracks[self.track_count - 1]) {
                return self.blend;
            }
            return track.fade_from * (1.0 - self.blend);
        }

        fn currentTrack(self: *Self) *Track {
            return &self.tracks[self.track_count - 1];
        }
    };
}
