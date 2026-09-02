const std = @import("std");
const fatal = @import("fatal.zig");
const Recipe = @import("Recipe.zig");

comptime {
    _ = @import("Recipe.zig");
}

const Command = enum {
    version,
    wp,
    check,
    help,
    @"-h",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    var verbose = false;

    var args = init.minimal.args.toSlice(arena) catch |err| switch (err) {
        error.OutOfMemory => |oom| fatal.oom(oom),
        error.Unexpected => fatal.fmt("Unexpected error when parsing args", .{}),
    };

    var recipe: Recipe = .init();

    if (args.len == 1) {
        try recipe.loadAndParse(io, arena);
        try recipe.execute(io, arena, verbose);
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "-v")) {
        verbose = true;
        try recipe.loadAndParse(io, arena);
        try recipe.execute(io, arena, verbose);
    }

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        std.debug.print("error: Unknown argument {q}\n", .{args[1]});
        usage();
    };

    switch (cmd) {
        .version => {
            std.debug.print("{s}\n", .{@import("build.zig.zon").version});
            std.process.cleanExit(io);
        },
        .help, .@"-h" => usage(),
        .check => try recipe.loadAndParse(io, arena),
        .wp => {
            args = args[2..]; // stew wp | ...
            if (args.len == 0) fatal.fmt("Expected, 'list' or '<workspace>'", .{});
            try recipe.loadAndParse(io, arena);

            if (std.mem.eql(u8, args[0], "list")) {
                for (recipe.steps.items, 0..) |wp, idx| {
                    if (idx == 0) {
                        std.debug.print(".\n", .{});
                        continue;
                    }

                    const bar = if (idx != recipe.steps.items.len - 1) "├─" else "└─";
                    std.debug.print("{s} {s} (cmds: {d})\n", .{ bar, wp.name, wp.commands.items.len });
                }
            } else {
            }
        },
    }

    _ = gpa;
}

fn usage() noreturn {
    std.debug.print(
        \\Usage: stew [command] [options]
        \\
        \\Commands:
        \\  wp          Interact with workspaces
        \\  check       Checks recipe file for errors
        \\
        \\  version     Print version number and exit
        \\  help, -h    Print this help message and exit
        \\
        \\  -v          Make the operation more talkative
        \\
        \\Options:
        \\  [wp]  list    List workspaces in recipe
        \\        <name>  Run the specified workspace commands
        \\
    , .{});

    std.process.exit(0);
}
