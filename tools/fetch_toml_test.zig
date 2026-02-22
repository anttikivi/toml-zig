const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");
const ArrayList = std.ArrayList;
const Sha256 = std.crypto.hash.sha2.Sha256;

const native_os = builtin.target.os.tag;

const base_url = "https://github.com/toml-lang/toml-test/releases/download/v{s}";
const sha256_hashes = std.StaticStringMap(*const [Sha256.digest_length * 2]u8).initComptime(.{
    .{
        "toml-test-v2.1.0-darwin-amd64.gz", "1dd1824df8002b03b3e52d32298a81748126c8ad4e2ce284d8bacd90b565919b",
    },
    .{
        "toml-test-v2.1.0-darwin-arm64.gz", "a29a87115587a9e7c7fdd3663cc957f03fb07c768af0dd6a991cc90212484dbc",
    },
    .{
        "toml-test-v2.1.0-dragonfly-amd64.gz", "2cb51f08b0bf13416f7350b7592d00c315466b369d6b6c9a6be1328b240d22c8",
    },
    .{
        "toml-test-v2.1.0-freebsd-amd64.gz", "19009a6ffb72d24e74ee162e8b36da1c7c1d11feaf878e1981ca3704d3767f4f",
    },
    .{
        "toml-test-v2.1.0-linux-amd64.gz", "99fd36c93b297ebde9719ec174266765f56a28924d7fca799d911f3f4354c25d",
    },
    .{
        "toml-test-v2.1.0-linux-arm.gz", "3a8039dd6d6ecaf2648d97bc2dff630cbe5633dd0e1c0879fb624ba732b7bfac",
    },
    .{
        "toml-test-v2.1.0-linux-arm64.gz", "fe250e7ad1e5ef8e0133940be48b550f40d33f839023bfbd7ef5382c38c4579c",
    },
    .{
        "toml-test-v2.1.0-netbsd-amd64.gz", "e96e926dbdb095326e20f622fa1f68c67d37dd37a2c8943178f3002dd89680a9",
    },
    .{
        "toml-test-v2.1.0-openbsd-amd64.gz", "abbab29054725ef20db885972fb506fdc23911d9c5145be7a9441297addc2532",
    },
    .{
        "toml-test-v2.1.0-windows-amd64.exe.gz", "ceef53c4795cb103239e8f2a73408012435fc735fab38b2fdcdc7548839d5451",
    },
});

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    var stdout = &stdout_writer.interface;

    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    var stderr = &stderr_writer.interface;

    const exe_name = if (native_os == .windows) "toml-test.exe" else "toml-test";
    const cwd = std.fs.cwd();

    try cwd.makePath(build_options.toml_test_path);

    const exe_path = try std.fs.path.join(gpa, &.{ build_options.toml_test_path, exe_name });
    defer gpa.free(exe_path);

    var found_exe = false;
    if (cwd.openFile(exe_path, .{})) |f| {
        defer f.close();
        found_exe = true;
    } else |err| switch (err) {
        error.FileNotFound => {
            try stdout.print("{s} not found, installing\n", .{exe_path});
            try stdout.flush();
        },
        else => return err,
    }

    if (found_exe) {
        var child_stdout: ArrayList(u8) = .empty;
        var child_stderr: ArrayList(u8) = .empty;
        defer child_stdout.deinit(gpa);
        defer child_stderr.deinit(gpa);

        var child = std.process.Child.init(&.{ exe_path, "version" }, gpa);
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
            try stderr.writeAll("'toml-test version' exited with non-zero status\n");
            try stderr.flush();
            return error.TomlTestFailed;
        }

        const out = try child_stdout.toOwnedSlice(gpa);
        defer gpa.free(out);

        const trimmed = std.mem.trim(u8, out, " \n\r");
        var it = std.mem.splitScalar(u8, trimmed, ' ');
        var next = it.next() orelse {
            try stderr.writeAll("unexpected 'toml-test version' output, first token not found:\n");
            try stderr.writeAll(out);
            try stderr.flush();
            return error.TomlTestOutput;
        };
        if (!std.mem.eql(u8, next, "toml-test")) {
            try stderr.print("unexpected 'toml-test version' first token '{s}', expected 'toml-test':\n", .{next});
            try stderr.writeAll(out);
            try stderr.flush();
            return error.TomlTestOutput;
        }

        next = it.next() orelse {
            try stderr.writeAll("unexpected 'toml-test version' output, second token not found:\n");
            try stderr.writeAll(out);
            try stderr.flush();
            return error.TomlTestOutput;
        };
        next = std.mem.trimStart(u8, next, "v \n\r");
        next = std.mem.trimEnd(u8, next, "; \n\r");

        if (std.mem.eql(u8, build_options.toml_test_version, next)) {
            try stdout.print("toml-test version {s} already installed\n", .{build_options.toml_test_version});
            try stdout.flush();
            return;
        }
    }

    const rand_int = std.crypto.random.int(u64);
    const tmp_dir_name = ".tmp-toml-test." ++ std.fmt.hex(rand_int);
    try cwd.makePath(tmp_dir_name);
    defer cwd.deleteTree(tmp_dir_name) catch @panic("failed to delete temporary directory");

    const archive_name = try std.fmt.allocPrint(gpa, "toml-test-v{[version]s}-{[os]s}-{[arch]s}{[extension]s}", .{
        .version = build_options.toml_test_version,
        .os = switch (native_os) {
            .macos => "darwin",
            else => |t| @tagName(t),
        },
        .arch = switch (builtin.target.cpu.arch) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            .arm => "arm",
            else => |t| {
                try stderr.print("architecture '{t}' is not supported\n", .{t});
                try stderr.flush();
                return error.UnsupportedPlatform;
            },
        },
        .extension = switch (native_os) {
            .windows => ".exe.gz",
            else => ".gz",
        },
    });
    defer gpa.free(archive_name);

    const fmt_base_url = try std.fmt.allocPrint(gpa, base_url, .{build_options.toml_test_version});
    defer gpa.free(fmt_base_url);
    const url = try std.mem.concat(gpa, u8, &.{ fmt_base_url, "/", archive_name });
    defer gpa.free(url);

    try stdout.print("downloading from {s}\n", .{url});
    try stdout.flush();

    var tmp_dir = try cwd.openDir(tmp_dir_name, .{});
    defer tmp_dir.close();

    var archive_closed = false;
    var toml_test_archive = try tmp_dir.createFile("toml-test.gz", .{ .exclusive = true, .truncate = true });
    defer if (!archive_closed) toml_test_archive.close();

    var archive_buffer: [1024]u8 = undefined;
    var archive_writer = toml_test_archive.writer(&archive_buffer);

    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const download_result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &archive_writer.interface,
    });

    if (download_result.status != .ok) {
        try stderr.print("failed to download, status {d}\n", .{download_result.status});
        try stderr.flush();
        return error.DownloadFailed;
    }

    try archive_writer.interface.flush();
    toml_test_archive.close();
    archive_closed = true;

    var sha_closed = false;
    var sha_file = try tmp_dir.openFile("toml-test.gz", .{});
    defer if (!sha_closed) sha_file.close();

    var sha_buf: [1024]u8 = undefined;
    var sha_reader = sha_file.reader(&sha_buf);

    var hasher = Sha256.init(.{});
    var hash_buf: [1024]u8 = undefined;
    while (true) {
        const n = try sha_reader.interface.readSliceShort(&hash_buf);
        if (n == 0) {
            break;
        }
        hasher.update(hash_buf[0..n]);
    }

    const digest: [Sha256.digest_length]u8 = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, sha256_hashes.get(archive_name) orelse return error.UnknownArtifact)) {
        try stderr.writeAll("checksum of the downloaded file does not match\n");
        try stderr.print("expected '{s}', got '{s}'\n", .{ sha256_hashes.get(archive_name).?, hex });
        try stderr.flush();
        return error.InvalidSha256;
    }

    sha_file.close();
    sha_closed = true;

    var input_file = try tmp_dir.openFile("toml-test.gz", .{});
    defer input_file.close();

    var output_file = try cwd.createFile(exe_path, .{ .truncate = true });
    defer output_file.close();

    var input_buf: [1024]u8 = undefined;
    var output_buf: [1024]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    var output_writer = output_file.writer(&output_buf);

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input_reader.interface, .gzip, &decompress_buf);

    _ = try decompress.reader.streamRemaining(&output_writer.interface);
    try output_writer.interface.flush();

    if (native_os != .windows) {
        try output_file.chmod(0o755);
    }
}
