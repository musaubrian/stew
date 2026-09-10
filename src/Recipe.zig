const Recipe = @This();

const std = @import("std");
const fatal = @import("fatal.zig");

const log = std.log;
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const assert = std.debug.assert;

/// Expects to find the recipe file at $cwd/recipe.stwf
const RECIPE_SRC = "recipe.stwf";
pub const ROOT_WP = "__root__";
const HOME_IDENT = "@home";

/// The maximum number of arguments on oneline (external cmds)
/// before we multiline it
const MAX_ARGS_ON_LINE = 6;

const Builtins = enum { create, copy, move, delete };

const BuiltinCmd = struct { cmd: Builtins, args: []const u8 };
const ExternalCmd = struct { bin: []const u8, args: []const u8 };
const SymlinkCmd = struct { src: []const u8, dest: []const u8 };

const Command = union(enum) {
    builtin: BuiltinCmd,
    external: ExternalCmd,
    symlink: SymlinkCmd,
};

const Entry = union(enum) {
    comment: []const u8,
    command: Command,
};

const Workspace = struct {
    name: []const u8,
    entries: ArrayList(Entry),
};

const Workspaces = ArrayList(Workspace);

workspaces: Workspaces = .empty,
testing: bool = false,

pub fn init(ctx: struct { testing: bool }) Recipe {
    return .{ .testing = ctx.testing };
}

pub fn executeAndExit(
    self: Recipe,
    io: Io,
    arena: Allocator,
    trash_path: []const u8,
    home_path: ?[]const u8,
    verbose: bool,
) noreturn {
    self.execute(io, arena, trash_path, home_path, verbose) catch |err| {
        fatal.fmt("Execute failed: {s}", .{@errorName(err)});
    };

    std.process.exit(0);
}

pub fn execute(
    self: Recipe,
    io: Io,
    arena: Allocator,
    trash_path: []const u8,
    home_path: ?[]const u8,
    verbose: bool,
) !void {
    if (home_path == null and !self.testing) std.log.warn("No HOME directory found", .{});
    for (self.workspaces.items) |step| {
        try executeWp(io, arena, step, home_path, trash_path, verbose);
    }
}

pub fn executeWp(
    io: Io,
    arena: Allocator,
    wp: Workspace,
    home_path: ?[]const u8,
    trash_path: []const u8,
    verbose: bool,
) !void {
    if (verbose) log.info("----- Running workspace {q}", .{wp.name});

    var cmd_count: u32 = 0;
    for (wp.entries.items) |entries| {
        switch (entries) {
            .comment => {},
            .command => |cmd| {
                cmd_count += 1;

                switch (cmd) {
                    .builtin => |blt| try execBuiltin(io, arena, blt, home_path, trash_path, verbose),
                    .symlink => |sym| try execSymlink(io, arena, sym, home_path, verbose),
                    .external => |ex| try execExternal(io, arena, ex, verbose),
                }
            },
        }
    }

    if (verbose) log.info("----- Ran {d} commands\n", .{cmd_count});
}

fn execExternal(
    io: Io,
    arena: Allocator,
    ex: ExternalCmd,
    verbose: bool,
) !void {
    if (verbose) log.info("cmd> {s} {s}", .{ ex.bin, ex.args });
    const raw = try mem.join(arena, " ", &[_][]const u8{ ex.bin, ex.args });
    const proper_args = try split_str(arena, raw, ' ');

    // TODO :: Add a way to specify a timeout from the stew file?
    const results = std.process.run(arena, io, .{ .argv = proper_args }) catch |err| {
        fatal.fmt("Cmd {q} failed: {s}", .{ ex.bin, @errorName(err) });
    };

    if (verbose) {
        const out = if (results.term.success())
            results.stdout
        else
            results.stderr;

        // Should the external cmds output get logged uncondionally
        // or only if verbose is set?
        if (out.len > 0) std.debug.print("{s}", .{out});

        switch (results.term) {
            .exited => |code| {
                if (code != 0) std.debug.print("terminated with code {d}\n", .{code});
            },
            .signal => |sig| std.debug.print("terminated with signal {t}\n", .{sig}),
            .stopped => |sig| std.debug.print("stopped with signal {t}\n", .{sig}),
            .unknown => std.debug.print("terminated unexpectedly\n", .{}),
        }

        if (!results.term.success()) fatal.fmt("Run Exec failed", .{});
    }
}

