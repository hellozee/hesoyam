const std = @import("std");

pub const Activity = struct {
    last_activity: std.Io.Timestamp,
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
    host: std.Io.net.IpAddress,
    target: std.Io.net.IpAddress,
    timeout: std.Io.Duration,
};
