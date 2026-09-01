const Recipe = @This();

const std = @import("std");
const fatal = @import("fatal.zig");

const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const assert = std.debug.assert;

/// Expects to find the recipe file at cwd/recipe.stw
const RECIPE_SRC = "recipe.stw";

const Builtins = enum {
    _none,
    create,
    copy,
    move,
    delete,
};

const Command = union(enum) {
    builtin: struct {
        cmd: Builtins,
        args: []const u8,
    },

    external: struct {
        bin: []const u8,
        args: []const u8,
    },

    symlink: struct {
        src: []const u8,
        dest: []const u8,
    },
};

const Workspace = struct {
    name: []const u8,
    dir: []const u8,
    commands: ArrayList(Command),
};

pub const Steps = ArrayList(Workspace);

steps: Steps = .empty,

pub fn init() Recipe {
    return .{};
}

pub fn loadAndParse(self: *Recipe, io: std.Io, arena: mem.Allocator, verbose: bool) !void {
    const stat = std.Io.Dir.cwd().statFile(io, RECIPE_SRC, .{}) catch |err| switch (err) {
        error.FileNotFound => fatal.fmt("'recipe.stw' not found", .{}),
        else => return err,
    };

    if (stat.size == 0) {
        fatal.fmt("{q} is empty, try adding a step \":ex echo 'Hello World'\"", .{RECIPE_SRC});
    }

    const file_contents = try arena.alloc(u8, stat.size);
    const src = try std.Io.Dir.cwd().readFile(io, RECIPE_SRC, file_contents);

    try self.parseFromSrc(arena, src, verbose);
}

/// Parses out the recipe from the source file contents
fn parseFromSrc(self: *Recipe, arena: Allocator, src: []const u8, verbose: bool) !void {
    _ = verbose;
    const root_workspace: Workspace = .{
        .name = "__root__",
        .dir = ".",
        .commands = .empty,
    };

    var current_workspace: Workspace = root_workspace;

    try self.steps.append(arena, current_workspace);

    var lines = mem.tokenizeScalar(u8, src, '\n');
    assert(lines.buffer.len > 0);

    var line_count: usize = 1;
    while (lines.next()) |line| : (line_count += 1) {
        const recipe_line = mem.trim(u8, line, " ");

        if (mem.startsWith(u8, recipe_line, ":wp")) {
            if (!mem.eql(u8, current_workspace.name, "__root__")) {
                reportError("Nested workspaces are not supported", recipe_line, RECIPE_SRC, line_count);
            }
            const wp = parseWorkspace(recipe_line) catch |err| switch (err) {
                WorkspaceError.MissingName => reportError("Expected workspace name", recipe_line, RECIPE_SRC, line_count),
                WorkspaceError.MissingDir => reportError("Expected workspace dir", recipe_line, RECIPE_SRC, line_count),
            };
            current_workspace = wp;
        } else if (mem.startsWith(u8, recipe_line, ":b") or
            mem.startsWith(u8, recipe_line, ":sym") or
            mem.startsWith(u8, recipe_line, ":ex"))
        {
            const cmd = try parseCmd(arena, recipe_line);
            try current_workspace.commands.append(arena, cmd);
        } else if (mem.eql(u8, recipe_line, "}")) {
            std.debug.print("End of workspace: {s}\n", .{current_workspace.name});
            current_workspace = root_workspace;
        } else if (mem.startsWith(u8, recipe_line, "//")) {
            continue;
        } else {
            reportError("Unexpected entry", recipe_line, RECIPE_SRC, line_count);
        }

        try self.steps.append(arena, current_workspace);
    }
}

fn reportError(
    message: []const u8,
    src: []const u8,
    file: []const u8,
    line: usize,
) noreturn {
    std.debug.print("{s}:{d} ", .{ file, line });
    std.debug.print("{s} {q}\n", .{ message, src });
    std.process.exit(1);
}

const WorkspaceError = error{ MissingName, MissingDir };
fn parseWorkspace(src: []const u8) WorkspaceError!Workspace {
    var wp: Workspace = .{
        .name = "",
        .dir = "",
        .commands = .empty,
    };

    var it = mem.tokenizeScalar(u8, src, ' ');
    _ = it.next(); // :wp identifier
    const name = it.next();
    if (mem.eql(u8, name.?, "{")) return WorkspaceError.MissingName;

    wp.name = name.?;

    const dir_or_curly = it.next();
    if (dir_or_curly != null and !mem.eql(u8, dir_or_curly.?, "{")) {
        wp.dir = dir_or_curly.?;
    } else {
        return WorkspaceError.MissingDir;
    }

    return wp;
}

const CommandError = error{
    UnknownInbuiltCmd,
    InvalidSymlinkOptions,
    MissingExternBin,
} || Allocator.Error;
fn parseCmd(arena: Allocator, src: []const u8) CommandError!Command {
    var cmd: ?Command = null;

    var it = mem.splitScalar(u8, src, ' ');
    const first = it.next();
    if (first) |f| {
        if (mem.eql(u8, f, ":ex")) {
            cmd = .{ .external = .{ .bin = "", .args = "" } };

            if (it.next()) |bin| cmd.?.external.bin = bin;

            while (it.next()) |arg| {
                if (cmd.?.external.args.len > 0) {
                    cmd.?.external.args = try std.fmt.allocPrint(arena, "{s} {s}", .{ cmd.?.external.args, arg });
                } else {
                    cmd.?.external.args = try std.fmt.allocPrint(arena, "{s}", .{arg});
                }
            }

            if (cmd.?.external.bin.len == 0) return CommandError.MissingExternBin;
        } else if (mem.eql(u8, f, ":b")) {
            cmd = .{ .builtin = .{ .cmd = ._none, .args = "" } };
        } else if (mem.eql(u8, f, ":sym")) {
            cmd = .{ .symlink = .{ .src = "", .dest = "" } };
            if (it.next()) |s| cmd.?.symlink.src = s;
            if (it.next()) |d| cmd.?.symlink.dest = d;
            if (cmd.?.symlink.src.len == 0 or cmd.?.symlink.dest.len == 0) return CommandError.InvalidSymlinkOptions;
        } else {
            fatal.fmt("Unknown command {q}", .{first.?});
        }
    }

    return cmd.?;
}

pub fn execute(self: Recipe, io: std.Io, arena: Allocator, verbose: bool) !void {
    _ = self;
    _ = verbose;
    _ = io;
    _ = arena;

    std.process.exit(1);
}

test parseFromSrc {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();

    const src =
        \\ // this is a comment
        \\       :wp example {
        \\
        \\ }
    ;
    var recipe: Recipe = .init();
    try recipe.parseFromSrc(allocator, src, true);
    try std.testing.expect(recipe.steps.items.len == 2);
    const root_wp = recipe.steps.items[0];
    try std.testing.expect(mem.eql(u8, root_wp.name, "__root__"));
}
