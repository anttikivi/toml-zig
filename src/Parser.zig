const Parser = @This();

const build_options = @import("build_options");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const DecodeOptions = @import("decoder.zig").DecodeOptions;
const Diagnostics = @import("decoder.zig").Diagnostics;
const Scanner = @import("Scanner.zig");
const Token = @import("Scanner.zig").Token;
const value = @import("value.zig");
const Date = @import("value.zig").Date;
const Datetime = @import("value.zig").Datetime;
const HashIndex = @import("value.zig").HashIndex;
const Time = @import("value.zig").Time;

arena: Allocator,
scanner: Scanner,
diagnostics: ?*Diagnostics = null,

const Error = Scanner.Error || error{
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
} || error{ ExtendedInlineArray, ExtendedInlineTable, InvalidTable };

const ParsingFlag = struct {
    inlined: bool = false,
    standard: bool = false,
    explicit: bool = false,
};

const ParsingValue = struct {
    flag: ParsingFlag = .{},
    value: union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool: bool,
        datetime: Datetime,
        local_datetime: Datetime,
        local_date: Date,
        local_time: Time,
        array: ArrayList(ParsingValue),
        table: ParsingTable,
    },
};

const ParsingEntry = struct {
    key: []const u8,
    value: ParsingValue,
};

const ParsingTable = struct {
    entries: ArrayList(ParsingEntry) = .empty,
    flag: ParsingFlag = .{},
    index: ?Index = null,

    const Table = @This();
    const Index = HashIndex(ParsingEntry);

    fn ensureIndex(self: *Table, gpa: Allocator) Allocator.Error!void {
        assert(self.index == null);

        if (self.entries.items.len < build_options.table_index_threshold) {
            return;
        }

        var capacity = build_options.min_index_capacity;
        while (capacity < self.entries.items.len * 2) {
            capacity *= 2;
        }

        self.index = try Index.init(gpa, self.entries.items, capacity);
    }

    fn getPtr(self: *Table, key: []const u8) ?*ParsingValue {
        if (self.index) |index| {
            if (index.lookup(self.entries.items, key)) |i| {
                return &self.entries.items[i].value;
            }

            return null;
        }

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return &entry.value;
            }
        }

        return null;
    }

    fn growIfNeeded(self: *Table, gpa: Allocator) Allocator.Error!void {
        if (self.index) |*index| {
            const used = self.entries.items.len;
            const capacity = index.mask + 1;

            if (used * 2 <= capacity) {
                return;
            }

            const new_capacity = capacity * 2;
            const new_index = try Index.init(gpa, self.entries.items, new_capacity);
            index.deinit(gpa);
            self.index = new_index;
        }
    }

    fn put(self: *Table, gpa: Allocator, key: []const u8, val: ParsingValue) Allocator.Error!void {
        try self.entries.append(gpa, .{ .key = key, .value = val });

        if (self.index) |*index| {
            try self.growIfNeeded(gpa);

            const i = self.entries.items.len - 1;
            const hash = std.hash.Wyhash.hash(0, key);

            var bucket = hash & index.mask;
            while (index.buckets[bucket] != value.empty_bucket) {
                bucket = (bucket + 1) & index.mask;
            }

            index.buckets[bucket] = i;
        } else {
            self.ensureIndex(gpa);
        }
    }
};

pub fn init(arena: Allocator, gpa: Allocator, input: []const u8, opts: DecodeOptions) Parser {
    return .{
        .arena = arena,
        .scanner = Scanner.init(gpa, input, opts),
    };
}

pub fn parse(self: *Parser) Error!ParsingTable {
    const root: ParsingTable = .{};
    const current: *ParsingTable = &root;

    while (self.scanner.cursor < self.scanner.input.len) {
        const token = try self.scanner.nextKey();

        switch (token) {
            .end_of_file => break,
            .line_feed => continue,
            .left_bracket => current = try self.parseTableHeader(&root),
            .double_left_bracket => current = try self.parseArrayTableHeader(&root),
            else => self.fail(.{ .@"error" = error.UnexpectedToken }),
        }
    }

    return root;
}