fn execSymlink(
    io: Io,
    arena: Allocator,
    sym: SymlinkCmd,
    home_path: ?[]const u8,
    verbose: bool,
) !void {
    const src = try expandHome(arena, sym.src, home_path);
    const dest = try expandHome(arena, sym.dest, home_path);

    if (verbose) log.info("sym> {s} -> {s}", .{ dest, src });

    const stat = try Io.Dir.cwd().statFile(io, src, .{});
    try Io.Dir.cwd().symLinkAtomic(
        io,
        src,
        dest,
        .{ .is_directory = stat.kind == .directory },
    );
}

fn execBuiltin(
    io: Io,
    arena: Allocator,
    blt: BuiltinCmd,
    home_path: ?[]const u8,
    trash_path: []const u8,
    verbose: bool,
) !void {
    if (verbose) log.info("blt> {} {s}", .{ blt.cmd, blt.args });

    const pathed_args = try expandHome(arena, blt.args, home_path);

    const is_directory = mem.endsWith(u8, blt.args, Io.Dir.path.sep_str);
    switch (blt.cmd) {
        .create => {
            if (is_directory) {
                try Io.Dir.cwd().createDirPath(io, pathed_args);
            } else {
                var atomic_file = try Io.Dir.cwd().createFileAtomic(io, pathed_args, .{});
                atomic_file.link(io) catch |err|
                    switch (err) {
                        error.PathAlreadyExists => {
                            if (verbose) {
                                log.info("Path {q} already exists; skipping\n", .{blt.args});
                            }
                        },
                        else => return err,
                    };
            }
        },
        .copy => {
            if (is_directory) fatal.fmt("Copying directories is unimplemented", .{});

            var it = mem.splitScalar(u8, blt.args, ' ');
            const copy_src = it.next() orelse unreachable;
            const copy_dest = it.next() orelse unreachable;

            try Io.Dir.cwd().copyFile(copy_src, Io.Dir.cwd(), copy_dest, io, .{});
        },
        .move => {
            var src_dest_it = mem.splitScalar(u8, blt.args, ' ');
            const move_src = src_dest_it.next() orelse unreachable;
            const move_dest = src_dest_it.next() orelse unreachable;

            if (is_directory) {
                const cwd = try Io.Dir.openDir(.cwd(), io, move_src, .{ .iterate = true });
                defer cwd.close(io);
                var base_dir = move_src;

                var dir_it = cwd.iterate();
                while (try dir_it.next(io)) |entry| {
                    if (entry.kind == .directory) {
                        base_dir = try mem.join(arena, Io.Dir.path.sep_str, &.{ base_dir, entry.name });
                        // recurse into the dir
                    } else {
                        const file_to_move = try mem.join(arena, Io.Dir.path.sep_str, &.{ base_dir, entry.name });
                        std.log.info("move_dir: {s}: {}", .{ entry.name, entry.kind });
                        std.log.info("would move {s} to {s}", .{ entry.name, file_to_move });
                    }
                }

                fatal.fmt("Copying directories is unimplemented", .{});
            }

            try Io.Dir.cwd().rename(move_src, .cwd(), move_dest, io);
        },
        .delete => del: {
            if (is_directory) {
                // TODO :: move to .trash first, then actually delete after everything gets done
                try Io.Dir.cwd().deleteTree(io, blt.args);
                break :del;
            }

            // We must always have the trash dir when we start up the application
            _ = Io.Dir.statFile(.cwd(), io, trash_path, .{}) catch |err|
                switch (err) {
                    error.FileNotFound => unreachable,
                    else => return err,
                };
            var del_dest = blt.args;
            const deletion_path_chunks = try split_str(arena, blt.args, Io.Dir.path.sep);

            if (deletion_path_chunks.len > 1) {
                const path_to_rebuild = try mem.join(
                    arena,
                    Io.Dir.path.sep_str,
                    deletion_path_chunks[0 .. deletion_path_chunks.len - 1],
                );

                const joined = try Io.Dir.path.join(arena, &.{ trash_path, path_to_rebuild });
                try Io.Dir.createDirPath(.cwd(), io, joined);
                del_dest = try Io.Dir.path.join(
                    arena,
                    &.{ joined, deletion_path_chunks[deletion_path_chunks.len - 1] },
                );
            }

            try Io.Dir.cwd().rename(blt.args, .cwd(), del_dest, io);
        },
    }
}

