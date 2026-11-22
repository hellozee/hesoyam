const std = @import("std");
const net = std.Io.net;
const tools = @import("tools.zig");

fn splice(io: std.Io, source: net.Stream, destination: net.Stream, tracker: *tools.ActivityRacer) void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var reader = source.reader(io, &read_buf);
    var writer = destination.writer(io, &write_buf);

    defer destination.shutdown(io, .send) catch {
        std.debug.print("couldn't shutdown destination\n", .{});
    };

    while (true) {
        var buffer: [4096]u8 = undefined;
        var slices: [1][]u8 = .{&buffer};
        const n = reader.interface.readVec(&slices) catch |err| {
            if (err != error.EndOfStream) {
                std.debug.print("cound't read: {any}\n", .{err});
            }
            break;
        };

        if (n == 0) {
            continue;
        }

        writer.interface.writeAll(buffer[0..n]) catch {
            std.debug.print("write failed\n", .{});
            return;
        };

        writer.interface.flush() catch {
            std.debug.print("flushing failed\n", .{});
            return;
        };

        tracker.touch(io);
    }
}

fn relay(io: std.Io, local: net.Stream, upstream: net.Stream, tracker: *tools.ActivityRacer) void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    group.concurrent(io, splice, .{ io, local, upstream, tracker }) catch return {};
    group.concurrent(io, splice, .{ io, upstream, local, tracker }) catch return {};
    group.await(io) catch return {};
}

const TimedOutcome = union(enum) { timedout: void, finished: void };

fn handle(io: std.Io, local: net.Stream, target: net.IpAddress, timeout: std.Io.Duration) void {
    defer local.close(io);

    const upstream = target.connect(io, .{ .mode = .stream }) catch {
        std.debug.print("could connect to backed\n", .{});
        return;
    };
    defer upstream.close(io);

    var slots: [2]TimedOutcome = undefined;
    var select: std.Io.Select(TimedOutcome) = .init(io, &slots);
    defer select.cancelDiscard();

    var tracker: tools.ActivityRacer = .{};

    select.concurrent(.finished, relay, .{ io, local, upstream, &tracker }) catch return;
    select.concurrent(.timedout, tools.ActivityRacer.deadline, .{ &tracker, io, timeout }) catch return;

    switch (select.await() catch return) {
        .finished => {},
        .timedout => std.debug.print("connection timed out\n", .{}),
    }
}

pub fn serve(io: std.Io, server: *net.Server, options: tools.ProxyOptions) void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            if (err != error.Canceled) {
                std.debug.print("couldn't accept client\n", .{});
            }
            return;
        };

        group.concurrent(io, handle, .{ io, stream, options.target, options.timeout }) catch {
            std.debug.print("something went wrong with handling client", .{});
            stream.close(io);
        };
    }
}
