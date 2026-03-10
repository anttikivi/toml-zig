// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");
const ArrayList = std.ArrayList;

const bench_data = @import("test/bench_data.zig");
const toml = @import("src/root.zig");

const toml_test_version: std.SemanticVersion = .{ .major = 2, .minor = 1, .patch = 0 };
const max_toml_test_version: std.SemanticVersion = .{ .major = 2, .minor = 2, .patch = 0 };

const default_toml_test_timeout = "5s";

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    force_local_tools: bool,

    toml_test_timeout: []const u8,
    local_toml_test_path: []const u8,
    toml_test_exe_name: []const u8,
    local_toml_test_exe: []const u8,
    force_toml_test_from_source: bool,
    go_path: []const u8,

    fmt_paths: []const []const u8,

    benchmarks: []const []const u8,
    bench_data_path: []const u8,
    bench_json: bool,
    bench_max_nesting: u8,
    bench_seed: u64,
    bench_output: []const u8,
    bench_top: u32,
    bench_rank_by: []const u8,
    bench_max_regression_pct: f64,
    bench_sweep_index_configs: bool,
    compare_refs: []const []const u8,
    random_bench: bool,

    legacy_min_index_capacity: u32,
    legacy_table_index_threshold: u32,

    const Self = @This();

    fn benchOptions(self: Self, b: *std.Build) *std.Build.Step.Options {
        const options = b.addOptions();

        options.addOption([]const []const u8, "benchmarks", self.benchmarks);
        options.addOption([]const u8, "data_path", self.bench_data_path);
        options.addOption(u64, "bench_seed", self.bench_seed);
        options.addOption([]const u8, "output_mode", self.bench_output);
        options.addOption(u32, "top_n", self.bench_top);
        options.addOption([]const u8, "rank_by", self.bench_rank_by);
        options.addOption(f64, "max_regression_pct", self.bench_max_regression_pct);
        options.addOption(bool, "sweep_index_configs", self.bench_sweep_index_configs);
        options.addOption(u32, "default_min_table_index_capacity", self.legacy_min_index_capacity);
        options.addOption(u32, "default_table_hash_index_threshold", self.legacy_table_index_threshold);
        options.addOption(u8, "max_nesting", self.bench_max_nesting);
        options.addOption(bool, "random_bench", self.random_bench);
        options.addOption(bool, "json_output", self.bench_json);

        return options;
    }

    fn benchCompareOptions(self: *Self, b: *std.Build) *std.Build.Step.Options {
        const old_bench_json = self.bench_json;
        const old_bench_sweep_index_configs = self.bench_sweep_index_configs;

        self.bench_json = false;
        self.bench_sweep_index_configs = false;

        const options = self.benchOptions(b);

        self.bench_json = old_bench_json;
        self.bench_sweep_index_configs = old_bench_sweep_index_configs;

        options.addOption([]const []const u8, "compare_refs", self.compare_refs);
        options.addOption([]const u8, "zig_exe", b.graph.zig_exe);

        var bench_arg_list: ArrayList(u8) = .empty;
        for (self.benchmarks, 0..) |s, i| {
            if (i != 0) {
                bench_arg_list.append(b.allocator, ',') catch @panic("OOM");
            }
            bench_arg_list.appendSlice(b.allocator, s) catch @panic("OOM");
        }
        const bench_arg = bench_arg_list.toOwnedSlice(b.allocator) catch @panic("OOM");
        options.addOption([]const u8, "benchmarks_arg", bench_arg);

        return options;
    }

    fn toolOptions(self: Self, b: *std.Build) *std.Build.Step.Options {
        const options = b.addOptions();

        options.addOption(bool, "force_local_tools", self.force_local_tools);
        options.addOption([]const u8, "go_path", self.go_path);
        options.addOption([]const u8, "local_toml_test_path", self.local_toml_test_path);
        options.addOption([]const u8, "toml_test_exe_name", self.toml_test_exe_name);
        options.addOption([]const u8, "local_toml_test_exe", self.local_toml_test_exe);
        options.addOption(bool, "force_toml_test_from_source", self.force_toml_test_from_source);
        options.addOption([]const u8, "toml_test_version", b.fmt("{f}", .{toml_test_version}));

        return options;
    }

    fn legacyBuildOptions(self: Self, b: *std.Build) *std.Build.Step.Options {
        const options = b.addOptions();

        options.addOption(u32, "min_index_capacity", self.legacy_min_index_capacity);
        options.addOption(u32, "table_index_threshold", self.legacy_table_index_threshold);

        return options;
    }
};

