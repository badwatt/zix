//! Best-effort terminal focus detection via the compositor IPC.
//!
//! Notifications are only useful when the user is looking at another window.
//! Comparing only the app id is not enough: several terminal windows share it.
//! On the first check zix writes a unique title, finds that window in the
//! compositor's window list, and caches its id/address. Later checks compare
//! the focused window against that id.
//!
//! Unknown compositors, unknown terminals and query failures are treated as
//! "focused", so zix stays quiet instead of notifying spuriously.

const std = @import("std");
const process = @import("process.zig");

const Kind = enum { niri, hyprland };

var kind: Kind = .niri;
var tracked_id: ?u64 = null;
var tracked_address: ?[64]u8 = null;
var tracked_address_len: usize = 0;
var tracked_attempted: bool = false;
var title_buf: [96]u8 = undefined;
var title_len: usize = 0;
var title_counter: u32 = 0;

const NiriWindow = struct { id: u64, title: []const u8 };
const NiriFocus = struct { id: u64 };
const HyprWindow = struct { address: []const u8, title: []const u8 };
const HyprFocus = struct { address: []const u8 };

/// Returns true when the terminal running zix appears to be the focused
/// window. Unknown compositors and query failures are treated as focused.
pub fn isTerminalFocused(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    runner: process.Runner,
    writer: *std.Io.Writer,
) bool {
    const k = compositor(environ) orelse return true;
    kind = k;
    if (!tracked_attempted) {
        tracked_attempted = true;
        track(io, allocator, runner, writer);
    }

    return switch (k) {
        .niri => if (tracked_id) |id| focusedNiri(io, allocator, runner, id) else fallback(io, allocator, environ, runner),
        .hyprland => if (tracked_address) |address| focusedHypr(io, allocator, runner, address[0..tracked_address_len]) else fallback(io, allocator, environ, runner),
    };
}

/// Compositor for the current environment, or null when unsupported.
fn compositor(environ: *std.process.Environ.Map) ?Kind {
    if (environ.get("NIRI_SOCKET") != null) return .niri;
    if (environ.get("HYPRLAND_INSTANCE_SIGNATURE") != null) return .hyprland;
    return null;
}

/// Writes an OSC 2 window title and flushes.
fn writeTitle(writer: *std.Io.Writer, title: []const u8) void {
    writer.writeAll("\x1b]2;") catch return;
    writer.writeAll(title) catch return;
    writer.writeAll("\x1b\\") catch return;
    writer.flush() catch {};
}

/// Sets a unique title, finds the matching compositor window and caches its
/// identity. Falls back to the app-id heuristic if the window cannot be found.
fn track(
    io: std.Io,
    allocator: std.mem.Allocator,
    runner: process.Runner,
    writer: *std.Io.Writer,
) void {
    title_counter +%= 1;
    const nonce = std.fmt.bufPrint(
        &title_buf,
        "zix-{d}-{d}",
        .{ std.os.linux.getpid(), title_counter },
    ) catch return;
    title_len = nonce.len;
    writeTitle(writer, nonce);

    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        const found = switch (kind) {
            .niri => blk: {
                const id = findNiriWindow(io, allocator, runner, nonce) orelse break :blk false;
                tracked_id = id;
                break :blk true;
            },
            .hyprland => findHyprWindow(io, allocator, runner, nonce),
        };
        if (found) break;
        var no_fds: [0]std.posix.pollfd = .{};
        _ = std.posix.poll(&no_fds, 5) catch {};
    }

    // The shell prompt sets the real title again after zix exits.
    writeTitle(writer, "zix");
}

