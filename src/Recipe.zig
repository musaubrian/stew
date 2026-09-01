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
    create,
    copy,
    move,
    delete,
};

const Command = union(enum) {
    builtin: struct {
        cmd: Builtins,
        args: []const u8,
        raw: []const u8,
    },

    external: struct {
        bin: []const u8,
        args: []const u8,
        raw: []const u8,
    },

    symlink: struct {
        src: []const u8,
        dest: []const u8,
        raw: []const u8,
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
    _ = io;
    const src = "something";
    try self.parseFromSrc(arena, src, verbose);
}

/// Parses out the recipe from the source file contents
fn parseFromSrc(self: *Recipe, arena: Allocator, src: []const u8, verbose: bool) !void {
    _ = verbose;
    var current_workspace: ?Workspace = .{
        .name = "__root__",
        .dir = ".",
        .commands = .empty,
    };

    try self.steps.append(arena, current_workspace.?);

    var lines = mem.tokenizeScalar(u8, src, '\n');
    assert(lines.buffer.len > 0);

    var line_count: usize = 1;
    while (lines.next()) |line| : (line_count += 1) {
        const recipe_line = mem.trim(u8, line, " ");

        if (mem.startsWith(u8, recipe_line, ":wp")) {
            if (current_workspace != null and !mem.eql(u8, current_workspace.?.name, "__root__")) {
                reportError("Nested workspaces are not supported", recipe_line, RECIPE_SRC, line_count);
            }
            // current_workspace.?
            const wp = parseWorkspace(recipe_line) catch |err| switch (err) {
                WorkspaceError.MissingDir => reportError("Expected workspace dir", recipe_line, RECIPE_SRC, line_count),
            };
            current_workspace.? = wp;
        } else if (mem.startsWith(u8, recipe_line, ":b") or
            mem.startsWith(u8, recipe_line, ":sym") or
            mem.startsWith(u8, recipe_line, ":ex"))
        {
            const cmd = try parseCmd(recipe_line);
            try current_workspace.?.commands.append(arena, cmd);
        } else if (mem.eql(u8, recipe_line, "}")) {
            std.debug.print("End of workspace: {}", .{current_workspace.?});
            current_workspace = null;
        } else if (mem.startsWith(u8, recipe_line, "//")) {
            continue;
        } else {
            reportError("Unexpected entry", recipe_line, RECIPE_SRC, line_count);
        }

        if (current_workspace) |wp| try self.steps.append(arena, wp);
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

const WorkspaceError = error{MissingDir};
fn parseWorkspace(src: []const u8) WorkspaceError!Workspace {
    var wp: Workspace = .{
        .name = "",
        .dir = "",
        .commands = .empty,
    };

    var it = mem.tokenizeScalar(u8, src, ' ');
    _ = it.next(); // :wp identifier
    if (it.next()) |name| wp.name = name;
    if (it.next()) |dir| {
        wp.dir = dir;
    } else {
        return WorkspaceError.MissingDir;
    }

    return wp;
}

fn parseCmd(src: []const u8) !Command {
    _ = src;
    return error.Unimplemented;
}

pub fn execute(self: Recipe, io: std.Io, arena: Allocator, verbose: bool) !void {
    _ = self;
    _ = verbose;
    _ = io;
    _ = arena;

    return error.Unimplemented;
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
