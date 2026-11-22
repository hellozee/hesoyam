const std = @import("std");
const proxy = @import("proxy.zig");
const tools = @import("tools.zig");

pub fn main(init: std.process.Init) void {
    const proxy_options = tools.ProxyOptions{
        .target = std.Io.net.IpAddress{ .ip4 = .loopback(8080) },
        .timeout = .fromSeconds(30),
    };
    const host = std.Io.net.IpAddress{ .ip4 = .loopback(8000) };
    var server = host.listen(init.io, .{
        .reuse_address = true,
    }) catch {
        std.debug.print("couldn't listen on address\n", .{});
        return;
    };

    defer server.deinit(init.io);

    proxy.serve(init.io, &server, proxy_options);
}
