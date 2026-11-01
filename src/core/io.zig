//! I/O utilities: formatted output and ANSI style constants.
//!
//! `printTo` wraps `Writer.print` + `flush` for immediate output.
//! Style constants provide shorthand ANSI escape sequences.

const std = @import("std");

// --- Formatting ---

/// Writes formatted text to `writer` and flushes immediately.
/// Asserts format string is non-empty.
pub fn printTo(
    writer: *std.Io.Writer,
    comptime format: []const u8,
    args: anytype,
) !void {
    // Assert preconditions: format must not be empty.
    std.debug.assert(format.len > 0);

    try writer.print(format, args);
    try writer.flush();
}

// --- ANSI Styles ---

/// Whether ANSI style sequences are emitted on stdout. Set once at startup from
/// `colorSupported`; tests may toggle it.
pub var color_enabled: bool = true;

/// Whether ANSI style sequences are emitted on stderr. Kept separate so a
/// redirected stream never receives escapes because the other one is a TTY.
pub var err_color_enabled: bool = true;

/// Returns `code` when stdout color is enabled, otherwise an empty string.
pub fn style(code: []const u8) []const u8 {
    return if (color_enabled) code else "";
}

/// Returns `code` when stderr color is enabled, otherwise an empty string.
pub fn styleErr(code: []const u8) []const u8 {
    return if (err_color_enabled) code else "";
}

/// True when the environment and `file` allow colored output: `NO_COLOR` is
/// unset or empty, `TERM` is not `dumb`, and `file` is a terminal.
pub fn colorSupported(io: std.Io, environ: *std.process.Environ.Map, file: std.Io.File) bool {
    if (!colorAllowedByEnv(environ)) return false;
    return file.isTty(io) catch false;
}

/// Environment half of `colorSupported`: `NO_COLOR` and `TERM=dumb` opt out.
fn colorAllowedByEnv(environ: *std.process.Environ.Map) bool {
    if (environ.get("NO_COLOR")) |value| {
        if (value.len > 0) return false;
    }
    if (environ.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return true;
}

/// True when `--no-color` appears anywhere in `args`. Scanned before parsing
/// so the flag also silences diagnostics from an argument error.
pub fn noColorRequested(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-color") or
            std.mem.startsWith(u8, arg, "--no-color=")) return true;
    }
    return false;
}

// --- Terminal control ---

/// Whether terminal control sequences (progress and notifications) are
/// emitted. Set once at startup from `controlSupported`; tests may toggle it.
pub var control_enabled: bool = false;

/// Whether to run the background keep-alive that refreshes the progress state.
/// Ghostty resets a stale progress bar after ~15 seconds, so long commands need
/// a periodic update. Enabled together with `control_enabled` in `main`.
pub var keepalive_enabled: bool = false;

/// Io and file used by the keep-alive thread. `main` points the file at stdout.
pub var control_io: std.Io = undefined;
pub var control_file: std.Io.File = undefined;

/// Time between keep-alive refreshes. Ghostty recommends at least one per
/// second; a shorter interval also shortens the join on stop.
var keepalive_interval_ms: i32 = 100;

const progress_running = "\x1b]9;4;3;0\x1b\\";
const progress_paused = "\x1b]9;4;4\x1b\\";
const progress_clear = "\x1b]9;4;0;0\x1b\\";

var progress_active: bool = false;
var control_lock: std.atomic.Mutex = .unlocked;
var keepalive_thread: ?std.Thread = null;
var keepalive_stop = std.atomic.Value(bool).init(true);
var keepalive_paused = std.atomic.Value(bool).init(false);
var keepalive_ticks = std.atomic.Value(usize).init(0);

