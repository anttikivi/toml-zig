// SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const bench_options = @import("bench_options");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

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
    dir: std.fs.Dir,
    name: []const u8,

    pub fn deinit(self: *@This(), gpa: Allocator, dir: std.fs.Dir) void {
        self.dir.close();
        dir.deleteTree(self.name) catch @panic("failed to delete temporary directory");
        gpa.free(self.name);
    }
};

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    var stdout_stream = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_stream.interface;

    var stderr_stream = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_stream.interface;

    const zig_path = bench_options.zig_path;
    const zig_realpath = try std.fs.cwd().realpathAlloc(gpa, zig_path);
    defer gpa.free(zig_realpath);
    const benchmarks = bench_options.benchmarks_arg;
    const compare_refs = bench_options.compare_refs;

    try stderr.writeAll("benchmarking HEAD...\n");
    try stderr.flush();

    const head_json = runBench(gpa, zig_path, benchmarks, null, stderr) catch |err| {
        try stderr.print("failed to run benchmarks for HEAD: {t}\n", .{err});
        try stderr.flush();
        return err;
    };
    defer gpa.free(head_json);

    const head_parsed = std.json.parseFromSlice(
        []bench.Result,
        gpa,
        head_json,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        try stderr.print("failed to parse HEAD results: {t}\n", .{err});
        try stderr.flush();
        return err;
    };
    defer head_parsed.deinit();

    var all_revisions: ArrayList(RevisionResults) = .empty;
    defer all_revisions.deinit(gpa);

    try all_revisions.append(gpa, .{
        .label = "HEAD",
        .results = head_parsed.value,
    });

    var parsed_results: ArrayList(std.json.Parsed([]bench.Result)) = .empty;
    defer {
        for (parsed_results.items) |*p| {
            p.deinit();
        }
        parsed_results.deinit(gpa);
    }

    for (compare_refs) |ref| {
        try stderr.print("benchmarking {s}...\n", .{ref});
        try stderr.flush();

        const tmp_dir_name_part = try std.mem.concat(gpa, u8, &.{ ".tmp-bench-", ref });
        defer gpa.free(tmp_dir_name_part);
        var tmp_dir = try makeTempDir(gpa, std.fs.cwd(), tmp_dir_name_part);
        defer tmp_dir.deinit(gpa, std.fs.cwd());

        var cwd = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer cwd.close();

        var git_walker = try cwd.walk(gpa);
        defer git_walker.deinit();

        while (try git_walker.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.path, ".git")) {
                continue;
            }

            switch (entry.kind) {
                .file => try entry.dir.copyFile(entry.basename, tmp_dir.dir, entry.path, .{}),
                .directory => try tmp_dir.dir.makeDir(entry.path),
                else => return error.UnexpectedEntryKind,
            }
        }

        var result = execCmd(gpa, &.{ "git", "rev-parse", "--verify", ref }, null, stderr) catch |err| {
            try stderr.print("warning: ref '{s}' not found, skipping: {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };
        gpa.free(result);
        result = execCmd(gpa, &.{ "git", "reset", "--hard", ref }, tmp_dir.name, stderr) catch |err| {
            try stderr.print("warning: failed to reset to '{s}': {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };
        gpa.free(result);
        result = execCmd(gpa, &.{ "git", "clean", "-fd" }, tmp_dir.name, stderr) catch |err| {
            try stderr.print("warning: failed to clean '{s}': {t}\n", .{ tmp_dir.name, err });
            try stderr.flush();
            continue;
        };
        gpa.free(result);

        try tmp_dir.dir.deleteFile("build.zig");
        try tmp_dir.dir.deleteFile("build.zig.zon");
        try tmp_dir.dir.deleteTree("test");

        var bench_walker = try cwd.walk(gpa);
        defer bench_walker.deinit();
        while (try bench_walker.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.path, "test") and !std.mem.startsWith(u8, entry.path, "build.zig")) {
                continue;
            }

            switch (entry.kind) {
                .file => try entry.dir.copyFile(entry.basename, tmp_dir.dir, entry.path, .{}),
                .directory => try tmp_dir.dir.makeDir(entry.path),
                else => return error.UnexpectedEntryKind,
            }
        }

        const ref_json = runBench(gpa, zig_realpath, benchmarks, tmp_dir.name, stderr) catch |err| {
            try stderr.print("failed to run benchmarks for '{s}': {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };
        defer gpa.free(ref_json);

        const ref_parsed = std.json.parseFromSlice([]bench.Result, gpa, ref_json, .{
            .allocate = .alloc_always,
        }) catch |err| {
            try stderr.print("failed to parse results for '{s}': {t}\n", .{ ref, err });
            try stderr.flush();
            continue;
        };

        try parsed_results.append(gpa, ref_parsed);

        try all_revisions.append(gpa, .{
            .label = ref,
            .results = ref_parsed.value,
        });
    }

    try printComparison(stdout, all_revisions.items);
    try stdout.flush();
}

fn execCmd(gpa: Allocator, argv: []const []const u8, cwd: ?[]const u8, stderr: *std.Io.Writer) ![]const u8 {
    var child: std.process.Child = .init(argv, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    if (cwd) |d| {
        child.cwd = d;
    }

    try child.spawn();

    var child_stdout: ArrayList(u8) = .empty;
    defer child_stdout.deinit(gpa);
    var child_stderr: ArrayList(u8) = .empty;
    defer child_stderr.deinit(gpa);

    child.collectOutput(gpa, &child_stdout, &child_stderr, 10 * 1024 * 1024) catch |err| {
        try stderr.writeAll(child_stderr.items);
        try stderr.flush();
        return err;
    };

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try stderr.writeAll(child_stderr.items);
                try stderr.flush();
                return error.CommandFailed;
            }
        },
        else => {
            try stderr.writeAll(child_stderr.items);
            try stderr.flush();
            return error.CommandFailed;
        },
    }

    return child_stdout.toOwnedSlice(gpa);
}

