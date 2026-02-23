const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Sha256 = std.crypto.hash.sha2.Sha256;
const tool_options = @import("tool_options");

const file = @import("file.zig");
const go = @import("go.zig");
const fail = @import("output.zig").fail;
const print = @import("output.zig").print;

const cpu_arch = builtin.cpu.arch;
const native_os = builtin.os.tag;

const exe_name = if (native_os == .windows) "toml-test.exe" else "toml-test";
const exe_path = tool_options.toml_test_path ++ std.fs.path.sep_str ++ exe_name;
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

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const cwd = std.fs.cwd();

    try cwd.makePath(tool_options.toml_test_path);

    if (try isInstalled(gpa, exe_path)) {
        try print("toml-test version {s} already installed\n", .{tool_options.toml_test_version});
        return;
    }

    if (hasPrebuilt()) {
        try installPrebuilt(gpa);
    } else {
        try installSource(gpa);
    }

    if (try isInstalled(gpa, exe_path)) {
        try print("toml-test version {s} installed\n", .{tool_options.toml_test_version});
        return;
    }

    return fail("unknown error when installing toml-test\n", .{});
}

fn isInstalled(gpa: Allocator, path: []const u8) !bool {
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
    } else |err| switch (err) {
        error.FileNotFound => {
            return false;
        },
        else => return err,
    }

    var child_stdout: ArrayList(u8) = .empty;
    var child_stderr: ArrayList(u8) = .empty;
    defer child_stdout.deinit(gpa);
    defer child_stderr.deinit(gpa);

    var child = std.process.Child.init(&.{ path, "version" }, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer _ = child.kill() catch |err| switch (err) {
        error.AlreadyTerminated => {},
        else => @panic("failed to kill toml-test"),
    };

    try child.collectOutput(gpa, &child_stdout, &child_stderr, 256);
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        return error.TomlTestFailed;
    }

    const out = try child_stdout.toOwnedSlice(gpa);
    defer gpa.free(out);

    const trimmed = std.mem.trim(u8, out, " \n\r");
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    var next = it.next() orelse return fail(
        "unexpected 'toml-test version' output, first token not found:\n{s}\n",
        .{out},
    );
    if (!std.mem.eql(u8, next, "toml-test")) {
        return fail("unexpected 'toml-test version' first token '{s}', expected 'toml-test':\n{s}\n", .{ next, out });
    }

    next = it.next() orelse return fail(
        "unexpected 'toml-test version' output, second token not found:\n{s}\n",
        .{out},
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

fn installPrebuilt(gpa: Allocator) !void {
    const fmt_base_url = try std.fmt.allocPrint(gpa, base_url, .{tool_options.toml_test_version});
    defer gpa.free(fmt_base_url);
    const url = try std.mem.concat(gpa, u8, &.{ fmt_base_url, "/", archive_name });
    defer gpa.free(url);

    try print("downloading from {s}\n", .{url});

    const cwd = std.fs.cwd();

    const tmp_archive_name = "toml-test.gz";
    var tmp_dir = try file.makeTempDir(gpa, cwd, ".tmp-toml-test");
    defer tmp_dir.deinit(gpa, cwd);

    const tmp_archive_path = try std.fs.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
    defer gpa.free(tmp_archive_path);

    try print("downloading to {s}\n", .{tmp_archive_path});

    try file.fetch(gpa, tmp_dir.dir, url, tmp_archive_name);

    try print("verifying SHA256 checksum of {s}\n", .{tmp_archive_path});

    file.verifySha256(
        tmp_dir.dir,
        tmp_archive_name,
        sha256_hashes.get(archive_name) orelse return error.UnknownArtifact,
    ) catch |err| {
        const path = try std.fs.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
        defer gpa.free(path);
        return switch (err) {
            error.Reported => fail("checking the SHA256 checksum of {s} failed\n", .{path}),
            else => fail("checking the SHA256 checksum of {s} failed: {t}\n", .{ path, err }),
        };
    };

    try print("extracting from {s} to {s}\n", .{ tmp_archive_path, exe_path });

    try file.extractGz(tmp_dir.dir, cwd, tmp_archive_name, exe_path);

    if (native_os != .windows) {
        const exe = try cwd.openFile(exe_path, .{});
        defer exe.close();
        try exe.chmod(0o755);
    }
}

fn installSource(gpa: Allocator) !void {
    try print("installing 'toml-test' using Go\n", .{});

    const cwd = std.fs.cwd();

    var tmp_dir = try file.makeTempDir(gpa, cwd, ".tmp-go-install-toml-test");
    defer tmp_dir.deinit(gpa, cwd);

    const version_flag = try std.mem.concat(gpa, u8, &.{ "-X zgo.at/zli.version=v", tool_options.toml_test_version });
    defer gpa.free(version_flag);

    try go.invoke(gpa, &.{ "install", "-ldflags", version_flag, go_install_url }, tmp_dir.name);

    if (native_os != .windows) {
        try file.recursivelySetPermissions(tmp_dir.dir, 0o755, 0o644);
    }

    const tmp_bin = try std.fs.path.join(gpa, &.{ tmp_dir.name, "bin", exe_name });
    defer gpa.free(tmp_bin);

    try print("moving 'toml-test' from '{s}' to '{s}'\n", .{ tmp_bin, exe_path });

    try cwd.rename(tmp_bin, exe_path);

    if (native_os != .windows) {
        const exe = try cwd.openFile(exe_path, .{});
        defer exe.close();
        try exe.chmod(0o755);
    }
}
