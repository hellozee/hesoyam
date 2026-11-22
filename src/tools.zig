const std = @import("std");

pub const ActivityRacer = struct {
    last_activity: std.Io.Timestamp = undefined,
    mutex: std.Io.Mutex = .init,

    pub fn touch(self: *@This(), io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.last_activity = std.Io.Timestamp.now(io, .awake);
    }

    pub fn elapsed(self: *@This(), io: std.Io) std.Io.Duration {
        self.mutex.lockUncancelable(io);
        const last = self.last_activity;
        self.mutex.unlock(io);

        const now = std.Io.Timestamp.now(io, .awake);
        return last.durationTo(now);
    }

    pub fn deadline(self: *@This(), io: std.Io, timeout: std.Io.Duration) void {
        self.touch(io);
        var remaining = timeout;

        while (true) {
            io.sleep(remaining, .awake) catch return;

            const waited = self.elapsed(io);
            if (waited.nanoseconds >= timeout.nanoseconds) {
                break;
            }

            remaining = .fromNanoseconds(timeout.nanoseconds - waited.nanoseconds);
        }
    }
};

pub const ProxyOptions = struct {
    target: std.Io.net.IpAddress,
    timeout: std.Io.Duration,
};

const expect = std.testing.expect;

test "elapsed increases without activity" {
    const io = std.testing.io;

    var racer: ActivityRacer = .{ .last_activity = std.Io.Timestamp.now(io, .awake) };
    io.sleep(.fromMilliseconds(20), .awake) catch unreachable;

    const elapsed = racer.elapsed(io);

    try expect(elapsed.nanoseconds >= std.Io.Duration.fromMilliseconds(20).nanoseconds);
}

test "touch resets elapsed" {
    const io = std.testing.io;

    var racer: ActivityRacer = .{ .last_activity = std.Io.Timestamp.now(io, .awake) };
    io.sleep(.fromMilliseconds(20), .awake) catch unreachable;

    const before = racer.elapsed(io);

    racer.touch(io);
    const after = racer.elapsed(io);

    try expect(after.nanoseconds <= before.nanoseconds);
}

test "deadline expires after inactivity" {
    const io = std.testing.io;
    const timeout: std.Io.Duration = .fromMilliseconds(100);

    var racer: ActivityRacer = .{};
    racer.deadline(io, timeout);

    try expect(racer.elapsed(io).nanoseconds >= timeout.nanoseconds);
}

fn probe(io: std.Io, timeout: std.Io.Duration, tag: u8) u8 {
    io.sleep(timeout, .awake) catch return 0;
    return tag;
}

const TestActivityRacerOutcomes = union(enum) {
    racer_finished: void,
    tester_finished: u8,
};

test "touch extends the deadline" {
    const io = std.testing.io;

    var racer: ActivityRacer = .{};

    var slots: [3]TestActivityRacerOutcomes = undefined;
    var select: std.Io.Select(TestActivityRacerOutcomes) = .init(io, &slots);

    select.concurrent(.racer_finished, ActivityRacer.deadline, .{
        &racer,
        io,
        .fromMilliseconds(200),
    }) catch unreachable;

    select.concurrent(.tester_finished, probe, .{
        io,
        .fromMilliseconds(100),
        1,
    }) catch unreachable;

    select.concurrent(.tester_finished, probe, .{
        io,
        .fromMilliseconds(250),
        2,
    }) catch unreachable;

    const first_tester_finished = select.await() catch unreachable;
    try expect(first_tester_finished == .tester_finished);
    try expect(first_tester_finished.tester_finished == 1);

    racer.touch(io);

    const second_tester_finished = select.await() catch unreachable;
    try expect(second_tester_finished == .tester_finished);
    try expect(second_tester_finished.tester_finished == 2);

    const racer_finished = select.await() catch unreachable;
    try expect(racer_finished == .racer_finished);
}
