//! Static HTTP file server for Zig autodoc.
//!
//! Serves files from a directory over HTTP/1.1 with `Connection: close`.
//! Supports WASM, JS, HTML, JSON, CSS, SVG, and TAR content types.
//! Designed to be built and run as part of `zig build docs:serve`.

const std = @import("std");
const Io = std.Io;

/// Listens on localhost:8000 and serves files from the directory given as
/// the first argument. Defaults to current directory if no argument.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;

    const port: u16 = 8000;
    const serve_dir = if (args.vector.len > 1) std.mem.sliceTo(args.vector[1], 0) else ".";

    // Bind to loopback only: this is a local documentation server.
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch {
        std.debug.print("invalid port\n", .{});
        std.process.exit(1);
    };
    var server = Io.net.IpAddress.listen(&address, io, .{}) catch |err| {
        std.debug.print("failed to listen on port {d}: {s}\n", .{ port, @errorName(err) });
        std.process.exit(1);
    };

    std.debug.print("serving {s} at http://localhost:{d}\n", .{ serve_dir, port });

    while (true) {
        const stream = server.accept(io) catch continue;
        handleClient(io, init.gpa, stream, serve_dir) catch continue;
    }
}

/// Reads one HTTP request, resolves the path to a file in `serve_dir`,
/// and writes the response with appropriate `Content-Type` and
/// `Connection: close` headers.
fn handleClient(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream, serve_dir: []const u8) !void {
    var rbuf: [8192]u8 = undefined;
    var net_reader = stream.reader(io, &rbuf);
    var reader = &net_reader.interface;

    // Read request headers
    while (true) {
        reader.fillMore() catch break;
        const data = reader.buffer[0..reader.end];
        if (std.mem.indexOf(u8, data, "\r\n\r\n")) |_| break;
    }

    const request = reader.buffer[reader.seek..reader.end];

    // Parse path from request line: "GET /path HTTP/1.1"
    var path_start: usize = 0;
    var path_end: usize = 0;
    for (request, 0..) |c, i| {
        if (c == ' ' and path_start == 0 and i >= 3) {
            path_start = i + 1;
        } else if (c == ' ' and path_start > 0 and path_end == 0) {
            path_end = i;
            break;
        }
    }
    if (path_start == 0 or path_end == 0) return;
    const raw_path = request[path_start..path_end];

    var path_buf: [4096]u8 = undefined;
    const path = resolvePath(raw_path, &path_buf) orelse {
        respond(io, stream, "403 Forbidden", "403 Forbidden");
        return;
    };

    const file_path = path[1..]; // strip leading /

    var full_path_buf: [4096]u8 = undefined;
    const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ serve_dir, file_path }) catch return;

    const cwd = Io.Dir.cwd();
    const contents = cwd.readFileAlloc(io, full_path, allocator, .limited(1 << 25)) catch {
        respond(io, stream, "404 Not Found", "404 Not Found");
        return;
    };
    defer allocator.free(contents);

    var wbuf: [4096]u8 = undefined;
    var net_writer = stream.writer(io, &wbuf);
    writeResponse(&net_writer.interface, "200 OK", contentType(file_path), contents) catch return;
    net_writer.interface.flush() catch return;
}

/// Maps a raw request path to a file path. Directory paths get `index.html`
/// appended; returns null when any segment is `..` (path traversal).
fn resolvePath(raw_path: []const u8, buf: []u8) ?[]const u8 {
    const path = if (raw_path.len == 0) "/" else raw_path;
    if (isForbidden(path)) return null;
    if (path[path.len - 1] == '/') {
        return std.fmt.bufPrint(buf, "{s}index.html", .{path}) catch null;
    }
    return path;
}

/// True when `path` contains a `..` segment.
fn isForbidden(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

/// Returns the `Content-Type` for a file name based on its extension.
fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".tar")) return "application/x-tar";
    return "application/octet-stream";
}

/// Writes a complete HTTP/1.1 response. `Content-Length` is derived from
/// `body`, so headers and payload can never disagree.
fn writeResponse(
    writer: *Io.Writer,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    try writer.print(
        "HTTP/1.1 {s}\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: {s}\r\n\r\n",
        .{ status, body.len, content_type },
    );
    try writer.writeAll(body);
}

/// Sends a plain-text HTTP response in one write.
fn respond(io: Io, stream: Io.net.Stream, status: []const u8, body: []const u8) void {
    var wbuf: [512]u8 = undefined;
    var net_writer = stream.writer(io, &wbuf);
    writeResponse(&net_writer.interface, status, "text/plain", body) catch return;
    net_writer.interface.flush() catch return;
}

// --- Tests ---

test "resolvePath appends index.html to directory paths" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/index.html", resolvePath("/", &buf).?);
    try std.testing.expectEqualStrings("/index.html", resolvePath("", &buf).?);
    try std.testing.expectEqualStrings("/sub/index.html", resolvePath("/sub/", &buf).?);
}

test "resolvePath keeps file paths" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/index.html", resolvePath("/index.html", &buf).?);
    try std.testing.expectEqualStrings("/a/b.js", resolvePath("/a/b.js", &buf).?);
}

test "resolvePath rejects traversal segments" {
    var buf: [128]u8 = undefined;
    try std.testing.expect(resolvePath("/../etc/passwd", &buf) == null);
    try std.testing.expect(resolvePath("/a/../b", &buf) == null);
    try std.testing.expect(resolvePath("/..", &buf) == null);
    try std.testing.expect(resolvePath("/..hidden/file", &buf) != null);
}

test "contentType maps extensions" {
    try std.testing.expectEqualStrings("text/html", contentType("a.html"));
    try std.testing.expectEqualStrings("application/javascript", contentType("a.js"));
    try std.testing.expectEqualStrings("application/wasm", contentType("a.wasm"));
    try std.testing.expectEqualStrings("text/css", contentType("a.css"));
    try std.testing.expectEqualStrings("application/json", contentType("a.json"));
    try std.testing.expectEqualStrings("image/svg+xml", contentType("a.svg"));
    try std.testing.expectEqualStrings("application/x-tar", contentType("a.tar"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("a.bin"));
}

test "writeResponse derives Content-Length from the body" {
    var buf: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    try writeResponse(&writer, "403 Forbidden", "text/plain", "403 Forbidden");
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 13\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n403 Forbidden"));
}