fn parseTableHeader(self: *Parser, root: *ParsingTable) Error!*ParsingTable {
    const keys = try self.parseKey(try self.scanner.nextKey());

    var tok = try self.scanner.nextKey();
    if (tok != .right_bracket) {
        return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "expected right square bracket" });
    }

    tok = try self.scanner.nextKey();
    if (tok != .line_feed and tok != .end_of_file) {
        return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "expected newline after table header" });
    }

    const last_key = keys[keys.len - 1];
    const table = try self.descendToTable(keys[0 .. keys.len - 1], root, true);

    if (table.getPtr(last_key)) |existing| {
        switch (existing.value) {
            .table => |*t| {
                if (existing.flag.explicit or existing.flag.inlined or !existing.flag.standard) {
                    return self.fail(.{ .@"error" = error.InvalidTable });
                }

                existing.flag.explicit = true;
                return t;
            },
            else => return self.fail(.{ .@"error" = error.InvalidTable }),
        }
    }

    if (table.flag.inlined) {
        return self.fail(.{ .@"error" = error.ExtendedInlineTable });
    }

    const new_table: ParsingTable = .{ .flag = .{ .standard = true, .explicit = true } };
    try table.put(self.arena, try self.arena.dupe(u8, last_key), .{
        .flag = .{ .standard = true, .explicit = true },
        .value = .{ .table = new_table },
    });

    const ptr = table.getPtr(last_key).?;
    return &ptr.value.table;
}

fn parseArrayTableHeader(self: *Parser, root: *ParsingTable) Error!*ParsingTable {
    const keys = try self.parseKey(try self.scanner.nextKey());

    var tok = try self.scanner.nextKey();
    if (tok != .double_right_bracket) {
        return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "expected two right square brackets" });
    }

    tok = try self.scanner.nextKey();
    if (tok != .line_feed and tok != .end_of_file) {
        return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "expected newline after table header" });
    }

    const last_key = keys[keys.len - 1];
    var table = root;

    for (keys[0 .. keys.len - 1]) |key| {
        if (table.getPtr(key)) |existing| {
            switch (existing.value) {
                .table => |*t| {
                    table = t;
                },
                .array => |*arr| {
                    if (existing.flag.inlined) {
                        return self.fail(.{ .@"error" = error.ExtendedInlineArray });
                    }

                    if (arr.items.len == 0) {
                        return self.fail(.{ .@"error" = error.UnexpectedToken });
                    }

                    switch (arr.items[arr.items.len - 1]) {
                        .table => |*t| table = t,
                        else => return self.fail(.{ .@"error" = error.InvalidTable }),
                    }
                },
                else => return self.fail(.{ .@"error" = error.InvalidTable }),
            }
        } else {
            const new_table: ParsingTable = .{ .flag = .{ .standard = true } };
            try table.put(self.arena, try self.arena.dupe(u8, key), .{
                .flag = .{ .standard = true },
                .value = .{ .table = new_table },
            });

            const ptr = table.getPtr(key).?;
            table = &ptr.value.table;
        }
    }

    if (table.getPtr(last_key)) |existing| {
        switch (existing.value) {
            .array => |arr| {
                if (existing.flag.inlined) {
                    return self.fail(.{ .@"error" = error.ExtendedInlineArray });
                }

                try arr.append(self.arena, .{ .value = .{ .table = .{} } });

                return &arr.items[arr.items.len - 1].value.table;
            },
            else => return self.fail(.{ .@"error" = error.InvalidTable }),
        }
    }

    const arr: ArrayList(ParsingValue) = .empty;
    try arr.append(self.arena, .{ .value = .{ .table = .{} } });
    try table.put(self.arena, try self.arena.dupe(u8, last_key), .{ .value = .{ .array = arr } });
    const ptr = table.getPtr(last_key).?;
    const array_ptr = &ptr.value.array;
    const last = &array_ptr.items[array_ptr.items.len - 1];
    return &last.value.table;
}

fn parseKey(self: *Parser, first: Token) Error![][]const u8 {
    var parts: ArrayList([]const u8) = .empty;

    const first_part = switch (first) {
        .literal, .literal_string => |s| s,
        .string => |s| self.normalizeString(s, false),
        else => self.fail(.{ .@"error" = error.UnexpectedToken }),
    };
    try parts.append(self.arena, first_part);

    while (self.scanner.cursor < self.scanner.input.len) {
        const cursor = self.scanner.cursor;
        const line = self.scanner.line;

        const maybe_dot = try self.scanner.nextKey();
        if (maybe_dot != .dot) {
            self.scanner.cursor = cursor;
            self.scanner.line = line;
            break;
        }

        const tok = try self.scanner.nextKey();
        const next = switch (tok) {
            .literal, .literal_string => |s| s,
            .string => |s| self.normalizeString(s, false),
            else => self.fail(.{ .@"error" = error.UnexpectedToken }),
        };
        try parts.append(self.arena, next);
    }

    return parts.toOwnedSlice(self.arena);
}

