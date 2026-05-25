const std = @import("std");

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

        const root = parsed.value.object;
        const pct_str = root.get("percent_covered").?.string;
        const pct = std.fmt.parseFloat(f64, pct_str) catch 0.0;
        const covered = root.get("covered_lines").?.integer;
        const total = root.get("total_lines").?.integer;

        std.debug.print("{d:.1}% ({d}/{d} lines)\n", .{ pct, covered, total });
        return;
    }

    std.debug.print("No coverage data found\n", .{});
    std.process.exit(1);
}