const std = @import("std");
const math = std.math;

/// Unity-style smooth damping function for smooth value transitions
/// current: The current value
/// target: The target value to move towards
/// current_velocity: Pointer to the current velocity (will be modified)
/// smooth_time: Approximate time to reach target
/// max_speed: Maximum speed
/// dt: Delta time
pub fn smoothDamp(current: f32, target: f32, current_velocity: *f32, smooth_time: f32, max_speed: f32, dt: f32) f32 {
    const safe_smooth_time = @max(0.0001, smooth_time);
    const num = 2.0 / safe_smooth_time;
    const num2 = num * dt;
    const num3 = 1.0 / (1.0 + num2 + 0.48 * num2 * num2 + 0.235 * num2 * num2 * num2);
    var num4 = current - target;
    const num5 = target;
    const num6 = max_speed * safe_smooth_time;
    num4 = math.clamp(num4, -num6, num6);
    const new_target = current - num4;
    const num7 = (current_velocity.* + num * num4) * dt;
    current_velocity.* = (current_velocity.* - num * num7) * num3;
    var num8 = new_target + (num4 + num7) * num3;
    if ((num5 - current > 0.0) == (num8 > num5)) {
        num8 = num5;
        current_velocity.* = (num8 - num5) / dt;
    }
    return num8;
}

/// Linear interpolation between two values
pub fn lerp(val1: f32, val2: f32, amt: f32) f32 {
    return val1 * (1.0 - amt) + val2 * amt;
}

/// Cubic interpolation between two values with smoothstep
pub fn cubicLerp(val1: f32, val2: f32, amt: f32) f32 {
    return lerp(val1, val2, 3.0 * amt * amt - 2.0 * amt * amt * amt);
}

/// Cubic interpolation with 4 control points (Catmull-Rom style)
pub fn cubicInterp(val0: f32, val1: f32, val2: f32, val3: f32, amt: f32) f32 {
    const amt2 = amt * amt;
    return ((val3 * 0.5 - val2 * 1.5 - val0 * 0.5 + val1 * 1.5) * amt * amt2 +
        (val0 - val1 * 2.5 + val2 * 2.0 - val3 * 0.5) * amt2 +
        (val2 * 0.5 - val0 * 0.5) * amt +
        val1);
}

/// Cubic interpolation using explicit tangents (Hermite interpolation)
pub fn cubicInterpTangents(val1: f32, tan1: f32, val2: f32, tan2: f32, amt: f32) f32 {
    const amt2 = amt * amt;
    return ((tan2 - val2 * 2.0 + tan1 + val1 * 2.0) * amt * amt2 +
        (tan1 * 2.0 - val1 * 3.0 + val2 * 3.0 - tan2 * 2.0) * amt2 +
        tan1 * amt +
        val1);
}

/// Bilinear interpolation (2D lerp)
pub fn bilerp(val00: f32, val10: f32, val01: f32, val11: f32, amt_x: f32, amt_y: f32) f32 {
    return lerp(lerp(val00, val10, amt_x), lerp(val01, val11, amt_x), amt_y);
}

/// Step function - returns 0 if x < edge, otherwise 1
pub fn step(edge: f32, x: f32) f32 {
    return if (x < edge) 0.0 else 1.0;
}

/// Ease in (quadratic) - accelerating from zero velocity
pub fn easeIn(start: f32, end: f32, alpha: f32) f32 {
    return lerp(start, end, alpha * alpha);
}

/// Ease out (quadratic) - decelerating to zero velocity
pub fn easeOut(start: f32, end: f32, alpha: f32) f32 {
    return lerp(start, end, 1.0 - (1.0 - alpha) * (1.0 - alpha));
}

/// Ease in-out (quadratic) - acceleration until halfway, then deceleration
pub fn easeInOut(start: f32, end: f32, alpha: f32) f32 {
    if (alpha < 0.5) {
        return lerp(start, end, 2.0 * alpha * alpha);
    }
    const val = -2.0 * alpha + 2.0;
    return lerp(start, end, 1.0 - math.pow(f32, val, 2.0) / 2.0);
}

/// Cubic easing
pub fn cubic(start: f32, end: f32, alpha: f32) f32 {
    return lerp(start, end, alpha * alpha * alpha);
}

/// Exponential easing
pub fn exponential(start: f32, end: f32, alpha: f32) f32 {
    if (alpha < 0.001 and alpha > -0.001) {
        return 0.0;
    }
    return lerp(start, end, math.pow(f32, 2.0, 10.0 * alpha - 10.0));
}

/// Bounce easing - simulates a bouncing effect
pub fn bounce(start: f32, end: f32, alpha_param: f32) f32 {
    var alpha = alpha_param;

    if (alpha < (1.0 / 2.75)) {
        return lerp(start, end, 7.5625 * alpha * alpha);
    } else if (alpha < (2.0 / 2.75)) {
        alpha -= (1.5 / 2.75);
        return lerp(start, end, 7.5625 * alpha * alpha + 0.75);
    } else if (alpha < (2.5 / 2.75)) {
        alpha -= (2.25 / 2.75);
        return lerp(start, end, 7.5625 * alpha * alpha + 0.9375);
    } else {
        alpha -= (2.625 / 2.75);
        return lerp(start, end, 7.5625 * alpha * alpha + 0.984375);
    }
}

/// Sinusoidal easing
pub fn sinusoidal(start: f32, end: f32, alpha: f32) f32 {
    return lerp(start, end, -math.cos(alpha * math.pi) / 2.0 + 0.5);
}
