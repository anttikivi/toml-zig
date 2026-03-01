// SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const ArrayList = std.ArrayList;

const bench_data = @import("test/bench_data.zig");
const toml = @import("src/root.zig");

const toml_test_version: std.SemanticVersion = .{ .major = 2, .minor = 1, .patch = 0 };
const max_toml_test_version: std.SemanticVersion = .{ .major = 2, .minor = 2, .patch = 0 };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const benchmarks_list = b.option([]const u8, "benchmarks", "A comma-separated list of benchmarks to run") orelse blk: {
        var result: ArrayList(u8) = .empty;
        var i: usize = 0;
        inline for (std.meta.fieldNames(bench_data.Size)) |size| {
            inline for (std.meta.fieldNames(bench_data.Pattern)) |pattern| {
                if (i != 0) {
                    result.append(b.allocator, ',') catch @panic("OOM");
                }

                result.appendSlice(b.allocator, size) catch @panic("OOM");
                result.append(b.allocator, '-') catch @panic("OOM");
                result.appendSlice(b.allocator, pattern) catch @panic("OOM");

                i += 1;
            }
        }
        break :blk result.toOwnedSlice(b.allocator) catch @panic("OOM");
    };
    const bench_max_nesting = b.option(
        u8,
        "max-bench-nesting",
        "Maximum number of nested tables and array to have in the heavily-nested benchmark data. Default is 5",
    ) orelse 5;
    const bench_seed = b.option(
        u64,
        "bench-seed",
        "Seed to use for generating the benchmark input data when randomizing the generation is enabled",
    ) orelse 0xdead_beef;
    const min_index_capacity = b.option(
        u32,
        "min-index-capacity",
        "Minimum capacity to initially allocate for the TOML hash table indices",
    ) orelse 16;
    const random_bench = b.option(
        bool,
        "random-bench",
        "Use random number generator for generating the benchmark input values instead of deterministic calculation",
    ) orelse false;
    const table_index_threshold = b.option(
        u32,
        "table-index-threshold",
        "Threshold for the parsed TOML tables for switching from linear lookup to hashes. Must be a power of 2",
    ) orelse 64;
    const toml_test_timeout = b.option(
        []const u8,
        "toml-test-timeout",
        "Timeout value to pass to 'toml-test' runs. The value is passed to 'toml-test' as is. Default is '1s'",
    ) orelse "1s";

    const options = b.addOptions();
    options.addOption(u32, "min_index_capacity", min_index_capacity);
    options.addOption(u32, "table_index_threshold", table_index_threshold);

    const toml_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    toml_mod.addOptions("build_options", options);

    // Add the library to the package's module set
    b.modules.put("toml", toml_mod) catch @panic("OOM");

    const test_step = b.step("test", "Run all of the tests");

    // Unit tests
    {
        const step = b.step("test-unit", "Run the unit tests");
        const tests = b.addTest(.{ .root_module = toml_mod });
        step.dependOn(&b.addRunArtifact(tests).step);
        test_step.dependOn(step);
    }

    // Benchmarks
    const bench_data_path = b.pathJoin(&.{ "test", ".bench" });
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "data_path", bench_data_path);
    bench_options.addOption(u64, "bench_seed", bench_seed);
    bench_options.addOption(u8, "max_nesting", bench_max_nesting);
    bench_options.addOption(bool, "random_bench", random_bench);
    {
        const count = std.mem.count(u8, benchmarks_list, ",");
        const benchmarks = b.allocator.alloc([]const u8, count + 1) catch @panic("OOM");

        var it = std.mem.splitScalar(u8, benchmarks_list, ',');
        var i: usize = 0;
        while (it.next()) |fixture| : (i += 1) {
            benchmarks[i] = fixture;
        }

        bench_options.addOption([]const []const u8, "benchmarks", benchmarks);
    }
    {
        const step = b.step("generate-bench-data", "Generate data for running the benchmarks");
        const generate_bench_data = b.addExecutable(.{
            .name = "generate-bench-data",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/generate_bench_data.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        generate_bench_data.root_module.addOptions("bench_options", bench_options);

        const run = b.addRunArtifact(generate_bench_data);
        step.dependOn(&run.step);
    }
    {
        const step = b.step("bench", "Run the bechmarks for the current revision");
        const bench = b.addExecutable(.{
            .name = "benchmark",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/benchmark.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        bench.root_module.addOptions("bench_options", bench_options);
        bench.root_module.addImport("toml", toml_mod);

        const run = b.addRunArtifact(bench);
        step.dependOn(&run.step);
    }

    // fetch-toml-test
    const toml_test_path = b.pathJoin(&.{ "vendor", "toml-test" });
    {
        const step = b.step("fetch-toml-test", "Install `toml-test` locally");
        const fetch_toml_test = b.addExecutable(.{
            .name = "fetch-toml-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/fetch_toml_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const tool_options = b.addOptions();
        tool_options.addOption([]const u8, "go_path", b.pathJoin(&.{ "tools", ".go" }));
        tool_options.addOption([]const u8, "toml_test_path", toml_test_path);
        tool_options.addOption([]const u8, "toml_test_version", b.fmt("{f}", .{toml_test_version}));

        fetch_toml_test.root_module.addOptions("tool_options", tool_options);

        const run = b.addRunArtifact(fetch_toml_test);
        step.dependOn(&run.step);
    }

    // toml-test
    {
        const step = b.step("test-toml", "Run the `toml-test` test suite against the library");

        test_step.dependOn(step);

        const toml_test = b.findProgram(&.{"toml-test"}, &.{toml_test_path}) catch |err| switch (err) {
            error.FileNotFound => {
                step.dependOn(&b.addFail(
                    "'toml-test' not found, consider running 'zig build fetch-toml-test' to install it locally",
                ).step);
                return;
            },
        };

        {
            var code: u8 = undefined;
            const out_untrimmed = b.runAllowFail(&.{ toml_test, "version" }, &code, .Ignore) catch |err| {
                step.dependOn(&b.addFail(
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
                step.dependOn(&b.addFail(b.fmt(
                    "unexpected 'toml-test version' output, first token not found:\n{s}",
                    .{out},
                )).step);
                return;
            };
            if (!std.mem.eql(u8, next, "toml-test")) {
                step.dependOn(&b.addFail(b.fmt(
                    "unexpected 'toml-test version' output, first token '{s}' did not match 'toml-test':\n{s}",
                    .{
                        next,
                        out,
                    },
                )).step);
                return;
            }

            next = it.next() orelse {
                step.dependOn(&b.addFail(b.fmt(
                    "unexpected 'toml-test version' output, second token not found:\n{s}",
                    .{out},
                )).step);
                return;
            };
            next = std.mem.trimStart(u8, next, "v \n\r");
            next = std.mem.trimEnd(u8, next, "; \n\r");

            const version = std.SemanticVersion.parse(next) catch |err| {
                step.dependOn(&b.addFail(b.fmt(
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
                step.dependOn(&b.addFail(b.fmt("wrong 'toml-test' version '{f}', want '>={f}, <{f}'", .{
                    version,
                    toml_test_version,
                    max_toml_test_version,
                })).step);
                return;
            }
        }

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
                    .target = target,
                    .optimize = optimize,
                }),
            });
            decoder.root_module.addOptions("test_options", test_options);
            decoder.root_module.addImport("toml", toml_mod);

            const version_arg = if (std.mem.eql(u8, "1.1.0", field.name)) blk: {
                break :blk "1.1";
            } else if (std.mem.eql(u8, "1.0.0", field.name)) blk: {
                break :blk "1.0";
            } else {
                step.dependOn(&b.addFail(b.fmt("invalid TOML version: {s}", .{field.name})).step);
                return;
            };
            const run = b.addSystemCommand(&[_][]const u8{
                toml_test,
                "test",
                "-toml",
                version_arg,
                "-timeout",
                toml_test_timeout,
                "-decoder",
            });
            run.addFileArg(decoder.getEmittedBin());
            run.setCwd(b.path("."));
            version_step.dependOn(&run.step);
            step.dependOn(version_step);
        }
    }

    // Formatting tasks
    const fmt_include_paths = &.{"."};
    {
        const step = b.step("fmt", "Modify source files in place to have conforming formatting");
        step.dependOn(&b.addFmt(.{ .paths = fmt_include_paths }).step);
    }
    {
        const step = b.step("test-fmt", "Check source files having conforming formatting");
        step.dependOn(&b.addFmt(.{ .paths = fmt_include_paths, .check = true }).step);
        test_step.dependOn(step);
    }
}
