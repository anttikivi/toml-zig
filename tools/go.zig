const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Sha256 = std.crypto.hash.sha2.Sha256;
const tool_options = @import("tool_options");

const file = @import("file.zig");
const fail = @import("output.zig").fail;
const print = @import("output.zig").print;

const cpu_arch = builtin.cpu.arch;
const native_os = builtin.os.tag;

const go_version: std.SemanticVersion = .{ .major = 1, .minor = 26, .patch = 0 };
const min_go_version: std.SemanticVersion = .{ .major = 1, .minor = 25, .patch = 0 };
const max_go_version: std.SemanticVersion = .{ .major = 1, .minor = 27, .patch = 0 };

const exe_name = if (native_os == .windows) "go.exe" else "go";
const exe_path = tool_options.go_path ++ std.fs.path.sep_str ++ "bin" ++ std.fs.path.sep_str ++ exe_name;
const system_go = "go";
const base_url = "https://go.dev/dl";
const archive_extension = switch (native_os) {
    .windows => ".zip",
    else => ".tar.gz",
};
const archive_name = std.fmt.comptimePrint("go{[version]f}.{[os]s}-{[arch]s}{[extension]s}", .{
    .version = go_version,
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
    .extension = archive_extension,
});
// https://go.dev/dl/?mode=json&include=all
const sha256_hashes = std.StaticStringMap(*const [Sha256.digest_length * 2]u8).initComptime(.{
    .{ "go1.26.0.darwin-amd64.tar.gz", "1ca28b7703cbea05a65b2a1d92d6b308610ef92f8824578a0874f2e60c9d5a22" },
    .{ "go1.26.0.darwin-arm64.tar.gz", "b1640525dfe68f066d56f200bef7bf4dce955a1a893bd061de6754c211431023" },
    .{ "go1.26.0.freebsd-amd64.tar.gz", "7bba5a430d2c562af87b6c1a31cccf72c43107b7318b48aa8a02441df61acd08" },
    .{ "go1.26.0.freebsd-arm64.tar.gz", "5d92e2d65a543811dca9f76a2b533cbdc051bdd5015bf789b137e2dcc33b2d52" },
    .{ "go1.26.0.linux-amd64.tar.gz", "aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235" },
    .{ "go1.26.0.linux-arm64.tar.gz", "bd03b743eb6eb4193ea3c3fd3956546bf0e3ca5b7076c8226334afe6b75704cd" },
    .{ "go1.26.0.netbsd-amd64.tar.gz", "22fc488ddd2c5958378fba2560866d6dae298160ba198e51ca5b998dc77b92f1" },
    .{ "go1.26.0.netbsd-arm.tar.gz", "1c70fd89c12dfda71f755dae1d7796f14702442b50ef2831117a641358276c5a" },
    .{ "go1.26.0.netbsd-arm64.tar.gz", "379d6ef6dfa8b67a7776744a536e69a1dc0fe5aeed48eb882ac71f89a98ba8ab" },
    .{ "go1.26.0.windows-amd64.zip", "9bbe0fc64236b2b51f6255c05c4232532b8ecc0e6d2e00950bd3021d8a4d07d4" },
    .{ "go1.26.0.windows-arm64.zip", "73bdbb9f64aa152758024485c5243a1098182bb741fcc603b6fb664ee5e0fe35" },
});

pub fn invoke(gpa: Allocator, args: []const []const u8, gopath: []const u8) !void {
    const exe = try getOrInstallExecutable(gpa);

    const argv = try gpa.alloc([]const u8, args.len + 1);
    defer gpa.free(argv);

    argv[0] = exe;
    for (args, 0..) |arg, i| {
        argv[i + 1] = arg;
    }

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const absolute_gopath = try std.fs.cwd().realpathAlloc(gpa, gopath);
    defer gpa.free(absolute_gopath);

    try env_map.put("GOPATH", absolute_gopath);

    const joined_argv = try std.mem.join(gpa, " ", argv);
    defer gpa.free(joined_argv);

    try print("+ {s}\n", .{joined_argv});

    var child = std.process.Child.init(argv, gpa);
    child.env_map = &env_map;

    try child.spawn();
    errdefer _ = child.kill() catch |err| switch (err) {
        error.AlreadyTerminated => {},
        else => @panic("failed to kill go"),
    };

    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        return error.GoFailed;
    }
}

