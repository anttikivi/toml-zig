// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const Decoder = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Parser = @import("Parser.zig");
const Diagnostics = @import("root.zig").Diagnostics;
const default_version = @import("toml.zig").default_version;
const Version = @import("toml.zig").Version;
const Array = @import("value.zig").Array;
const Table = @import("value.zig").Table;
const Value = @import("value.zig").Value;

const Span = @import("root.zig").Span;

diagnostics: ?*Diagnostics,

tables: ArrayList(Table) = .empty,
arrays: ArrayList(Array) = .empty,
entries: ArrayList(Table.Entry) = .empty,
values: ArrayList(Value) = .empty,
strings: ArrayList(u8) = .empty,

header_path: ArrayList(Span) = .empty,

pub const Error = Allocator.Error || Diagnostics.Error || error{
    InputTooLarge,
};

pub const Options = struct {
    borrow: bool = false,
    toml_version: Version = default_version,
    diagnostics: ?*Diagnostics = null,
};

pub const Parsed = struct {
    root: usize,

    src: []const u8,
    owner: bool,

    tables: ArrayList(Table),
    arrays: ArrayList(Array),
};

pub fn decode(gpa: Allocator, input: []const u8, options: Options) Error!void {
    var decoder: Decoder = .{
        .diagnostics = options.diagnostics,
    };
    defer decoder.deinit(gpa);

    // Reserve first index for root.
    try decoder.tables.append(gpa, .{ .entries = .{ .start = 0, .end = 0 } });

    if (input.len > std.math.maxInt(u32)) {
        return decoder.fail(error.InputTooLarge, "input exceed 4GiB");
    }

    var parser: Parser = .init(input, .{
        .toml_version = options.toml_version,
        .diagnostics = options.diagnostics,
    });

    while (try parser.next()) |_| {}
}

fn deinit(self: *Decoder, gpa: Allocator) void {
    self.tables.deinit(gpa);
    self.arrays.deinit(gpa);
    self.entries.deinit(gpa);
    self.values.deinit(gpa);
    self.strings.deinit(gpa);

    self.header_path.deinit(gpa);
}

fn fail(self: Decoder, err: Error, msg: ?[]const u8) Error {
    assert(err != error.Reported);

    if (self.diagnostics) |diag| {
        diag.* = .{
            .position = self.tokenizer.position(),
            .message = if (msg) |m| m else switch (err) {
                error.InputTooLarge => "input too large",
                error.Reported => unreachable,
            },
        };

        return error.Reported;
    }

    return err;
}