fn descendToTable(self: *Parser, keys: [][]const u8, root: *ParsingTable, is_standard: bool) Error!*ParsingTable {
    var table = root;

    for (keys) |key| {
        if (table.getPtr(key)) |existing| {
            switch (existing.value) {
                .table => |*t| table = t,
                .array => |*arr| {
                    if (arr.items.len == 0) {
                        return self.fail(.{ .@"error" = error.UnexpectedToken });
                    }

                    const last = &arr[arr.items.len - 1];
                    switch (last.value) {
                        .table => |*t| table = t,
                        else => return self.fail(.{ .@"error" = error.InvalidTable }),
                    }
                },
                // TODO: Not so sure which error to choose here, but that's what
                // the UnexpectedToken is for.
                else => return self.fail(.{ .@"error" = error.UnexpectedToken }),
            }
        } else {
            // We need to create the intermediate table.
            var new_table: ParsingTable = .{};
            new_table.flag.standard = is_standard;

            try table.put(self.arena, try self.arena.dupe(u8, key), .{
                .flag = .{ .standard = is_standard },
                .value = .{ .table = new_table },
            });

            const ptr = table.getPtr(key).?;
            table = &ptr.value.table;
        }
    }

    return table;
}

fn normalizeString(self: *Parser, s: []const u8, multiline: bool) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) {
        return s;
    }

    var result: ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try result.append(self.arena, s[i]);
            i += 1;
            continue;
        }

        i += 1;
        if (i >= s.len) {
            return self.fail(.{ .@"error" = error.UnexpectedToken });
        }

        const c = s[i];
        switch (c) {
            '"', '\\' => {
                try result.append(self.arena, c);
                i += 1;
            },
            'b' => {
                try result.append(self.arena, 8);
                i += 1;
            },
            'f' => {
                try result.append(self.arena, 12);
                i += 1;
            },
            't' => {
                try result.append(self.arena, '\t');
                i += 1;
            },
            'r' => {
                try result.append(self.arena, '\r');
                i += 1;
            },
            'n' => {
                try result.append(self.arena, '\n');
                i += 1;
            },
            // It might be that these never get through from the parser if
            // the escape character feature is not enabled, but it won't hurt to
            // double check.
            'e' => if (self.scanner.features.escape_e) {
                try result.append(self.arena, 27);
                i += 1;
            } else {
                self.fail(.{ .@"error" = error.InvalidEscapeSequence });
            },
            // Same deal here.
            'x' => if (self.scanner.features.escape_xhh) {
                i += 1;

                if (i + 2 < s.len) {
                    return self.fail(.{ .@"error" = error.UnexpectedToken });
                }

                const hex = s[i .. i + 2];
                const codepoint = std.fmt.parseInt(u8, hex, 16) catch |err| return self.fail(.{ .@"error" = err });
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &buf) catch |err| return self.fail(.{ .@"error" = err });
                try result.appendSlice(self.arena, buf[0..n]);
                i += 2;
            } else {
                self.fail(.{ .@"error" = error.InvalidEscapeSequence });
            },
            'u' => {
                i += 1;

                if (i + 4 < s.len) {
                    return self.fail(.{ .@"error" = error.UnexpectedToken });
                }

                const hex = s[i .. i + 4];
                const codepoint = std.fmt.parseInt(u21, hex, 16) catch |err| return self.fail(.{ .@"error" = err });
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &buf) catch |err| return self.fail(.{ .@"error" = err });
                try result.appendSlice(self.arena, buf[0..n]);
                i += 4;
            },
            'U' => {
                i += 1;

                if (i + 8 < s.len) {
                    return self.fail(.{ .@"error" = error.UnexpectedToken });
                }

                const hex = s[i .. i + 8];
                const codepoint = std.fmt.parseInt(u21, hex, 16) catch |err| return self.fail(.{ .@"error" = err });
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &buf) catch |err| return self.fail(.{ .@"error" = err });
                try result.appendSlice(self.arena, buf[0..n]);
                i += 8;
            },
            ' ', '\t', '\r', '\n' => if (multiline) {
                // Skip whitespaces after a line-ending backslash.
                while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) : (i += 1) {}
            } else {
                try result.append(self.arena, c);
                i += 1;
            },
            else => {
                result.append(self.arena, c);
                i += 1;
            },
        }
    }

    return result.toOwnedSlice(self.arena);
}

/// Fail the parsing in the Parser. This either fills the Diagnostics with
/// the appropriate information and returns `error.Reported` or returns
/// the given error.
fn fail(self: *const Parser, opts: struct { @"error": Error, msg: ?[]const u8 = null }) Error {
    assert(opts.@"error" != error.OutOfMemory);
    assert(opts.@"error" != error.Reported);

    if (self.diagnostics) |d| {
        const msg = if (opts.msg) |m| m else switch (opts.@"error") {
            error.ExtendedInlineArray => "extended inline table",
            error.ExtendedInlineTable => "extended inline table",
            error.InvalidEscapeSequence => "invalid escape sequence",
            error.InvalidTable => "invalid table definition",
            error.UnexpectedToken => "unexpected token",
            error.Reported => unreachable,
        };
        try d.initLineKnown(self.scanner.gpa, msg, self.scanner.input, self.scanner.cursor, self.scanner.line);

        return error.Reported;
    }

    return opts.@"error";
}
