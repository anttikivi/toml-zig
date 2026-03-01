// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

var stderr_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;

pub fn fail(comptime fmt: []const u8, args: anytype) error{ Reported, WriteFailed } {
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    var stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
    return error.Reported;
}

pub fn print(comptime fmt: []const u8, args: anytype) !void {
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    var stdout = &stdout_writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}