pub fn build(b: *std.Build) void {
    const local_toml_test_path = b.pathJoin(&.{ "vendor", "toml-test" });
    const toml_test_exe_name = blk: {
        if (b.graph.host.result.os.tag == .windows) {
            break :blk "toml-test.exe";
        } else {
            break :blk "toml-test";
        }
    };
    const local_toml_test_exe = b.pathJoin(&.{ local_toml_test_path, toml_test_exe_name });

    var options: Options = .{
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
        .force_local_tools = b.option(
            bool,
            "force-local-tools",
            "Force the scripts to use locally installed tools instead of ones found on the system",
        ) orelse false,
        .toml_test_timeout = b.option(
            []const u8,
            "toml-test-timeout",
            b.fmt(
                "Timeout value to pass to 'toml-test' runs. The value is passed to 'toml-test' as is. Default is '{s}'",
                .{default_toml_test_timeout},
            ),
        ) orelse default_toml_test_timeout,
        .local_toml_test_path = local_toml_test_path,
        .toml_test_exe_name = toml_test_exe_name,
        .local_toml_test_exe = local_toml_test_exe,
        .force_toml_test_from_source = b.option(
            bool,
            "force-toml-test-from-source",
            "Forces building 'toml-test' from source even if there is a prebuild binary available",
        ) orelse false,
        .go_path = b.pathJoin(&.{ "tools", ".go" }),
        .fmt_paths = &.{"."},
        .benchmarks = blk: {
            const benchmarks_list = b.option([]const u8, "benchmarks", "A comma-separated list of benchmarks to run");

            if (benchmarks_list) |list| {
                const count = std.mem.count(u8, list, ",");
                const result = b.allocator.alloc([]const u8, count + 1) catch @panic("OOM");

                var it = std.mem.splitScalar(u8, list, ',');
                var i: usize = 0;
                while (it.next()) |fixture| : (i += 1) {
                    result[i] = fixture;
                }

                break :blk result;
            } else {
                var result: ArrayList([]const u8) = .empty;
                for (std.meta.fieldNames(bench_data.Size)) |size| {
                    for (std.meta.fieldNames(bench_data.Pattern)) |pattern| {
                        const fixture = b.fmt("{s}-{s}", .{ size, pattern });
                        result.append(b.allocator, fixture) catch @panic("OOM");
                    }
                }
                break :blk result.toOwnedSlice(b.allocator) catch @panic("OOM");
            }
        },
        .bench_data_path = b.pathJoin(&.{ "test", ".bench" }),
        .bench_json = b.option(
            bool,
            "bench-json",
            "Output benchmark results as JSON instead of human-readable text",
        ) orelse false,
        .bench_max_nesting = b.option(
            u8,
            "max-bench-nesting",
            "Maximum number of nested tables and array to have in the heavily-nested benchmark data. Default is 5",
        ) orelse 5,
        .bench_seed = b.option(
            u64,
            "bench-seed",
            "Seed to use for generating the benchmark input data when randomizing the generation is enabled",
        ) orelse 0xdead_beef,
        .bench_output = b.option(
            []const u8,
            "bench-output",
            "Benchmark output mode: summary, full, or json",
        ) orelse "summary",
        .bench_top = b.option(
            u32,
            "bench-top",
            "How many top index configurations to print in summary mode (0 = all)",
        ) orelse 5,
        .bench_rank_by = b.option(
            []const u8,
            "bench-rank-by",
            "How to rank index configurations in summary mode: parse, lookup, balanced",
        ) orelse "balanced",
        .bench_max_regression_pct = b.option(
            f64,
            "bench-max-regression-pct",
            "Max allowed parse/lookup regression percent for balanced summary filtering",
        ) orelse 5.0,
        .bench_sweep_index_configs = b.option(
            bool,
            "bench-sweep-index-configs",
            "Benchmark all index config combinations instead of only the default config",
        ) orelse false,
        .compare_refs = blk: {
            const compare_refs = b.option(
                []const u8,
                "compare-refs",
                "Comma-separated list of git refs to compare benchmarks against (for bench-compare step)",
            );

            if (compare_refs) |refs| {
                const count = std.mem.count(u8, refs, ",");
                const result = b.allocator.alloc([]const u8, count + 1) catch @panic("OOM");

                var it = std.mem.splitScalar(u8, refs, ',');
                var i: usize = 0;
                while (it.next()) |ref| : (i += 1) {
                    result[i] = ref;
                }

                break :blk result;
            } else {
                break :blk &.{"v0.1.0"};
            }
        },
        .random_bench = b.option(
            bool,
            "random-bench",
            "Use random number generator for generating the benchmark input values instead of deterministic calculation",
        ) orelse false,
        .legacy_min_index_capacity = b.option(
            u32,
            "min-index-capacity",
            "Minimum initial index capacity for older revisions that use compile-time table index options",
        ) orelse 16,
        .legacy_table_index_threshold = b.option(
            u32,
            "table-index-threshold",
            "Table size threshold for enabling hash index in older revisions that use compile-time options",
        ) orelse 16,
    };

    b.modules.put("toml", addTomlMod(b, options)) catch @panic("OOM");

    addGenerateBenchDataStep(b, options);
    addBenchmarkStep(b, options);
    addBenchCompareStep(b, &options);
    addTestStep(b, options);
    addFetchTomlTestStep(b, options);

    {
        const step = b.step("fmt", "Modify source files in place to have conforming formatting");
        step.dependOn(&b.addFmt(.{ .paths = options.fmt_paths }).step);
    }
}

