// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const bench_options = @import("bench_options");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const bench = @import("bench.zig");
const formatTime = bench.formatTime;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var stdout_buffer: [8192]u8 = undefined;
var stderr_buffer: [8192]u8 = undefined;

const RevisionResults = struct {
    label: []const u8,
    results: []const bench.Result,
};

const MetricKind = enum { u64_metric, f64_metric };

const MakeTempDirResult = struct {
    dir: Io.Dir,
    name: []const u8,

    pub fn deinit(self: *@This(), gpa: Allocator, io: Io, dir: Io.Dir) void {
        self.dir.close(io);
        dir.deleteTree(io, self.name) catch @panic("failed to delete temporary directory");
        gpa.free(self.name);
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout_stream = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_stream.interface;

    var stderr_stream = Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_stream.interface;

    const zig_exe = bench_options.zig_exe;
    const benchmarks = bench_options.benchmarks_arg;
    const compare_refs = bench_options.compare_refs;
    const default_min_table_index_capacity = bench_options.default_min_table_index_capacity;
    const default_table_hash_index_threshold = bench_options.default_table_hash_index_threshold;

    try stderr.writeAll("benchmarking HEAD...\n");
    try stderr.flush();

    const head_json = runBench(
        init.gpa,
        init.io,
        zig_exe,
        benchmarks,
        default_min_table_index_capacity,
        default_table_hash_index_threshold,
        null,
    ) catch |err| {
        try stderr.print("failed to run benchmarks for HEAD: {t}\n", .{err});
        try stderr.flush();
        return err;
    };
    defer init.gpa.free(head_json);

    const head_parsed = std.json.parseFromSlice(
        []bench.Result,
        init.gpa,
        head_json,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        try stderr.print("failed to parse HEAD results: {t}\n", .{err});
        try stderr.flush();
        return err;
    };
    defer head_parsed.deinit();

    var all_revisions: ArrayList(RevisionResults) = .empty;
    defer all_revisions.deinit(init.gpa);

    try all_revisions.append(init.gpa, .{
        .label = "HEAD",
        .results = head_parsed.value,
    });

    var parsed_results: ArrayList(std.json.Parsed([]bench.Result)) = .empty;
    defer {
        for (parsed_results.items) |*p| {
            p.deinit();
        }
        parsed_results.deinit(init.gpa);
    }

    for (compare_refs) |ref| {
        try stderr.print("benchmarking {s}...\n", .{ref});
        try stderr.flush();

        const tmp_dir_name_part = try std.mem.concat(init.gpa, u8, &.{ ".tmp-bench-", ref });
        defer init.gpa.free(tmp_dir_name_part);
        var tmp_dir = try makeTempDir(init.gpa, init.io, Io.Dir.cwd(), tmp_dir_name_part);
        defer tmp_dir.deinit(init.gpa, init.io, Io.Dir.cwd());

        var cwd = try Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
        defer cwd.close(init.io);

        var git_walker = try cwd.walk(init.gpa);
        defer git_walker.deinit();

        while (try git_walker.next(init.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.path, ".git")) {
                continue;
            }

            switch (entry.kind) {
                .file => try entry.dir.copyFile(entry.basename, tmp_dir.dir, entry.path, init.io, .{}),
                .directory => try tmp_dir.dir.createDir(init.io, entry.path, .default_dir),
                else => return error.UnexpectedEntryKind,
            }
        }

        runIgnoreResult(init.io, &.{ "git", "rev-parse", "--verify", ref }, null) catch |err| {
            try stderr.print("warning: ref '{s}' not found, skipping: {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };
        runIgnoreResult(init.io, &.{ "git", "reset", "--hard", ref }, tmp_dir.name) catch |err| {
            try stderr.print("warning: failed to reset to '{s}': {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };
        runIgnoreResult(init.io, &.{ "git", "clean", "-fd" }, tmp_dir.name) catch |err| {
            try stderr.print("warning: failed to clean '{s}': {t}\n", .{ tmp_dir.name, err });
            try stderr.flush();
            continue;
        };

        try tmp_dir.dir.deleteFile(init.io, "build.zig");
        try tmp_dir.dir.deleteFile(init.io, "build.zig.zon");
        try tmp_dir.dir.deleteTree(init.io, "test");

        var bench_walker = try cwd.walk(init.gpa);
        defer bench_walker.deinit();
        while (try bench_walker.next(init.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.path, "test") and !std.mem.startsWith(u8, entry.path, "build.zig")) {
                continue;
            }

            switch (entry.kind) {
                .file => try entry.dir.copyFile(entry.basename, tmp_dir.dir, entry.path, init.io, .{}),
                .directory => try tmp_dir.dir.createDir(init.io, entry.path, .default_dir),
                else => return error.UnexpectedEntryKind,
            }
        }

        const ref_json = runBench(
            init.gpa,
            init.io,
            zig_exe,
            benchmarks,
            default_min_table_index_capacity,
            default_table_hash_index_threshold,
            tmp_dir.name,
        ) catch |err| {
            try stderr.print("failed to run benchmarks for '{s}': {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };
        defer init.gpa.free(ref_json);

        const ref_parsed = std.json.parseFromSlice([]bench.Result, init.gpa, ref_json, .{
            .allocate = .alloc_always,
        }) catch |err| {
            try stderr.print("failed to parse results for '{s}': {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };

        try parsed_results.append(init.gpa, ref_parsed);

        try all_revisions.append(init.gpa, .{
            .label = ref,
            .results = ref_parsed.value,
        });
    }

    try printComparison(init.gpa, stdout, all_revisions.items);
    try stdout.flush();
}

fn runIgnoreResult(io: Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
    });

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                // try stderr.writeAll(child_stderr.items);
                // try stderr.flush();
                return error.CommandFailed;
            }
        },
        else => {
            // try stderr.writeAll(child_stderr.items);
            // try stderr.flush();
            return error.CommandFailed;
        },
    }
}

fn runBench(
    gpa: Allocator,
    io: Io,
    zig_exe: []const u8,
    benchmarks: []const u8,
    default_min_table_index_capacity: u32,
    default_table_hash_index_threshold: u32,
    cwd: ?[]const u8,
) ![]const u8 {
    const benchmarks_arg = try std.fmt.allocPrint(gpa, "-Dbenchmarks={s}", .{benchmarks});
    defer gpa.free(benchmarks_arg);
    const default_min_table_index_capacity_arg = try std.fmt.allocPrint(
        gpa,
        "-Dmin-index-capacity={d}",
        .{default_min_table_index_capacity},
    );
    defer gpa.free(default_min_table_index_capacity_arg);
    const default_table_hash_index_threshold_arg = try std.fmt.allocPrint(
        gpa,
        "-Dtable-index-threshold={d}",
        .{default_table_hash_index_threshold},
    );
    defer gpa.free(default_table_hash_index_threshold_arg);

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{
            zig_exe,
            "build",
            "bench",
            benchmarks_arg,
            "-Doptimize=ReleaseFast",
            "-Dbench-json=true",
            "-Dbench-sweep-index-configs=false",
            default_min_table_index_capacity_arg,
            default_table_hash_index_threshold_arg,
        },
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
    });

    return run_result.stdout;
}

