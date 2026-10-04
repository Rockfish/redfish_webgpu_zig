//! The captain's squad (docs/reviews/2026-10-04-link-style-controller-review.md section
//! 10, phase E): six undisciplined soldiers who loosely cluster near the captain and
//! follow him. Steering behaviors (`core.gameplay.steering`), not formation slots:
//!
//! - Each member heads for its own spot near the captain: behind him, somewhere within a
//!   spread either side, at a distance, both drifting at random, so the cluster is loose
//!   and keeps shifting (`arrive`, still once there).
//! - It sees the captain late: where it thinks he is trails him by its own reaction time.
//! - It keeps apart from the others and the captain (`separation`), drifts weakly toward
//!   the squad's middle (`cohesion`), and meanders a little while moving (`Wander`).
//!
//! The sum steers the member's motor like a stick (`ToonSoldier.steer`), so members turn,
//! arc, and walk or run like the captain instead of sliding.
//!
//! Settling: a member that reaches its spot and slows down settles, and stays put until
//! its spot is `restart_radius` away; settled, it only steps aside for someone inside its
//! personal space. Members yield by rank (the captain, then the first member, ...): each
//! keeps apart only from those ranked above it, so pushes go one way and can't bounce back
//! and forth. Spots drift only while the captain moves, so a halted squad settles. Fear, scatter, and focus fire
//! come later (phases F and G).

const std = @import("std");
const zgui = @import("zgui");
const core = @import("core");
const math = @import("math");

const toon_soldier = @import("toon_soldier.zig");
const ToonSoldier = toon_soldier.ToonSoldier;
const character_control = @import("character_control.zig");

const steering = core.gameplay.steering;
const Frame = core.Frame;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const Random = core.Random;
const ResourceManager = core.ResourceManager;
const Transform = core.Transform;
const motion = core.motion;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

pub const SIZE = 6;

/// Who's who: looks alternate so the squad reads as a mixed group; the captain alone is
/// the Soldier.
const members_setup = [SIZE]struct { look: toon_soldier.Look, weapon: toon_soldier.Weapon }{
    .{ .look = .enemy, .weapon = .AK },
    .{ .look = .hazmat, .weapon = .SMG },
    .{ .look = .enemy, .weapon = .Shotgun },
    .{ .look = .hazmat, .weapon = .AK },
    .{ .look = .enemy, .weapon = .SMG },
    .{ .look = .hazmat, .weapon = .GrenadeLauncher },
};

/// Everything the squad's behavior is tuned by; the panel edits it live.
pub const Tuning = struct {
    /// A member's spot: behind the captain to one side, between `spot_gap` and
    /// `spot_spread` degrees from straight behind (the gap keeps the lane behind him
    /// clear for the follow camera), this many meters away; a new random spot every
    /// `spot_interval` seconds (give or take half), moved to at `spot_drift` (`dampAngle`
    /// rate).
    spot_gap: f32 = 30.0,
    spot_spread: f32 = 110.0,
    spot_min_distance: f32 = 2.0,
    spot_max_distance: f32 = 4.5,
    spot_interval: f32 = 4.0,
    spot_drift: f32 = 0.6,
    /// Reaction time, seconds: where a member thinks the captain is trails him by about
    /// this much, each member picking within the range.
    reaction_min: f32 = 0.15,
    reaction_max: f32 = 0.6,
    /// `arrive`: slowing within this many meters of the spot, still within `stop_radius`.
    slow_radius: f32 = 3.0,
    stop_radius: f32 = 0.6,
    /// A member settles at its spot below this speed (meters per second), and starts again
    /// when the spot is farther than `restart_radius`.
    settle_speed: f32 = 0.3,
    restart_radius: f32 = 1.5,
    /// Settled, a member steps aside only for someone closer than this (meters).
    personal_space: f32 = 0.7,
    /// Each member keeps apart only from those ranked above it (one-way pushes); off: from
    /// everyone (pushes both ways).
    rank_yields: bool = true,
    /// The captain counts as moving (spots drift) above this speed, meters per second.
    captain_moving_speed: f32 = 0.1,
    /// Pushing apart within this many meters, times the walking speed.
    separation_radius: f32 = 1.3,
    separation_weight: f32 = 1.2,
    /// Pull toward the squad's middle, times the walking speed.
    cohesion_weight: f32 = 0.15,
    /// Meander while moving, times the running speed and how fast it's going.
    wander_weight: f32 = 0.25,
    /// How fast the steering sum is smoothed (`dampVec3` rate), so two pulls fighting
    /// don't flip it from frame to frame.
    smoothing: f32 = 6.0,
    /// Below this stick travel a member stands; above, it moves at least at
    /// `min_throttle`, so it never creeps.
    stand_below: f32 = 0.12,
    min_throttle: f32 = 0.3,

    /// A random spot angle (radians from straight behind) on `side` (+1 or -1), outside
    /// the gap and within the spread.
    fn spotAngle(self: Tuning, random: *Random, side: f32) f32 {
        const degrees = random.randFloatInRange(self.spot_gap, @max(self.spot_spread, self.spot_gap));
        return side * std.math.degreesToRadians(degrees);
    }
};

