// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const Result = struct {
    fixture: []const u8,
    input_bytes: u64,
    iter: usize,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    median_ns: u64,
    total_bytes: u64,
    throughput_mbs: f64,
    total_allocated: u64,
    total_freed: u64,
    live_bytes: u64,
    peak_live_bytes: u64,
    alloc_count: u64,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("    {d} iterations\n", .{self.iter});
        try writer.print("    {d} total bytes\n\n", .{self.total_bytes});
        try writer.print("    throughput:  {d}MB/s\n", .{self.throughput_mbs});
        try writer.print("    allocated:   {d}B per run\n", .{self.total_allocated});
        try writer.print("    freed:       {d}B per run\n", .{self.total_freed});
        try writer.print("    retained:    {d}B per run\n", .{self.live_bytes});
        try writer.print("    peak live:   {d}B per run\n", .{self.peak_live_bytes});
        try writer.print("    allocations: {d} per run\n\n", .{self.alloc_count});
        try writer.print("    min:         {s}\n", .{formatTime(self.min_ns)});
        try writer.print("    max:         {s}\n", .{formatTime(self.max_ns)});
        try writer.print("    mean:        {s}\n", .{formatTime(self.mean_ns)});
        try writer.print("    median:      {s}", .{formatTime(self.median_ns)});
    }
};

pub fn formatTime(ns: u64) [10]u8 {
    var buf: [10]u8 = [_]u8{' '} ** 10;
    if (ns < 1_000) {
        _ = std.fmt.bufPrint(&buf, "{d: >6}ns", .{ns}) catch unreachable;
    } else if (ns < 1_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d: >6.2}us", .{@as(f64, @floatFromInt(ns)) / 1_000.0}) catch unreachable;
    } else if (ns < 1_000_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d: >6.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch unreachable;
    } else {
        _ = std.fmt.bufPrint(&buf, "{d: >6.2}s ", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch unreachable;
    }
    return buf;
}