fn findNiriWindow(
    io: std.Io,
    allocator: std.mem.Allocator,
    runner: process.Runner,
    nonce: []const u8,
) ?u64 {
    const result = runner.capture(io, allocator, &.{ "niri", "msg", "-j", "windows" }) catch return null;
    defer result.deinit(allocator);
    if (result.code != 0) return null;

    const parsed = std.json.parseFromSlice([]const NiriWindow, allocator, result.stdout, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    for (parsed.value) |window| {
        if (std.mem.eql(u8, window.title, nonce)) return window.id;
    }
    return null;
}

fn findHyprWindow(
    io: std.Io,
    allocator: std.mem.Allocator,
    runner: process.Runner,
    nonce: []const u8,
) bool {
    const result = runner.capture(io, allocator, &.{ "hyprctl", "clients", "-j" }) catch return false;
    defer result.deinit(allocator);
    if (result.code != 0) return false;

    const parsed = std.json.parseFromSlice([]const HyprWindow, allocator, result.stdout, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    for (parsed.value) |window| {
        if (!std.mem.eql(u8, window.title, nonce)) continue;
        const len = @min(window.address.len, tracked_address_buffer_len);
        @memcpy(tracked_address_buf[0..len], window.address[0..len]);
        tracked_address_len = len;
        tracked_address = tracked_address_buf;
        return true;
    }
    return false;
}

var tracked_address_buf: [64]u8 = undefined;
const tracked_address_buffer_len = tracked_address_buf.len;

fn focusedNiri(io: std.Io, allocator: std.mem.Allocator, runner: process.Runner, id: u64) bool {
    const result = runner.capture(io, allocator, &.{ "niri", "msg", "-j", "focused-window" }) catch return true;
    defer result.deinit(allocator);
    if (result.code != 0) return true;

    const parsed = std.json.parseFromSlice(NiriFocus, allocator, result.stdout, .{ .ignore_unknown_fields = true }) catch return true;
    defer parsed.deinit();
    return parsed.value.id == id;
}

fn focusedHypr(
    io: std.Io,
    allocator: std.mem.Allocator,
    runner: process.Runner,
    address: []const u8,
) bool {
    const result = runner.capture(io, allocator, &.{ "hyprctl", "activewindow", "-j" }) catch return true;
    defer result.deinit(allocator);
    if (result.code != 0) return true;

    const parsed = std.json.parseFromSlice(HyprFocus, allocator, result.stdout, .{ .ignore_unknown_fields = true }) catch return true;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.address, address);
}

/// Fallback for when the window could not be identified: compare the app id
/// of the focused window with the running terminal.
fn fallback(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    runner: process.Runner,
) bool {
    const argv: []const []const u8 = switch (kind) {
        .niri => &.{ "niri", "msg", "-j", "focused-window" },
        .hyprland => &.{ "hyprctl", "activewindow", "-j" },
    };
    const result = runner.capture(io, allocator, argv) catch return true;
    defer result.deinit(allocator);
    if (result.code != 0) return true;
    return focusedApp(allocator, result.stdout, environ);
}

/// Expected compositor app id for the running terminal, if known.
fn terminalAppId(environ: *std.process.Environ.Map) ?[]const u8 {
    if (environ.get("TERM_PROGRAM")) |program| {
        if (std.ascii.eqlIgnoreCase(program, "ghostty")) return "com.mitchellh.ghostty";
        if (std.ascii.eqlIgnoreCase(program, "iTerm.app")) return "iTerm2";
        if (std.ascii.eqlIgnoreCase(program, "WezTerm")) return "org.wezfurlong.wezterm";
        if (std.ascii.eqlIgnoreCase(program, "vscode")) return "code";
        if (std.ascii.eqlIgnoreCase(program, "Apple_Terminal")) return "com.apple.Terminal";
    }
    if (environ.get("KITTY_WINDOW_ID") != null) return "kitty";
    if (environ.get("WEZTERM_PANE") != null) return "org.wezfurlong.wezterm";
    if (environ.get("ALACRITTY_WINDOW_ID") != null) return "Alacritty";
    return null;
}

fn focusedApp(
    allocator: std.mem.Allocator,
    json: []const u8,
    environ: *std.process.Environ.Map,
) bool {
    const expected = terminalAppId(environ) orelse return true;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return true;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return true,
    };
    const app = object.get("app_id") orelse object.get("class") orelse return true;
    const app_id = switch (app) {
        .string => |value| value,
        else => return true,
    };
    return std.ascii.eqlIgnoreCase(app_id, expected);
}

// --- Tests ---

var mock_focused_id: u64 = 42;
var mock_focused_address: []const u8 = "0xabc";
var mock_error: bool = false;
var mock_windows_empty: bool = false;
var mock_clients_empty: bool = false;

fn mockRun(_: ?*anyopaque, _: std.Io, _: process.Runner.Command) anyerror!i32 {
    return 0;
}

fn mockProbe(_: ?*anyopaque, _: std.Io, _: process.Runner.Command) anyerror!i32 {
    return 0;
}

fn mockCapture(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    argv: process.Runner.Command,
) anyerror!process.Capture {
    if (mock_error) return error.MockError;
    const out = if (hasArg(argv, "windows"))
        if (mock_windows_empty)
            try allocator.dupe(u8, "[]")
        else
            try std.fmt.allocPrint(
                allocator,
                "[{{\"id\":42,\"title\":\"{s}\"}}]",
                .{title_buf[0..title_len]},
            )
    else if (hasArg(argv, "clients"))
        if (mock_clients_empty)
            try allocator.dupe(u8, "[]")
        else
            try std.fmt.allocPrint(
                allocator,
                "[{{\"address\":\"{s}\",\"title\":\"{s}\"}}]",
                .{ mock_focused_address, title_buf[0..title_len] },
            )
    else if (std.mem.eql(u8, argv[0], "niri"))
        try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"app_id\":\"firefox\"}}", .{mock_focused_id})
    else
        try std.fmt.allocPrint(allocator, "{{\"address\":\"{s}\",\"class\":\"firefox\"}}", .{mock_focused_address});
    return .{ .code = 0, .stdout = out, .stderr = try allocator.dupe(u8, &.{}) };
}

