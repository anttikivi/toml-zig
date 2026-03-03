// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const Result = struct {
    fixture: []const u8,
    input_bytes: u64,
    min_table_index_capacity: u32 = 0,
    table_hash_index_threshold: u32 = 0,
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
    lookup_iter: usize = 0,
    lookup_ops_per_iter: u64 = 0,
    lookup_hits_per_iter: u64 = 0,
    lookup_misses_per_iter: u64 = 0,
    lookup_min_ns: u64 = 0,
    lookup_max_ns: u64 = 0,
    lookup_mean_ns: u64 = 0,
    lookup_median_ns: u64 = 0,
    lookup_mops_per_s: f64 = 0,
    lookup_ns_per_op: f64 = 0,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("\n    index config: min_capacity={d}, threshold={d}\n", .{
            self.min_table_index_capacity,
            self.table_hash_index_threshold,
        });
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
        try writer.print("    median:      {s}\n\n", .{formatTime(self.median_ns)});

        try writer.writeAll("    table access:\n");
        try writer.print("    iterations:  {d}\n", .{self.lookup_iter});
        try writer.print("    operations:  {d} per iter\n", .{self.lookup_ops_per_iter});
        try writer.print("    hits:        {d} per iter\n", .{self.lookup_hits_per_iter});
        try writer.print("    misses:      {d} per iter\n\n", .{self.lookup_misses_per_iter});
        try writer.print("    throughput:  {d:.2}M ops/s\n", .{self.lookup_mops_per_s});
        try writer.print("    ns/op:       {d:.2}\n", .{self.lookup_ns_per_op});
        try writer.print("    min:         {s}\n", .{formatTime(self.lookup_min_ns)});
        try writer.print("    max:         {s}\n", .{formatTime(self.lookup_max_ns)});
        try writer.print("    mean:        {s}\n", .{formatTime(self.lookup_mean_ns)});
        try writer.print("    median:      {s}", .{formatTime(self.lookup_median_ns)});
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
