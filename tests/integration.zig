//! End-to-end tests for the compiled `zix` binary.
//!
//! Exercises help/version output, exit codes, and `--dry-run`. Every workflow
//! test uses `--dry-run` so no real `git pull`/`nixos-rebuild` runs against the
//! user's repository.

const std = @import("std");
const exe_path = @import("build_options").zix_exe;

/// Captured run of the binary, with owned stdout/stderr.
const Run = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    fn code(self: Run) i32 {
        return switch (self.term) {
            .exited => |c| c,
            else => 1,
        };
    }
};

/// Runs the binary with `extra` args (stdin ignored).
fn run(extra: []const []const u8) !Run {
    return runWith(extra, null);
}

/// Runs the binary with `extra` args and an optional replacement environment.
fn runWith(extra: []const []const u8, environ_map: ?*const std.process.Environ.Map) !Run {
    const allocator = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    for (extra) |arg| try argv.append(allocator, arg);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .environ_map = environ_map,
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

test "help flag prints banner and exits zero" {
    const result = try run(&.{"-h"});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.code());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ZIX") != null);
}

test "long help and version flags work" {
    const help = try run(&.{"--help"});
    defer help.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "ZIX") != null);

    const version = try run(&.{"--version"});
    defer version.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, version.stdout, "ZIX version") != null);
}

test "unknown flag exits with code 2 and reports on stderr" {
    const result = try run(&.{"-x"});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 2), result.code());
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Unknown flag") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unknown flag") == null);
}

test "zero keep exits with code 2" {
    const result = try run(&.{ "-k", "0" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 2), result.code());
}

test "dry run prints commands without executing" {
    const result = try run(&.{ "--dry-run", "-y", "-n", "testhost", "-r", "/tmp" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.code());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "$ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nixos-rebuild") != null);
}

test "jobs and cores flags flow into the rebuild command" {
    const result = try run(&.{
        "--dry-run", "-y", "-n", "testhost", "-r", "/tmp", "-j", "4", "-c", "6",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.code());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--max-jobs 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--cores 6") != null);
}

test "no-color flag is accepted and keeps help plain" {
    const result = try run(&.{ "--no-color", "-h" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.code());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ZIX") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\x1b[") == null);
}

test "unknown hostname aborts before rebuild" {
    const result = try run(&.{ "--dry-run", "-y", "-n", "unknown", "-r", "/tmp" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 1), result.code());
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "hostname") != null);
}

test "output has no ANSI escapes without a terminal" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("NO_COLOR", "1");

    const result = try runWith(&.{"-h"}, &environ);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.code());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\x1b[") == null);
}