fn getOrInstallExecutable(gpa: Allocator) ![]const u8 {
    if (try hasLocalGo(gpa, exe_path)) {
        return exe_path;
    }

    if (try hasSystemGo(gpa)) {
        return system_go;
    }

    const url = try std.mem.concat(gpa, u8, &.{ base_url, "/", archive_name });
    defer gpa.free(url);

    try print("downloading Go from {s}\n", .{url});

    const cwd = std.fs.cwd();

    var go_dir = try cwd.makeOpenPath(tool_options.go_path, .{});
    defer go_dir.close();

    const tmp_archive_name = "go" ++ archive_extension;
    var tmp_dir = try file.makeTempDir(gpa, cwd, ".tmp-go");
    defer tmp_dir.deinit(gpa, cwd);

    const tmp_archive_path = try std.fs.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
    defer gpa.free(tmp_archive_path);

    try print("downloading Go to {s}\n", .{tmp_archive_path});

    try file.fetch(gpa, tmp_dir.dir, url, tmp_archive_name);

    try print("verifying SHA256 checksum of {s}\n", .{tmp_archive_path});

    file.verifySha256(
        tmp_dir.dir,
        tmp_archive_name,
        sha256_hashes.get(archive_name) orelse return fail("unknown Go artifact: {s}\n", .{archive_name}),
    ) catch |err| {
        const path = try std.fs.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
        defer gpa.free(path);
        return switch (err) {
            error.Reported => fail("checking the SHA256 checksum of {s} failed\n", .{path}),
            else => fail("checking the SHA256 checksum of {s} failed: {t}\n", .{ path, err }),
        };
    };

    var extract_dir = try file.makeTempDir(gpa, cwd, ".tmp-extract-go");
    defer extract_dir.deinit(gpa, cwd);

    try print("extracting from {s} to {s}\n", .{ tmp_archive_path, extract_dir.name });

    if (file.exists(cwd, tool_options.go_path)) {
        try cwd.deleteTree(tool_options.go_path);
    }

    if (std.mem.eql(u8, archive_extension, ".zip")) {
        try file.extractZip(tmp_dir.dir, extract_dir.dir, tmp_archive_name);
    } else if (std.mem.eql(u8, archive_extension, ".tar.gz")) {
        try file.extractTarGz(gpa, tmp_dir.dir, extract_dir.dir, tmp_archive_name);
    } else {
        @panic("unknown archive extension: " ++ archive_extension);
    }

    try cwd.makePath(std.fs.path.dirname(tool_options.go_path).?);

    const extracted_go_path = try std.fs.path.join(gpa, &.{ extract_dir.name, "go" });
    defer gpa.free(extracted_go_path);

    try cwd.rename(extracted_go_path, tool_options.go_path);

    if (native_os != .windows) {
        const exe = try cwd.openFile(exe_path, .{});
        defer exe.close();
        try exe.chmod(0o755);
    }

    return exe_path;
}

fn hasLocalGo(gpa: Allocator, path: []const u8) !bool {
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
    } else |err| switch (err) {
        error.FileNotFound => {
            return false;
        },
        else => return err,
    }

    const out = captureStdout(gpa, &.{ path, "version" }) catch return false;
    defer gpa.free(out);

    return hasCorrectVersion(out) catch return false;
}

fn hasSystemGo(gpa: Allocator) !bool {
    const out = captureStdout(gpa, &.{ system_go, "version" }) catch return false;
    defer gpa.free(out);

    return hasCorrectVersion(out) catch return false;
}

fn captureStdout(gpa: Allocator, argv: []const []const u8) ![]const u8 {
    var child_stdout: ArrayList(u8) = .empty;
    var child_stderr: ArrayList(u8) = .empty;
    defer child_stdout.deinit(gpa);
    defer child_stderr.deinit(gpa);

    var child = std.process.Child.init(argv, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer _ = child.kill() catch |err| switch (err) {
        error.AlreadyTerminated => {},
        else => @panic("failed to kill go"),
    };

    try child.collectOutput(gpa, &child_stdout, &child_stderr, 256);
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        return error.GoFailed;
    }

    return child_stdout.toOwnedSlice(gpa);
}

fn hasCorrectVersion(cmd_output: []const u8) !bool {
    const trimmed = std.mem.trim(u8, cmd_output, " \n\r");
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    var next = it.next() orelse return fail(
        "unexpected 'go version' output, first token not found:\n{s}\n",
        .{cmd_output},
    );
    if (!std.mem.eql(u8, next, "go")) {
        return fail("unexpected 'go version' first token '{s}', expected 'go':\n{s}\n", .{ next, cmd_output });
    }

    next = it.next() orelse return fail(
        "unexpected 'go version' output, second token not found:\n{s}\n",
        .{cmd_output},
    );
    if (!std.mem.eql(u8, next, "version")) {
        return fail("unexpected 'go version' second token '{s}', expected 'version':\n{s}\n", .{ next, cmd_output });
    }

    next = it.next() orelse return fail(
        "unexpected 'go version' output, third token not found:\n{s}\n",
        .{cmd_output},
    );
    next = next[2..];
    next = std.mem.trimStart(u8, next, " \n\r");
    next = std.mem.trimEnd(u8, next, " \n\r");

    const current_version = try std.SemanticVersion.parse(next);

    const min_order = std.SemanticVersion.order(current_version, min_go_version);
    const max_order = std.SemanticVersion.order(current_version, max_go_version);

    return min_order != .lt and max_order != .gt;
}
