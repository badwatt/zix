//! Shell process execution wrapper.
//!
//! Spawns commands via `sh -c` with configurable stdout/stderr suppression.

const std = @import("std");

/// Options for process execution. `output` controls whether
/// stdout and stderr are inherited (true) or suppressed (false).
pub const RunOpts = struct { output: bool = true };

/// Spawns `sh -c <command>` and returns the exit code.
/// Asserts command is non-empty. Returns 1 for non-exit terminations.
pub fn run(io: std.Io, command: []const u8, opts: RunOpts) !i32 {
    std.debug.assert(command.len > 0);

    const shellCommand = [_][]const u8{ "sh", "-c", command };
    var child = try std.process.spawn(io, .{
        .argv = &shellCommand,
        .stdin = .inherit,
        .stdout = if (opts.output) .inherit else .ignore,
        .stderr = if (opts.output) .inherit else .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| return code,
        else => return 1,
    }
}

test "run basic commands" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(i32, 0), try run(io, "true", .{}));
    try std.testing.expectEqual(@as(i32, 1), try run(io, "false", .{}));
    try std.testing.expectEqual(@as(i32, 1), try run(io, "kill -9 $$", .{}));
}
