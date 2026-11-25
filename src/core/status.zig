//! OSC 7501 Program Status Protocol reports.
//!
//! Terminals that implement the protocol can badge the tab with what zix is
//! doing: working, blocked on a prompt or sudo, done, idle or failed. The
//! message is base64-encoded UTF-8, sanitized and capped so one bad report
//! cannot take the state update down.

const std = @import("std");

/// Program states understood by OSC 7501.
pub const State = enum {
    idle,
    working,
    blocked_permission,
    blocked_auth,
    done,
    failed,
};

/// Longest message sent. The protocol drops reports with oversized fields.
pub const max_message = 512;

/// Base64 of 512 bytes is 684 bytes; leave headroom for the envelope.
const encoded_max = 1024;

fn stateName(state: State) []const u8 {
    return switch (state) {
        .idle => "idle",
        .working => "working",
        .blocked_permission, .blocked_auth => "blocked",
        .done => "done",
        .failed => "error",
    };
}

fn stateKind(state: State) ?[]const u8 {
    return switch (state) {
        .blocked_permission => "permission",
        .blocked_auth => "auth",
        else => null,
    };
}

/// Writes one OSC 7501 report and flushes. Control characters in `msg` are
/// replaced by spaces; the UTF-8 bytes are base64-encoded.
pub fn report(writer: *std.Io.Writer, state: State, msg: []const u8) !void {
    var clean: [max_message]u8 = undefined;
    var clean_len: usize = 0;
    for (msg) |c| {
        if (clean_len == clean.len) break;
        clean[clean_len] = if (c < 0x20 or c == 0x7f) ' ' else c;
        clean_len += 1;
    }

    var encoded_buf: [encoded_max]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buf, clean[0..clean_len]);

    try writer.writeAll("\x1b]7501;state=");
    try writer.writeAll(stateName(state));
    if (stateKind(state)) |kind| {
        try writer.writeAll(":kind=");
        try writer.writeAll(kind);
    }
    try writer.writeAll(":app=zix:msg=");
    try writer.writeAll(encoded);
    try writer.writeAll("\x1b\\");
    try writer.flush();
}

// --- Tests ---

fn expectReport(state: State, msg: []const u8, expected: []const u8) !void {
    var buf: [encoded_max + 128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try report(&writer, state, msg);
    try std.testing.expectEqualStrings(expected, buf[0..writer.end]);
}

test "working report has the exact envelope" {
    try expectReport(
        .working,
        "Working",
        "\x1b]7501;state=working:app=zix:msg=V29ya2luZw==\x1b\\",
    );
}

test "blocked reports carry the kind" {
    try expectReport(
        .blocked_permission,
        "",
        "\x1b]7501;state=blocked:kind=permission:app=zix:msg=\x1b\\",
    );
    try expectReport(
        .blocked_auth,
        "",
        "\x1b]7501;state=blocked:kind=auth:app=zix:msg=\x1b\\",
    );
}

test "idle done and failed names" {
    try expectReport(.idle, "ok", "\x1b]7501;state=idle:app=zix:msg=b2s=\x1b\\");
    try expectReport(.done, "ok", "\x1b]7501;state=done:app=zix:msg=b2s=\x1b\\");
    try expectReport(.failed, "boom", "\x1b]7501;state=error:app=zix:msg=Ym9vbQ==\x1b\\");
}

test "UTF-8 is encoded as bytes" {
    try expectReport(
        .done,
        "ñ€",
        "\x1b]7501;state=done:app=zix:msg=w7Higqw=\x1b\\",
    );
}

test "control characters become spaces" {
    try expectReport(
        .done,
        "a\nb\tc",
        "\x1b]7501;state=done:app=zix:msg=YSBiIGM=\x1b\\",
    );
}

test "message is capped" {
    var long: [2000]u8 = undefined;
    @memset(&long, 'x');
    var buf: [encoded_max + 128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try report(&writer, .done, &long);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..writer.end], "\x1b\\"));
    try std.testing.expect(writer.end < encoded_max);
}