const Member = struct {
    soldier: *ToonSoldier,
    /// Where the member thinks the captain is.
    seen_captain: Vec3,
    /// 1 / its reaction time.
    notice_rate: f32,
    /// Its spot, from straight behind the captain (radians) and its distance; each eases
    /// toward a goal picked at random now and then.
    spot_angle: f32,
    spot_angle_goal: f32,
    spot_distance: f32,
    spot_distance_goal: f32,
    spot_timer: f32 = 0.0,
    wander: steering.Wander,
    /// The smoothed steering sum, meters per second.
    desired: Vec3 = Vec3.Zero,
    /// Where it's heading this frame (for the debug lines).
    spot: Vec3 = Vec3.Zero,
    /// At its spot and staying there.
    settled: bool = false,
};

pub const Squad = struct {
    members: [SIZE]Member,
    tuning: Tuning = .{},
    show_debug: bool = false,
    lines: Lines,
    debug_segments: [SIZE * 2]LineSegment = undefined,

    const Self = @This();

    /// The squad standing behind the captain at `captain`.
    pub fn init(rm: *ResourceManager, captain: Transform, random: *Random) !Self {
        const lines_shader = try rm.createShader("examples/bullets/shaders/lines.wgsl", .{
            .vertex_buffers = &Lines.vertex_buffer_layouts,
            .topology = .line_list,
        });
        var self: Self = .{
            .members = undefined,
            .lines = try Lines.init(rm.context.alloc, lines_shader, 1.0, 1.0, SIZE * 2),
        };

        const tuning = self.tuning;
        for (&self.members, members_setup, 0..) |*member, setup, i| {
            const reaction = random.randFloatInRange(tuning.reaction_min, tuning.reaction_max);
            // Half the squad starts on each side
            const side: f32 = if (i % 2 == 0) 1.0 else -1.0;
            const angle = tuning.spotAngle(random, side);
            const distance = random.randFloatInRange(tuning.spot_min_distance, tuning.spot_max_distance);
            member.* = .{
                .soldier = try ToonSoldier.init(rm, setup.look, setup.weapon, false),
                .seen_captain = captain.translation,
                .notice_rate = 1.0 / reaction,
                .spot_angle = angle,
                .spot_angle_goal = angle,
                .spot_distance = distance,
                .spot_distance_goal = distance,
                .wander = .{ .heading = random.randClamped() * std.math.pi, .interval = 1.5, .spread = 1.2, .rate = 2.0 },
            };
            member.soldier.transform.translation = spotPosition(captain.translation, character_control.heading(captain.rotation), angle, distance);
            member.soldier.transform.rotation = captain.rotation;
        }
        return self;
    }

    /// Steers every member toward its spot near the captain (moving at `captain_speed`)
    /// and moves it on.
    pub fn update(self: *Self, captain: Transform, captain_speed: f32, random: *Random, dt: f32) !void {
        // Everyone's position before anyone moves, by rank: the captain first
        var positions: [SIZE + 1]Vec3 = undefined;
        positions[0] = captain.translation;
        for (self.members, 1..) |member, i| {
            positions[i] = member.soldier.transform.translation;
        }

        const captain_heading = character_control.heading(captain.rotation);
        const captain_moving = captain_speed > self.tuning.captain_moving_speed;
        for (&self.members, 1..) |*member, rank| {
            if (captain_moving) {
                self.driftSpot(member, random, dt);
            }
            member.seen_captain = motion.dampVec3(member.seen_captain, captain.translation, member.notice_rate, dt);
            member.spot = spotPosition(member.seen_captain, captain_heading, member.spot_angle, member.spot_distance);

            // Those it keeps apart from: everyone above it by rank, or everyone
            const others = if (self.tuning.rank_yields) positions[0..rank] else positions[0..];
            const goal = self.steeringSum(member, others, positions[1..], random, dt);
            member.desired = motion.dampVec3(member.desired, goal, self.tuning.smoothing, dt);
            member.soldier.steer(self.stick(member), dt);
            try member.soldier.update(dt);
        }
    }

    pub fn draw(self: *Self, frame: *const Frame) void {
        for (self.members) |member| {
            member.soldier.draw(frame);
        }
        if (self.show_debug) {
            self.drawDebugLines(frame);
        }
    }

    pub fn drawGui(self: *Self) void {
        const tuning = &self.tuning;
        zgui.setNextWindowPos(.{ .x = 400, .y = 20, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 360, .h = 470, .cond = .first_use_ever });
        if (zgui.begin("squad", .{})) {
            _ = zgui.checkbox("debug lines (spot yellow, steering cyan)", .{ .v = &self.show_debug });
            zgui.separatorText("spot near the captain");
            _ = zgui.sliderFloat("gap behind (deg)", .{ .v = &tuning.spot_gap, .min = 0.0, .max = 90.0 });
            _ = zgui.sliderFloat("spread (deg)", .{ .v = &tuning.spot_spread, .min = 0.0, .max = 180.0 });
            _ = zgui.sliderFloat("min distance (m)", .{ .v = &tuning.spot_min_distance, .min = 0.5, .max = 10.0 });
            _ = zgui.sliderFloat("max distance (m)", .{ .v = &tuning.spot_max_distance, .min = 0.5, .max = 15.0 });
            _ = zgui.sliderFloat("new spot every (s)", .{ .v = &tuning.spot_interval, .min = 0.5, .max = 15.0 });
            _ = zgui.sliderFloat("spot drift (rate)", .{ .v = &tuning.spot_drift, .min = 0.05, .max = 5.0 });
            zgui.separatorText("steering");
            _ = zgui.sliderFloat("slow radius (m)", .{ .v = &tuning.slow_radius, .min = 0.5, .max = 8.0 });
            _ = zgui.sliderFloat("stop radius (m)", .{ .v = &tuning.stop_radius, .min = 0.1, .max = 3.0 });
            zgui.separatorText("settling");
            _ = zgui.checkbox("yield by rank", .{ .v = &tuning.rank_yields });
            _ = zgui.sliderFloat("settle below (m/s)", .{ .v = &tuning.settle_speed, .min = 0.0, .max = 2.0 });
            _ = zgui.sliderFloat("restart beyond (m)", .{ .v = &tuning.restart_radius, .min = 0.3, .max = 5.0 });
            _ = zgui.sliderFloat("personal space (m)", .{ .v = &tuning.personal_space, .min = 0.2, .max = 2.0 });
            zgui.text("settled: {d} of {d}", .{ self.settledCount(), SIZE });
            _ = zgui.sliderFloat("separation radius (m)", .{ .v = &tuning.separation_radius, .min = 0.3, .max = 4.0 });
            _ = zgui.sliderFloat("separation", .{ .v = &tuning.separation_weight, .min = 0.0, .max = 4.0 });
            _ = zgui.sliderFloat("cohesion", .{ .v = &tuning.cohesion_weight, .min = 0.0, .max = 2.0 });
            _ = zgui.sliderFloat("wander", .{ .v = &tuning.wander_weight, .min = 0.0, .max = 1.0 });
            _ = zgui.sliderFloat("smoothing (rate)", .{ .v = &tuning.smoothing, .min = 0.5, .max = 20.0 });
            _ = zgui.sliderFloat("stand below (throttle)", .{ .v = &tuning.stand_below, .min = 0.0, .max = 0.5 });
            _ = zgui.sliderFloat("min throttle", .{ .v = &tuning.min_throttle, .min = 0.0, .max = 1.0 });
            zgui.text("reaction times are picked at start ({d:.2} to {d:.2} s)", .{ tuning.reaction_min, tuning.reaction_max });
        }
        zgui.end();
    }

    fn settledCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.members) |member| {
            if (member.settled) {
                count += 1;
            }
        }
        return count;
    }

    /// Now and then a new random spot (angle and distance) to drift toward.
    fn driftSpot(self: *const Self, member: *Member, random: *Random, dt: f32) void {
        const tuning = self.tuning;
        member.spot_timer -= dt;
        if (member.spot_timer <= 0.0) {
            // Mostly stays on its side, sometimes crosses over
            const side: f32 = if ((member.spot_angle >= 0.0) != (random.randFloat() < 0.2)) 1.0 else -1.0;
            member.spot_angle_goal = tuning.spotAngle(random, side);
            member.spot_distance_goal = random.randFloatInRange(tuning.spot_min_distance, tuning.spot_max_distance);
            member.spot_timer = tuning.spot_interval * (0.5 + random.randFloat());
        }
        member.spot_angle = motion.dampAngle(member.spot_angle, member.spot_angle_goal, tuning.spot_drift, dt);
        member.spot_distance += (member.spot_distance_goal - member.spot_distance) * motion.dampAlpha(tuning.spot_drift, dt);
    }

    /// Arrive at the spot, keep apart from `others`, drift toward the middle of `squad`,
    /// meander while moving: meters per second. Settled, only keeping out of `others`'
    /// personal space.
    fn steeringSum(self: *const Self, member: *Member, others: []const Vec3, squad: []const Vec3, random: *Random, dt: f32) Vec3 {
        const tuning = self.tuning;
        const motor = member.soldier.motor;
        const position = member.soldier.transform.translation;
        const to_spot = position.sub(member.spot).length();

        if (member.settled and to_spot > tuning.restart_radius) {
            member.settled = false;
        } else if (!member.settled and to_spot < tuning.stop_radius and motor.speed < tuning.settle_speed) {
            member.settled = true;
        }

        _ = member.wander.update(random, dt);
        if (member.settled) {
            return steering.separation(position, others, tuning.personal_space).mulScalar(tuning.separation_weight * motor.walk_speed);
        }

        const at_spot = to_spot < tuning.stop_radius;
        const arrive = if (at_spot) Vec3.Zero else steering.arrive(position, member.spot, motor.run_speed, tuning.slow_radius);
        const separation = steering.separation(position, others, tuning.separation_radius).mulScalar(tuning.separation_weight * motor.walk_speed);
        const cohesion = steering.cohesion(position, squad, motor.walk_speed, 1.0).mulScalar(tuning.cohesion_weight);

        const moving = arrive.length() / motor.run_speed;
        const wander = member.wander.direction().mulScalar(tuning.wander_weight * motor.run_speed * moving);

        return arrive.add(separation).add(cohesion).add(wander);
    }

    /// The smoothed sum as a move stick (length 0 to 1): standing below `stand_below`, at
    /// least `min_throttle` above it.
    fn stick(self: *const Self, member: *const Member) Vec3 {
        const throttle = member.desired.length() / member.soldier.motor.run_speed;
        if (throttle < self.tuning.stand_below) {
            return Vec3.Zero;
        }
        const travel = std.math.clamp(throttle, self.tuning.min_throttle, 1.0);
        return member.desired.mulScalar(travel / throttle);
    }

    /// For each member, a yellow line to its spot and a cyan one along its steering.
    fn drawDebugLines(self: *Self, frame: *const Frame) void {
        const lift = vec3(0.0, 0.05, 0.0);
        for (self.members, 0..) |member, i| {
            const position = member.soldier.transform.translation.add(lift);
            self.debug_segments[i * 2] = .{ .start = position, .end = member.spot.add(lift), .color = .yellow };
            self.debug_segments[i * 2 + 1] = .{ .start = position, .end = position.add(member.desired), .color = .cyan };
        }
        self.lines.draw(frame, &self.debug_segments);
    }
};

/// The spot `angle` radians from straight behind a captain at `captain` facing
/// `captain_heading`, `distance` meters away.
fn spotPosition(captain: Vec3, captain_heading: f32, angle: f32, distance: f32) Vec3 {
    const behind = captain_heading + std.math.pi + angle;
    return captain.add(character_control.headingDirection(behind).mulScalar(distance));
}
