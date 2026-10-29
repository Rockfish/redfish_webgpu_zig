//! Where the robot can walk (plan 021, phase G): rectangles of floor (`Area`), joined
//! where they touch or overlap. Inside one rectangle any two points are a straight walk
//! apart; between rectangles the robot goes through their shared edges. Enough for rooms
//! with something in the way (Room 02's hole) and doorways between them (an area that
//! needs the door open).
//!
//! Areas are where the robot's center can go: they keep its body clear of walls and
//! holes.

const std = @import("std");
const math = @import("math");

const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// Most areas a deck has; more needs a larger `MAX_AREAS`.
const MAX_AREAS = 16;
/// Points in a path: one per area passed through, plus the target.
pub const MAX_PATH_POINTS = MAX_AREAS + 1;

/// A rectangle of floor, on x and z.
pub const Area = struct {
    min_x: f32,
    max_x: f32,
    min_z: f32,
    max_z: f32,
    /// A doorway: walkable only while the door is open.
    needs_open_door: bool = false,

    pub fn contains(self: Area, point: Vec3) bool {
        const margin = 1e-3;
        return point.x >= self.min_x - margin and point.x <= self.max_x + margin and
            point.z >= self.min_z - margin and point.z <= self.max_z + margin;
    }

    pub fn nearestPoint(self: Area, point: Vec3) Vec3 {
        return vec3(std.math.clamp(point.x, self.min_x, self.max_x), 0.0, std.math.clamp(point.z, self.min_z, self.max_z));
    }

    /// Where two areas meet (an edge or a rectangle), or null if they don't.
    fn overlap(self: Area, other: Area) ?Area {
        const shared: Area = .{
            .min_x = @max(self.min_x, other.min_x),
            .max_x = @min(self.max_x, other.max_x),
            .min_z = @max(self.min_z, other.min_z),
            .max_z = @min(self.max_z, other.max_z),
        };
        if (shared.min_x > shared.max_x or shared.min_z > shared.max_z) {
            return null;
        }
        return shared;
    }
};

/// Points to walk to in turn, on the floor; the last is the target.
pub const Path = struct {
    points: [MAX_PATH_POINTS]Vec3 = undefined,
    len: usize = 0,

    pub fn last(self: *const Path) Vec3 {
        return self.points[self.len - 1];
    }

    fn append(self: *Path, point: Vec3) void {
        self.points[self.len] = point;
        self.len += 1;
    }
};

/// The walk from `from` toward `wanted`: to the nearest point to `wanted` the robot can
/// reach from where it is, through the areas between. `from` is in an area (or is moved
/// into the nearest one).
pub fn findPath(areas: []const Area, is_door_open: bool, from: Vec3, wanted: Vec3) Path {
    std.debug.assert(areas.len <= MAX_AREAS);
    const start = nearestArea(areas, is_door_open, from, null);

    // Breadth-first over the areas, from the start: each reached area's previous one
    var previous: [MAX_AREAS]?usize = @splat(null);
    var is_reached: [MAX_AREAS]bool = @splat(false);
    var queue: [MAX_AREAS]usize = undefined;
    var queue_start: usize = 0;
    var queue_end: usize = 1;
    queue[0] = start;
    is_reached[start] = true;
    while (queue_start < queue_end) : (queue_start += 1) {
        const current = queue[queue_start];
        for (areas, 0..) |area, next| {
            if (is_reached[next] or !isUsable(area, is_door_open) or areas[current].overlap(area) == null) {
                continue;
            }
            is_reached[next] = true;
            previous[next] = current;
            queue[queue_end] = next;
            queue_end += 1;
        }
    }

    const goal = nearestArea(areas, is_door_open, wanted, &is_reached);
    const target = areas[goal].nearestPoint(wanted);

    // The areas from the goal back to the start, then a point on each shared edge: the
    // one nearest the point after it, so the path stays close to straight
    var chain: [MAX_AREAS]usize = undefined;
    var chain_len: usize = 0;
    var area: ?usize = goal;
    while (area) |index| : (area = previous[index]) {
        chain[chain_len] = index;
        chain_len += 1;
    }
    var crossings: [MAX_AREAS]Vec3 = undefined;
    var after = target;
    for (0..chain_len - 1) |i| {
        const shared = areas[chain[i]].overlap(areas[chain[i + 1]]).?;
        crossings[i] = shared.nearestPoint(after);
        after = crossings[i];
    }

    var path: Path = .{};
    var i = chain_len - 1;
    while (i > 0) {
        i -= 1;
        path.append(crossings[i]);
    }
    path.append(target);
    return path;
}

