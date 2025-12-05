const std = @import("std");

const Options = struct {
    target: std.Build.ResolvedTarget,
};

pub fn build(b: *std.Build) void {
    const build_steps = .{
        .check = b.step("check", "Check if the library compiles"),
        .ci = b.step("ci", "Run the CI test suite"),
        .@"test" = b.step("test", "Run tests"),
        .test_fmt = b.step("test-fmt", "Check formatting"),
        .test_toml = b.step("test-toml", "Run the `toml-test` test suite"),
        .test_unit = b.step("test-unit", "Run unit tests"),
    };
    const options: Options = .{
        .target = b.standardTargetOptions(.{}),
    };

    const mod = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
    });

    buildCheck(b, mod, build_steps.check);
    buildTest(b, mod, .{
        .@"test" = build_steps.@"test",
        .test_fmt = build_steps.test_fmt,
        .test_toml = build_steps.test_toml,
        .test_unit = build_steps.test_unit,
    }, options);
    buildCi(b, build_steps.ci);
}

fn buildCi(b: *std.Build, step: *std.Build.Step) void {
    const CiMode = enum { all, check, default, @"test" };

    const mode: CiMode = if (b.args) |args| mode: {
        if (args.len != 1) {
            step.dependOn(&b.addFail("invalid CI mode").step);
            return;
        }

        if (std.meta.stringToEnum(CiMode, args[0])) |m| {
            break :mode m;
        } else {
            step.dependOn(&b.addFail("invalid CI mode").step);
            return;
        }
    } else .default;

    const all = mode == .all;
    const default = all or mode == .default;

    if (default or mode == .check) {
        buildCiStep(b, step, .{"test-fmt"});
        buildCiStep(b, step, .{"check"});
    }

    if (default or mode == .@"test") {
        buildCiStep(b, step, .{"test"});
    }
}

fn buildCiStep(b: *std.Build, step: *std.Build.Step, command: anytype) void {
    const argv = .{ b.graph.zig_exe, "build" } ++ command;
    const system_command = b.addSystemCommand(&argv);
    const name = std.mem.join(b.allocator, " ", &command) catch @panic("OOM");
    system_command.setName(name);
    step.dependOn(&system_command.step);
}

/// Build the library without full codegen.
fn buildCheck(b: *std.Build, mod: *std.Build.Module, step: *std.Build.Step) void {
    const lib = b.addLibrary(.{
        .name = "toml",
        .root_module = mod,
    });
    step.dependOn(&lib.step);
}

fn buildTest(b: *std.Build, mod: *std.Build.Module, steps: struct {
    @"test": *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_toml: *std.Build.Step,
    test_unit: *std.Build.Step,
}, options: Options) void {
    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    steps.test_unit.dependOn(&run_unit_tests.step);

    buildTestToml(b, mod, steps.test_toml, options);

    const run_fmt = b.addFmt(.{ .paths = &.{"."}, .check = true });
    steps.test_fmt.dependOn(&run_fmt.step);

    steps.@"test".dependOn(&run_unit_tests.step);

    if (b.args == null) {
        steps.@"test".dependOn(steps.test_fmt);
        steps.@"test".dependOn(steps.test_toml);
    }
}

fn buildTestToml(
    b: *std.Build,
    mod: *std.Build.Module,
    step: *std.Build.Step,
    options: Options,
) void {
    const decoder = b.addExecutable(.{
        .name = "toml-decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/toml_decoder.zig"),
            .target = options.target,
        }),
    });
    decoder.root_module.addImport("toml", mod);

    const toml_test = b.findProgram(&.{"toml-test"}, &.{}) catch |err| switch (err) {
        // Explicitly switch on the error so we can catch new possible error
        // types in the future.
        error.FileNotFound => {
            // TODO: Add a script for installing `toml-test` to the repository.
            step.dependOn(&b.addFail("\"toml-test\" not found").step);
            return;
        },
    };
    const run_toml_test = b.addSystemCommand(&[_][]const u8{toml_test});
    run_toml_test.addFileArg(decoder.getEmittedBin());

    step.dependOn(&run_toml_test.step);
}