fn printComparison(gpa: Allocator, stdout: *std.Io.Writer, revisions: []const RevisionResults) !void {
    if (revisions.len == 0) {
        return;
    }

    const head = revisions[0];
    const metric_col_width: usize = 22;

    var value_col_width: usize = 18;
    for (revisions) |rev| {
        value_col_width = @max(value_col_width, rev.label.len + 2);
    }

    var delta_col_width: usize = 18;
    for (revisions[1..]) |rev| {
        delta_col_width = @max(delta_col_width, ("vs ".len + rev.label.len) + 2);
    }

    try stdout.writeByte('\n');
    try printRepeat(stdout, '=', 80);
    try stdout.writeAll("\n  BENCHMARK COMPARISON\n");
    try printRepeat(stdout, '=', 80);
    try stdout.writeByte('\n');

    for (head.results) |head_result| {
        try stdout.writeByte('\n');
        try printRepeat(stdout, '-', 80);
        try stdout.print("\n  {s} ({d} bytes input, min_capacity={d}, threshold={d})\n", .{
            head_result.fixture,
            head_result.input_bytes,
            head_result.min_table_index_capacity,
            head_result.table_hash_index_threshold,
        });
        try printRepeat(stdout, '-', 80);
        try stdout.writeByte('\n');

        try stdout.writeAll("\n  ");
        try printCellLeft(stdout, "metric", metric_col_width);

        for (revisions) |rev| {
            try printCellRight(stdout, rev.label, value_col_width);
        }

        for (revisions[1..]) |rev| {
            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "vs {s}", .{rev.label}) catch "vs ???";
            try printCellRight(stdout, label, delta_col_width);
        }

        try stdout.writeAll("\n  ");
        const total_width = metric_col_width + revisions.len * value_col_width + (revisions.len - 1) * delta_col_width;
        try printRepeat(stdout, '-', total_width);
        try stdout.writeByte('\n');

        const Metric = struct {
            name: []const u8,
            unit: []const u8,
            kind: MetricKind,
            field_idx: usize,
            higher_is_better: bool,
        };

        const metrics = [_]Metric{
            .{ .name = "throughput", .unit = "MB/s", .kind = .f64_metric, .field_idx = 0, .higher_is_better = true },
            .{ .name = "min", .unit = "", .kind = .u64_metric, .field_idx = 1, .higher_is_better = false },
            .{ .name = "max", .unit = "", .kind = .u64_metric, .field_idx = 2, .higher_is_better = false },
            .{ .name = "mean", .unit = "", .kind = .u64_metric, .field_idx = 3, .higher_is_better = false },
            .{ .name = "median", .unit = "", .kind = .u64_metric, .field_idx = 4, .higher_is_better = false },
            .{ .name = "iterations", .unit = "", .kind = .u64_metric, .field_idx = 5, .higher_is_better = true },
            .{ .name = "allocated", .unit = "B", .kind = .u64_metric, .field_idx = 6, .higher_is_better = false },
            .{ .name = "freed", .unit = "B", .kind = .u64_metric, .field_idx = 7, .higher_is_better = true },
            .{ .name = "retained", .unit = "B", .kind = .u64_metric, .field_idx = 8, .higher_is_better = false },
            .{ .name = "peak live", .unit = "B", .kind = .u64_metric, .field_idx = 9, .higher_is_better = false },
            .{ .name = "allocations", .unit = "", .kind = .u64_metric, .field_idx = 10, .higher_is_better = false },
            .{ .name = "lookup mops", .unit = "", .kind = .f64_metric, .field_idx = 11, .higher_is_better = true },
            .{ .name = "lookup ns/op", .unit = "", .kind = .f64_metric, .field_idx = 12, .higher_is_better = false },
            .{ .name = "lookup min", .unit = "", .kind = .u64_metric, .field_idx = 13, .higher_is_better = false },
            .{ .name = "lookup max", .unit = "", .kind = .u64_metric, .field_idx = 14, .higher_is_better = false },
            .{ .name = "lookup mean", .unit = "", .kind = .u64_metric, .field_idx = 15, .higher_is_better = false },
            .{ .name = "lookup median", .unit = "", .kind = .u64_metric, .field_idx = 16, .higher_is_better = false },
            .{ .name = "lookup iter", .unit = "", .kind = .u64_metric, .field_idx = 17, .higher_is_better = true },
            .{ .name = "lookup ops", .unit = "", .kind = .u64_metric, .field_idx = 18, .higher_is_better = true },
            .{ .name = "lookup hits", .unit = "", .kind = .u64_metric, .field_idx = 19, .higher_is_better = true },
            .{ .name = "lookup misses", .unit = "", .kind = .u64_metric, .field_idx = 20, .higher_is_better = false },
        };

        for (&metrics) |*metric| {
            try stdout.writeAll("  ");
            try printCellLeft(stdout, metric.name, metric_col_width);

            var head_val_f: f64 = 0;
            var vals_f: ArrayList(f64) = .empty;
            defer vals_f.deinit(gpa);

            for (revisions) |rev| {
                const rev_result = findResult(rev.results, head_result);
                if (rev_result) |r| {
                    const val_f = getMetricF64(r, metric.kind, metric.field_idx);

                    if (vals_f.items.len == 0) {
                        head_val_f = val_f;
                    }

                    try vals_f.append(gpa, val_f);

                    if (metric.kind == .f64_metric) {
                        if (std.mem.eql(u8, metric.name, "lookup mops")) {
                            var abs_buf: [48]u8 = undefined;
                            const abs_text = std.fmt.bufPrint(&abs_buf, "{d:.2}M/s", .{val_f}) catch "?";
                            try printCellRight(stdout, abs_text, value_col_width);
                            continue;
                        }

                        if (std.mem.eql(u8, metric.name, "lookup ns/op")) {
                            var abs_buf: [48]u8 = undefined;
                            const abs_text = std.fmt.bufPrint(&abs_buf, "{d:.2}ns", .{val_f}) catch "?";
                            try printCellRight(stdout, abs_text, value_col_width);
                            continue;
                        }

                        var abs_buf: [48]u8 = undefined;
                        const abs_text = std.fmt.bufPrint(&abs_buf, "{d:.2}{s}", .{ val_f, metric.unit }) catch "?";
                        try printCellRight(stdout, abs_text, value_col_width);
                    } else {
                        const is_time = std.mem.eql(u8, metric.name, "min") or
                            std.mem.eql(u8, metric.name, "max") or
                            std.mem.eql(u8, metric.name, "mean") or
                            std.mem.eql(u8, metric.name, "median");

                        if (is_time) {
                            const t = formatTime(@intFromFloat(val_f));
                            try printCellRight(stdout, std.mem.trimEnd(u8, &t, " "), value_col_width);
                        } else {
                            var abs_buf: [48]u8 = undefined;
                            const abs_text = std.fmt.bufPrint(&abs_buf, "{d:.0}{s}", .{ val_f, metric.unit }) catch "?";
                            try printCellRight(stdout, abs_text, value_col_width);
                        }
                    }
                } else {
                    try printCellRight(stdout, "n/a", value_col_width);
                    try vals_f.append(gpa, 0);
                }
            }

            for (vals_f.items[1..]) |ref_val| {
                if (head_val_f == 0 and ref_val == 0) {
                    try printCellRight(stdout, "--", delta_col_width);
                } else if (ref_val == 0) {
                    try printCellRight(stdout, "n/a", delta_col_width);
                } else {
                    const pct = ((head_val_f - ref_val) / ref_val) * 100.0;
                    const indicator: []const u8 = blk: {
                        if (pct > 1.0) {
                            if (metric.higher_is_better) {
                                break :blk " (+)";
                            } else {
                                break :blk " (!)";
                            }
                        } else if (pct < -1.0) {
                            if (metric.higher_is_better) {
                                break :blk " (!)";
                            } else {
                                break :blk " (+)";
                            }
                        } else {
                            break :blk " (=)";
                        }
                    };

                    const sign: u8 = if (pct >= 0) '+' else '-';
                    const abs_pct = @abs(pct);
                    var pct_buf: [32]u8 = undefined;
                    const pct_str = std.fmt.bufPrint(
                        &pct_buf,
                        "{c}{d:.1}%{s}",
                        .{
                            sign,
                            abs_pct,
                            indicator,
                        },
                    ) catch "???";
                    try printCellRight(stdout, pct_str, delta_col_width);
                }
            }

            try stdout.writeByte('\n');
        }
    }

    try stdout.writeByte('\n');
    try printRepeat(stdout, '=', 80);
    try stdout.writeAll("\n  (+) = improvement, (!) = regression, (=) = within noise (~1%)\n");
    try printRepeat(stdout, '=', 80);
    try stdout.writeByte('\n');
}

