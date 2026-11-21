const std = @import("std");
const proxy = @import("proxy.zig");

pub fn main(init: std.process.Init) !void {
    try proxy.serve(init.io, .{
        .host = std.Io.net.IpAddress{ .ip4 = .loopback(8000) },
        .target = std.Io.net.IpAddress{ .ip4 = .loopback(8080) },
        .timeout = .fromSeconds(30),
    });
}
