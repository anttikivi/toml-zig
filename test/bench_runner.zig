// SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const bench_options = @import("bench_options");
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const toml = @import("toml");

const bench = @import("bench.zig");
const Pattern = @import("bench_data.zig").Pattern;
const Size = @import("bench_data.zig").Size;
const TrackingAllocator = @import("TrackingAllocator.zig");

const native_os = builtin.target.os.tag;
const json_output = bench_options.json_output;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var stdout_buffer: [8192]u8 = undefined;
var stderr_buffer: [8192]u8 = undefined;

const Config = struct {
    min_iter: usize = 10,
    max_iter: usize = 1_000,
    min_ns: u64 = 100_000_000,
    warmup_iterations: usize = 10,
};

const MemoryResult = struct {
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

    if (!json_output) {
        try stdout.writeAll("==================\n");
        try stdout.writeAll("toml-zig benchmark\n");
        try stdout.writeAll("==================\n");
        try stdout.flush();
    }

    const cwd = std.fs.cwd();

    var dir = try cwd.openDir(bench_options.data_path, .{});
    defer dir.close();

    var fixtures: ArrayList([]const u8) = .empty;
    defer {
        for (fixtures.items) |item| {
            gpa.free(item);
        }
        fixtures.deinit(gpa);
    }

    for (bench_options.benchmarks) |fixture| {
        if (std.meta.stringToEnum(Size, fixture)) |_| {
            for (std.meta.fieldNames(Pattern)) |pattern| {
                const full_fixture = try std.mem.concat(gpa, u8, &.{ fixture, "-", pattern });

                for (fixtures.items) |f| {
                    if (std.mem.eql(u8, f, full_fixture)) {
                        try stderr.print("duplicate fixture {s}\n", .{full_fixture});
                        try stderr.flush();
                        return error.DuplicateFixture;
                    }
                }

                try fixtures.append(gpa, full_fixture);
            }
        } else {
            const full_fixture = try gpa.dupe(u8, fixture);

            for (fixtures.items) |f| {
                if (std.mem.eql(u8, f, full_fixture)) {
                    try stderr.print("duplicate fixture {s}\n", .{full_fixture});
                    try stderr.flush();
                    return error.DuplicateFixture;
                }
            }

            try fixtures.append(gpa, full_fixture);
        }
    }

    var results: ArrayList(bench.Result) = .empty;
    defer results.deinit(gpa);

    for (fixtures.items) |fixture| {
        if (!json_output) {
            try stdout.print("\n{s}", .{fixture});
            try stdout.flush();
        }

        const i = std.mem.indexOfScalar(
            u8,
            fixture,
            '-',
        ) orelse std.debug.panic("invalid benchmark target: {s}", .{fixture});
        const size_name = fixture[0..i];
        const size = std.meta.stringToEnum(Size, size_name) orelse std.debug.panic(
            "invalid benchmark size in {s}",
            .{fixture},
        );

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

        if (!json_output) {
            try stdout.print(" ({d} bytes)\n", .{data.len});
        }

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

        const result = run(gpa, fixture, benchDecodeTiming, benchDecodeTracking, data, config);

        if (json_output) {
            try results.append(gpa, result);
        } else {
            try stdout.print("{f}\n", .{result});
            try stdout.flush();
        }
    }

    if (json_output) {
        try stdout.print("{f}\n", .{std.json.fmt(results.items, .{})});
        try stdout.flush();
    }
}

fn run(
    gpa: Allocator,
    fixture: []const u8,
    comptime timing: fn (Allocator, []const u8) anyerror!u64,
    comptime memory: fn (*TrackingAllocator, []const u8) anyerror!MemoryResult,
    data: []const u8,
    config: Config,
) bench.Result {
    var times: ArrayList(u64) = .empty;
    defer times.deinit(gpa);

    for (0..config.warmup_iterations) |_| {
        _ = timing(gpa, data) catch |err| std.debug.panic("warmup failed: {t}", .{err});
    }

    var ns: u64 = 0;
    var iter: usize = 0;

    while (iter < config.min_iter or (ns < config.min_ns and iter < config.max_iter)) : (iter += 1) {
        const result = timing(gpa, data) catch |err| std.debug.panic("benchmark failed: {t}", .{err});

        times.append(gpa, result) catch @panic("OOM");
        ns += result;
    }

    if (times.items.len == 0) {
        @panic("benchmark recorded no samples");
    }

    const items = times.items;
    std.mem.sort(u64, items, {}, std.sort.asc(u64));

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

    var tracking: TrackingAllocator = .init(gpa);

    const memory_result = memory(&tracking, data) catch |err| std.debug.panic("benchmark failed: {t}", .{err});

    return .{
        .fixture = fixture,
        .input_bytes = data.len,
        .iter = iter,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .median_ns = median_ns,
        .total_bytes = total_bytes,
        .throughput_mbs = throughput_mbs,
        .total_allocated = memory_result.total_allocated,
        .total_freed = memory_result.total_freed,
        .live_bytes = memory_result.live_bytes,
        .peak_live_bytes = memory_result.peak_live_bytes,
        .alloc_count = memory_result.alloc_count,
    };
}

fn benchDecodeTiming(gpa: Allocator, data: []const u8) !u64 {
    const start = std.time.nanoTimestamp();

    var parsed = try toml.decode(gpa, data, .{});
    defer parsed.deinit();

    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

fn benchDecodeTracking(tracker: *TrackingAllocator, data: []const u8) !MemoryResult {
    const gpa = tracker.allocator();

    var parsed = try toml.decode(gpa, data, .{});
    defer parsed.deinit();

    return .{
        .alloc_count = tracker.alloc_count,
        .total_allocated = tracker.total_allocated,
        .total_freed = tracker.total_freed,
        .live_bytes = tracker.live_bytes,
        .peak_live_bytes = tracker.peak_live_bytes,
    };
}
