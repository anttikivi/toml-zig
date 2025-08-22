const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_mod_tests.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("toml", mod);

    const test_exe = b.addExecutable(.{
        .name = "toml-test",
        .root_module = test_mod,
    });

    const run_toml_test = b.addSystemCommand(&[_][]const u8{"toml-test"});
    run_toml_test.addFileArg(test_exe.getEmittedBin());

    const toml_test_step = b.step("toml-test", "Run toml-test for the TOML parser in Reginald");
    toml_test_step.dependOn(&run_toml_test.step);
}
