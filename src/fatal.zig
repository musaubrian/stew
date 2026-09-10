const std = @import("std");

pub fn fmt(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format ++ "\n", args);
    std.process.exit(1);
}

pub fn oom(_: error{OutOfMemory}) noreturn {
    fmt("out of memory", .{});
}
