//! Command execution port and its `std.process`-backed implementation.
//!
//! `Runner` is the driven port the workflow depends on. Tests inject mocks and
//! `--dry-run` swaps in `dry_run.DryRun`. Every command is an argv list; no
//! shell is ever spawned.

const std = @import("std");

/// Captured command output. `stdout`/`stderr` are owned by the caller and must
/// be freed with the same allocator passed to `Runner.capture`.
pub const Capture = struct {
    code: i32,
    stdout: []u8,
    stderr: []u8,

    /// Frees the captured buffers. Zero-length slices are ignored by `free`.
    pub fn deinit(self: Capture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Driven port: execute external commands as argv lists.
pub const Runner = struct {
    ctx: ?*anyopaque = null,
    runFn: *const fn (?*anyopaque, std.Io, Command) anyerror!i32,
    captureFn: *const fn (?*anyopaque, std.Io, std.mem.Allocator, Command) anyerror!Capture,
    probeFn: *const fn (?*anyopaque, std.Io, Command) anyerror!i32,

    /// An argv list: program name first, then its arguments.
    pub const Command = []const []const u8;

    /// Runs `argv` inheriting stdio, returning its exit code.
    pub fn run(self: Runner, io: std.Io, argv: Command) anyerror!i32 {
        return self.runFn(self.ctx, io, argv);
    }

    /// Runs `argv` capturing stdout/stderr, returning its exit code.
    pub fn capture(
        self: Runner,
        io: std.Io,
        allocator: std.mem.Allocator,
        argv: Command,
    ) anyerror!Capture {
        return self.captureFn(self.ctx, io, allocator, argv);
    }

    /// Runs `argv` with output discarded, returning its exit code. Used for
    /// capability probes that must stay silent.
    pub fn probe(self: Runner, io: std.Io, argv: Command) anyerror!i32 {
        return self.probeFn(self.ctx, io, argv);
    }
};

/// Production runner backed by `std.process`.
pub const real = Runner{ .runFn = realRun, .captureFn = realCapture, .probeFn = realProbe };

/// Spawns `argv` with the given stdio and waits, returning its exit code.
fn spawnAndWait(io: std.Io, argv: Runner.Command, stdio: std.process.SpawnOptions.StdIo) anyerror!i32 {
    std.debug.assert(argv.len > 0);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = stdio,
        .stdout = stdio,
        .stderr = stdio,
    });
    return termCode(try child.wait(io));
}

fn realRun(_: ?*anyopaque, io: std.Io, argv: Runner.Command) anyerror!i32 {
    return spawnAndWait(io, argv, .inherit);
}

fn realCapture(
    _: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: Runner.Command,
) anyerror!Capture {
    std.debug.assert(argv.len > 0);
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    return .{
        .code = termCode(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn realProbe(_: ?*anyopaque, io: std.Io, argv: Runner.Command) anyerror!i32 {
    return spawnAndWait(io, argv, .ignore);
}

/// Exit code for a terminated child. A process killed or stopped by signal N
/// reports the shell convention `128 + N`; unknown terminations report 1.
fn termCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 + @as(i32, @intCast(@backingInt(sig))),
        .unknown => 1,
    };
}

// --- Tests ---

test "real run returns exit codes" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(i32, 0), try realRun(null, io, &.{"true"}));
    try std.testing.expectEqual(@as(i32, 1), try realRun(null, io, &.{"false"}));
    // Signal-killed process reports 128 + signal (SIGKILL = 9).
    try std.testing.expectEqual(@as(i32, 137), try realRun(null, io, &.{ "sh", "-c", "kill -9 $$" }));
}

test "real run surfaces spawn errors" {
    const io = std.testing.io;
    try std.testing.expectError(
        error.FileNotFound,
        realRun(null, io, &.{"zix_nonexistent_binary_xyz"}),
    );
}

test "real capture returns output and code" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const ok = try realCapture(null, io, alloc, &.{ "echo", "hello" });
    defer ok.deinit(alloc);
    try std.testing.expectEqual(@as(i32, 0), ok.code);
    try std.testing.expectEqualStrings("hello\n", ok.stdout);

    const bad = try realCapture(null, io, alloc, &.{ "sh", "-c", "echo x; exit 3" });
    defer bad.deinit(alloc);
    try std.testing.expectEqual(@as(i32, 3), bad.code);
    try std.testing.expectEqualStrings("x\n", bad.stdout);
}

test "real capture surfaces spawn errors" {
    const io = std.testing.io;
    try std.testing.expectError(
        error.FileNotFound,
        realCapture(null, io, std.testing.allocator, &.{"zix_nonexistent_binary_xyz"}),
    );
}

test "real probe returns exit codes silently" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(i32, 0), try realProbe(null, io, &.{"true"}));
    try std.testing.expectEqual(@as(i32, 1), try realProbe(null, io, &.{"false"}));
    try std.testing.expectError(
        error.FileNotFound,
        realProbe(null, io, &.{"zix_nonexistent_binary_xyz"}),
    );
}

test "termCode maps terminated variants" {
    try std.testing.expectEqual(@as(i32, 4), termCode(.{ .exited = 4 }));
    try std.testing.expectEqual(@as(i32, 137), termCode(.{ .signal = .KILL }));
    try std.testing.expectEqual(@as(i32, 143), termCode(.{ .stopped = .TERM }));
    try std.testing.expectEqual(@as(i32, 1), termCode(.{ .unknown = 9 }));
}

test "RunOpts and Capture deinit tolerate empty slices" {
    const alloc = std.testing.allocator;
    const empty = Capture{ .code = 0, .stdout = &.{}, .stderr = &.{} };
    empty.deinit(alloc);
}

// Mock runner used by the port-dispatch test.
var mock_probe_code: i32 = 0;

fn mockRun(_: ?*anyopaque, _: std.Io, _: Runner.Command) anyerror!i32 {
    return 7;
}

fn mockCapture(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    _: Runner.Command,
) anyerror!Capture {
    return .{ .code = 0, .stdout = &.{}, .stderr = &.{} };
}

fn mockProbe(_: ?*anyopaque, _: std.Io, _: Runner.Command) anyerror!i32 {
    return mock_probe_code;
}

test "Runner port dispatches to injected functions" {
    const runner = Runner{ .runFn = mockRun, .captureFn = mockCapture, .probeFn = mockProbe };
    const io = std.testing.io;

    try std.testing.expectEqual(@as(i32, 7), try runner.run(io, &.{"x"}));
    const captured = try runner.capture(io, std.testing.allocator, &.{"x"});
    try std.testing.expectEqual(@as(i32, 0), captured.code);

    mock_probe_code = 0;
    try std.testing.expectEqual(@as(i32, 0), try runner.probe(io, &.{"x"}));
    mock_probe_code = 5;
    try std.testing.expectEqual(@as(i32, 5), try runner.probe(io, &.{"x"}));
}
