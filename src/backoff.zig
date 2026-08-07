const std = @import("std");

/// Exponential backoff with full jitter. `next()` returns a sleep duration
/// drawn uniformly from [base, min(cap, base * 2^attempt)].
pub const Backoff = struct {
    base_ns: u64,
    cap_ns: u64,
    attempt: u6 = 0,
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64, base_ns: u64, cap_ns: u64) Backoff {
        return .{
            .base_ns = base_ns,
            .cap_ns = cap_ns,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn reset(self: *Backoff) void {
        self.attempt = 0;
    }

    pub fn next(self: *Backoff) u64 {
        var hi = self.base_ns;
        var i: u6 = 0;
        while (i < self.attempt and hi < self.cap_ns) : (i += 1) {
            hi = @min(self.cap_ns, hi *| 2);
        }
        if (self.attempt < 32) self.attempt += 1;
        return self.prng.random().intRangeAtMost(u64, self.base_ns, hi);
    }
};

test "backoff stays within bounds and grows" {
    var b = Backoff.init(42, 100, 1000);
    var prev_hi: u64 = 0;
    for (0..8) |_| {
        const v = b.next();
        try std.testing.expect(v >= 100);
        try std.testing.expect(v <= 1000);
        prev_hi = @max(prev_hi, v);
    }
    b.reset();
    const v = b.next();
    try std.testing.expect(v >= 100 and v <= 100);
}
