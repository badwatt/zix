const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;

    const port: u16 = 8000;
    const serve_dir = if (args.vector.len > 1) std.mem.sliceTo(args.vector[1], 0) else ".";

    const address = Io.net.IpAddress.parseIp4("0.0.0.0", port) catch {
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
        handleClient(io, stream, serve_dir) catch continue;
    }
}

fn handleClient(io: Io, stream: Io.net.Stream, serve_dir: []const u8) !void {
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

    // Parse path from request line
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

    // Default to index.html
    const path = if (std.mem.endsWith(u8, raw_path, "/") or std.mem.endsWith(u8, raw_path, "/.."))
        "/index.html"
    else
        raw_path;

    if (std.mem.containsAtLeast(u8, path, 1, "../")) {
        respond(io, stream, "HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 15\r\n\r\n403 Forbidden");
        return;
    }

    const file_path = path[1..]; // strip leading /

    var path_buf: [4096]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ serve_dir, file_path }) catch return;

    const content_type = ct: {
        if (std.mem.endsWith(u8, file_path, ".html")) break :ct "text/html";
        if (std.mem.endsWith(u8, file_path, ".js")) break :ct "application/javascript";
        if (std.mem.endsWith(u8, file_path, ".wasm")) break :ct "application/wasm";
        if (std.mem.endsWith(u8, file_path, ".css")) break :ct "text/css";
        if (std.mem.endsWith(u8, file_path, ".json")) break :ct "application/json";
        if (std.mem.endsWith(u8, file_path, ".svg")) break :ct "image/svg+xml";
        if (std.mem.endsWith(u8, file_path, ".tar")) break :ct "application/x-tar";
        break :ct "application/octet-stream";
    };

    var gpa_buf: [1 << 25]u8 = undefined;
    var gpa_fixed = std.heap.FixedBufferAllocator.init(&gpa_buf);
    const allocator = gpa_fixed.allocator();

    const cwd = Io.Dir.cwd();
    const contents = cwd.readFileAlloc(io, full_path, allocator, .limited(1 << 25)) catch {
        respond(io, stream, "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 13\r\n\r\n404 Not Found");
        return;
    };

    var wbuf: [4096]u8 = undefined;
    var net_writer = stream.writer(io, &wbuf);
    var writer = &net_writer.interface;
    writer.print(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: {s}\r\n\r\n",
        .{ contents.len, content_type },
    ) catch return;
    writer.writeAll(contents) catch return;
    writer.flush() catch return;
}

fn respond(io: Io, stream: Io.net.Stream, msg: []const u8) void {
    var wbuf: [512]u8 = undefined;
    var net_writer = stream.writer(io, &wbuf);
    var writer = &net_writer.interface;
    writer.writeAll(msg) catch return;
    writer.flush() catch return;
}