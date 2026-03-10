// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const tool_options = @import("tool_options");

const file = @import("file.zig");
const go = @import("go.zig");
const fail = @import("output.zig").fail;
const print = @import("output.zig").print;

const cpu_arch = builtin.cpu.arch;
const native_os = builtin.os.tag;

const base_url = "https://github.com/toml-lang/toml-test/releases/download/v{s}";
const go_install_base_url = "github.com/toml-lang/toml-test/v2/cmd/toml-test";
const go_install_url = std.fmt.comptimePrint("{s}@v{s}", .{ go_install_base_url, tool_options.toml_test_version });
const source_base_url = "https://github.com/toml-lang/toml-test/archive/refs/tags";
const archive_extension = switch (native_os) {
    .windows => ".exe.gz",
    else => ".gz",
};
const archive_name = std.fmt.comptimePrint("toml-test-v{[version]s}-{[os]s}-{[arch]s}{[extension]s}", .{
    .version = tool_options.toml_test_version,
    .os = switch (native_os) {
        .macos => "darwin",
        else => |t| @tagName(t),
    },
    .arch = switch (cpu_arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "arm",
        else => |t| @compileError("architecture " ++ @tagName(t) ++ " is not supported"),
    },
    .extension = switch (native_os) {
        .windows => ".exe.gz",
        else => ".gz",
    },
});
const source_archive_extension = ".tar.gz";
const source_archive_name = std.fmt.comptimePrint("v{s}{s}", .{
    tool_options.toml_test_version,
    source_archive_extension,
});
const prebuilt_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .dragonfly },
    .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .arm, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .netbsd },
    .{ .cpu_arch = .x86_64, .os_tag = .openbsd },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};
const sha256_hashes = std.StaticStringMap(*const [Sha256.digest_length * 2]u8).initComptime(.{
    .{ "toml-test-v2.1.0-darwin-amd64.gz", "1dd1824df8002b03b3e52d32298a81748126c8ad4e2ce284d8bacd90b565919b" },
    .{ "toml-test-v2.1.0-darwin-arm64.gz", "a29a87115587a9e7c7fdd3663cc957f03fb07c768af0dd6a991cc90212484dbc" },
    .{ "toml-test-v2.1.0-dragonfly-amd64.gz", "2cb51f08b0bf13416f7350b7592d00c315466b369d6b6c9a6be1328b240d22c8" },
    .{ "toml-test-v2.1.0-freebsd-amd64.gz", "19009a6ffb72d24e74ee162e8b36da1c7c1d11feaf878e1981ca3704d3767f4f" },
    .{ "toml-test-v2.1.0-linux-amd64.gz", "99fd36c93b297ebde9719ec174266765f56a28924d7fca799d911f3f4354c25d" },
    .{ "toml-test-v2.1.0-linux-arm.gz", "3a8039dd6d6ecaf2648d97bc2dff630cbe5633dd0e1c0879fb624ba732b7bfac" },
    .{ "toml-test-v2.1.0-linux-arm64.gz", "fe250e7ad1e5ef8e0133940be48b550f40d33f839023bfbd7ef5382c38c4579c" },
    .{ "toml-test-v2.1.0-netbsd-amd64.gz", "e96e926dbdb095326e20f622fa1f68c67d37dd37a2c8943178f3002dd89680a9" },
    .{ "toml-test-v2.1.0-openbsd-amd64.gz", "abbab29054725ef20db885972fb506fdc23911d9c5145be7a9441297addc2532" },
    .{ "toml-test-v2.1.0-windows-amd64.exe.gz", "ceef53c4795cb103239e8f2a73408012435fc735fab38b2fdcdc7548839d5451" },
    .{ "toml-test-2.1.0.zip", "cb958470ec2f7a2501be94414fd118380a39ae51620c2311aa2bd0ea19ef08f4" },
    .{ "toml-test-2.1.0.tar.gz", "41d5a748b6942e535c43fc6d8a12ea7ecb6b24cb8bbe09adf929364099407741" },
});

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const cwd = Io.Dir.cwd();

    try cwd.createDirPath(init.io, tool_options.local_toml_test_path);

    if (try isInstalled(init.gpa, init.io, tool_options.local_toml_test_exe)) {
        try print(init.io, "toml-test version {s} already installed\n", .{tool_options.toml_test_version});
        return;
    }

    if (!tool_options.force_toml_test_from_source and hasPrebuilt()) {
        try installPrebuilt(init.gpa, init.io);
    } else {
        try installSource(init.gpa, init.io, init.environ_map);
    }

    if (try isInstalled(init.gpa, init.io, tool_options.local_toml_test_exe)) {
        try print(init.io, "toml-test version {s} installed\n", .{tool_options.toml_test_version});
        return;
    }

    return fail(init.io, "unknown error when installing toml-test\n", .{});
}

