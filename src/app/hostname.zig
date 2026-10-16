//! Hostname resolution: `/proc` → `$HOSTNAME` → `gethostname` → "unknown".

const std = @import("std");

/// Linux procfs hostname path.
pub const proc_path = "/proc/sys/kernel/hostname";

/// Chooses the first non-empty candidate, falling back to `"unknown"`.
pub fn choose(proc: ?[]const u8, env: ?[]const u8, cmd: []const u8) []const u8 {
    if (proc) |h| {
        if (h.len > 0) return h;
    }
    if (env) |h| {
        if (h.len > 0) return h;
    }
    if (cmd.len > 0) return cmd;
    return "unknown";
}

/// Resolves the hostname from the real environment.
pub fn resolve(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    gethostname_buf: *[std.posix.HOST_NAME_MAX]u8,
) []const u8 {
    const proc = readFileOrNull(io, allocator, proc_path);
    const env = environ.get("HOSTNAME");
    // `catch ""` keeps this branchless; `choose` treats empty as missing.
    const cmd = std.posix.gethostname(gethostname_buf) catch "";
    return choose(proc, env, cmd);
}

/// Reads a small file and trims it; returns null on error or empty content.
///
/// Reads through a `File.Reader` instead of `readFileAlloc`, which returns an
/// empty slice for procfs files (they report size 0).
fn readFileOrNull(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var read_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var total: usize = 0;
    while (total < out.len) {
        const n = reader.interface.readSliceShort(out[total..]) catch return null;
        if (n == 0) break;
        total += n;
    }
    const trimmed = std.mem.trim(u8, out[0..total], " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

// --- Tests ---

test "choose prefers non-empty candidates in order" {
    try std.testing.expectEqualStrings("proc", choose("proc", "env", "cmd"));
    try std.testing.expectEqualStrings("env", choose(null, "env", "cmd"));
    try std.testing.expectEqualStrings("env", choose("", "env", "cmd"));
    try std.testing.expectEqualStrings("cmd", choose(null, null, "cmd"));
    try std.testing.expectEqualStrings("cmd", choose(null, "", "cmd"));
    try std.testing.expectEqualStrings("unknown", choose(null, null, ""));
}

test "readFileOrNull reads, rejects empty, and rejects missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    // Non-empty file.
    const hostname = readFileOrNull(io, arena.allocator(), proc_path);
    try std.testing.expect(hostname != null);
    try std.testing.expect(hostname.?.len > 0);

    // Existing but empty file.
    try std.testing.expect(readFileOrNull(io, arena.allocator(), "/dev/null") == null);

    // Missing file.
    try std.testing.expect(readFileOrNull(io, arena.allocator(), "/nonexistent_zix_host") == null);
}

test "resolve produces a non-empty hostname" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(arena.allocator());
    defer environ.deinit();

    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = resolve(std.testing.io, arena.allocator(), &environ, &buf);
    try std.testing.expect(hostname.len > 0);
}