fn runBench(
    gpa: Allocator,
    zig_path: []const u8,
    benchmarks: []const u8,
    cwd: ?[]const u8,
    stderr: *std.Io.Writer,
) ![]const u8 {
    const benchmarks_arg = try std.fmt.allocPrint(gpa, "-Dbenchmarks={s}", .{benchmarks});
    defer gpa.free(benchmarks_arg);

    return execCmd(gpa, &.{
        zig_path,
        "build",
        "bench",
        benchmarks_arg,
        "-Doptimize=ReleaseFast",
        "-Dbench-json=true",
    }, cwd, stderr);
}

fn printComparison(stdout: *std.Io.Writer, revisions: []const RevisionResults) !void {
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
        try stdout.print("\n  {s} ({d} bytes input)\n", .{
            head_result.fixture,
            head_result.input_bytes,
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
        };

        for (&metrics) |*metric| {
            try stdout.writeAll("  ");
            try printCellLeft(stdout, metric.name, metric_col_width);

            var head_val_f: f64 = 0;
            var vals_f: [16]f64 = undefined;
            var val_count: usize = 0;

            for (revisions) |rev| {
                const rev_result = findResult(rev.results, head_result.fixture);
                if (rev_result) |r| {
                    const val_f = getMetricF64(r, metric.kind, metric.field_idx);

                    if (val_count == 0) {
                        head_val_f = val_f;
                    }

                    vals_f[val_count] = val_f;
                    val_count += 1;

                    if (metric.kind == .f64_metric) {
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
                            try printCellRight(stdout, std.mem.trimRight(u8, &t, " "), value_col_width);
                        } else {
                            var abs_buf: [48]u8 = undefined;
                            const abs_text = std.fmt.bufPrint(&abs_buf, "{d:.0}{s}", .{ val_f, metric.unit }) catch "?";
                            try printCellRight(stdout, abs_text, value_col_width);
                        }
                    }
                } else {
                    try printCellRight(stdout, "n/a", value_col_width);
                    vals_f[val_count] = 0;
                    val_count += 1;
                }
            }

            for (vals_f[1..val_count]) |ref_val| {
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

fn findResult(results: []const bench.Result, fixture: []const u8) ?bench.Result {
    for (results) |r| {
        if (std.mem.eql(u8, r.fixture, fixture)) return r;
    }
    return null;
}

fn getMetricF64(r: bench.Result, kind: MetricKind, idx: usize) f64 {
    return switch (kind) {
        .f64_metric => switch (idx) {
            0 => r.throughput_mbs,
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
            else => 0,
        },
    };
}

fn makeTempDir(gpa: Allocator, dir: std.fs.Dir, name: []const u8) !MakeTempDirResult {
    const rand_int = std.crypto.random.int(u64);
    const dir_name = try std.mem.concat(gpa, u8, &.{ name, ".", &std.fmt.hex(rand_int) });
    return .{ .dir = try dir.makeOpenPath(dir_name, .{}), .name = dir_name };
}