pub fn loadAndParse(
    self: *Recipe,
    io: Io,
    arena: mem.Allocator,
) !void {
    const stat = Io.Dir.cwd().statFile(io, RECIPE_SRC, .{}) catch |err|
        switch (err) {
            error.FileNotFound => fatal.fmt("{q} not found", .{RECIPE_SRC}),
            else => return err,
        };

    if (stat.size == 0) {
        fatal.fmt("{q} is empty, try adding a step \":ex echo 'Hello World'\"", .{RECIPE_SRC});
    }

    const file_contents = try arena.alloc(u8, stat.size);
    const src = try Io.Dir.cwd().readFile(io, RECIPE_SRC, file_contents);

    try self.parseFromSrc(io, arena, src);
}

/// Parses out the recipe from the source file contents
fn parseFromSrc(self: *Recipe, io: Io, arena: Allocator, contents: []const u8) !void {
    var current_wp: u64 = 0;

    try self.workspaces.append(arena, .{
        .name = ROOT_WP,
        .entries = .empty,
    });

    var lines = mem.splitScalar(u8, contents, '\n');
    assert(lines.buffer.len > 0);

    var line_no: u64 = 0;
    var to_multiline_end: u64 = 0;

    parse: while (lines.next()) |line| {
        line_no += 1;

        const src = mem.trim(u8, line, " ");
        if (src.len == 0) continue :parse;

        if (mem.startsWith(u8, src, ":wp")) {
            if (current_wp != 0) {
                reportError(
                    io,
                    "Nested workspaces are not supported",
                    .{ .src = src, .file = RECIPE_SRC, .line_no = line_no, .offset = 0 },
                );
            }
            const wp = parseWorkspace(io, src, line_no);
            try self.workspaces.append(arena, wp);
            current_wp = @intCast(self.workspaces.items.len - 1);
        } else if (mem.startsWith(u8, src, ":b") or
            mem.startsWith(u8, src, ":sym") or
            mem.startsWith(u8, src, ":ex"))
        {
            var cmd_src = src;
            if (mem.endsWith(u8, src, "\\")) {
                const collected = try collectMultiLine(
                    arena,
                    try mem.join(arena, "\n", &.{ src, lines.rest() }),
                );
                cmd_src = collected.str;
                to_multiline_end = collected.to_skip;
            }

            const cmd = parseCmd(io, arena, cmd_src, line_no) catch |err| fatal.oom(err);
            try self.workspaces.items[current_wp].entries.append(arena, .{ .command = cmd });
            continue :parse;
        } else if (mem.eql(u8, src, "}")) {
            if (current_wp == 0) reportError(io, "Unexpected '}'", .{
                .src = src,
                .file = RECIPE_SRC,
                .line_no = line_no,
                .offset = 0,
            });

            current_wp = 0;
        } else if (mem.startsWith(u8, src, "//")) {
            try self.workspaces.items[current_wp].entries.append(arena, .{ .comment = src });
        } else {
            if (to_multiline_end != 0) {
                to_multiline_end -= 1;
                continue :parse;
            }

            reportError(
                io,
                "Unexpected entry",
                .{ .src = src, .file = RECIPE_SRC, .line_no = line_no, .offset = 0 },
            );
        }
    } else {
        if (current_wp != 0) reportError(
            io,
            "Unclosed workspace block",
            .{ .src = "", .file = RECIPE_SRC, .line_no = line_no, .offset = 0 },
        );
    }
}