fn hasArg(argv: process.Runner.Command, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

const mock_runner = process.Runner{ .runFn = mockRun, .captureFn = mockCapture, .probeFn = mockProbe };

fn testEnv(allocator: std.mem.Allocator) std.process.Environ.Map {
    return std.process.Environ.Map.init(allocator);
}

fn resetTracking() void {
    tracked_id = null;
    tracked_address = null;
    tracked_address_len = 0;
    tracked_attempted = false;
    title_len = 0;
    title_counter = 0;
    kind = .niri;
    mock_error = false;
    mock_focused_id = 42;
    mock_focused_address = "0xabc";
    mock_windows_empty = false;
    mock_clients_empty = false;
}

test "compositor picks the supported environments" {
    _ = try mockRun(null, std.testing.io, &.{"x"});
    _ = try mockProbe(null, std.testing.io, &.{"x"});

    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expect(compositor(&environ) == null);

    try environ.put("NIRI_SOCKET", "/run/user/1000/niri.sock");
    try std.testing.expectEqual(Kind.niri, compositor(&environ).?);

    var hypr = testEnv(std.testing.allocator);
    defer hypr.deinit();
    try hypr.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    try std.testing.expectEqual(Kind.hyprland, compositor(&hypr).?);
}

test "terminalAppId maps known terminals" {
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expect(terminalAppId(&environ) == null);

    try environ.put("TERM_PROGRAM", "ghostty");
    try std.testing.expectEqualStrings("com.mitchellh.ghostty", terminalAppId(&environ).?);
    try environ.put("TERM_PROGRAM", "WezTerm");
    try std.testing.expectEqualStrings("org.wezfurlong.wezterm", terminalAppId(&environ).?);
    try environ.put("TERM_PROGRAM", "");
    try environ.put("KITTY_WINDOW_ID", "1");
    try std.testing.expectEqualStrings("kitty", terminalAppId(&environ).?);
}

test "focusedApp compares the compositor app id" {
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("TERM_PROGRAM", "ghostty");

    try std.testing.expect(focusedApp(
        std.testing.allocator,
        "{\"app_id\":\"com.mitchellh.ghostty\"}",
        &environ,
    ));
    try std.testing.expect(!focusedApp(
        std.testing.allocator,
        "{\"app_id\":\"firefox\"}",
        &environ,
    ));
    try std.testing.expect(focusedApp(
        std.testing.allocator,
        "{\"class\":\"com.mitchellh.ghostty\"}",
        &environ,
    ));
    try std.testing.expect(focusedApp(std.testing.allocator, "not json", &environ));
}

test "niri tracks the exact window and compares its id" {
    resetTracking();
    defer resetTracking();
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("NIRI_SOCKET", "/run/user/1000/niri.sock");
    try environ.put("TERM_PROGRAM", "ghostty");

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner, &writer));
    try std.testing.expectEqual(@as(?u64, 42), tracked_id);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "\x1b]2;zix-") != null);

    mock_focused_id = 7;
    try std.testing.expect(!isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner, &writer));
}

test "hyprland tracks the exact window and compares its address" {
    resetTracking();
    defer resetTracking();
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    try environ.put("TERM_PROGRAM", "ghostty");

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner, &writer));
    try std.testing.expect(tracked_address != null);

    mock_focused_address = "0xdef";
    try std.testing.expect(!isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner, &writer));
}

test "niri falls back to the app id when the window is not found" {
    resetTracking();
    defer resetTracking();
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("NIRI_SOCKET", "/run/user/1000/niri.sock");
    try environ.put("TERM_PROGRAM", "ghostty");

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    mock_windows_empty = true;
    try std.testing.expect(!isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner, &writer));
}

test "hyprland falls back to the app id when the window is not found" {
    resetTracking();
    defer resetTracking();
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    try environ.put("TERM_PROGRAM", "ghostty");

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    mock_clients_empty = true;
    try std.testing.expect(!isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner, &writer));
}

test "focus queries fall back to the app id on errors" {
    resetTracking();
    defer resetTracking();
    var environ = testEnv(std.testing.allocator);
    defer environ.deinit();
    try environ.put("NIRI_SOCKET", "/run/user/1000/niri.sock");
    try environ.put("TERM_PROGRAM", "ghostty");

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    mock_error = true;
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &environ, mock_runner, &writer));

    var plain = testEnv(std.testing.allocator);
    defer plain.deinit();
    try std.testing.expect(isTerminalFocused(std.testing.io, std.testing.allocator, &plain, mock_runner, &writer));
}
