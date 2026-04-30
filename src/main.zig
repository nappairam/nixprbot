const std = @import("std");
const zqlite = @import("zqlite");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.log.info("nixprbot starting", .{});
}
