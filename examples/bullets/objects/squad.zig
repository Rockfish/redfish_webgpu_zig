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
//! and forth. Spots drift only while the captain moves, so a halted squad settles.
//!
//! Focus fire (section 10.3, phase F): the captain's shots that land close together in
//! quick succession make a focus point; after a couple of them the squad engages it. Each
//! member keeps following but turns to face the point, waits its own delay so they open
//! up raggedly, and fires bursts of jittered tracers at its own cadence, until the captain
//! hasn't fired at the point for a while or the target is gone. Fear and scatter come in
//! phase G.

const std = @import("std");
const zgui = @import("zgui");
const core = @import("core");
const math = @import("math");

const toon_soldier = @import("toon_soldier.zig");
const ToonSoldier = toon_soldier.ToonSoldier;
const character_control = @import("character_control.zig");

const gameplay = core.gameplay;
const steering = gameplay.steering;
const FireControl = gameplay.FireControl;
const Projectiles = gameplay.projectiles.Projectiles;
const ShotJitter = gameplay.ShotJitter;
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

    /// The captain's shots landing within `focus_radius` meters of each other, each within
    /// `focus_window` seconds of the last, make one focus point; `shots_to_engage` of them
    /// and the squad opens fire, until the captain hasn't shot at it for `focus_hold`
    /// seconds.
    focus_radius: f32 = 2.0,
    focus_window: f32 = 1.5,
    shots_to_engage: i32 = 2,
    focus_hold: f32 = 3.0,
    /// Each member's own wait before it opens fire, seconds, picked per engagement.
    engage_delay_min: f32 = 0.2,
    engage_delay_max: f32 = 0.8,
    /// How fast a member turns to the focus point (`dampAngle` rate), and how close
    /// (degrees) its facing must be before it fires.
    aim_turn_rate: f32 = 8.0,
    aim_tolerance: f32 = 20.0,
    /// A shot's spread, degrees (a cone around the line to the point).
    aim_jitter: f32 = 2.5,

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
    /// Firing at the focus point (once `engage_timer` runs out).
    engaged: bool = false,
    engage_timer: f32 = 0.0,
    /// Where it faces while engaged (about +Y from +Z), turning toward the point.
    aim_heading: f32 = 0.0,
    /// Its own bursts: shot count, spacing, and pause picked at the start.
    fire_control: FireControl,
};

/// What the captain is shooting at.
const Focus = struct {
    /// The average of his shots on it.
    point: Vec3 = Vec3.Zero,
    /// The turret it's on (an index into the scene's turrets), if any.
    target: ?usize = null,
    shots: u32 = 0,
    /// Seconds since his last shot at it.
    age: f32 = std.math.inf(f32),
};

/// Members' tracers: meters per second, seconds before they're dropped; where on a
/// member they leave from (above its feet, and ahead along its facing).
const TRACER_SPEED: f32 = 80.0;
const TRACER_LIFETIME: f32 = 1.5;
const MUZZLE_HEIGHT: f32 = 1.0;
const MUZZLE_AHEAD: f32 = 0.45;

