const std = @import("std");

var stderr_buffer: [4096]u8 = undefined;

pub fn fail(comptime fmt: []const u8, args: anytype) error{ Reported, WriteFailed } {
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    var stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
    return error.Reported;
}