fn collectMultiLine(gpa: Allocator, lines: []const u8) !struct {
    str: []const u8,
    to_skip: u32,
} {
    var collected: []const u8 = "";
    var to_skip: u32 = 0;

    var it = mem.splitScalar(u8, lines, '\n');
    collect: while (it.next()) |line| {
        if (mem.endsWith(u8, line, "\\")) {
            collected = try mem.join(gpa, " ", &.{
                collected,
                try mem.replaceOwned(u8, gpa, line, "\\", ""),
            });
            to_skip += 1;

            if (it.peek()) |next_line| {
                if (!mem.endsWith(u8, next_line, "\\")) {
                    collected = try mem.join(gpa, " ", &.{ collected, next_line });
                    to_skip += 1;
                    break :collect;
                }
            }
        }
    }

    return .{ .str = collected, .to_skip = to_skip };
}

fn parseWorkspace(io: Io, src: []const u8, line: usize) Workspace {
    var wp: Workspace = .{
        .name = "",
        .entries = .empty,
    };

    if (!mem.endsWith(u8, src, "{") or mem.endsWith(u8, src, "}")) {
        reportError(
            io,
            "Inlining workspaces is not supported",
            .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = src.len - 1 },
        );
    }

    var it = mem.tokenizeScalar(u8, src, ' ');

    // we already know that this line starts with :wp,
    // before getting dropped to this fn
    const ident = it.next() orelse unreachable;

    const name = it.next();
    if (mem.eql(u8, name.?, "{")) {
        reportError(
            io,
            "Expected workspace name",
            .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = ident.len },
        );
    }
    if (mem.eql(u8, name.?, ROOT_WP)) {
        reportError(
            io,
            "'__root__' is a reserved workspace name",
            .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = ident.len },
        );
    }

    wp.name = name.?;

    const wp_open = it.next();
    if (!mem.eql(u8, wp_open.?, "{")) {
        reportError(
            io,
            "Expected '{'",
            .{
                .src = src,
                .file = RECIPE_SRC,
                .line_no = line,
                .offset = ident.len + 1 + wp.name.len + 1,
            },
        );
    }

    return wp;
}

