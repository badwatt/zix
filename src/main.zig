const std = @import("std");
const app = @import("app/init.zig");
const cli = @import("app/cli.zig");
const ui = @import("core/ui.zig");
const process = @import("core/process.zig");
const StaticAllocator = @import("core/static_allocator.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Arena allocator: all allocation happens during init only.
    // StaticAllocator blocks alloc/free after transition to .static.
    // arena.deinit() frees everything at shutdown — after execute() returns.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var static_allocator = StaticAllocator.init(arena.allocator());

    const allocator = static_allocator.allocator();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    for (init.minimal.args.vector) |arg_z| {
        try args_list.append(allocator, std.mem.sliceTo(arg_z, 0));
    }
    // Must have at least the program name.
    std.debug.assert(args_list.items.len >= 1);

    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    // Dependency injection: all side effects go through Deps for testability.
    const deps = cli.Deps{
        .run = process.run,
        .confirm = ui.confirm,
        .printTitle = ui.printTitle,
        .configPrint = ui.configPrint,
    };

    try app.run(
        io,
        &stdout_writer.interface,
        args_list.items,
        deps,
        &static_allocator,
    );

    // Transition from static to deinit only if run() reached static phase.
    // Early returns (help, version, errors) never transition to static.
    static_allocator.transition_from_static_to_deinit_if_static();
}

test {
    _ = @import("app/init.zig");
    _ = @import("app/config.zig");
    _ = @import("app/cli.zig");
    _ = @import("core/io.zig");
    _ = @import("core/commands.zig");
    _ = @import("core/ui.zig");
    _ = @import("core/process.zig");
    _ = @import("core/static_allocator.zig");
    _ = @import("zon");
}