fn printCellLeft(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) {
        try printRepeat(writer, ' ', width - text.len);
    }
}

fn printCellRight(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    if (text.len < width) {
        try printRepeat(writer, ' ', width - text.len);
    }
    try writer.writeAll(text);
}

fn printRepeat(writer: *std.Io.Writer, char: u8, count: usize) !void {
    for (0..count) |_| {
        try writer.writeByte(char);
    }
}

fn findResult(results: []const bench.Result, candidate: bench.Result) ?bench.Result {
    for (results) |r| {
        if (std.mem.eql(u8, r.fixture, candidate.fixture) and
            r.min_table_index_capacity == candidate.min_table_index_capacity and
            r.table_hash_index_threshold == candidate.table_hash_index_threshold)
        {
            return r;
        }
    }
    return null;
}

fn getMetricF64(r: bench.Result, kind: MetricKind, idx: usize) f64 {
    return switch (kind) {
        .f64_metric => switch (idx) {
            0 => r.throughput_mbs,
            11 => r.lookup_mops_per_s,
            12 => r.lookup_ns_per_op,
            else => 0,
        },
        .u64_metric => switch (idx) {
            1 => @floatFromInt(r.min_ns),
            2 => @floatFromInt(r.max_ns),
            3 => @floatFromInt(r.mean_ns),
            4 => @floatFromInt(r.median_ns),
            5 => @floatFromInt(@as(u64, @intCast(r.iter))),
            6 => @floatFromInt(r.total_allocated),
            7 => @floatFromInt(r.total_freed),
            8 => @floatFromInt(r.live_bytes),
            9 => @floatFromInt(r.peak_live_bytes),
            10 => @floatFromInt(r.alloc_count),
            13 => @floatFromInt(r.lookup_min_ns),
            14 => @floatFromInt(r.lookup_max_ns),
            15 => @floatFromInt(r.lookup_mean_ns),
            16 => @floatFromInt(r.lookup_median_ns),
            17 => @floatFromInt(@as(u64, @intCast(r.lookup_iter))),
            18 => @floatFromInt(r.lookup_ops_per_iter),
            19 => @floatFromInt(r.lookup_hits_per_iter),
            20 => @floatFromInt(r.lookup_misses_per_iter),
            else => 0,
        },
    };
}

fn makeTempDir(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) !MakeTempDirResult {
    const rand_src: std.Random.IoSource = .{ .io = io };
    const rand = rand_src.interface();
    const rand_int = rand.int(u64);
    const dir_name = try std.mem.concat(gpa, u8, &.{ name, ".", &std.fmt.hex(rand_int) });
    return .{ .dir = try dir.createDirPathOpen(io, dir_name, .{}), .name = dir_name };
}