fn parseCmd(
    io: Io,
    arena: Allocator,
    src: []const u8,
    line: usize,
) Allocator.Error!Command {
    var cmd: ?Command = null;

    if (mem.endsWith(u8, src, "}")) {
        reportError(
            io,
            "Expected '}' on new line",
            .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = src.len - 1 },
        );
    }

    var it = mem.tokenizeScalar(u8, src, ' ');
    const first = it.next();
    if (first) |f| {
        if (mem.eql(u8, f, ":ex")) {
            cmd = .{ .external = .{ .bin = "", .args = "" } };

            cmd.?.external.bin = it.next() orelse
                reportError(
                    io,
                    "Expected executable to run",
                    .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = f.len },
                );

            while (it.next()) |arg| {
                if (cmd.?.external.args.len > 0) {
                    cmd.?.external.args =
                        try mem.join(arena, " ", &[_][]const u8{ cmd.?.external.args, arg });
                } else {
                    cmd.?.external.args = arg;
                }
            }
        } else if (mem.eql(u8, f, ":b")) {
            cmd = .{ .builtin = .{ .cmd = undefined, .args = "" } };
            if (it.next()) |ib| {
                const ib_cmd = std.meta.stringToEnum(Builtins, ib) orelse
                    reportError(
                        io,
                        "Unknown builtin command",
                        .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = f.len + 1 },
                    );

                cmd.?.builtin.cmd = switch (ib_cmd) {
                    .copy => .copy,
                    .move => .move,
                    .delete => .delete,
                    .create => .create,
                };

                var arg_count: u32 = 0;
                while (it.next()) |arg| : (arg_count += 1) {
                    if (cmd.?.builtin.args.len > 0) {
                        cmd.?.builtin.args =
                            try mem.join(arena, " ", &[_][]const u8{ cmd.?.builtin.args, arg });
                    } else {
                        cmd.?.builtin.args = arg;
                    }
                }

                {
                    if (arg_count == 0)
                        reportError(
                            io,
                            "Expected arguments after builtin cmd",
                            .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = src.len },
                        );

                    if ((cmd.?.builtin.cmd == .create or
                        cmd.?.builtin.cmd == .delete) and arg_count > 1)
                    {
                        reportError(
                            io,
                            "More than one file/directory specified",
                            .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = src.len },
                        );
                    }

                    if ((cmd.?.builtin.cmd == .copy or
                        cmd.?.builtin.cmd == .move) and arg_count < 2)
                    {
                        reportError(
                            io,
                            "Expected destination",
                            .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = src.len },
                        );
                    }
                }
            } else {
                reportError(
                    io,
                    "Expected builtin command",
                    .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = f.len },
                );
            }
        } else if (mem.eql(u8, f, ":sym")) {
            cmd = .{ .symlink = .{ .src = "", .dest = "" } };

            cmd.?.symlink.src = it.next() orelse
                reportError(
                    io,
                    "Expected symlink source",
                    .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = src.len },
                );

            cmd.?.symlink.dest = it.next() orelse
                reportError(
                    io,
                    "Expected symlink destination",
                    .{ .src = src, .file = RECIPE_SRC, .line_no = line, .offset = src.len },
                );
        } else {
            fatal.fmt("Unknown command {q}", .{first.?});
        }
    }

    return cmd.?;
}

fn reportError(
    _: Io,
    message: []const u8,
    ctx: struct { src: []const u8, file: []const u8, line_no: u64, offset: usize },
) noreturn {
    std.debug.print("{s}:{d}: {s}\n", .{ ctx.file, ctx.line_no, message });
    if (ctx.src.len != 0) {
        std.debug.print("   {s}\n", .{ctx.src});
        std.debug.print("   ", .{});
        for (0..ctx.offset) |_| std.debug.print(" ", .{});
        std.debug.print("^\n", .{});
    }

    std.process.exit(1);
}

pub fn dir(
    _: Recipe,
    io: Io,
    path: []const u8,
    verbose: bool,
    mode: enum { create, destroy },
) !void {
    switch (mode) {
        .create => {
            if (verbose) std.log.info("Creating {q}", .{path});
            try std.Io.Dir.createDirPath(.cwd(), io, path);
        },
        .destroy => {
            if (verbose) std.log.info("Deleting {q}", .{path});
            std.Io.Dir.deleteTree(.cwd(), io, path) catch |err|
                fatal.fmt("Failed to delete .trash dir: {s}", .{@errorName(err)});
        },
    }
}

pub fn fmtPot(
    self: Recipe,
    io: Io,
    arena: Allocator,
) !void {
    var formatted_src = try Io.Dir.cwd().createFileAtomic(
        io,
        RECIPE_SRC,
        .{ .replace = true },
    );

    var buffer: [1024]u8 = undefined;
    var file_writer = formatted_src.file.writer(io, &buffer);
    const writer = &file_writer.interface;

    const formatted = try self.format(arena);

    try writer.writeAll(formatted);
    try writer.flush();

    try formatted_src.replace(io);
}

