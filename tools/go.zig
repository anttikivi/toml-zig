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
const fail = @import("output.zig").fail;
const print = @import("output.zig").print;

const cpu_arch = builtin.cpu.arch;
const native_os = builtin.os.tag;

const go_version: std.SemanticVersion = .{ .major = 1, .minor = 26, .patch = 0 };
const min_go_version: std.SemanticVersion = .{ .major = 1, .minor = 25, .patch = 0 };
const max_go_version: std.SemanticVersion = .{ .major = 1, .minor = 27, .patch = 0 };

const exe_name = if (native_os == .windows) "go.exe" else "go";
const exe_path = tool_options.go_path ++ Io.Dir.path.sep_str ++ "bin" ++ Io.Dir.path.sep_str ++ exe_name;
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

pub fn invoke(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    args: []const []const u8,
    gopath: []const u8,
) !void {
    const exe = try getOrInstallExecutable(gpa, io);

    const argv = try gpa.alloc([]const u8, args.len + 1);
    defer gpa.free(argv);

    argv[0] = exe;
    for (args, 0..) |arg, i| {
        argv[i + 1] = arg;
    }

    const absolute_gopath = try Io.Dir.cwd().realPathFileAlloc(io, gopath, gpa);
    defer gpa.free(absolute_gopath);

    try environ_map.put("GOPATH", absolute_gopath);

    const joined_argv = try std.mem.join(gpa, " ", argv);
    defer gpa.free(joined_argv);

    try print(io, "+ {s}\n", .{joined_argv});

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
    });

    const term = try child.wait(io);

    if (term != .exited or term.exited != 0) {
        return error.GoFailed;
    }
}

fn getOrInstallExecutable(gpa: Allocator, io: Io) ![]const u8 {
    if (try hasLocalGo(gpa, io, exe_path)) {
        return exe_path;
    }

    if (hasCorrectVersion(gpa, io, system_go) catch false) {
        return system_go;
    }

    const url = try std.mem.concat(gpa, u8, &.{ base_url, "/", archive_name });
    defer gpa.free(url);

    try print(io, "downloading Go from {s}\n", .{url});

    const cwd = Io.Dir.cwd();

    var go_dir = try cwd.createDirPathOpen(io, tool_options.go_path, .{});
    defer go_dir.close(io);

    const tmp_archive_name = "go" ++ archive_extension;
    var tmp_dir = try file.makeTempDir(gpa, io, cwd, ".tmp-go");
    defer tmp_dir.deinit(gpa, io, cwd);

    const tmp_archive_path = try Io.Dir.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
    defer gpa.free(tmp_archive_path);

    try print(io, "downloading Go to {s}\n", .{tmp_archive_path});

    try file.fetch(gpa, io, tmp_dir.dir, url, tmp_archive_name);

    try print(io, "verifying SHA256 checksum of {s}\n", .{tmp_archive_path});

    file.verifySha256(
        io,
        tmp_dir.dir,
        tmp_archive_name,
        sha256_hashes.get(archive_name) orelse return fail(io, "unknown Go artifact: {s}\n", .{archive_name}),
    ) catch |err| {
        const path = try Io.Dir.path.join(gpa, &.{ tmp_dir.name, tmp_archive_name });
        defer gpa.free(path);
        return switch (err) {
            error.Reported => fail(io, "checking the SHA256 checksum of {s} failed\n", .{path}),
            else => fail(io, "checking the SHA256 checksum of {s} failed: {t}\n", .{ path, err }),
        };
    };

    var extract_dir = try file.makeTempDir(gpa, io, cwd, ".tmp-extract-go");
    defer extract_dir.deinit(gpa, io, cwd);

    try print(io, "extracting from {s} to {s}\n", .{ tmp_archive_path, extract_dir.name });

    if (file.exists(io, cwd, tool_options.go_path)) {
        try cwd.deleteTree(io, tool_options.go_path);
    }

    if (std.mem.eql(u8, archive_extension, ".zip")) {
        try file.extractZip(io, tmp_dir.dir, extract_dir.dir, tmp_archive_name);
    } else if (std.mem.eql(u8, archive_extension, ".tar.gz")) {
        try file.extractTarGz(gpa, io, tmp_dir.dir, extract_dir.dir, tmp_archive_name);
    } else {
        @panic("unknown archive extension: " ++ archive_extension);
    }

    try cwd.createDirPath(io, Io.Dir.path.dirname(tool_options.go_path).?);

    const extracted_go_path = try Io.Dir.path.join(gpa, &.{ extract_dir.name, "go" });
    defer gpa.free(extracted_go_path);

    try cwd.rename(extracted_go_path, cwd, tool_options.go_path, io);

    if (native_os != .windows) {
        const exe = try cwd.openFile(io, exe_path, .{});
        defer exe.close(io);
        try exe.setPermissions(io, .executable_file);
    }

    return exe_path;
}

fn hasLocalGo(gpa: Allocator, io: Io, path: []const u8) !bool {
    if (Io.Dir.cwd().openFile(io, path, .{})) |f| {
        defer f.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {
            return false;
        },
        else => return err,
    }

    return hasCorrectVersion(gpa, io, path) catch false;
}

fn hasCorrectVersion(gpa: Allocator, io: Io, go: []const u8) !bool {
    const run_result = std.process.run(gpa, io, .{ .argv = &.{ go, "version" } }) catch return false;
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);

    const trimmed = std.mem.trim(u8, run_result.stdout, " \n\r");
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    var next = it.next() orelse return fail(
        io,
        "unexpected 'go version' output, first token not found:\n{s}\n",
        .{run_result.stdout},
    );
    if (!std.mem.eql(u8, next, "go")) {
        return fail(
            io,
            "unexpected 'go version' first token '{s}', expected 'go':\n{s}\n",
            .{ next, run_result.stdout },
        );
    }

    next = it.next() orelse return fail(
        io,
        "unexpected 'go version' output, second token not found:\n{s}\n",
        .{run_result.stdout},
    );
    if (!std.mem.eql(u8, next, "version")) {
        return fail(
            io,
            "unexpected 'go version' second token '{s}', expected 'version':\n{s}\n",
            .{ next, run_result.stdout },
        );
    }

    next = it.next() orelse return fail(
        io,
        "unexpected 'go version' output, third token not found:\n{s}\n",
        .{run_result.stdout},
    );
    next = next[2..];
    next = std.mem.trimStart(u8, next, " \n\r");
    next = std.mem.trimEnd(u8, next, " \n\r");

    const current_version = try std.SemanticVersion.parse(next);

    const min_order = std.SemanticVersion.order(current_version, min_go_version);
    const max_order = std.SemanticVersion.order(current_version, max_go_version);

    return min_order != .lt and max_order != .gt;
}
