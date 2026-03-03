// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
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
    lookup_passes_per_sample: u32 = 64,
};

const OutputMode = enum {
    summary,
    full,
    json,
};

const RankBy = enum {
    parse,
    lookup,
    balanced,
};

const IndexConfig = struct {
    min_table_index_capacity: u32,
    table_hash_index_threshold: u32,
};

const min_table_index_capacities = [_]u32{ 8, 16, 32, 64 };
const table_hash_index_thresholds = [_]u32{ 16, 32, 64, 128 };
const AccessPassResult = struct {
    hits: u64 = 0,
    misses: u64 = 0,
};

const LookupResult = struct {
    iter: usize,
    hits_per_iter: u64,
    misses_per_iter: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    median_ns: u64,
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

    const output_mode_name = bench_options.output_mode;
    var output_mode = std.meta.stringToEnum(OutputMode, output_mode_name) orelse {
        try stderr.print(
            "invalid bench output mode '{s}', expected one of: summary, full, json\n",
            .{output_mode_name},
        );
        try stderr.flush();
        return error.InvalidOutputMode;
    };
    if (json_output) {
        output_mode = .json;
    }

    const rank_by_name = bench_options.rank_by;
    const rank_by = std.meta.stringToEnum(RankBy, rank_by_name) orelse {
        try stderr.print(
            "invalid bench ranking mode '{s}', expected one of: parse, lookup, balanced\n",
            .{rank_by_name},
        );
        try stderr.flush();
        return error.InvalidRankBy;
    };

    const top_n: usize = @intCast(bench_options.top_n);
    const max_regression_pct: f64 = bench_options.max_regression_pct;

    const default_index_config: IndexConfig = .{
        .min_table_index_capacity = bench_options.default_min_table_index_capacity,
        .table_hash_index_threshold = bench_options.default_table_hash_index_threshold,
    };

    var index_configs: [min_table_index_capacities.len * table_hash_index_thresholds.len]IndexConfig = undefined;
    var index_config_len: usize = 0;
    if (bench_options.sweep_index_configs) {
        for (min_table_index_capacities) |min_table_index_capacity| {
            for (table_hash_index_thresholds) |table_hash_index_threshold| {
                index_configs[index_config_len] = .{
                    .min_table_index_capacity = min_table_index_capacity,
                    .table_hash_index_threshold = table_hash_index_threshold,
                };
                index_config_len += 1;
            }
        }
    } else {
        index_configs[0] = default_index_config;
        index_config_len = 1;
    }

    if (output_mode != .json) {
        try stdout.writeAll("==================\n");
        try stdout.writeAll("toml-zig benchmark\n");
        try stdout.writeAll("==================\n");
        try stdout.print("index configs: {d}\n", .{index_config_len});
        if (output_mode == .summary) {
            try stdout.print("summary: top {d}, rank={s}, max regression={d:.1}%\n", .{
                top_n,
                rank_by_name,
                max_regression_pct,
            });
        }
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

    var all_results: ArrayList(bench.Result) = .empty;
    defer all_results.deinit(gpa);

    for (fixtures.items) |fixture| {
        if (output_mode == .full) {
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

        if (output_mode == .full) {
            try stdout.print(" ({d} bytes)\n", .{data.len});
        }

        var fixture_results: ArrayList(bench.Result) = .empty;
        defer fixture_results.deinit(gpa);

        const config: Config = switch (size) {
            .tiny => .{
                .min_iter = 2_000,
                .max_iter = 200_000,
                .min_ns = 250_000_000,
                .lookup_passes_per_sample = 96,
            },
            .small => .{
                .min_iter = 1_000,
                .max_iter = 100_000,
                .min_ns = 200_000_000,
                .lookup_passes_per_sample = 80,
            },
            .medium => .{
                .min_iter = 500,
                .max_iter = 50_000,
                .min_ns = 150_000_000,
                .lookup_passes_per_sample = 64,
            },
            .large => .{
                .min_iter = 200,
                .max_iter = 10_000,
                .min_ns = 120_000_000,
                .lookup_passes_per_sample = 40,
            },
            .xlarge => .{
                .min_iter = 100,
                .max_iter = 5_000,
                .min_ns = 100_000_000,
                .lookup_passes_per_sample = 24,
            },
        };

        for (index_configs[0..index_config_len]) |index_config| {
            const result = run(gpa, fixture, data, config, index_config);

            try fixture_results.append(gpa, result);

            if (output_mode == .full) {
                try stdout.print("{f}\n", .{result});
                try stdout.flush();
            }
        }

        switch (output_mode) {
            .summary => {
                try printFixtureSummary(gpa, stdout, fixture_results.items, top_n, rank_by, max_regression_pct);
                try stdout.flush();
            },
            .json => {
                try all_results.appendSlice(gpa, fixture_results.items);
            },
            .full => {},
        }
    }

    if (output_mode == .json) {
        try stdout.print("{f}\n", .{std.json.fmt(all_results.items, .{})});
        try stdout.flush();
    }
}

fn printFixtureSummary(
    gpa: Allocator,
    stdout: *std.Io.Writer,
    results: []const bench.Result,
    top_n: usize,
    rank_by: RankBy,
    max_regression_pct: f64,
) !void {
    if (results.len == 0) {
        return;
    }

    const fixture = results[0].fixture;
    const input_bytes = results[0].input_bytes;

    var best_parse = results[0];
    var best_lookup = results[0];
    var best_peak = results[0].peak_live_bytes;

    for (results[1..]) |r| {
        if (r.median_ns < best_parse.median_ns) {
            best_parse = r;
        }
        if (r.lookup_ns_per_op < best_lookup.lookup_ns_per_op) {
            best_lookup = r;
        }
        if (r.peak_live_bytes < best_peak) {
            best_peak = r.peak_live_bytes;
        }
    }

    try stdout.print("\n{s} ({d} bytes)\n", .{ fixture, input_bytes });
    try stdout.print(
        "  best parse:  cap={d: >2} thr={d: >3} median={s}\n",
        .{
            best_parse.min_table_index_capacity,
            best_parse.table_hash_index_threshold,
            std.mem.trimRight(u8, &bench.formatTime(best_parse.median_ns), " "),
        },
    );
    try stdout.print(
        "  best lookup: cap={d: >2} thr={d: >3} ns/op={d:.2}\n",
        .{
            best_lookup.min_table_index_capacity,
            best_lookup.table_hash_index_threshold,
            best_lookup.lookup_ns_per_op,
        },
    );

    var candidates: ArrayList(bench.Result) = .empty;
    defer candidates.deinit(gpa);

    const parse_limit = @as(f64, @floatFromInt(best_parse.median_ns)) * (1.0 + max_regression_pct / 100.0);
    const lookup_limit = best_lookup.lookup_ns_per_op * (1.0 + max_regression_pct / 100.0);

    if (rank_by == .balanced) {
        for (results) |r| {
            if (@as(f64, @floatFromInt(r.median_ns)) <= parse_limit and r.lookup_ns_per_op <= lookup_limit) {
                try candidates.append(gpa, r);
            }
        }
    }

    if (rank_by != .balanced or candidates.items.len == 0) {
        try candidates.appendSlice(gpa, results);
    }

    switch (rank_by) {
        .parse => std.mem.sort(bench.Result, candidates.items, {}, lessByParse),
        .lookup => std.mem.sort(bench.Result, candidates.items, {}, lessByLookup),
        .balanced => std.mem.sort(bench.Result, candidates.items, BalancedCtx{
            .best_parse = best_parse.median_ns,
            .best_lookup = best_lookup.lookup_ns_per_op,
            .best_peak = best_peak,
        }, lessByBalanced),
    }

    const limit = if (top_n == 0) candidates.items.len else @min(top_n, candidates.items.len);

    try stdout.writeAll("  top configs:\n");
    try stdout.writeAll("    cap thr  parse_us   dP%  ns/op   dL%      peak\n");
    for (candidates.items[0..limit]) |r| {
        const parse_delta = if (best_parse.median_ns > 0)
            (@as(f64, @floatFromInt(r.median_ns)) / @as(f64, @floatFromInt(best_parse.median_ns)) - 1.0) * 100.0
        else
            0.0;
        const lookup_delta = if (best_lookup.lookup_ns_per_op > 0)
            (r.lookup_ns_per_op / best_lookup.lookup_ns_per_op - 1.0) * 100.0
        else
            0.0;
        const parse_us = @as(f64, @floatFromInt(r.median_ns)) / 1000.0;
        var parse_delta_buf: [16]u8 = undefined;
        const parse_delta_sign: u8 = if (parse_delta >= 0) '+' else '-';
        const parse_delta_text = std.fmt.bufPrint(&parse_delta_buf, "{c}{d:.1}", .{
            parse_delta_sign,
            @abs(parse_delta),
        }) catch "?";

        var lookup_delta_buf: [16]u8 = undefined;
        const lookup_delta_sign: u8 = if (lookup_delta >= 0) '+' else '-';
        const lookup_delta_text = std.fmt.bufPrint(&lookup_delta_buf, "{c}{d:.1}", .{
            lookup_delta_sign,
            @abs(lookup_delta),
        }) catch "?";

        try stdout.print("    {d: >3} {d: >3}  {d: >8.2} {s: >5}  {d: >5.2} {s: >5}  {d: >8}B\n", .{
            r.min_table_index_capacity,
            r.table_hash_index_threshold,
            parse_us,
            parse_delta_text,
            r.lookup_ns_per_op,
            lookup_delta_text,
            r.peak_live_bytes,
        });
    }
}

fn lessByParse(_: void, a: bench.Result, b: bench.Result) bool {
    if (a.median_ns != b.median_ns) {
        return a.median_ns < b.median_ns;
    }
    if (a.lookup_ns_per_op != b.lookup_ns_per_op) {
        return a.lookup_ns_per_op < b.lookup_ns_per_op;
    }
    return a.peak_live_bytes < b.peak_live_bytes;
}

fn lessByLookup(_: void, a: bench.Result, b: bench.Result) bool {
    if (a.lookup_ns_per_op != b.lookup_ns_per_op) {
        return a.lookup_ns_per_op < b.lookup_ns_per_op;
    }
    if (a.median_ns != b.median_ns) {
        return a.median_ns < b.median_ns;
    }
    return a.peak_live_bytes < b.peak_live_bytes;
}

const BalancedCtx = struct {
    best_parse: u64,
    best_lookup: f64,
    best_peak: u64,
};

fn lessByBalanced(ctx: BalancedCtx, a: bench.Result, b: bench.Result) bool {
    const score_a = balancedScore(ctx, a);
    const score_b = balancedScore(ctx, b);

    if (score_a != score_b) {
        return score_a < score_b;
    }

    if (a.peak_live_bytes != b.peak_live_bytes) {
        return a.peak_live_bytes < b.peak_live_bytes;
    }

    return a.median_ns < b.median_ns;
}

fn balancedScore(ctx: BalancedCtx, r: bench.Result) f64 {
    const parse_ratio = @as(f64, @floatFromInt(r.median_ns)) / @as(f64, @floatFromInt(@max(ctx.best_parse, 1)));
    const lookup_ratio = r.lookup_ns_per_op / @max(ctx.best_lookup, 0.000001);
    const peak_ratio = @as(f64, @floatFromInt(r.peak_live_bytes)) / @as(f64, @floatFromInt(@max(ctx.best_peak, 1)));
    return (parse_ratio - 1.0) + (lookup_ratio - 1.0) + 0.15 * (peak_ratio - 1.0);
}

fn run(
    gpa: Allocator,
    fixture: []const u8,
    data: []const u8,
    bench_config: Config,
    index_config: IndexConfig,
) bench.Result {
    var times: ArrayList(u64) = .empty;
    defer times.deinit(gpa);

    for (0..bench_config.warmup_iterations) |_| {
        _ = benchDecodeTiming(gpa, data, index_config) catch |err| std.debug.panic("warmup failed: {t}", .{err});
    }

    var ns: u64 = 0;
    var iter: usize = 0;

    while (iter < bench_config.min_iter or (ns < bench_config.min_ns and iter < bench_config.max_iter)) : (iter += 1) {
        const result = benchDecodeTiming(gpa, data, index_config) catch |err| std.debug.panic(
            "benchmark failed: {t}",
            .{err},
        );

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

    const memory_result = benchDecodeTracking(&tracking, data, index_config) catch |err| std.debug.panic(
        "benchmark failed: {t}",
        .{err},
    );
    const lookup_result = runTableAccessBench(gpa, data, bench_config, index_config) catch |err| std.debug.panic(
        "lookup benchmark failed: {t}",
        .{err},
    );

    const lookup_mops_per_s = blk: {
        if (lookup_result.median_ns > 0) {
            break :blk @as(f64, @floatFromInt(lookup_result.hits_per_iter + lookup_result.misses_per_iter)) /
                @as(f64, @floatFromInt(lookup_result.median_ns)) * 1000.0;
        } else {
            break :blk 0;
        }
    };
    const lookup_ns_per_op = blk: {
        if (lookup_result.hits_per_iter + lookup_result.misses_per_iter > 0) {
            break :blk @as(f64, @floatFromInt(lookup_result.median_ns)) /
                @as(f64, @floatFromInt(lookup_result.hits_per_iter + lookup_result.misses_per_iter));
        } else {
            break :blk 0;
        }
    };

    return .{
        .fixture = fixture,
        .input_bytes = data.len,
        .min_table_index_capacity = index_config.min_table_index_capacity,
        .table_hash_index_threshold = index_config.table_hash_index_threshold,
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
        .lookup_iter = lookup_result.iter,
        .lookup_ops_per_iter = lookup_result.hits_per_iter + lookup_result.misses_per_iter,
        .lookup_hits_per_iter = lookup_result.hits_per_iter,
        .lookup_misses_per_iter = lookup_result.misses_per_iter,
        .lookup_min_ns = lookup_result.min_ns,
        .lookup_max_ns = lookup_result.max_ns,
        .lookup_mean_ns = lookup_result.mean_ns,
        .lookup_median_ns = lookup_result.median_ns,
        .lookup_mops_per_s = lookup_mops_per_s,
        .lookup_ns_per_op = lookup_ns_per_op,
    };
}

fn benchDecodeTiming(gpa: Allocator, data: []const u8, index_config: IndexConfig) !u64 {
    var timer = try std.time.Timer.start();

    var parsed = blk: {
        if (@hasDecl(toml, "DecodeOptions")) {
            const DecodeOptions = toml.DecodeOptions;
            if (@hasField(DecodeOptions, "min_table_index_capacity") and
                @hasField(DecodeOptions, "table_hash_index_threshold"))
            {
                break :blk try toml.decode(gpa, data, .{
                    .min_table_index_capacity = index_config.min_table_index_capacity,
                    .table_hash_index_threshold = index_config.table_hash_index_threshold,
                });
            }
        }

        break :blk try toml.decode(gpa, data, .{});
    };
    defer parsed.deinit();

    return timer.read();
}

fn benchDecodeTracking(tracker: *TrackingAllocator, data: []const u8, index_config: IndexConfig) !MemoryResult {
    const gpa = tracker.allocator();

    var parsed = blk: {
        if (@hasDecl(toml, "DecodeOptions")) {
            const DecodeOptions = toml.DecodeOptions;
            if (@hasField(DecodeOptions, "min_table_index_capacity") and
                @hasField(DecodeOptions, "table_hash_index_threshold"))
            {
                break :blk try toml.decode(gpa, data, .{
                    .min_table_index_capacity = index_config.min_table_index_capacity,
                    .table_hash_index_threshold = index_config.table_hash_index_threshold,
                });
            }
        }

        break :blk try toml.decode(gpa, data, .{});
    };
    defer parsed.deinit();

    return .{
        .alloc_count = tracker.alloc_count,
        .total_allocated = tracker.total_allocated,
        .total_freed = tracker.total_freed,
        .live_bytes = tracker.live_bytes,
        .peak_live_bytes = tracker.peak_live_bytes,
    };
}

fn runTableAccessBench(gpa: Allocator, data: []const u8, config: Config, index_config: IndexConfig) !LookupResult {
    var parsed = blk: {
        if (@hasDecl(toml, "DecodeOptions")) {
            const DecodeOptions = toml.DecodeOptions;
            if (@hasField(DecodeOptions, "min_table_index_capacity") and
                @hasField(DecodeOptions, "table_hash_index_threshold"))
            {
                break :blk try toml.decode(gpa, data, .{
                    .min_table_index_capacity = index_config.min_table_index_capacity,
                    .table_hash_index_threshold = index_config.table_hash_index_threshold,
                });
            }
        }

        break :blk try toml.decode(gpa, data, .{});
    };
    defer parsed.deinit();

    const baseline = runAccessPass(&parsed.root);

    var times: ArrayList(u64) = .empty;
    defer times.deinit(gpa);

    for (0..config.warmup_iterations) |_| {
        for (0..config.lookup_passes_per_sample) |_| {
            _ = runAccessPass(&parsed.root);
        }
    }

    var ns: u64 = 0;
    var iter: usize = 0;
    while (iter < config.min_iter or (ns < config.min_ns and iter < config.max_iter)) : (iter += 1) {
        var timer = try std.time.Timer.start();
        var pass: AccessPassResult = .{};
        for (0..config.lookup_passes_per_sample) |_| {
            const one_pass = runAccessPass(&parsed.root);
            pass.hits += one_pass.hits;
            pass.misses += one_pass.misses;
        }

        if (pass.hits != baseline.hits * @as(u64, config.lookup_passes_per_sample) or
            pass.misses != baseline.misses * @as(u64, config.lookup_passes_per_sample))
        {
            return error.InvalidBenchmarkResult;
        }

        const elapsed = timer.read();
        try times.append(gpa, elapsed);
        ns += elapsed;
    }

    if (times.items.len == 0) {
        return error.InvalidBenchmarkResult;
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

    return .{
        .iter = iter,
        .hits_per_iter = baseline.hits * @as(u64, config.lookup_passes_per_sample),
        .misses_per_iter = baseline.misses * @as(u64, config.lookup_passes_per_sample),
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = @intCast(sum / items.len),
        .median_ns = median_ns,
    };
}

fn runAccessPass(root: *const toml.Table) AccessPassResult {
    var result: AccessPassResult = .{};
    runAccessOnTable(root, &result);
    return result;
}

fn runAccessOnTable(table: *const toml.Table, result: *AccessPassResult) void {
    for (table.entries) |entry| {
        if (table.getPtr(entry.key) == null) {
            @panic("missing existing key during benchmark");
        }

        if (@hasDecl(toml.Table, "getEntryPtr")) {
            if (table.getEntryPtr(entry.key) == null) {
                @panic("missing existing entry during benchmark");
            }
        } else {
            if (table.getPtr(entry.key) == null) {
                @panic("missing existing key during benchmark");
            }
        }

        result.hits += 2;

        if (table.getPtr("__toml_zig_bench_missing__") != null) {
            @panic("missing-key lookup unexpectedly succeeded");
        }
        result.misses += 1;

        runAccessOnValue(&entry.value, result);
    }
}

fn runAccessOnValue(value: *const toml.Value, result: *AccessPassResult) void {
    switch (value.*) {
        .table => |*table| runAccessOnTable(table, result),
        .array => |items| {
            for (items) |*item| {
                runAccessOnValue(item, result);
            }
        },
        else => {},
    }
}