/// True when stdout can receive terminal control sequences: it is a TTY and
/// `TERM` is not `dumb`. `NO_COLOR` only affects colors, not progress.
pub fn controlSupported(io: std.Io, environ: *std.process.Environ.Map) bool {
    if (environ.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return std.Io.File.stdout().isTty(io) catch false;
}

/// Serializes control writes between the main thread and the keep-alive
/// thread. The critical sections only write a short OSC sequence.
fn lockControl() void {
    while (!control_lock.tryLock()) std.atomic.spinLoopHint();
}

fn unlockControl() void {
    control_lock.unlock();
}

/// Writes `seq` and flushes; the caller holds `control_lock`.
fn writeControlUnlocked(writer: *std.Io.Writer, seq: []const u8) void {
    writer.writeAll(seq) catch return;
    writer.flush() catch {};
}

/// Writes `seq` and flushes; control sequences are best-effort.
fn writeControl(writer: *std.Io.Writer, seq: []const u8) void {
    lockControl();
    defer unlockControl();
    writeControlUnlocked(writer, seq);
}

/// Background refresher: Ghostty forgets a progress state after ~15s without
/// an update, so re-emit the current state while the run is active.
fn keepAlive() void {
    var no_fds: [0]std.posix.pollfd = .{};
    while (true) {
        _ = std.posix.poll(&no_fds, keepalive_interval_ms) catch {};
        lockControl();
        if (keepalive_stop.load(.acquire)) {
            unlockControl();
            break;
        }
        const seq = if (keepalive_paused.load(.acquire))
            progress_paused
        else
            progress_running;
        control_file.writeStreamingAll(control_io, seq) catch {};
        unlockControl();
        _ = keepalive_ticks.fetchAdd(1, .monotonic);
    }
}

/// Shows an indeterminate progress bar (OSC 9;4;3) and starts the keep-alive.
pub fn progressStart(writer: *std.Io.Writer) void {
    if (!control_enabled) return;
    lockControl();
    if (progress_active) {
        keepalive_paused.store(false, .release);
        writeControlUnlocked(writer, progress_running);
        unlockControl();
        return;
    }
    progress_active = true;
    keepalive_paused.store(false, .release);
    writeControlUnlocked(writer, progress_running);
    unlockControl();

    if (!keepalive_enabled or keepalive_thread != null) return;
    keepalive_stop.store(false, .release);
    keepalive_thread = std.Thread.spawn(.{}, keepAlive, .{}) catch null;
}

/// Pauses the progress bar while waiting for the user (OSC 9;4;4).
pub fn progressPause(writer: *std.Io.Writer) void {
    if (!control_enabled or !progress_active) return;
    lockControl();
    defer unlockControl();
    if (!progress_active or keepalive_paused.load(.acquire)) return;
    keepalive_paused.store(true, .release);
    writeControlUnlocked(writer, progress_paused);
}

/// Resumes a paused progress bar (OSC 9;4;3).
pub fn progressResume(writer: *std.Io.Writer) void {
    if (!control_enabled or !progress_active) return;
    lockControl();
    defer unlockControl();
    if (!progress_active or !keepalive_paused.load(.acquire)) return;
    keepalive_paused.store(false, .release);
    writeControlUnlocked(writer, progress_running);
}

/// Clears the progress bar (OSC 9;4;0) and stops the keep-alive.
pub fn progressStop(writer: *std.Io.Writer) void {
    if (!progress_active) return;
    lockControl();
    progress_active = false;
    keepalive_stop.store(true, .release);
    unlockControl();

    if (keepalive_thread) |thread| {
        thread.join();
        keepalive_thread = null;
    }
    if (control_enabled) writeControl(writer, progress_clear);
}

/// Writes an OSC 2 window title. The caller must ensure that terminal control
/// is enabled; focus detection only runs in that case.
pub fn writeTitle(writer: *std.Io.Writer, title: []const u8) void {
    std.debug.assert(title.len > 0);
    lockControl();
    defer unlockControl();
    writer.writeAll("\x1b]2;") catch return;
    writer.writeAll(title) catch return;
    writer.writeAll("\x1b\\") catch return;
    writer.flush() catch {};
}

/// Emits a desktop notification (OSC 9) and rings the bell so the user looks
/// at the terminal when input is needed or the run ends.
pub fn notify(writer: *std.Io.Writer, msg: []const u8) void {
    if (!control_enabled) return;
    std.debug.assert(msg.len > 0);
    lockControl();
    defer unlockControl();
    writer.writeAll("\x1b]9;") catch return;
    writer.writeAll(msg) catch return;
    writer.writeAll("\x1b\\\x07") catch return;
    writer.flush() catch {};
}

/// ANSI foreground color escape sequences and reset codes.
pub const Red = "\x1b[31m";
pub const Green = "\x1b[32m";
pub const Yellow = "\x1b[33m";
pub const Blue = "\x1b[34m";
pub const Cyan = "\x1b[36m";
pub const Reset = "\x1b[0m";

test "printTo writes exact bytes" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printTo(&writer, "hello {d} {s}", .{ 42, "world" });
    try std.testing.expectEqualStrings("hello 42 world", buf[0..14]);
}

test "style honors the per-stream flags" {
    color_enabled = false;
    err_color_enabled = false;
    defer {
        color_enabled = true;
        err_color_enabled = true;
    }
    try std.testing.expectEqualStrings("", style(Red));
    try std.testing.expectEqualStrings("", style(Reset));
    try std.testing.expectEqualStrings("", styleErr(Red));
    try std.testing.expectEqualStrings("", styleErr(Reset));

    color_enabled = true;
    try std.testing.expectEqualStrings(Red, style(Red));
    try std.testing.expectEqualStrings("", styleErr(Red));

    err_color_enabled = true;
    try std.testing.expectEqualStrings(Red, styleErr(Red));
}

