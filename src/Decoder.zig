// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const Decoder = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Parser = @import("Parser.zig");
const Item = @import("Parser.zig").Item;
const Diagnostics = @import("root.zig").Diagnostics;
const Span = @import("root.zig").Span;
const default_version = @import("toml.zig").default_version;
const Features = @import("toml.zig").Features;
const Version = @import("toml.zig").Version;
const Array = @import("value.zig").Array;
const String = @import("value.zig").String;
const Table = @import("value.zig").Table;
const TableIndex = @import("value.zig").TableIndex;
const Value = @import("value.zig").Value;

borrow: bool,
result: Parsed,
features: Features,
diagnostics: ?*Diagnostics,

current_table: TableIndex = .root,
current_header: ArrayList(HeaderPart) = .empty,

/// Build-time information on the TOML tables. Its indices must run in parallel to the table
/// indices.
table_states: std.MultiArrayList(TableState) = .empty,

pub const Error = Allocator.Error || Diagnostics.Error || std.fmt.ParseIntError || error{
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
} || error{
    InputTooLarge,
    NotTable,
};

pub const Options = struct {
    /// Whether to borrow the string values from the input slice where possible instead of copying
    /// them.
    borrow: bool = false,
    toml_version: Version = default_version,
    diagnostics: ?*Diagnostics = null,
};

pub const Parsed = struct {
    arena: *ArenaAllocator,
    input: []const u8,

    tables: ArrayList(Table) = .empty,
    arrays: ArrayList(Array) = .empty,
    entries: ArrayList(Table.Entry) = .empty,
    values: ArrayList(Value) = .empty,
    strings: ArrayList(u8) = .empty,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.arena.* = undefined;
        self.* = undefined;
    }
};

const HeaderPart = struct {
    key: String,
    array: bool = false,
};

const TableState = struct {
    /// Collection of entries of this table. They will be inserted to the result type list at
    /// the end to preserve order.
    entries: ArrayList(Table.Entry) = .empty,
    def: Definition,

    const Self = @This();

    const Definition = enum {
        root,
        header,
        implicit,
    };

    fn append(self: *Self, gpa: Allocator, key: String, value: Value) Allocator.Error!void {
        try self.entries.append(gpa, .{ .key = key, .value = value });
    }
};

pub fn decode(gpa: Allocator, input: []const u8, options: Options) Error!Parsed {
    var self: Decoder = .{
        .borrow = options.borrow,
        .result = .{
            .arena = .init(gpa),
            .input = input,
        },
        .features = .init(options.toml_version),
        .diagnostics = options.diagnostics,
    };
    errdefer self.result.deinit();
    defer self.deinit(gpa);

    const arena = self.result.arena.allocator();

    // Reserve first index for root.
    try self.result.tables.append(arena, .{ .entries = .{ .start = 0, .end = 0 } });
    try self.table_states.append(gpa, .{ .def = .root });

    if (input.len > std.math.maxInt(u32)) {
        return self.fail(error.InputTooLarge, "input exceed 4GiB");
    }

    var parser: Parser = .init(input, .{
        .toml_version = options.toml_version,
        .diagnostics = options.diagnostics,
    });

    while (try parser.next()) |item| {
        switch (item.tag) {
            // TODO:
            .table_header_start => {},
            .table_key, .array_table_key => self.current_header.append(gpa, .{
                .key = try self.takeKey(arena, item),
            }),
            .table_header_end => {
                assert(self.current_header.items.len > 0);
                self.current_table = self.resolveHeader(gpa, arena);
                assert(self.current_table != .root);
            },
            .array_table_header_end => {
                assert(self.current_header.items.len > 0);
            },
        }
    }

    return self.result;
}

fn deinit(self: *Decoder, gpa: Allocator) void {
    self.current_header.deinit(gpa);
    self.table_states.deinit(gpa);
}

fn takeKey(self: *Decoder, arena: Allocator, item: Item) Error!String {
    return switch (item.value) {
        .literal, .literal_string => blk: {
            if (self.borrow) {
                break :blk .{ .borrowed = item.span };
            } else {
                const span = item.span;
                const start = self.result.strings.items.len;
                const end = start + span.len();
                try self.result.strings.appendSlice(arena, self.result.input[span.start..span.end]);
                break :blk .{ .owned = .{ .start = start, .end = end } };
            }
        },
        .string => try self.decodeString(arena, item),
        else => unreachable,
    };
}

/// Resolve the table attached to the current table header by creating or looking up
/// the intermediate tables and the final table.
fn resolveHeader(self: *Decoder, gpa: Allocator, arena: Allocator) Error!void {
    assert(self.current_header.items.len > 0);

    var current: TableIndex = .root;
    for (self.current_header.items[0 .. self.current_header.items.len - 1]) |key| {
        current = try self.getOrCreateTable(gpa, arena, current, key.key);
    }

    const final_key = self.current_header.items[self.current_header.items.len - 1];

    if (try self.findTable(current, final_key.key)) |existing| {
        const ts = self.table_states.get(existing);
        switch (ts.def) {
            .implicit => {
                ts.def = .header;
                return existing;
            },
            .root => unreachable,
            else => return self.fail(error.InvalidTableDefinition, "invalid redefinition of table"),
        }
    }

    const i = try self.createTable(gpa, arena, .header);
    try self.appendTable(gpa, current, final_key.key, .{ .table = i });

    return i;
}

