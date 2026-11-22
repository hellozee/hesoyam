const std = @import("std");
const testing = std.testing;
const net = std.Io.net;

const proxy = @import("hesoyam").proxy;

fn echo_once(io: std.Io, server: *net.Server) void {
    const stream = server.accept(io) catch {
        testing.failPrintLine("fail to initialize the backend\n");
        return;
    };
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var message: [5]u8 = undefined;
    reader.interface.readSliceAll(&message) catch {
        testing.failPrintLine("failed to read opened stream\n");
        return;
    };

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(&message) catch {
        testing.failPrintLine("failed to write message\n");
        return;
    };
    writer.interface.flush() catch {
        testing.failPrintLine("failed to flush\n");
        return;
    };
}

test "simple proxy roundtrip" {
    const target: net.IpAddress = .{ .ip4 = .loopback(19091) };
    const host = std.Io.net.IpAddress{ .ip4 = .loopback(19092) };

    var server = try host.listen(testing.io, .{
        .reuse_address = true,
    });
    defer server.deinit(testing.io);

    var backend = try target.listen(testing.io, .{
        .reuse_address = true,
    });
    defer backend.deinit(testing.io);

    var group: std.Io.Group = .init;
    defer group.cancel(testing.io);

    try group.concurrent(testing.io, echo_once, .{ testing.io, &backend });

    try group.concurrent(testing.io, proxy.serve, .{
        testing.io,
        &server,
        .{
            .target = target,
            .timeout = .fromSeconds(5),
        },
    });

    try testing.io.sleep(.fromSeconds(1), .awake);

    const client = try host.connect(testing.io, .{ .mode = .stream });
    defer client.close(testing.io);

    var write_buffer: [4096]u8 = undefined;
    var writer = client.writer(testing.io, &write_buffer);

    try writer.interface.writeAll("hello");
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = client.reader(testing.io, &read_buffer);

    var received_message: [5]u8 = undefined;
    try reader.interface.readSliceAll(&received_message);

    try testing.expectEqualStrings("hello", &received_message);
}