fn addTomlMod(b: *std.Build, opts: Options) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    mod.addOptions("build_options", opts.legacyBuildOptions(b));

    return mod;
}

fn addTestStep(b: *std.Build, opts: Options) void {
    const step = b.step("test", "Run all of the tests");

    step.dependOn(addTestFmtStep(b, opts));
    step.dependOn(addTestUnitStep(b, opts));
    addTestTomlStep(b, step, opts);
}

fn addTestUnitStep(b: *std.Build, opts: Options) *std.Build.Step {
    const step = b.step("test-unit", "Run the unit tests");
    const tests = b.addTest(.{ .root_module = addTomlMod(b, opts) });
    step.dependOn(&b.addRunArtifact(tests).step);

    return step;
}

fn addTestFmtStep(b: *std.Build, opts: Options) *std.Build.Step {
    const step = b.step("test-fmt", "Check source files having conforming formatting");
    step.dependOn(&b.addFmt(.{ .paths = opts.fmt_paths, .check = true }).step);

    return step;
}

fn addTestTomlStep(b: *std.Build, test_step: *std.Build.Step, opts: Options) void {
    const step = b.step("test-toml", "Run the `toml-test` test suite against the library");

    test_step.dependOn(step);

    checkTomlTestVersion(b, step, opts);

    inline for (std.meta.fields(toml.Version)) |field| {
        const step_version = b.dupe(field.name);
        std.mem.replaceScalar(u8, step_version, '.', '-');
        const version_step = b.step(
            b.fmt("test-toml-{s}", .{step_version}),
            b.fmt("Run the `toml-test` test suite against the library using TOML {s}", .{field.name}),
        );

        const test_options = b.addOptions();
        test_options.addOption([]const u8, "toml_version", field.name);

        const decoder = b.addExecutable(.{
            .name = "toml-decoder",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/decoder.zig"),
                .target = opts.target,
                .optimize = opts.optimize,
            }),
        });
        decoder.root_module.addOptions("test_options", test_options);
        decoder.root_module.addImport("toml", addTomlMod(b, opts));

        const version_arg = if (std.mem.eql(u8, "1.1.0", field.name)) blk: {
            break :blk "1.1";
        } else if (std.mem.eql(u8, "1.0.0", field.name)) blk: {
            break :blk "1.0";
        } else {
            step.dependOn(&b.addFail(b.fmt("invalid TOML version: {s}", .{field.name})).step);
            return;
        };
        const run = b.addSystemCommand(&[_][]const u8{
            findTomlTestProgram(b, step, opts),
            "test",
            "-toml",
            version_arg,
            "-timeout",
            opts.toml_test_timeout,
            "-decoder",
        });
        run.addFileArg(decoder.getEmittedBin());
        run.setCwd(b.path("."));
        version_step.dependOn(&run.step);
        step.dependOn(version_step);
    }
}

fn findTomlTestProgram(b: *std.Build, toml_test_step: *std.Build.Step, opts: Options) []const u8 {
    if (opts.force_local_tools) {
        b.build_root.handle.access(b.graph.io, opts.local_toml_test_exe, .{}) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied, error.FileNotFound => {
                toml_test_step.dependOn(&b.addFail(
                    b.fmt(
                        "'toml-test' not found at {s}, consider running 'zig build fetch-toml-test' to install it",
                        .{opts.local_toml_test_exe},
                    ),
                ).step);
                return "";
            },
            else => {
                toml_test_step.dependOn(&b.addFail(
                    b.fmt(
                        "unknown error while trying to access 'toml-test' at {s}: {t}",
                        .{ opts.local_toml_test_exe, err },
                    ),
                ).step);
                return "";
            },
        };
        return b.build_root.handle.realPathFileAlloc(b.graph.io, opts.local_toml_test_exe, b.allocator) catch |err| {
            switch (err) {
                error.OutOfMemory => @panic("OOM"),
                else => {
                    toml_test_step.dependOn(&b.addFail(
                        b.fmt(
                            "error while trying to obtain realpath for 'toml-test' at {s}: {t}",
                            .{ opts.local_toml_test_exe, err },
                        ),
                    ).step);
                    return "";
                },
            }
        };
    }

    return b.findProgram(&.{"toml-test"}, &.{opts.local_toml_test_path}) catch |err| switch (err) {
        error.FileNotFound => {
            toml_test_step.dependOn(&b.addFail(
                "'toml-test' not found, consider running 'zig build fetch-toml-test' to install it locally",
            ).step);
            return "";
        },
    };
}