test "colorSupported honors NO_COLOR and TERM" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expect(colorAllowedByEnv(&environ));

    try environ.put("NO_COLOR", "1");
    try std.testing.expect(!colorAllowedByEnv(&environ));
    try environ.put("NO_COLOR", "");
    try std.testing.expect(colorAllowedByEnv(&environ));

    try environ.put("TERM", "dumb");
    try std.testing.expect(!colorAllowedByEnv(&environ));
    try environ.put("TERM", "xterm-256color");
    try std.testing.expect(colorAllowedByEnv(&environ));

    // The terminal probe depends on the real streams; just exercise it.
    _ = colorSupported(std.testing.io, &environ, std.Io.File.stdout());
    _ = colorSupported(std.testing.io, &environ, std.Io.File.stderr());
}

test "noColorRequested scans every argument" {
    try std.testing.expect(!noColorRequested(&.{"zix"}));
    try std.testing.expect(noColorRequested(&.{ "zix", "-y", "--no-color" }));
    try std.testing.expect(noColorRequested(&.{ "zix", "--no-color=1" }));
}

test "progress sequences follow the lifecycle" {
    control_enabled = true;
    keepalive_enabled = false;
    progress_active = false;
    defer {
        control_enabled = false;
        progress_active = false;
    }

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressStart(&writer);
    progressPause(&writer);
    progressResume(&writer);
    progressStop(&writer);
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;4;3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;4;4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;4;0") != null);
}

test "progressStart while active refreshes without a second thread" {
    control_enabled = true;
    keepalive_enabled = false;
    progress_active = false;
    defer {
        control_enabled = false;
        progress_active = false;
    }

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressStart(&writer);
    const first = writer.end;
    progressStart(&writer);
    try std.testing.expect(writer.end > first);
    progressStop(&writer);
}

test "progress pause and resume are no-ops outside their state" {
    control_enabled = true;
    keepalive_enabled = false;
    progress_active = false;
    defer {
        control_enabled = false;
        progress_active = false;
    }

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressPause(&writer);
    progressResume(&writer);
    try std.testing.expectEqual(@as(usize, 0), writer.end);

    progressStart(&writer);
    const after_start = writer.end;
    progressResume(&writer);
    try std.testing.expectEqual(after_start, writer.end);

    progressPause(&writer);
    const after_pause = writer.end;
    progressPause(&writer);
    try std.testing.expectEqual(after_pause, writer.end);

    progressStop(&writer);
    const after_stop = writer.end;
    progressStop(&writer);
    try std.testing.expectEqual(after_stop, writer.end);
}

test "terminal control is silent when disabled" {
    control_enabled = false;
    progress_active = false;
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressStart(&writer);
    progressPause(&writer);
    progressResume(&writer);
    progressStop(&writer);
    notify(&writer, "zix: none");
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "notify writes an OSC 9 notification and a bell" {
    control_enabled = true;
    defer control_enabled = false;

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    notify(&writer, "zix: done");
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]9;zix: done\x1b\\") != null);
    try std.testing.expectEqual(@as(u8, '\x07'), out[out.len - 1]);
}

test "progress keep-alive refreshes the state" {
    control_enabled = true;
    keepalive_enabled = true;
    keepalive_interval_ms = 10;
    progress_active = false;
    control_io = std.testing.io;
    const devnull = try std.Io.Dir.cwd().openFile(std.testing.io, "/dev/null", .{ .mode = .write_only });
    control_file = devnull;
    keepalive_ticks.store(0, .release);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    progressStart(&writer);
    defer {
        progressStop(&writer);
        devnull.close(std.testing.io);
        control_enabled = false;
        keepalive_enabled = false;
        keepalive_interval_ms = 500;
        progress_active = false;
        control_file = undefined;
        control_io = undefined;
    }

    // Give the keep-alive thread time to refresh once.
    var no_fds: [0]std.posix.pollfd = .{};
    _ = std.posix.poll(&no_fds, 30) catch {};
    try std.testing.expect(keepalive_ticks.load(.acquire) > 0);
}

test "controlSupported honors TERM=dumb" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("TERM", "dumb");
    try std.testing.expect(!controlSupported(std.testing.io, &environ));
    try environ.put("TERM", "xterm-256color");
    // The TTY half depends on the real stdout; just exercise it.
    _ = controlSupported(std.testing.io, &environ);
}

test "style constants are non-empty" {
    for ([_][]const u8{ Red, Green, Yellow, Blue, Cyan, Reset }) |code| {
        try std.testing.expect(code.len > 0);
    }
}