fn format(
    self: Recipe,
    arena: Allocator,
) ![]const u8 {
    assert(self.workspaces.items.len != 0);

    var sb: ArrayList([]const u8) = .empty;
    for (self.workspaces.items, 0..) |wp, wp_idx| {
        if (wp_idx != 0) {
            try sb.append(arena, try fmt.allocPrint(arena, "\n:wp {s} {{", .{wp.name}));
        }
        const indent = if (wp_idx == 0) "" else "  ";
        for (wp.entries.items) |entry| {
            switch (entry) {
                .comment => |c| try sb.append(arena, c),
                .command => |cmd| {
                    switch (cmd) {
                        .builtin => |b| {
                            const b_str = switch (b.cmd) {
                                .copy => "copy",
                                .create => "create",
                                .delete => "delete",
                                .move => "move",
                            };
                            try sb.append(
                                arena,
                                try fmt.allocPrint(
                                    arena,
                                    "{s}:b {s} {s}",
                                    .{ indent, b_str, b.args },
                                ),
                            );
                        },
                        .external => |ex| {
                            var it = mem.tokenizeScalar(u8, ex.args, ' ');
                            var args: []const u8 = "";

                            { // multiline long commands
                                var count: u32 = 0;

                                fmt_extern: while (it.next()) |arg| : (count += 1) {
                                    if (count == 0) {
                                        args = arg;
                                        continue :fmt_extern;
                                    }
                                    if (count == MAX_ARGS_ON_LINE) {
                                        args = try fmt.allocPrint(arena,
                                            \\{s} \
                                            \\{s}    {s}
                                        , .{ args, indent, arg });

                                        count = 0;
                                        continue :fmt_extern;
                                    }

                                    args = try fmt.allocPrint(arena, "{s} {s}", .{ args, arg });
                                }
                            }

                            try sb.append(
                                arena,
                                try fmt.allocPrint(
                                    arena,
                                    "{s}:ex {s} {s}",
                                    .{ indent, ex.bin, args },
                                ),
                            );
                        },
                        .symlink => |sym| {
                            try sb.append(
                                arena,
                                try fmt.allocPrint(
                                    arena,
                                    "{s}:sym {s} {s}",
                                    .{ indent, sym.src, sym.dest },
                                ),
                            );
                        },
                    }
                },
            }
        }
        if (wp_idx != 0) try sb.append(arena, "}");
    }

    const slices = try sb.toOwnedSlice(arena);
    return try mem.join(arena, "\n", slices);
}

fn split_str(gpa: Allocator, buffer: []const u8, delimiter: u8) ![][]const u8 {
    var buf: ArrayList([]const u8) = .empty;

    var it = mem.splitScalar(u8, buffer, delimiter);
    while (it.next()) |item| try buf.append(gpa, item);

    return try buf.toOwnedSlice(gpa);
}

fn expandHome(gpa: Allocator, path: []const u8, home: ?[]const u8) ![]const u8 {
    if (!mem.startsWith(u8, path, HOME_IDENT) or home == null) return path;

    return try mem.replaceOwned(u8, gpa, path, HOME_IDENT, home.?);
}

test "parse inline commands" {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();

    const src =
        \\ :ex echo 'hello world';
        \\ :b copy file1 file2
    ;

    var recipe: Recipe = .init(.{ .testing = true });
    try recipe.parseFromSrc(std.testing.io, allocator, src);
    try std.testing.expect(recipe.workspaces.items.len == 1);
    const root_wp = recipe.workspaces.items[0];
    try std.testing.expect(mem.eql(u8, root_wp.name, ROOT_WP));
}

