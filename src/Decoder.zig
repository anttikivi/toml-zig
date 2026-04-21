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
parser: Parser,
result: Parsed,
features: Features,
diagnostics: ?*Diagnostics,

current_table: TableIndex = .root,
current_header: ArrayList(String) = .empty,

/// Build-time information on how to TOML tables are defined in the input document. The indices must
/// run in parallel to the table indices.
table_defs: ArrayList(TableDef) = .empty,

/// Build-time buffers to the table entries. Entries are buffered before appending to the final list
/// to keep the entries for each table in order. The indices must run in parallel to the table
/// indices.
entry_bufs: ArrayList(ArrayList(Table.Entry)) = .empty,
total_entries: u32 = 0,

pub const Error = Allocator.Error || Diagnostics.Error || std.fmt.ParseIntError || error{
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
} || error{
    InputTooLarge,
    InvalidTable,
    NotArray,
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
    arrays: ArrayList(Span) = .empty,
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

const TableDef = enum {
    root,
    header,
    array_element,
    implicit,
};

pub fn decode(gpa: Allocator, input: []const u8, options: Options) (Error || Parser.Error)!Parsed {
    var self: Decoder = .{
        .borrow = options.borrow,
        .parser = .init(input, .{
            .toml_version = options.toml_version,
            .diagnostics = options.diagnostics,
        }),
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

    while (try self.parser.next()) |item| {
        switch (item.tag) {
            .table_header_start, .array_table_header_start => {
                self.current_header.clearRetainingCapacity();
            },
            .table_key, .array_table_key => try self.current_header.append(
                gpa,
                try self.takeKey(arena, item),
            ),
            .table_header_end => {
                assert(self.current_header.items.len > 0);
                self.current_table = self.resolveHeader(gpa, arena, .header);
                assert(self.current_table != .root);
            },
            .array_table_header_end => {
                assert(self.current_header.items.len > 0);
                self.current_table = self.resolveHeader(gpa, arena, .array_element);
                assert(self.current_table != .root);
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
fn resolveHeader(self: *Decoder, gpa: Allocator, arena: Allocator, def: TableDef) Error!void {
    assert(self.current_header.items.len > 0);

    var current: TableIndex = .root;
    const header = self.current_header.items;
    for (header[0 .. header.len - 1]) |key| {
        current = try self.getOrCreateTable(gpa, arena, current, key);
    }

    const final_key = header[header.len - 1];

    switch (def) {
        .header => {
            if (try self.findTable(current, final_key.slice(self.result))) |existing| {
                const existing_def = self.table_defs.items[existing];
                switch (existing_def) {
                    .implicit => {
                        self.table_defs.items[existing] = .header;
                        return existing;
                    },
                    .root => unreachable,
                    else => return self.fail(
                        error.InvalidTableDefinition,
                        "invalid redefinition of table",
                    ),
                }
            }

            const i = try self.createTable(gpa, arena, .header);
            try self.appendTable(gpa, current, final_key, .{ .table = i });

            return i;
        },
        .array_element => {
            const entries = self.entry_bufs.items[current];
            const key_str = final_key.slice(self.result);
            var i: ?u32 = null;
            for (entries.items) |entry| {
                if (std.mem.eql(u8, key_str, entry.key.slice(self.result))) {
                    switch (entry.value) {
                        .array => |a| {
                            i = a;
                            break;
                        },
                        else => return self.fail(
                            error.NotArray,
                            "cannot append table to element that is not array of tables",
                        ),
                    }
                }
            }

            if (i == null) {
                i = self.result.arrays.items.len;
                const start = self.result.values.items.len;
                try self.result.arrays.append(arena, .{ .start = start, .end = start });

                assert(self.result.arrays.items.len == i);

                try self.appendTable(gpa, current, final_key, .{ .array = i });
            }

            const table = try self.createTable(gpa, arena, .array_element);

            assert(self.result.values.items.len == self.result.arrays.items[i].end);
            try self.result.values.append(arena, .{ .table = table });

            self.result.arrays.items[i].end += 1;

            return i;
        },
        else => unreachable,
    }
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
        const td = self.table_defs.items[existing];
        switch (td) {
            .implicit, .header => return existing,
            .array_element => {
                const parent_entries = self.entry_bufs.items[parent];
                const key_str = key.slice(self.result);
                const i = blk: for (parent_entries.items) |entry| {
                    if (std.mem.eql(u8, key_str, entry.key.slice(self.result))) {
                        switch (entry.value) {
                            .array => |a| break :blk a,
                            else => return self.fail(error.NotArray, null),
                        }
                    }

                    break :blk null;
                };
                const arr = self.result.arrays.items[i];

                if (arr.start == arr.end) {
                    return self.fail(error.InvalidTable, "referring table in an empty array");
                }

                return switch (self.result.values.items[arr.end - 1]) {
                    .table => |t| t,
                    else => self.fail(error.InvalidTable, "given array element is not a table"),
                };
            },
            .root => unreachable,
            else => return self.fail(error.InvalidTable, "invalid redefinition of table"),
        }
    }

    const i = try self.createTable(gpa, arena, .implicit);
    try self.appendTable(gpa, parent, key, .{ .table = i });

    return i;
}

fn findTable(self: Decoder, parent: TableIndex, name: []const u8) Error!?TableIndex {
    const entries = self.entry_bufs.items[parent];
    for (entries.items) |entry| {
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
    def: TableDef,
) Allocator.Error!TableIndex {
    assert(self.result.tables.items.len == self.table_defs.items.len);
    assert(self.result.tables.items.len == self.entry_bufs.items.len);

    const i: TableIndex = @enumFromInt(self.result.tables.items.len);

    try self.result.tables.append(arena, .{ .entries = .{ .start = 0, .end = 0 } });
    try self.table_defs.append(gpa, def);
    try self.entry_bufs.append(gpa, .empty);

    assert(self.result.tables.items.len == self.table_defs.items.len);
    assert(self.result.tables.items.len == self.entry_bufs.items.len);

    return i;
}

fn appendTable(
    self: *Decoder,
    gpa: Allocator,
    table: TableIndex,
    key: String,
    value: Value,
) Allocator.Error!void {
    var entries = self.entry_bufs.items[table];
    try entries.append(gpa, .{ .key = key, .value = value });
    self.total_entries += 1;
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

fn fail(self: *Decoder, err: Error, msg: ?[]const u8) Error {
    assert(err != error.Reported);

    if (self.diagnostics) |diag| {
        diag.* = .{
            // TODO: Calculate a more granular position for decoder errors.
            .position = self.parser.tokenizer.position(),
            .message = if (msg) |m| m else switch (err) {
                error.InputTooLarge => "input too large",
                error.InvalidTable => "invalid table definition",
                error.NotArray => "element is not an array",
                error.NotTable => "element is not a table",
                error.Reported => unreachable,
            },
        };

        return error.Reported;
    }

    return err;
}
