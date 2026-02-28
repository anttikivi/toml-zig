// SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const bench_options = @import("bench_options");
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const toml = @import("toml");

// const Pattern = @import("bench_data.zig").Pattern;
const Size = @import("bench_data.zig").Size;
const TrackingAllocator = @import("TrackingAllocator.zig");

const native_os = builtin.target.os.tag;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var stdout_buffer: [8192]u8 = undefined;
var stderr_buffer: [8192]u8 = undefined;

const Config = struct {
    min_iter: usize = 10,
    max_iter: usize = 1_000,
    min_ns: u64 = 100_000_000,
    warmup_iterations: usize = 10,
};

const Result = struct {
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

const RunResult = struct {
    time: u64,
    alloc_result: AllocatorResult,
};

const AllocatorResult = struct {
    alloc_count: u64,
    total_allocated: u64,
    total_freed: u64,
    live_bytes: u64,
    peak_live_bytes: u64,
};

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (native_os == .wasi) {
            break :gpa .{ std.heap.wasm_allocator, false };
        }

        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var stdout_stream = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_stream.interface;

    var stderr_stream = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_stream.interface;

    try stdout.writeAll("==================\n");
    try stdout.writeAll("toml-zig benchmark\n");
    try stdout.writeAll("==================\n");
    try stdout.flush();

    const cwd = std.fs.cwd();

    var dir = try cwd.openDir(bench_options.data_path, .{});
    defer dir.close();

    inline for (bench_options.benchmarks) |fixture| {
        try stdout.print("\n{s}", .{fixture});
        try stdout.flush();

        const i = std.mem.indexOfScalar(
            u8,
            fixture,
            '-',
        ) orelse @panic("invalid benchmark generation target: " ++ fixture);
        const size_name = fixture[0..i];
        const size = std.meta.stringToEnum(Size, size_name) orelse @panic("invalid benchmark size in " ++ fixture);

        const filename = try if (bench_options.random_bench) std.fmt.allocPrint(
            gpa,
            "{s}-0x{x}.toml",
            .{ fixture, bench_options.bench_seed },
        ) else std.fmt.allocPrint(
            gpa,
            "{s}-static.toml",
            .{fixture},
        );
        defer gpa.free(filename);

        var file = dir.openFile(filename, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    try stderr.print("benchmark data for '{s}' is not generated\n", .{std.mem.trimEnd(
                        u8,
                        filename,
                        ".toml",
                    )});
                    try stderr.flush();
                },
                else => {},
            }
            return err;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        var file_stream = file.readerStreaming(&buf);
        var reader = &file_stream.interface;

        const data = try reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(data);

        try stdout.print(" ({d} bytes)\n", .{data.len});

        const config: Config = switch (size) {
            .tiny => .{
                .min_iter = 1_000,
                .max_iter = 1_000_000,
            },
            .small => .{
                .min_iter = 1_000,
                .max_iter = 1_000_000,
            },
            .medium => .{
                .min_iter = 1_000,
                .max_iter = 2_000_000,
            },
            .large => .{
                .min_iter = 50,
                .max_iter = 5_000_000,
            },
            .xlarge => .{
                .min_iter = 50,
                .max_iter = 5_000_000,
            },
        };

        const result = run(gpa, benchDecode, data, config);
        try stdout.print("{f}\n", .{result});
        try stdout.flush();
    }
}

fn run(
    gpa: Allocator,
    comptime func: fn (*TrackingAllocator, []const u8) anyerror!RunResult,
    data: []const u8,
    config: Config,
) Result {
    var times: ArrayList(u64) = .empty;
    defer times.deinit(gpa);

    var alloc_results: ArrayList(AllocatorResult) = .empty;
    defer alloc_results.deinit(gpa);

    for (0..config.warmup_iterations) |_| {
        var tracking: TrackingAllocator = .init(gpa);
        _ = func(&tracking, data) catch |err| std.debug.panic("warmup failed: {t}", .{err});
    }

    var ns: u64 = 0;
    var iter: usize = 0;

    while (iter < config.min_iter or (ns < config.min_ns and iter < config.max_iter)) : (iter += 1) {
        var tracking: TrackingAllocator = .init(gpa);

        const result = func(&tracking, data) catch |err| std.debug.panic("benchmark failed: {t}", .{err});

        times.append(gpa, result.time) catch @panic("OOM");
        ns += result.time;

        alloc_results.append(gpa, result.alloc_result) catch @panic("OOM");
    }

    if (times.items.len == 0) {
        @panic("benchmark recorded no samples");
    }

    const items = times.items;
    std.mem.sort(u64, items, {}, std.sort.asc(u64));

    const allocs = alloc_results.items;
    for (allocs[1..], 1..) |alloc, i| {
        if (allocs[i - 1].total_allocated != alloc.total_allocated or
            allocs[i - 1].total_freed != alloc.total_freed or
            allocs[i - 1].live_bytes != alloc.live_bytes or
            allocs[i - 1].peak_live_bytes != alloc.peak_live_bytes or
            allocs[i - 1].alloc_count != alloc.alloc_count)
        {
            @panic("nondeterministic parsing");
        }
    }

    const min_ns = items[0];
    const max_ns = items[items.len - 1];
    const median_ns = items[items.len / 2];

    var sum: u128 = 0;
    for (items) |t| {
        sum += t;
    }
    const mean_ns: u64 = @intCast(sum / items.len);

    const total_bytes = data.len * iter;
    const throughput_mbs = @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(ns)) * 1000.0;

    return .{
        .iter = iter,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .median_ns = median_ns,
        .total_bytes = total_bytes,
        .throughput_mbs = throughput_mbs,
        .total_allocated = allocs[0].total_allocated,
        .total_freed = allocs[0].total_freed,
        .live_bytes = allocs[0].live_bytes,
        .peak_live_bytes = allocs[0].peak_live_bytes,
        .alloc_count = allocs[0].alloc_count,
    };
}

fn formatTime(ns: u64) [10]u8 {
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

fn benchDecode(tracker: *TrackingAllocator, data: []const u8) !RunResult {
    const gpa = tracker.allocator();

    const start = std.time.nanoTimestamp();

    var parsed = try toml.decode(gpa, data, .{});
    defer parsed.deinit();

    const end = std.time.nanoTimestamp();

    return .{
        .time = @intCast(end - start),
        .alloc_result = .{
            .alloc_count = tracker.alloc_count,
            .total_allocated = tracker.total_allocated,
            .total_freed = tracker.total_freed,
            .live_bytes = tracker.live_bytes,
            .peak_live_bytes = tracker.peak_live_bytes,
        },
    };
}