fn isInstalled(gpa: Allocator, io: Io, path: []const u8) !bool {
    if (Io.Dir.cwd().openFile(io, path, .{})) |f| {
        defer f.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {
            return false;
        },
        else => return err,
    }

    const run_result = try std.process.run(gpa, io, .{ .argv = &.{ path, "version" } });
    defer gpa.free(run_result.stderr);
    defer gpa.free(run_result.stdout);

    const trimmed = std.mem.trim(u8, run_result.stdout, " \n\r");
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    var next = it.next() orelse return fail(
        io,
        "unexpected 'toml-test version' output, first token not found:\n{s}\n",
        .{run_result.stdout},
    );
    if (!std.mem.eql(u8, next, "toml-test")) {
        return fail(
            io,
            "unexpected 'toml-test version' first token '{s}', expected 'toml-test':\n{s}\n",
            .{
                next,
                run_result.stdout,
            },
        );
    }

    next = it.next() orelse return fail(
        io,
        "unexpected 'toml-test version' output, second token not found:\n{s}\n",
        .{run_result.stdout},
    );
    next = std.mem.trimStart(u8, next, "v \n\r");
    next = std.mem.trimEnd(u8, next, "; \n\r");

    return std.mem.eql(u8, tool_options.toml_test_version, next);
}

fn hasPrebuilt() bool {
    for (prebuilt_targets) |target| {
        if (cpu_arch == target.cpu_arch and native_os == target.os_tag) {
            return true;
        }
    }

    return false;
}

fn installPrebuilt(gpa: Allocator, io: Io) !void {
    const fmt_base_url = try std.fmt.allocPrint(gpa, base_url, .{tool_options.toml_test_version});
    defer gpa.free(fmt_base_url);
    const url = try std.mem.concat(gpa, u8, &.{ fmt_base_url, "/", archive_name });
    defer gpa.free(url);

    try print(io, "downloading from {s}\n", .{url});

    const cwd = Io.Dir.cwd();

    const tmp_archive_name = "toml-test.gz";
    var tmp_dir = try file.makeTempDir(gpa, io, cwd, ".tmp-toml-test");
    defer tmp_dir.deinit(gpa, io, cwd);

    const tmp_archive_path = try Io.Dir.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
    defer gpa.free(tmp_archive_path);

    try print(io, "downloading to {s}\n", .{tmp_archive_path});

    try file.fetch(gpa, io, tmp_dir.dir, url, tmp_archive_name);

    try print(io, "verifying SHA256 checksum of {s}\n", .{tmp_archive_path});

    file.verifySha256(
        io,
        tmp_dir.dir,
        tmp_archive_name,
        sha256_hashes.get(archive_name) orelse return error.UnknownArtifact,
    ) catch |err| {
        const path = try Io.Dir.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
        defer gpa.free(path);
        return switch (err) {
            error.Reported => fail(io, "checking the SHA256 checksum of {s} failed\n", .{path}),
            else => fail(io, "checking the SHA256 checksum of {s} failed: {t}\n", .{ path, err }),
        };
    };

    try print(io, "extracting from {s} to {s}\n", .{ tmp_archive_path, tool_options.local_toml_test_exe });

    try file.extractGz(io, tmp_dir.dir, cwd, tmp_archive_name, tool_options.local_toml_test_exe);

    if (native_os != .windows) {
        const exe = try cwd.openFile(io, tool_options.local_toml_test_exe, .{});
        defer exe.close(io);
        try exe.setPermissions(io, .executable_file);
    }
}

fn installSource(gpa: Allocator, io: Io, environ_map: *std.process.Environ.Map) !void {
    try print(io, "installing 'toml-test' using Go\n", .{});

    const cwd = Io.Dir.cwd();

    var tmp_dir = try file.makeTempDir(gpa, io, cwd, ".tmp-go-install-toml-test");
    defer tmp_dir.deinit(gpa, io, cwd);

    const ldflags = try std.mem.concat(gpa, u8, &.{
        "-X \"zgo.at/zli.version=v",
        tool_options.toml_test_version,
        "\" ",
        "-X \"zgo.at/zli.progname=toml-test\"",
    });
    defer gpa.free(ldflags);

    try go.invoke(
        gpa,
        io,
        environ_map,
        &.{
            "install",
            "-ldflags",
            ldflags,
            go_install_url,
        },
        tmp_dir.name,
    );

    if (native_os != .windows) {
        try file.recursivelySetPermissions(io, tmp_dir.dir, @enumFromInt(0o755), @enumFromInt(0o644));
    }

    const tmp_bin = try Io.Dir.path.join(gpa, &.{ tmp_dir.name, "bin", tool_options.toml_test_exe_name });
    defer gpa.free(tmp_bin);

    try print(io, "moving 'toml-test' from '{s}' to '{s}'\n", .{ tmp_bin, tool_options.local_toml_test_exe });

    try cwd.rename(tmp_bin, cwd, tool_options.local_toml_test_exe, io);

    if (native_os != .windows) {
        const exe = try cwd.openFile(io, tool_options.local_toml_test_exe, .{});
        defer exe.close(io);
        try exe.setPermissions(io, .executable_file);
    }
}