/// Find or create the implicit, intermediate table from the given parent table.
fn getOrCreateTable(
    self: *Decoder,
    gpa: Allocator,
    arena: Allocator,
    parent: TableIndex,
    key: String,
) Error!TableIndex {
    if (try self.findTable(parent, key.slice(self.result))) |existing| {
        const ts = self.table_states.get(existing);
        switch (ts.def) {
            .implicit, .header => return existing,
            .root => unreachable,
            else => return self.fail(error.InvalidTableDefinition, "invalid redefinition of table"),
        }
    }

    const i = try self.createTable(gpa, arena, .implicit);
    try self.appendTable(gpa, parent, key, .{ .table = i });

    return i;
}

fn findTable(self: Decoder, parent: TableIndex, name: []const u8) Error!?TableIndex {
    const ts = self.table_states.get(parent);
    for (ts.entries.items) |entry| {
        if (std.mem.eql(u8, name, entry.key.slice(self.result))) {
            return switch (entry.value) {
                .table => |t| t,
                else => self.fail(error.NotTable, null),
            };
        }
    }

    return null;
}

fn createTable(
    self: *Decoder,
    gpa: Allocator,
    arena: Allocator,
    def: TableState.Definition,
) Allocator.Error!TableIndex {
    assert(self.result.tables.items.len == self.table_states.len);

    const i: TableIndex = @enumFromInt(self.result.tables.items.len);

    try self.result.tables.append(arena, .{ .entries = .{ .start = 0, .end = 0 } });
    try self.table_states.append(gpa, .{ .def = def });

    assert(self.result.tables.items.len == self.table_states.len);

    return i;
}

fn appendTable(
    self: *Decoder,
    gpa: Allocator,
    table: TableIndex,
    key: String,
    value: Value,
) Allocator.Error!void {
    const ts = self.table_states.get(table);
    try ts.append(gpa, key, value);
}

fn decodeString(self: *Decoder, arena: Allocator, item: Item) Error!String {
    const buf = self.result.input[item.span.start..self.span.end];
    var i = std.mem.findScalar(u8, buf, '\\');
    if (self.borrow and i == null) {
        return .{ .borrowed = item.span };
    }

    const start = self.result.strings.items.len;

    try self.result.strings.appendSlice(arena, buf[0..i]);

    while (std.mem.findScalarPos(u8, buf, i, '\\')) |j| {
        assert(j + 1 < buf.len);

        if (i != j) {
            try self.result.strings.appendSlice(arena, buf[i..j]);
        }

        j += 1;
        const c = buf[j];
        switch (c) {
            '"', '\\' => {},
            'b' => {
                try self.result.strings.append(arena, 8);
                j += 1;
            },
            'f' => {
                try self.result.strings.append(arena, 12);
                j += 1;
            },
            't' => {
                try self.result.strings.append(arena, '\t');
                j += 1;
            },
            'r' => {
                try self.result.strings.append(arena, '\r');
                j += 1;
            },
            'n' => {
                try self.result.strings.append(arena, '\n');
                j += 1;
            },
            'e' => {
                assert(self.features.escape_e);
                try self.result.strings.append(arena, 27);
                j += 1;
            },
            'x' => {
                assert(self.features.escape_xhh);
                assert(j + 2 < buf.len);

                j += 1;

                const hex = buf[j .. j + 2];
                const codepoint = std.fmt.parseInt(u8, hex, 16) catch |err| {
                    return self.fail(err, null);
                };
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &b) catch |err| {
                    return self.fail(err, null);
                };
                try self.result.strings.appendSlice(arena, b[0..n]);
                j += 2;
            },
            'u' => {
                assert(j + 4 < buf.len);

                j += 1;

                const hex = buf[j .. j + 4];
                const codepoint = std.fmt.parseInt(u8, hex, 16) catch |err| {
                    return self.fail(err, null);
                };
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &b) catch |err| {
                    return self.fail(err, null);
                };
                try self.result.strings.appendSlice(arena, b[0..n]);
                j += 4;
            },
            'U' => {
                assert(j + 8 < buf.len);

                j += 1;

                const hex = buf[j .. j + 8];
                const codepoint = std.fmt.parseInt(u8, hex, 16) catch |err| {
                    return self.fail(err, null);
                };
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &b) catch |err| {
                    return self.fail(err, null);
                };
                try self.result.strings.appendSlice(arena, b[0..n]);
                j += 8;
            },
            ' ', '\t', '\r', '\n' => switch (item.value) {
                .multiline_string => {
                    while (j < buf.len and
                        (buf[j] == ' ' or
                            buf[j] == '\t' or
                            buf[j] == '\r' or
                            buf[j] == '\n')) : (j += 1)
                    {}
                },
                .literal_string, .multiline_literal_string => {},
                else => unreachable,
            },
            else => switch (item.value) {
                .literal_string, .multiline_literal_string => {},
                else => unreachable,
            },
        }

        i = j;
    } else {
        try self.result.strings.appendSlice(arena, buf[i..]);
    }

    return .{ .owned = .{ .start = start, .end = self.result.strings.items.len } };
}

// TODO:
fn fail(self: Decoder, err: Error, msg: ?[]const u8) Error {
    assert(err != error.Reported);
    _ = self;
    _ = msg;

    // if (self.diagnostics) |diag| {
    //     diag.* = .{
    //         .position = self.parser.tokenizer.position(),
    //         .message = if (msg) |m| m else switch (err) {
    //             error.InputTooLarge => "input too large",
    //             error.Reported => unreachable,
    //         },
    //     };
    //
    //     return error.Reported;
    // }

    return err;
}
