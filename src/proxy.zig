const std = @import("std");
const net = std.Io.net;
const tools = @import("tools.zig");

fn splice(io: std.Io, source: net.Stream, destination: net.Stream, tracker: *tools.ActivityRacer) !void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var reader = source.reader(io, &read_buf);
    var writer = destination.writer(io, &write_buf);

    defer destination.shutdown(io, .send) catch {};

    while (true) {
        var buffer: [4096]u8 = undefined;
        var slices: [1][]u8 = .{&buffer};
        const n = reader.interface.readVec(&slices) catch |err| {
            if (err != error.EndOfStream) {
                return err;
            }
            break;
        };

        if (n == 0) {
            continue;
        }

        try writer.interface.writeAll(buffer[0..n]);
        try writer.interface.flush();

        tracker.touch(io);
    }
}

fn contained_splice(
    io: std.Io,
    source: net.Stream,
    destination: net.Stream,
    racer: *tools.ActivityRacer,
    state: *tools.SpliceState,
) void {
    splice(io, source, destination, racer) catch |err| {
        if (state.failure == null) {
            state.failure = err;
        }
    };
}

fn relay(io: std.Io, local: net.Stream, upstream: net.Stream, context: *tools.ConnectionContext) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(io, contained_splice, .{
        io,
        local,
        upstream,
        &context.racer,
        &context.client_to_upstream,
    });
    try group.concurrent(io, contained_splice, .{
        io,
        upstream,
        local,
        &context.racer,
        &context.upstream_to_client,
    });
    try group.await(io);
}

fn contained_relay(
    io: std.Io,
    local: net.Stream,
    upstream: net.Stream,
    context: *tools.ConnectionContext,
) void {
    relay(io, local, upstream, context) catch |err| {
        if (context.relay_failure == null) {
            context.relay_failure = err;
        }
    };
}

const TimedOutcome = union(enum) { timedout: void, finished: void };

fn run(
    io: std.Io,
    local: net.Stream,
    upstream: net.Stream,
    timeout: std.Io.Duration,
    context: *tools.ConnectionContext,
) !void {
    var slots: [2]TimedOutcome = undefined;
    var select: std.Io.Select(TimedOutcome) = .init(io, &slots);
    defer select.cancelDiscard();

    try select.concurrent(.finished, contained_relay, .{ io, local, upstream, context });
    try select.concurrent(.timedout, tools.ActivityRacer.deadline, .{ &context.racer, io, timeout });

    switch (try select.await()) {
        .finished => {},
        .timedout => std.debug.print("connection timed out\n", .{}),
    }
}

fn handle(io: std.Io, local: net.Stream, target: net.IpAddress, timeout: std.Io.Duration) void {
    defer local.close(io);

    const upstream = target.connect(io, .{ .mode = .stream }) catch {
        std.debug.print("could connect to backed\n", .{});
        return;
    };

    defer upstream.close(io);

    var context: tools.ConnectionContext = .{};

    run(io, local, upstream, timeout, &context) catch return;
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
