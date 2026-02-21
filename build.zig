const std = @import("std");
const toml = @import("src/root.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const min_index_capacity = b.option(
        u32,
        "min-index-capacity",
        "Minimum capacity to initially allocate for the TOML hash table indices",
    ) orelse 16;
    const table_index_threshold = b.option(
        u32,
        "table-index-threshold",
        "Threshold for the parsed TOML tables for switching from linear lookup to hashes. Must be a power of 2",
    ) orelse 64;

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

    // toml-test
    {
        const step = b.step("test-toml", "Run the `toml-test` test suite against the library");
        const toml_test = b.findProgram(&.{"toml-test"}, &.{}) catch |err| switch (err) {
            error.FileNotFound => {
                // TODO: Add a script for installing `toml-test` to
                // the repository.
                step.dependOn(&b.addFail("\"toml-test\" not found").step);
                return;
            },
        };

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
            const run = b.addSystemCommand(&[_][]const u8{ toml_test, "test", "-toml", version_arg, "-decoder" });
            run.addFileArg(decoder.getEmittedBin());
            version_step.dependOn(&run.step);
            step.dependOn(version_step);
        }

        test_step.dependOn(step);
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
