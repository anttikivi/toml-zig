const std = @import("std");

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