pub const Squad = struct {
    members: [SIZE]Member,
    tuning: Tuning = .{},
    show_debug: bool = false,
    lines: Lines,
    debug_segments: [SIZE * 3]LineSegment = undefined,
    focus: Focus = .{},
    /// Every member's shots in flight; the scene moves them against the turrets.
    tracers: Projectiles = .{},
    shots_fired: u32 = 0,

    const Self = @This();

    /// The squad standing behind the captain at `captain`.
    pub fn init(rm: *ResourceManager, captain: Transform, random: *Random) !Self {
        const lines_shader = try rm.createShader("examples/bullets/shaders/lines.wgsl", .{
            .vertex_buffers = &Lines.vertex_buffer_layouts,
            .topology = .line_list,
        });
        var self: Self = .{
            .members = undefined,
            .lines = try Lines.init(rm.context.alloc, lines_shader, 1.0, 1.0, SIZE * 3),
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
                .fire_control = .{ .cadence = .{ .bursts = .{
                    .count = 2 + @as(u32, @intFromFloat(random.randFloat() * 4.0)),
                    .interval = random.randFloatInRange(0.07, 0.14),
                    .pause = random.randFloatInRange(0.5, 1.4),
                } } },
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
        self.focus.age += dt;
        const engaging = self.isEngaging();
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
            self.moveAndShoot(member, engaging, random, dt);
            try member.soldier.update(dt);
        }
    }

    /// The captain fired a shot that will land at `point`, on turret `target` if any: it
    /// adds to the focus if it's close to the last shots in time and place, else starts a
    /// new one.
    pub fn reportShot(self: *Self, point: Vec3, target: ?usize) void {
        const focus = &self.focus;
        const is_close = focus.shots > 0 and focus.age < self.tuning.focus_window and point.sub(focus.point).length() < self.tuning.focus_radius;
        if (is_close) {
            const count: f32 = @floatFromInt(focus.shots);
            focus.point = focus.point.mulScalar(count).add(point).mulScalar(1.0 / (count + 1.0));
            focus.shots += 1;
            focus.target = target orelse focus.target;
        } else {
            focus.* = .{ .point = point, .target = target, .shots = 1 };
        }
        focus.age = 0.0;
    }

    /// The focus is gone (its turret destroyed): the squad stops firing.
    pub fn clearFocus(self: *Self) void {
        self.focus = .{};
    }

    /// Whether the squad is firing at the focus point.
    pub fn isEngaging(self: *const Self) bool {
        const needed: u32 = @intCast(@max(self.tuning.shots_to_engage, 1));
        return self.focus.shots >= needed and self.focus.age < self.tuning.focus_hold;
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
            _ = zgui.checkbox("debug lines (spot yellow, steering cyan, aim red)", .{ .v = &self.show_debug });
            zgui.separatorText("spot near the captain");
            _ = zgui.sliderFloat("gap behind (deg)", .{ .v = &tuning.spot_gap, .min = 0.0, .max = 90.0 });
            _ = zgui.sliderFloat("spread (deg)", .{ .v = &tuning.spot_spread, .min = 0.0, .max = 180.0 });
            _ = zgui.sliderFloat("min distance (m)", .{ .v = &tuning.spot_min_distance, .min = 0.5, .max = 10.0 });
            _ = zgui.sliderFloat("max distance (m)", .{ .v = &tuning.spot_max_distance, .min = 0.5, .max = 15.0 });
            _ = zgui.sliderFloat("new spot every (s)", .{ .v = &tuning.spot_interval, .min = 0.5, .max = 15.0 });
            _ = zgui.sliderFloat("spot drift (rate)", .{ .v = &tuning.spot_drift, .min = 0.05, .max = 5.0 });
            zgui.separatorText("focus fire");
            if (self.isEngaging()) {
                zgui.text("engaging: {d} shots on the point, {d:.1} s ago", .{ self.focus.shots, self.focus.age });
            } else {
                zgui.text("holding fire", .{});
            }
            zgui.text("squad shots: {d}", .{self.shots_fired});
            _ = zgui.sliderFloat("focus radius (m)", .{ .v = &tuning.focus_radius, .min = 0.5, .max = 6.0 });
            _ = zgui.sliderFloat("focus window (s)", .{ .v = &tuning.focus_window, .min = 0.2, .max = 4.0 });
            _ = zgui.sliderInt("shots to engage", .{ .v = &tuning.shots_to_engage, .min = 1, .max = 6 });
            _ = zgui.sliderFloat("hold fire after (s)", .{ .v = &tuning.focus_hold, .min = 0.5, .max = 10.0 });
            _ = zgui.sliderFloat("delay min (s)", .{ .v = &tuning.engage_delay_min, .min = 0.0, .max = 2.0 });
            _ = zgui.sliderFloat("delay max (s)", .{ .v = &tuning.engage_delay_max, .min = 0.0, .max = 3.0 });
            _ = zgui.sliderFloat("aim turn (rate)", .{ .v = &tuning.aim_turn_rate, .min = 1.0, .max = 20.0 });
            _ = zgui.sliderFloat("aim jitter (deg)", .{ .v = &tuning.aim_jitter, .min = 0.0, .max = 10.0 });
            zgui.separatorText("settling");
            _ = zgui.checkbox("yield by rank", .{ .v = &tuning.rank_yields });
            _ = zgui.sliderFloat("settle below (m/s)", .{ .v = &tuning.settle_speed, .min = 0.0, .max = 2.0 });
            _ = zgui.sliderFloat("restart beyond (m)", .{ .v = &tuning.restart_radius, .min = 0.3, .max = 5.0 });
            _ = zgui.sliderFloat("personal space (m)", .{ .v = &tuning.personal_space, .min = 0.2, .max = 2.0 });
            zgui.text("settled: {d} of {d}", .{ self.settledCount(), SIZE });
            zgui.separatorText("steering");
            _ = zgui.sliderFloat("slow radius (m)", .{ .v = &tuning.slow_radius, .min = 0.5, .max = 8.0 });
            _ = zgui.sliderFloat("stop radius (m)", .{ .v = &tuning.stop_radius, .min = 0.1, .max = 3.0 });
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

    /// Steers the member by its smoothed sum. Engaged, it faces the focus point while it
    /// moves (gun up) and, once its delay is over and it faces the point, fires its bursts.
    fn moveAndShoot(self: *Self, member: *Member, engaging: bool, random: *Random, dt: f32) void {
        const soldier = member.soldier;
        if (engaging and !member.engaged) {
            member.engage_timer = random.randFloatInRange(self.tuning.engage_delay_min, self.tuning.engage_delay_max);
            member.aim_heading = character_control.heading(soldier.transform.rotation);
        }
        member.engaged = engaging;

        if (!member.engaged) {
            member.fire_control.update(dt, false, 0.0);
            soldier.steer(self.stick(member), dt);
            return;
        }

        const to_point = self.focus.point.sub(soldier.transform.translation);
        const point_heading = std.math.atan2(to_point.x, to_point.z);
        member.aim_heading = motion.dampAngle(member.aim_heading, point_heading, self.tuning.aim_turn_rate, dt);
        member.engage_timer -= dt;
        const off_by = @abs(motion.wrapAngle(point_heading - member.aim_heading));
        const ready = member.engage_timer <= 0.0 and off_by < std.math.degreesToRadians(self.tuning.aim_tolerance);

        member.fire_control.update(dt, ready, 0.0);
        soldier.steerAiming(self.stick(member), member.aim_heading, ready, dt);
        self.fireDueShots(member, random);
    }

    /// Each shot due leaves the member's gun for the focus point, jittered.
    fn fireDueShots(self: *Self, member: *Member, random: *Random) void {
        const muzzle = muzzlePosition(member);
        const toward = self.focus.point.sub(muzzle).toNormalized();
        const jitter: ShotJitter = .{ .aim = std.math.degreesToRadians(self.tuning.aim_jitter), .speed = 0.05 };
        while (member.fire_control.nextShot()) |age| {
            const shot = jitter.apply(random, toward, TRACER_SPEED);
            self.tracers.spawn(muzzle, shot.direction.mulScalar(shot.speed), TRACER_LIFETIME, age);
            self.shots_fired += 1;
        }
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

    /// For each member, a yellow line to its spot and a cyan one along its steering; red
    /// from its gun to the focus point while engaged.
    fn drawDebugLines(self: *Self, frame: *const Frame) void {
        const lift = vec3(0.0, 0.05, 0.0);
        var count: usize = 0;
        for (self.members) |member| {
            const position = member.soldier.transform.translation.add(lift);
            self.debug_segments[count] = .{ .start = position, .end = member.spot.add(lift), .color = .yellow };
            self.debug_segments[count + 1] = .{ .start = position, .end = position.add(member.desired), .color = .cyan };
            count += 2;
            if (member.engaged) {
                self.debug_segments[count] = .{ .start = muzzlePosition(&member), .end = self.focus.point, .color = .red };
                count += 1;
            }
        }
        self.lines.draw(frame, self.debug_segments[0..count]);
    }
};

/// Where a member's shots leave from: about its gun, ahead along where it aims.
fn muzzlePosition(member: *const Member) Vec3 {
    const ahead = character_control.headingDirection(member.aim_heading).mulScalar(MUZZLE_AHEAD);
    return member.soldier.transform.translation.add(vec3(0.0, MUZZLE_HEIGHT, 0.0)).add(ahead);
}

/// The spot `angle` radians from straight behind a captain at `captain` facing
/// `captain_heading`, `distance` meters away.
fn spotPosition(captain: Vec3, captain_heading: f32, angle: f32, distance: f32) Vec3 {
    const behind = captain_heading + std.math.pi + angle;
    return captain.add(character_control.headingDirection(behind).mulScalar(distance));
}