fn checkTomlTestVersion(b: *std.Build, toml_test_step: *std.Build.Step, opts: Options) void {
    var code: u8 = undefined;
    const out_untrimmed = b.runAllowFail(
        &.{ findTomlTestProgram(b, toml_test_step, opts), "version" },
        &code,
        .ignore,
    ) catch |err| {
        toml_test_step.dependOn(&b.addFail(
            b.fmt(
                "'toml-test' not found, consider running 'zig build fetch-toml-test' to install it locally\nerror: {t}",
                .{err},
            ),
        ).step);
        return;
    };
    const out = std.mem.trim(u8, out_untrimmed, " \n\r");

    var it = std.mem.splitScalar(u8, out, ' ');
    var next = it.next() orelse {
        toml_test_step.dependOn(&b.addFail(b.fmt(
            "unexpected 'toml-test version' output, first token not found:\n{s}",
            .{out},
        )).step);
        return;
    };
    if (!std.mem.eql(u8, next, "toml-test")) {
        toml_test_step.dependOn(&b.addFail(b.fmt(
            "unexpected 'toml-test version' output, first token '{s}' did not match 'toml-test':\n{s}",
            .{
                next,
                out,
            },
        )).step);
        return;
    }

    next = it.next() orelse {
        toml_test_step.dependOn(&b.addFail(b.fmt(
            "unexpected 'toml-test version' output, second token not found:\n{s}",
            .{out},
        )).step);
        return;
    };
    next = std.mem.trimStart(u8, next, "v \n\r");
    next = std.mem.trimEnd(u8, next, "; \n\r");

    const version = std.SemanticVersion.parse(next) catch |err| {
        toml_test_step.dependOn(&b.addFail(b.fmt(
            "failed to parse version '{s}' from 'toml-test version' output:\n{s}\n\nerror: {t}",
            .{
                next,
                out,
                err,
            },
        )).step);
        return;
    };
    const min_order = std.SemanticVersion.order(version, toml_test_version);
    const max_order = std.SemanticVersion.order(version, max_toml_test_version);
    if (min_order == .lt or max_order != .lt) {
        toml_test_step.dependOn(&b.addFail(b.fmt("wrong 'toml-test' version '{f}', want '>={f}, <{f}'", .{
            version,
            toml_test_version,
            max_toml_test_version,
        })).step);
        return;
    }
}

fn addFetchTomlTestStep(b: *std.Build, opts: Options) void {
    const step = b.step("fetch-toml-test", "Install `toml-test` locally");
    const fetch_toml_test = b.addExecutable(.{
        .name = "fetch-toml-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_toml_test.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });

    fetch_toml_test.root_module.addOptions("tool_options", opts.toolOptions(b));

    const run = b.addRunArtifact(fetch_toml_test);
    step.dependOn(&run.step);
}

fn addBenchmarkStep(b: *std.Build, opts: Options) void {
    const step = b.step("bench", "Run the benchmarks for the current revision");
    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench_runner.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });

    bench.root_module.addOptions("bench_options", opts.benchOptions(b));
    bench.root_module.addImport("toml", addTomlMod(b, opts));

    const run = b.addRunArtifact(bench);
    step.dependOn(&run.step);
}

fn addBenchCompareStep(b: *std.Build, opts: *Options) void {
    const step = b.step("bench-compare", "Run benchmarks and compare against other revisions");

    const bench_compare = b.addExecutable(.{
        .name = "bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench_compare.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });

    bench_compare.root_module.addOptions("bench_options", opts.benchCompareOptions(b));

    const run = b.addRunArtifact(bench_compare);
    step.dependOn(&run.step);
}

fn addGenerateBenchDataStep(b: *std.Build, opts: Options) void {
    const step = b.step("generate-bench-data", "Generate data for running the benchmarks");
    const generate_bench_data = b.addExecutable(.{
        .name = "generate-bench-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generate_bench_data.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });

    generate_bench_data.root_module.addOptions("bench_options", opts.benchOptions(b));

    const run = b.addRunArtifact(generate_bench_data);
    step.dependOn(&run.step);
}
