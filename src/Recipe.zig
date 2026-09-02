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

const Steps = ArrayList(Workspace);

steps: Steps = .empty,

pub fn init() Recipe {
    return .{};
}

pub fn loadAndParse(self: *Recipe, io: std.Io, arena: mem.Allocator) !void {
    const stat = std.Io.Dir.cwd().statFile(io, RECIPE_SRC, .{}) catch |err| switch (err) {
        error.FileNotFound => fatal.fmt("'recipe.stw' not found", .{}),
        else => return err,
    };

    if (stat.size == 0) {
        fatal.fmt("{q} is empty, try adding a step \":ex echo 'Hello World'\"", .{RECIPE_SRC});
    }

    const file_contents = try arena.alloc(u8, stat.size);
    const src = try std.Io.Dir.cwd().readFile(io, RECIPE_SRC, file_contents);

    try self.parseFromSrc(io, arena, src);
}

pub fn execute(self: Recipe, io: std.Io, arena: Allocator, verbose: bool) !void {
    _ = self;
    _ = verbose;
    _ = io;
    _ = arena;

    std.process.exit(1);
}

/// Parses out the recipe from the source file contents
fn parseFromSrc(self: *Recipe, io: std.Io, arena: Allocator, contents: []const u8) !void {
    const root_workspace: Workspace = .{
        .name = "__root__",
        .dir = ".",
        .commands = .empty,
    };

    var current_workspace: Workspace = root_workspace;

    try self.steps.append(arena, current_workspace);

    var lines = mem.tokenizeScalar(u8, contents, '\n');
    assert(lines.buffer.len > 0);

    var line_count: usize = 1;
    while (lines.next()) |line| : (line_count += 1) {
        const src = mem.trim(u8, line, " ");

        if (mem.startsWith(u8, src, ":wp")) {
            if (!mem.eql(u8, current_workspace.name, "__root__")) {
                reportError(io, "Nested workspaces are not supported", src, RECIPE_SRC, line_count, 0);
            }
            const wp = parseWorkspace(io, src, line_count);
            current_workspace = wp;
        } else if (mem.startsWith(u8, src, ":b") or
            mem.startsWith(u8, src, ":sym") or
            mem.startsWith(u8, src, ":ex"))
        {
            const cmd = parseCmd(io, arena, src, line_count) catch |err| fatal.oom(err);

            try current_workspace.commands.append(arena, cmd);
        } else if (mem.eql(u8, src, "}")) {
            try self.steps.append(arena, current_workspace);
            current_workspace = root_workspace;
        } else if (mem.startsWith(u8, src, "//")) {
            continue;
        } else {
            reportError(io, "Unexpected entry", src, RECIPE_SRC, line_count, src.len);
        }
    }
}

fn parseWorkspace(io: std.Io, src: []const u8, line: usize) Workspace {
    var wp: Workspace = .{
        .name = "",
        .dir = "",
        .commands = .empty,
    };

    if (mem.endsWith(u8, src, "}")) {
        reportError(io, "Inlining workspaces is not supported", src, RECIPE_SRC, line, src.len - 1);
    }

    var it = mem.tokenizeScalar(u8, src, ' ');
    const ident = it.next() orelse fatal.fmt("Expected to find ':wp' ident", .{}); // :wp identifier
    const name = it.next();
    if (mem.eql(u8, name.?, "{")) {
        reportError(io, "Expected workspace name", src, RECIPE_SRC, line, ident.len);
    }

    wp.name = name.?;

    const dir_or_curly = it.next();
    if (dir_or_curly != null and !mem.eql(u8, dir_or_curly.?, "{")) {
        wp.dir = dir_or_curly.?;
    } else {
        reportError(io, "Expected workspace dir", src, RECIPE_SRC, line, ident.len + wp.name.len + 1);
    }

    return wp;
}