test "parse multiple workspaces" {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();

    const src =
        \\ :ex echo 'hello world'
        \\ :b copy file1 file2
        \\
        \\ :wp name {
        \\      :b delete ./to-trash
        \\ }
        \\
        \\
        \\ :wp 2 {
        \\      :b copy ./src ./dest
        \\      :sym /some/src /other/dest
        \\ }
    ;

    var recipe: Recipe = .init(.{ .testing = true });
    try recipe.parseFromSrc(std.testing.io, allocator, src);
    try std.testing.expect(recipe.workspaces.items.len == 3);
    try std.testing.expect(mem.eql(u8, recipe.workspaces.items[0].name, ROOT_WP));

    try std.testing.expect(mem.eql(u8, recipe.workspaces.items[1].name, "name"));
    try std.testing.expect(recipe.workspaces.items[1].entries.items.len == 1);

    try std.testing.expect(mem.eql(u8, recipe.workspaces.items[2].name, "2"));
    try std.testing.expect(recipe.workspaces.items[2].entries.items.len == 2);
}

test "builtin" {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();
    const io = std.testing.io;

    const src =
        \\ :b create .test/
        \\ :sym .test/ .test/sample
        \\ :b create .test/nested/
        \\ :b create .test/stew
        \\ :b copy   .test/stew .test/stew_copy
        \\ :b create .test/to_delete
        \\ :b delete .test/to_delete
        \\
        \\ :wp example {
        \\   :b create .test/to_move
        \\   :b move   .test/to_move .test/nested/to_move
        \\ }
        \\ :ex ls ~/work/
        \\
    ;
    const trash_dir = ".testing_trash";
    var recipe: Recipe = .init(.{ .testing = true });
    try recipe.dir(io, trash_dir, false, .create);
    defer recipe.dir(io, trash_dir, false, .destroy) catch unreachable;

    try recipe.parseFromSrc(std.testing.io, allocator, src);
    try recipe.execute(std.testing.io, allocator, trash_dir, null, false);

    _ = try Io.Dir.cwd().statFile(io, ".test/stew", .{});
    _ = try Io.Dir.cwd().statFile(io, ".test/stew_copy", .{});
    _ = try Io.Dir.cwd().statFile(io, trash_dir ++ "/.test/to_delete", .{});
    _ = try Io.Dir.cwd().statFile(io, ".test/nested/to_move", .{});

    try recipe.dir(io, ".test", false, .destroy);
}

test format {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();
    const io = std.testing.io;

    const src =
        \\ :wp    example {
        \\:b create         something
        \\      :ex echo hello
        \\ }
        \\ // should come first
        \\   :sym example com
        \\
    ;

    const expected_formatted =
        \\// should come first
        \\:sym example com
        \\
        \\:wp example {
        \\  :b create something
        \\  :ex echo hello
        \\}
    ;

    var recipe: Recipe = .init(.{ .testing = true });
    try recipe.parseFromSrc(io, allocator, src);

    const formatted = try recipe.format(allocator);
    try std.testing.expectEqualStrings(expected_formatted, formatted);
}

test "new line continuation" {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();
    const io = std.testing.io;

    const src =
        \\:sym example com
        \\
        \\:wp example {
        \\  :b create something
        \\  :ex echo hello
        \\}
        \\:ex some really \
        \\ long command\
        \\ that we should \
        \\ handle
        \\ :ex some other command
    ;

    var recipe: Recipe = .init(.{ .testing = true });
    try recipe.parseFromSrc(io, allocator, src);
}

test "new line formatting" {
    var testing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer testing_arena.deinit();
    const allocator = testing_arena.allocator();
    const io = std.testing.io;

    const src =
        \\:ex some really   \
        \\ long   command\
        \\ that  we should \
        \\ handle
    ;

    const expected_formatted =
        \\:ex some really long command that we should \
        \\    handle
    ;

    var recipe: Recipe = .init(.{ .testing = true });
    try recipe.parseFromSrc(io, allocator, src);
    const formatted = try recipe.format(allocator);
    try std.testing.expectEqualStrings(expected_formatted, formatted);
}
