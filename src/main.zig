const std = @import("std");
const fatal = @import("fatal.zig");
const Recipe = @import("Recipe.zig");

comptime {
    _ = @import("Recipe.zig");
}

const mem = std.mem;

const Command = enum {
    version,
    wp,
    check,
    clean,
    help,
    @"-h",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var verbose = false;

    const trash_dir_path = ".trash";

    var args = init.minimal.args.toSlice(arena) catch |err| switch (err) {
        error.OutOfMemory => |oom| fatal.oom(oom),
        error.Unexpected => fatal.fmt("Unexpected error when parsing args", .{}),
    };

    var recipe: Recipe = .init();
    try recipe.dir(io, trash_dir_path, verbose, .create);
    // should we automatically remove the trash dir after run
    // or let the user remove it with 'clean'?

    for (args) |arg| {
        if (mem.eql(u8, arg, "-v")) verbose = true;
    }

    {
        if (args.len == 1) { // stew
            try recipe.loadAndParse(io, arena);
            try recipe.execute(io, arena, trash_dir_path, verbose);
        }

        if (args.len <= 2 and verbose) { // != stew -v
            try recipe.loadAndParse(io, arena);
            try recipe.execute(io, arena, trash_dir_path, verbose);
        }
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
        .clean => try recipe.dir(io, trash_dir_path, verbose, .destroy),
        .wp => wp: {
            args = args[2..]; // stew wp | ...
            if (args.len == 0) fatal.fmt("Expected, 'list' or '<workspace>'", .{});
            try recipe.loadAndParse(io, arena);

            if (mem.eql(u8, args[0], "list")) {
                for (recipe.workspaces.items, 0..) |wp, idx| {
                    if (idx == 0) {
                        std.debug.print(".\n", .{});
                        continue;
                    }

                    const bar = if (idx != recipe.workspaces.items.len - 1) "├─" else "└─";
                    std.debug.print(
                        "{s} {s} (cmds: {d})\n",
                        .{ bar, wp.name, wp.commands.items.len },
                    );
                }
            } else {
                const workspace = args[0];
                if (mem.eql(u8, workspace, Recipe.ROOT_WP)) fatal.fmt("Use 'stew' instead", .{});

                for (recipe.workspaces.items) |wp| {
                    if (mem.eql(u8, wp.name, workspace)) {
                        try Recipe.executeWp(io, arena, wp, trash_dir_path, verbose);
                        break :wp;
                    }
                } else {
                    fatal.fmt("No workspace name {q} found", .{workspace});
                }
            }
        },
    }
}

fn usage() noreturn {
    std.debug.print(
        \\Usage: stew [command] [options]
        \\
        \\Commands:
        \\  wp          Interact with workspaces
        \\  check       Checks recipe file for errors
        \\  clean       Removes non-user artifacts created (e.g .trash dir)
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