/// The point the robot would walk to for `wanted`, from `from` (`findPath`'s target).
pub fn nearestReachable(areas: []const Area, is_door_open: bool, from: Vec3, wanted: Vec3) Vec3 {
    return findPath(areas, is_door_open, from, wanted).last();
}

fn isUsable(area: Area, is_door_open: bool) bool {
    return is_door_open or !area.needs_open_door;
}

/// The usable area (among `allowed`, if given) nearest `point`.
fn nearestArea(areas: []const Area, is_door_open: bool, point: Vec3, allowed: ?*const [MAX_AREAS]bool) usize {
    var best: usize = 0;
    var best_distance = std.math.inf(f32);
    for (areas, 0..) |area, i| {
        if (!isUsable(area, is_door_open)) {
            continue;
        }
        if (allowed) |is_allowed| {
            if (!is_allowed[i]) {
                continue;
            }
        }
        const distance = area.nearestPoint(point).sub(vec3(point.x, 0.0, point.z)).length();
        if (distance < best_distance) {
            best = i;
            best_distance = distance;
        }
    }
    return best;
}

const testing = std.testing;

/// A room joined by a doorway to a room with a hole: a front strip and a strip either
/// side of the hole behind it; the doorway opens onto the right one.
const test_areas = [_]Area{
    .{ .min_x = 0.0, .max_x = 4.0, .min_z = -4.0, .max_z = 0.0 },
    .{ .min_x = -1.0, .max_x = 0.0, .min_z = -2.5, .max_z = -1.5, .needs_open_door = true },
    .{ .min_x = -5.0, .max_x = -1.0, .min_z = -1.0, .max_z = 0.0 },
    .{ .min_x = -5.0, .max_x = -4.0, .min_z = -4.0, .max_z = -1.0 },
    .{ .min_x = -2.0, .max_x = -1.0, .min_z = -4.0, .max_z = -1.0 },
};

fn expectPoint(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, 1e-5);
    try testing.expectApproxEqAbs(expected.y, actual.y, 1e-5);
    try testing.expectApproxEqAbs(expected.z, actual.z, 1e-5);
}

test "findPath: inside one area, straight to the target" {
    const path = findPath(&test_areas, false, vec3(1.0, 0.0, -1.0), vec3(3.0, 0.0, -3.0));
    try testing.expectEqual(1, path.len);
    try expectPoint(vec3(3.0, 0.0, -3.0), path.last());
}

test "findPath: a point outside every area goes to the nearest point in one" {
    const path = findPath(&test_areas, false, vec3(1.0, 0.0, -1.0), vec3(6.0, 1.5, -2.0));
    try testing.expectEqual(1, path.len);
    try expectPoint(vec3(4.0, 0.0, -2.0), path.last());
}

test "findPath: through the doorway when the door is open" {
    const path = findPath(&test_areas, true, vec3(2.0, 0.0, -2.0), vec3(-3.0, 0.0, -0.5));
    try testing.expectEqual(4, path.len);
    // Into the doorway, out of it into the strip beside the hole, into the front strip
    try expectPoint(vec3(0.0, 0.0, -1.5), path.points[0]);
    try expectPoint(vec3(-1.0, 0.0, -1.5), path.points[1]);
    try expectPoint(vec3(-2.0, 0.0, -1.0), path.points[2]);
    try expectPoint(vec3(-3.0, 0.0, -0.5), path.points[3]);
}

test "findPath: a closed door keeps the robot in its room" {
    const target = nearestReachable(&test_areas, false, vec3(2.0, 0.0, -2.0), vec3(-3.0, 0.0, -0.5));
    try expectPoint(vec3(0.0, 0.0, -0.5), target);
}

test "findPath: around the hole's front, from one side behind it to the other" {
    const path = findPath(&test_areas, false, vec3(-4.5, 0.0, -3.0), vec3(-1.5, 0.0, -3.0));
    try testing.expectEqual(3, path.len);
    // Each crossing is the point of the shared edge nearest the next point
    try expectPoint(vec3(-4.0, 0.0, -1.0), path.points[0]);
    try expectPoint(vec3(-1.5, 0.0, -1.0), path.points[1]);
    try expectPoint(vec3(-1.5, 0.0, -3.0), path.last());
}

test "Area.contains allows a point on the edge" {
    try testing.expect(test_areas[0].contains(vec3(4.0, 0.0, 0.0)));
    try testing.expect(!test_areas[0].contains(vec3(4.1, 0.0, 0.0)));
}
