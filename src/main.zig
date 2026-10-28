//! Entry point for zix, a NixOS system update CLI.
//!
//! Initializes the allocator system, builds the real dependency ports, parses
//! CLI arguments (inside `app.run`), and maps workflow errors to exit codes.
//! A two-phase `StaticAllocator` guards the init-time allocations; runtime
//! command captures use the general-purpose allocator as scratch memory.

const std = @import("std");
const app = @import("app/init.zig");
const cli = @import("app/cli.zig");
const ui = @import("core/ui.zig");
const io_mod = @import("core/io.zig");
const process = @import("core/process.zig");
const StaticAllocator = @import("core/static_allocator.zig");

/// Application entry point. Sets up the arena + static allocator, collects
/// args, wires dependency injection, runs app logic, and returns the process
/// exit code (2 for invalid usage, 1 otherwise).
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena;
    const args = init.minimal.args;

    // StaticAllocator wraps the process arena and blocks allocation after the
    // workflow starts. Runtime captures use `init.gpa` (see Deps.allocator);
    // the arena is cleaned up automatically on process exit.
    var static_allocator = StaticAllocator.init(arena.allocator());
    const allocator = static_allocator.allocator();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    for (args.vector) |arg_z| {
        try args_list.append(allocator, std.mem.sliceTo(arg_z, 0));
    }
    // Must have at least the program name.
    std.debug.assert(args_list.items.len >= 1);

    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    // Diagnostics go to stderr; colors only when the terminal supports them.
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    io_mod.color_enabled = io_mod.colorSupported(io, init.environ_map) and
        !io_mod.noColorRequested(args_list.items);

    // Dependency injection: command execution, user I/O, scratch allocator,
    // and environment all flow through Deps for testability.
    const deps = cli.Deps{
        .allocator = init.gpa,
        .runner = process.real,
        .ui = ui.terminal,
        .err_writer = &stderr_writer.interface,
        .environ = init.environ_map,
    };

    app.run(io, &stdout_writer.interface, args_list.items, deps, &static_allocator) catch |err| {
        // A closed stdout (e.g. `zix | head`) is a normal way to stop; report
        // it the way a SIGPIPE'd process would instead of an "unexpected error".
        if (err == error.WriteFailed) return 141;

        // Use the same stderr writer as the workflow: mixing it with
        // `std.debug.print` corrupts the stream when stderr is a file.
        var err_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "Error: {s}", .{cli.errorMessage(err)}) catch
            cli.errorMessage(err);
        ui.printError(&stderr_writer.interface, msg) catch {};
        return cli.exitCode(err);
    };

    // Transition from static to deinit only if run() reached the static phase.
    // Early returns (help, version, errors) never transition to static.
    static_allocator.transition_from_static_to_deinit_if_static();
    return 0;
}

// Root test block — imports all module tests for `zig build test`.
test {
    _ = @import("app/init.zig");
    _ = @import("app/config.zig");
    _ = @import("app/hostname.zig");
    _ = @import("app/completions.zig");
    _ = @import("app/cli.zig");
    _ = @import("core/io.zig");
    _ = @import("core/commands.zig");
    _ = @import("core/ui.zig");
    _ = @import("core/process.zig");
    _ = @import("core/dry_run.zig");
    _ = @import("core/static_allocator.zig");
    _ = @import("zon");
}
