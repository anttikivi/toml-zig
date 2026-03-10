// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fail = @import("output.zig").fail;
const print = @import("output.zig").print;

pub const MakeTempDirResult = struct {
    dir: Io.Dir,
    name: []const u8,

    pub fn deinit(self: *@This(), gpa: Allocator, io: Io, dir: Io.Dir) void {
        self.dir.close(io);
        dir.deleteTree(io, self.name) catch @panic("failed to delete temporary directory");
        gpa.free(self.name);
    }
};

pub fn exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

pub fn extractGz(io: Io, input_dir: Io.Dir, output_dir: Io.Dir, input_path: []const u8, output_path: []const u8) !void {
    var input = try input_dir.openFile(io, input_path, .{});
    defer input.close(io);

    var output = try output_dir.createFile(io, output_path, .{ .truncate = true });
    defer output.close(io);

    var input_buf: [1024]u8 = undefined;
    var output_buf: [1024]u8 = undefined;
    var input_reader = input.reader(io, &input_buf);
    var output_writer = output.writer(io, &output_buf);

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input_reader.interface, .gzip, &decompress_buf);

    _ = try decompress.reader.streamRemaining(&output_writer.interface);
    try output_writer.interface.flush();
}

pub fn extractTarGz(gpa: Allocator, io: Io, input_dir: Io.Dir, output_dir: Io.Dir, input_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var tmp_dir = try makeTempDir(gpa, io, cwd, ".tmp-tar-gz");
    defer tmp_dir.deinit(gpa, io, cwd);

    const tmp_file_path = ".tmp.tar";
    try extractGz(io, input_dir, tmp_dir.dir, input_path, tmp_file_path);

    var input = try tmp_dir.dir.openFile(io, tmp_file_path, .{});
    defer input.close(io);

    var input_buf: [1024]u8 = undefined;
    var input_reader = input.reader(io, &input_buf);

    try std.tar.pipeToFileSystem(io, output_dir, &input_reader.interface, .{});
}

pub fn extractZip(io: Io, input_dir: Io.Dir, output_dir: Io.Dir, input_path: []const u8) !void {
    var input = try input_dir.openFile(io, input_path, .{});
    defer input.close(io);

    var input_buf: [1024]u8 = undefined;
    var input_reader = input.reader(io, &input_buf);

    try std.zip.extract(output_dir, &input_reader, .{});
}

pub fn fetch(gpa: Allocator, io: Io, dir: Io.Dir, url: []const u8, dest: []const u8) !void {
    var file = try dir.createFile(io, dest, .{ .exclusive = true, .truncate = true });
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const download_result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });

    if (download_result.status != .ok) {
        return fail(io, "failed to download, status {d}\n", .{download_result.status});
    }

    try writer.interface.flush();
}

pub fn makeTempDir(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) !MakeTempDirResult {
    const rand_src: std.Random.IoSource = .{ .io = io };
    const rand = rand_src.interface();
    const rand_int = rand.int(u64);
    const dir_name = try std.mem.concat(gpa, u8, &.{ name, ".", &std.fmt.hex(rand_int) });
    return .{
        .dir = try dir.createDirPathOpen(
            io,
            dir_name,
            .{
                .open_options = .{
                    .iterate = true,
                },
            },
        ),
        .name = dir_name,
    };
}

pub fn recursivelySetPermissions(
    io: Io,
    dir: Io.Dir,
    dir_mode: Io.Dir.Permissions,
    file_mode: Io.File.Permissions,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var d = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer d.close(io);
                try d.setPermissions(io, dir_mode);

                try recursivelySetPermissions(io, d, dir_mode, file_mode);
            },
            .file => {
                var f = try dir.openFile(io, entry.name, .{});
                defer f.close(io);
                try f.setPermissions(io, file_mode);
            },
            else => {},
        }
    }
}

pub fn verifySha256(io: Io, dir: Io.Dir, path: []const u8, expected: *const [Sha256.digest_length * 2]u8) !void {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);

    var hasher = Sha256.init(.{});
    var hash_buf: [1024]u8 = undefined;
    var n = try reader.interface.readSliceShort(&hash_buf);
    while (n != 0) {
        hasher.update(hash_buf[0..n]);
        n = try reader.interface.readSliceShort(&hash_buf);
    }

    const digest: [Sha256.digest_length]u8 = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected)) {
        return fail(io, "SHA256 checksums did not match: expected '{s}', got '{s}'\n", .{ expected, hex });
    }
}
