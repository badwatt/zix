//! Coverage report parser for kcov JSON output.
//!
//! Walks the coverage directory, finds coverage.json, and prints
//! a summary line: `{percent}% ({covered}/{total} lines)`.
//! Designed to be built and run as part of `zig build coverage`.

const std = @import("std");

/// Numeric summary extracted from a kcov `coverage.json` document.
const Summary = struct {
    percent: f64,
    covered: i64,
    total: i64,
};

/// Entry point. Reads kcov output directory, parses coverage.json,
/// and prints percentage summary. Exits 1 if no data found.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = init.minimal.args;

    if (args.vector.len < 2) {
        std.debug.print("usage: coverage-report <coverage-dir>\n", .{});
        std.process.exit(1);
    }
    const coverage_dir = std.mem.sliceTo(args.vector[1], 0);

    const cwd = std.Io.Dir.cwd();

    const dir = cwd.openDir(io, coverage_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No coverage data found\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, "coverage.json")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ coverage_dir, entry.path });
        defer allocator.free(path);

        const contents = cwd.readFileAlloc(io, path, allocator, .limited(1 << 20)) catch continue;
        defer allocator.free(contents);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch continue;
        defer parsed.deinit();

        const summary = summarize(parsed.value) orelse continue;
        std.debug.print("{d:.1}% ({d}/{d} lines)\n", .{
            summary.percent,
            summary.covered,
            summary.total,
        });
        return;
    }

    std.debug.print("No coverage data found\n", .{});
    std.process.exit(1);
}

/// Extracts the summary fields from a parsed `coverage.json` value. Returns
/// null when the document is not an object or a required field is missing or
/// has the wrong JSON type.
fn summarize(value: std.json.Value) ?Summary {
    const root = switch (value) {
        .object => |object| object,
        else => return null,
    };

    const percent = switch (root.get("percent_covered") orelse return null) {
        .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    const covered = switch (root.get("covered_lines") orelse return null) {
        .integer => |number| number,
        else => return null,
    };
    const total = switch (root.get("total_lines") orelse return null) {
        .integer => |number| number,
        else => return null,
    };

    return .{ .percent = percent, .covered = covered, .total = total };
}

// --- Tests ---

fn summarizeJson(document: []const u8) ?Summary {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        document,
        .{},
    ) catch return null;
    defer parsed.deinit();
    return summarize(parsed.value);
}

test "summarize parses a kcov summary" {
    const summary = summarizeJson(
        "{\"percent_covered\":\"99.5\",\"covered_lines\":199,\"total_lines\":200}",
    ).?;
    try std.testing.expectEqual(@as(f64, 99.5), summary.percent);
    try std.testing.expectEqual(@as(i64, 199), summary.covered);
    try std.testing.expectEqual(@as(i64, 200), summary.total);
}

test "summarize rejects malformed documents" {
    const cases = [_][]const u8{
        "[]",
        "{}",
        "{\"percent_covered\":1,\"covered_lines\":1,\"total_lines\":1}",
        "{\"percent_covered\":\"nope\",\"covered_lines\":1,\"total_lines\":1}",
        "{\"percent_covered\":\"1\",\"total_lines\":1}",
        "{\"percent_covered\":\"1\",\"covered_lines\":1}",
        "{\"percent_covered\":\"1\",\"covered_lines\":\"1\",\"total_lines\":1}",
        "{\"percent_covered\":\"1\",\"covered_lines\":1,\"total_lines\":\"1\"}",
        "not json",
    };
    for (cases) |document| {
        try std.testing.expect(summarizeJson(document) == null);
    }
}