fn parseCmd(io: std.Io, arena: Allocator, src: []const u8, line: usize) Allocator.Error!Command {
    var cmd: ?Command = null;

    if (mem.endsWith(u8, src, "}")) {
        reportError(io, "Expected '}' on new line", src, RECIPE_SRC, line, src.len - 1);
    }

    var it = mem.splitScalar(u8, src, ' ');
    const first = it.next();
    if (first) |f| {
        if (mem.eql(u8, f, ":ex")) {
            cmd = .{ .external = .{ .bin = "", .args = "" } };

            cmd.?.external.bin = it.next() orelse {
                reportError(io, "Expected executable to run", src, RECIPE_SRC, line, f.len);
            };

            while (it.next()) |arg| {
                if (cmd.?.external.args.len > 0) {
                    cmd.?.external.args = try std.fmt.allocPrint(arena, "{s} {s}", .{ cmd.?.external.args, arg });
                } else {
                    cmd.?.external.args = try std.fmt.allocPrint(arena, "{s}", .{arg});
                }
            }
        } else if (mem.eql(u8, f, ":b")) {
            cmd = .{ .builtin = .{ .cmd = ._none, .args = "" } };
            if (it.next()) |ib| {
                const ib_cmd = std.meta.stringToEnum(Builtins, ib) orelse {
                    reportError(io, "Unknown builtin command", src, RECIPE_SRC, line, f.len + 1);
                };

                cmd.?.builtin.cmd = switch (ib_cmd) {
                    .copy => .copy,
                    .move => .move,
                    .delete => .delete,
                    .create => .create,
                    ._none => reportError(io, "Unknown builtin command", src, RECIPE_SRC, line, f.len + 1),
                };

                while (it.next()) |arg| {
                    if (cmd.?.builtin.args.len > 0) {
                        cmd.?.builtin.args = try std.fmt.allocPrint(arena, "{s} {s}", .{ cmd.?.builtin.args, arg });
                    } else {
                        cmd.?.builtin.args = try std.fmt.allocPrint(arena, "{s}", .{arg});
                    }
                }
            } else {
                reportError(io, "Expected builtin command", src, RECIPE_SRC, line, f.len);
            }
        } else if (mem.eql(u8, f, ":sym")) {
            cmd = .{ .symlink = .{ .src = "", .dest = "" } };
            cmd.?.symlink.src = it.next() orelse reportError(io, "Expected symlink source", src, RECIPE_SRC, line, src.len);
            cmd.?.symlink.dest = it.next() orelse reportError(io, "Expected symlink destination", src, RECIPE_SRC, line, src.len);
        } else {
            fatal.fmt("Unknown command {q}", .{first.?});
        }
    }

    return cmd.?;
}

fn reportError(
    _: std.Io,
    message: []const u8,
    src: []const u8,
    file: []const u8,
    line: usize,
    offset: usize,
) noreturn {
    std.debug.print("{s}:{d}: {s}\n", .{ file, line, message });
    std.debug.print("   {s}\n", .{src});

    std.debug.print("   ", .{});
    const safe_offset = if (offset > 1) offset else 1;
    for (0..safe_offset) |_| std.debug.print(" ", .{});
    std.debug.print("^\n", .{});

    std.process.exit(1);
}

test "parse inline commands" {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();

    const src =
        \\ :ex echo 'hello world';
        \\ :b copy file1 file2
    ;

    var recipe: Recipe = .init();
    try recipe.parseFromSrc(allocator, src, true);
    try std.testing.expect(recipe.steps.items.len == 1);
    const root_wp = recipe.steps.items[0];
    try std.testing.expect(mem.eql(u8, root_wp.name, "__root__"));
}

test "parse multiple workspaces" {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();

    const src =
        \\ :ex echo 'hello world'
        \\ :b copy file1 file2
        \\
        \\ :wp name ~/some/dir {
        \\      :b delete ./to-trash
        \\ }
        \\
        \\
        \\ :wp 2 ./dir {
        \\      :b copy ./src ./dest
        \\      :sym /some/src /other/dest
        \\ }
    ;

    var recipe: Recipe = .init();
    try recipe.parseFromSrc(allocator, src, true);
    try std.testing.expect(recipe.steps.items.len == 3);
    try std.testing.expect(mem.eql(u8, recipe.steps.items[0].name, "__root__"));

    try std.testing.expect(mem.eql(u8, recipe.steps.items[1].name, "name"));
    try std.testing.expect(mem.eql(u8, recipe.steps.items[1].dir, "~/some/dir"));
    try std.testing.expect(recipe.steps.items[1].commands.items.len == 1);

    try std.testing.expect(mem.eql(u8, recipe.steps.items[2].name, "2"));
    try std.testing.expect(mem.eql(u8, recipe.steps.items[2].dir, "./dir"));
    try std.testing.expect(recipe.steps.items[2].commands.items.len == 2);
}

// var stdout_buffer: [1024]u8 = undefined;
// var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
// const stdout_writer = &stdout_file_writer.interface;
// stdout_writer.print("{s}:{d}:{d}: {s}\n", .{ file, line, offset, message }) catch {};
// stdout_writer.print("   {s}\n", .{src}) catch {};
//
// stdout_writer.print("   ", .{}) catch {};
// for (0..offset-1) |_| {
//     stdout_writer.print(" ", .{}) catch {};
// }
// stdout_writer.print("^\n", .{}) catch {};
//
//
// stdout_writer.flush() catch {};
