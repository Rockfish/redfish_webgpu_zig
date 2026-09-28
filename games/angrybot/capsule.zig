pub const Capsule = struct {
    length: f32,
    radius: f32,

    const Self = @This();

    pub fn new(height: f32, radius: f32) Self {
        return .{ .length = height, .radius = radius };
    }
};
