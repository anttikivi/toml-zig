const Parser = @This();

const build_options = @import("build_options");
const builtin = @import("builtin");
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
const HashIndex = @import("value.zig").Table.HashIndex;
const Table = @import("value.zig").Table;
const Time = @import("value.zig").Time;
const Value = @import("value.zig").Value;

arena: Allocator,
scanner: Scanner,
diagnostics: ?*Diagnostics = null,

const Error = Scanner.Error || error{
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
} || error{ DuplicateKey, ExtendedInlineArray, ExtendedInlineTable, InvalidTable };

const ParsingFlag = struct {
    inlined: bool = false,
    standard: bool = false,
    explicit: bool = false,
};

const ParsingArray = ArrayList(ParsingValue);

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
        array: ParsingArray,
        table: ParsingTable,
    },

    const Self = @This();

    fn toValue(self: Self, gpa: Allocator) Allocator.Error!Value {
        return switch (self.value) {
            .string => |s| .{ .string = s },
            .int => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            .bool => |b| .{ .bool = b },
            .datetime => |dt| .{ .datetime = dt },
            .local_datetime => |dt| .{ .local_datetime = dt },
            .local_date => |d| .{ .local_date = d },
            .local_time => |t| .{ .local_time = t },
            .array => |arr| {
                const items = try gpa.alloc(Value, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    items[i] = try item.toValue(gpa);
                }
                return .{ .array = items };
            },
            .table => |t| .{ .table = try t.toTable(gpa) },
        };
    }
};

const ParsingEntry = struct {
    key: []const u8,
    value: ParsingValue,
};

const ParsingTable = struct {
    entries: ArrayList(ParsingEntry) = .empty,
    flag: ParsingFlag = .{},
    index: ?Index = null,

    const Self = @This();
    const Index = HashIndex(ParsingEntry);

    fn contains(self: *const Self, key: []const u8) bool {
        if (self.index) |index| {
            return index.lookup(self.entries.items, key) != null;
        }

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return true;
            }
        }

        return false;
    }

    fn ensureIndex(self: *Self, gpa: Allocator) Allocator.Error!void {
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

    fn getPtr(self: *Self, key: []const u8) ?*ParsingValue {
        if (self.index) |index| {
            if (index.lookup(self.entries.items, key)) |i| {
                return &self.entries.items[i].value;
            }

            return null;
        }

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return &entry.value;
            }
        }

        return null;
    }

    fn growIfNeeded(self: *Self, gpa: Allocator) Allocator.Error!void {
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

    fn put(self: *Self, gpa: Allocator, key: []const u8, val: ParsingValue) Allocator.Error!void {
        try self.entries.append(gpa, .{ .key = key, .value = val });

        if (self.index) |*index| {
            try self.growIfNeeded(gpa);

            const i: u32 = @intCast(self.entries.items.len - 1);
            const hash = std.hash.Wyhash.hash(0, key);

            var bucket = hash & index.mask;
            while (index.buckets[bucket] != value.empty_bucket) {
                bucket = (bucket + 1) & index.mask;
            }

            index.buckets[bucket] = i;
        } else {
            try self.ensureIndex(gpa);
        }
    }

    fn toTable(self: Self, gpa: Allocator) Allocator.Error!Table {
        const entries = try gpa.alloc(Table.Entry, self.entries.items.len);

        for (self.entries.items, 0..) |entry, i| {
            entries[i] = .{
                .key = entry.key,
                .value = try entry.value.toValue(gpa),
            };
        }

        var index: ?Table.Index = null;
        if (entries.len > build_options.table_index_threshold) {
            // Find next power of 2 >= 2 * entries.len
            var capacity: u32 = build_options.min_index_capacity;
            while (capacity < entries.len * 2) {
                capacity *= 2;
            }
            index = try Table.Index.init(gpa, entries, capacity);
        }

        return .{
            .entries = entries,
            .index = index,
        };
    }
};

pub fn init(arena: Allocator, gpa: Allocator, input: []const u8, opts: DecodeOptions) Parser {
    return .{
        .arena = arena,
        .scanner = Scanner.init(gpa, input, opts),
    };
}

pub fn parse(self: *Parser) Error!Table {
    var root: ParsingTable = .{};
    var current = &root;

    while (self.scanner.cursor < self.scanner.input.len) {
        const token = try self.scanner.nextKey();

        switch (token) {
            .end_of_file => break,
            .line_feed => continue,
            .left_bracket => current = try self.parseTableHeader(&root),
            .double_left_bracket => current = try self.parseArrayTableHeader(&root),
            .literal, .string, .literal_string => try self.parseKeyValue(token, current),
            else => return self.fail(.{ .@"error" = error.UnexpectedToken }),
        }
    }

    return root.toTable(self.arena);
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
                if (existing.flag.inlined) {
                    return self.fail(.{ .@"error" = error.ExtendedInlineTable });
                }

                if (existing.flag.explicit or !existing.flag.standard) {
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

                    switch (arr.items[arr.items.len - 1].value) {
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
            .array => |*arr| {
                if (existing.flag.inlined) {
                    return self.fail(.{ .@"error" = error.ExtendedInlineArray });
                }

                try arr.append(self.arena, .{ .value = .{ .table = .{} } });

                return &arr.items[arr.items.len - 1].value.table;
            },
            else => return self.fail(.{ .@"error" = error.InvalidTable }),
        }
    }

    var arr: ParsingArray = .empty;
    try arr.append(self.arena, .{ .value = .{ .table = .{} } });
    try table.put(self.arena, try self.arena.dupe(u8, last_key), .{ .value = .{ .array = arr } });
    const ptr = table.getPtr(last_key).?;
    const array_ptr = &ptr.value.array;
    const last = &array_ptr.items[array_ptr.items.len - 1];
    return &last.value.table;
}

fn parseKeyValue(self: *Parser, first_token: Token, current_table: *ParsingTable) Error!void {
    const keys = try self.parseKey(first_token);

    var token = try self.scanner.nextKey();
    if (token != .equal) {
        return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "expected an equals sign" });
    }

    token = try self.scanner.nextValue();

    var table = current_table;
    for (keys[0 .. keys.len - 1], 0..) |key, i| {
        if (table.getPtr(key)) |existing| {
            switch (existing.value) {
                .table => |*t| table = t,
                else => return self.fail(.{ .@"error" = error.InvalidTable }),
            }
        } else {
            if (table.flag.inlined) {
                return self.fail(.{ .@"error" = error.ExtendedInlineTable });
            }

            if (i > 0 and table.flag.explicit) {
                return self.fail(.{ .@"error" = error.InvalidTable });
            }

            try table.put(self.arena, try self.arena.dupe(u8, key), .{ .value = .{ .table = .{} } });

            const ptr = table.getPtr(key).?;
            table = &ptr.value.table;
        }
    }

    if (table.flag.inlined) {
        return self.fail(.{ .@"error" = error.ExtendedInlineTable });
    }

    if (keys.len > 1 and table.flag.explicit) {
        return self.fail(.{ .@"error" = error.InvalidTable });
    }

    const final_key = keys[keys.len - 1];
    if (table.contains(final_key)) {
        return self.fail(.{ .@"error" = error.DuplicateKey });
    }

    const val = try self.parseValue(token);
    try table.put(self.arena, try self.arena.dupe(u8, final_key), val);

    // After parsing the value, verify the line ends properly. A comment
    // after the value consumes the newline in the scanner, so we may get
    // the next line's first token instead of line_feed. In that case, we
    // push back by restoring the cursor.
    const cursor = self.scanner.cursor;
    const line = self.scanner.line;
    token = try self.scanner.nextKey();
    if (token != .line_feed and token != .end_of_file) {
        // Check if this could be the start of the next expression (meaning
        // the newline was consumed by a comment). If so, push back.
        switch (token) {
            .literal,
            .string,
            .literal_string,
            .left_bracket,
            .double_left_bracket,
            => {
                self.scanner.cursor = cursor;
                self.scanner.line = line;
            },
            else => return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "expected a newline after value" }),
        }
    }
}

fn parseKey(self: *Parser, first: Token) Error![][]const u8 {
    var parts: ArrayList([]const u8) = .empty;

    const first_part = switch (first) {
        .literal, .literal_string => |s| s,
        .string => |s| try self.normalizeString(s, false),
        else => return self.fail(.{ .@"error" = error.UnexpectedToken }),
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
            .string => |s| try self.normalizeString(s, false),
            else => return self.fail(.{ .@"error" = error.UnexpectedToken }),
        };
        try parts.append(self.arena, next);
    }

    return parts.toOwnedSlice(self.arena);
}

fn parseValue(self: *Parser, token: Token) Error!ParsingValue {
    return switch (token) {
        .string => |s| .{ .value = .{ .string = try self.normalizeString(s, false) } },
        .multiline_string => |s| .{ .value = .{ .string = try self.normalizeString(s, true) } },
        .literal_string, .multiline_literal_string => |s| .{ .value = .{ .string = s } },
        .int => |i| .{ .value = .{ .int = i } },
        .float => |f| .{ .value = .{ .float = f } },
        .bool => |b| .{ .value = .{ .bool = b } },
        .datetime => |dt| .{ .value = .{ .datetime = dt } },
        .local_datetime => |dt| .{ .value = .{ .local_datetime = dt } },
        .local_date => |d| .{ .value = .{ .local_date = d } },
        .local_time => |t| .{ .value = .{ .local_time = t } },
        .left_bracket => try self.parseInlineArray(),
        .left_brace => try self.parseInlineTable(),
        else => return self.fail(.{ .@"error" = error.UnexpectedToken }),
    };
}

fn parseInlineArray(self: *Parser) Error!ParsingValue {
    var arr: ParsingArray = .empty;
    var need_comma = false;

    while (true) {
        var token = try self.scanner.nextValue();
        while (token == .line_feed) {
            token = try self.scanner.nextValue();
        }

        if (token == .right_bracket) {
            break;
        }

        if (token == .comma) {
            if (!need_comma) {
                return self.fail(.{ .@"error" = error.UnexpectedToken });
            }

            need_comma = false;
            continue;
        }

        if (need_comma) {
            return self.fail(.{ .@"error" = error.UnexpectedToken });
        }

        const val = try self.parseValue(token);
        try arr.append(self.arena, val);
        need_comma = true;
    }

    var result: ParsingValue = .{ .value = .{ .array = arr } };
    setFlagRecursively(&result, .{ .inlined = true, .standard = false, .explicit = false });
    return result;
}

fn parseInlineTable(self: *Parser) Error!ParsingValue {
    var table: ParsingTable = .{ .flag = .{ .inlined = true } };
    var need_comma = false;
    var was_comma = false;

    while (true) {
        var token = try self.scanner.nextKey();

        if (self.scanner.features.inline_table_newlines) {
            while (token == .line_feed) {
                token = try self.scanner.nextKey();
            }
        }

        if (token == .right_brace) {
            if (was_comma and !self.scanner.features.inline_table_trailing_comma) {
                return self.fail(.{ .@"error" = error.UnexpectedToken });
            }

            break;
        }

        if (token == .comma) {
            if (!need_comma) {
                return self.fail(.{ .@"error" = error.UnexpectedToken });
            }

            need_comma = false;
            was_comma = true;
            continue;
        }

        if (need_comma) {
            return self.fail(.{ .@"error" = error.UnexpectedToken });
        }

        if (token == .line_feed) {
            return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "newlines not allowed in inline tables" });
        }

        const keys = try self.parseKey(token);

        // TODO: Is a newline allowed here?
        token = try self.scanner.nextValue();
        if (token != .equal) {
            return self.fail(.{ .@"error" = error.UnexpectedToken, .msg = "expected an equals sign" });
        }

        var current = &table;
        for (keys[0 .. keys.len - 1]) |key| {
            if (current.getPtr(key)) |existing| {
                switch (existing.value) {
                    .table => |*t| {
                        if (existing.flag.explicit) {
                            return self.fail(.{ .@"error" = error.InvalidTable });
                        }

                        current = t;
                    },
                    else => return self.fail(.{ .@"error" = error.InvalidTable }),
                }
            } else {
                try current.put(self.arena, try self.arena.dupe(u8, key), .{ .value = .{ .table = .{} } });
                const ptr = current.getPtr(key).?;
                current = &ptr.value.table;
            }
        }

        const final_key = keys[keys.len - 1];
        if (current.contains(final_key)) {
            return self.fail(.{ .@"error" = error.DuplicateKey });
        }

        token = try self.scanner.nextValue();
        var val = try self.parseValue(token);
        val.flag.explicit = true;

        try current.put(self.arena, final_key, val);

        need_comma = true;
        was_comma = false;
    }

    var result: ParsingValue = .{
        .flag = .{ .inlined = true },
        .value = .{ .table = table },
    };
    setFlagRecursively(&result, .{ .inlined = true });
    return result;
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

                    const last = &arr.items[arr.items.len - 1];
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
                return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
            },
            // Same deal here.
            'x' => if (self.scanner.features.escape_xhh) {
                i += 1;

                if (i + 2 > s.len) {
                    return self.fail(.{ .@"error" = error.UnexpectedToken });
                }

                const hex = s[i .. i + 2];
                const codepoint = std.fmt.parseInt(u8, hex, 16) catch |err| return self.fail(.{ .@"error" = err });
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &buf) catch |err| return self.fail(.{ .@"error" = err });
                try result.appendSlice(self.arena, buf[0..n]);
                i += 2;
            } else {
                return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
            },
            'u' => {
                i += 1;

                if (i + 4 > s.len) {
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

                if (i + 8 > s.len) {
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
                try result.append(self.arena, c);
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
    assert(opts.@"error" != error.InvalidControlCharacter);
    assert(opts.@"error" != error.InvalidDatetime);
    assert(opts.@"error" != error.InvalidNumber);
    assert(opts.@"error" != error.OutOfMemory);
    assert(opts.@"error" != error.Overflow);
    assert(opts.@"error" != error.Reported);
    assert(opts.@"error" != error.UnterminatedString);

    if (self.diagnostics) |d| {
        const msg = if (opts.msg) |m| m else switch (opts.@"error") {
            error.DuplicateKey => "duplicate key",
            error.ExtendedInlineArray => "extended inline array",
            error.ExtendedInlineTable => "extended inline table",
            error.InvalidEscapeSequence => "invalid escape sequence",
            error.InvalidTable => "invalid table definition",
            error.UnexpectedToken => "unexpected token",
            error.Utf8CannotEncodeSurrogateHalf => "invalid unicode codepoint",
            error.CodepointTooLarge => "codepoint too large",

            error.InvalidCharacter,
            error.InvalidControlCharacter,
            error.InvalidDatetime,
            error.InvalidNumber,
            error.OutOfMemory,
            error.Overflow,
            error.Reported,
            error.UnterminatedString,
            => unreachable,
        };
        try d.initLineKnown(self.scanner.gpa, msg, self.scanner.input, self.scanner.cursor, self.scanner.line);

        return error.Reported;
    }

    return opts.@"error";
}

fn setFlagRecursively(val: *ParsingValue, flag: ParsingFlag) void {
    if (flag.explicit) {
        val.flag.explicit = true;
    }

    if (flag.inlined) {
        val.flag.inlined = true;
    }

    if (flag.standard) {
        val.flag.standard = true;
    }

    switch (val.value) {
        .array => |*arr| for (arr.items) |*item| {
            setFlagRecursively(item, flag);
        },
        .table => |*t| for (t.entries.items) |*entry| {
            setFlagRecursively(&entry.value, flag);
        },
        else => {},
    }
}

const TestParseResult = struct {
    arena: std.heap.ArenaAllocator,
    root: Table,

    fn deinit(self: *TestParseResult) void {
        self.arena.deinit();
    }
};

fn testParse(input: []const u8) !TestParseResult {
    return testParseWithOpts(input, .{});
}

fn testParseWithOpts(input: []const u8, opts: DecodeOptions) !TestParseResult {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    var parser: Parser = .init(arena.allocator(), std.testing.allocator, input, opts);
    const root = try parser.parse();
    return .{ .arena = arena, .root = root };
}

fn testParseFails(input: []const u8, expected_err: Error) !void {
    return testParseFailsWithOpts(input, .{}, expected_err);
}

fn testParseFailsWithOpts(input: []const u8, opts: DecodeOptions, expected_err: Error) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser: Parser = .init(arena.allocator(), std.testing.allocator, input, opts);
    try std.testing.expectError(expected_err, parser.parse());
}

fn expectString(table: *const Table, key: []const u8, expected: []const u8) !void {
    if (!builtin.is_test) {
        @compileError("expectString may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .string => |s| try std.testing.expectEqualStrings(expected, s),
        else => return error.TestExpectedEqual,
    }
}

fn expectInt(table: *const Table, key: []const u8, expected: i64) !void {
    if (!builtin.is_test) {
        @compileError("expectInt may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .int => |i| try std.testing.expectEqual(expected, i),
        else => return error.TestExpectedEqual,
    }
}

fn expectFloat(table: *const Table, key: []const u8, expected: f64) !void {
    if (!builtin.is_test) {
        @compileError("expectFloat may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .float => |f| try std.testing.expectEqual(expected, f),
        else => return error.TestExpectedEqual,
    }
}

fn expectBool(table: *const Table, key: []const u8, expected: bool) !void {
    if (!builtin.is_test) {
        @compileError("expectBool may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .bool => |b| try std.testing.expectEqual(expected, b),
        else => return error.TestExpectedEqual,
    }
}

fn expectDatetime(table: *const Table, key: []const u8, expected: Datetime) !void {
    if (!builtin.is_test) {
        @compileError("expectDatetime may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .datetime => |dt| try std.testing.expect(expected.eql(dt)),
        else => return error.TestExpectedEqual,
    }
}

fn expectLocalDatetime(table: *const Table, key: []const u8, expected: Datetime) !void {
    if (!builtin.is_test) {
        @compileError("expectLocalDatetime may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .local_datetime => |dt| try std.testing.expect(expected.eql(dt)),
        else => return error.TestExpectedEqual,
    }
}

fn expectLocalDate(table: *const Table, key: []const u8, expected: Date) !void {
    if (!builtin.is_test) {
        @compileError("expectLocalDate may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .local_date => |d| try std.testing.expect(expected.eql(d)),
        else => return error.TestExpectedEqual,
    }
}

fn expectLocalTime(table: *const Table, key: []const u8, expected: Time) !void {
    if (!builtin.is_test) {
        @compileError("expectLocalTime may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .local_time => |t| try std.testing.expect(expected.eql(t)),
        else => return error.TestExpectedEqual,
    }
}

fn expectTable(table: *const Table, key: []const u8) !*const Table {
    if (!builtin.is_test) {
        @compileError("expectTable may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .table => |*t| return t,
        else => return error.TestExpectedEqual,
    }
}

fn expectArray(table: *const Table, key: []const u8) ![]const Value {
    if (!builtin.is_test) {
        @compileError("expectArray may only be used in tests");
    }

    const val = table.getPtr(key) orelse return error.TestExpectedEqual;
    switch (val.*) {
        .array => |arr| return arr,
        else => return error.TestExpectedEqual,
    }
}

fn expectArrayTable(arr: []const Value, index: usize) !*const Table {
    if (!builtin.is_test) {
        @compileError("expectArrayTable may only be used in tests");
    }

    if (index >= arr.len) {
        return error.TestExpectedEqual;
    }

    switch (arr[index]) {
        .table => |*t| return t,
        else => return error.TestExpectedEqual,
    }
}

fn expectArrayString(arr: []const Value, index: usize, expected: []const u8) !void {
    if (!builtin.is_test) {
        @compileError("expectArrayString may only be used in tests");
    }

    if (index >= arr.len) {
        return error.TestExpectedEqual;
    }

    switch (arr[index]) {
        .string => |s| try std.testing.expectEqualStrings(expected, s),
        else => return error.TestExpectedEqual,
    }
}

fn expectArrayInt(arr: []const Value, index: usize, expected: i64) !void {
    if (!builtin.is_test) {
        @compileError("expectArrayInt may only be used in tests");
    }

    if (index >= arr.len) {
        return error.TestExpectedEqual;
    }

    switch (arr[index]) {
        .int => |i| try std.testing.expectEqual(expected, i),
        else => return error.TestExpectedEqual,
    }
}

fn expectArrayFloat(arr: []const Value, index: usize, expected: f64) !void {
    if (!builtin.is_test) {
        @compileError("expectArrayFloat may only be used in tests");
    }

    if (index >= arr.len) {
        return error.TestExpectedEqual;
    }

    switch (arr[index]) {
        .float => |f| try std.testing.expectEqual(expected, f),
        else => return error.TestExpectedEqual,
    }
}

fn expectArrayBool(arr: []const Value, index: usize, expected: bool) !void {
    if (!builtin.is_test) {
        @compileError("expectArrayBool may only be used in tests");
    }

    if (index >= arr.len) {
        return error.TestExpectedEqual;
    }

    switch (arr[index]) {
        .bool => |b| try std.testing.expectEqual(expected, b),
        else => return error.TestExpectedEqual,
    }
}

fn expectArrayArray(arr: []const Value, index: usize) ![]const Value {
    if (!builtin.is_test) {
        @compileError("expectArrayArray may only be used in tests");
    }

    if (index >= arr.len) {
        return error.TestExpectedEqual;
    }

    switch (arr[index]) {
        .array => |a| return a,
        else => return error.TestExpectedEqual,
    }
}

test "parse empty document" {
    var result = try testParse("");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.root.entries.len);
}

test "parse whitespace-only document" {
    var result = try testParse("   \t  ");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.root.entries.len);
}

test "parse newline-only document" {
    var result = try testParse("\n\n\n");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.root.entries.len);
}

test "parse comment-only document" {
    var result = try testParse("# This is a comment\n# Another comment\n");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.root.entries.len);
}

test "parse basic string value" {
    var result = try testParse(
        \\name = "Tom"
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "name", "Tom");
}

test "parse literal string value" {
    var result = try testParse(
        \\path = 'C:\Users\Tom'
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "path", "C:\\Users\\Tom");
}

test "parse empty string value" {
    var result = try testParse(
        \\empty = ""
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "empty", "");
}

test "parse multiline basic string value" {
    var result = try testParse("msg = \"\"\"\nline1\nline2\n\"\"\"\n");
    defer result.deinit();
    try expectString(&result.root, "msg", "line1\nline2\n");
}

test "parse multiline literal string value" {
    var result = try testParse("msg = '''\nline1\nline2\n'''\n");
    defer result.deinit();
    try expectString(&result.root, "msg", "line1\nline2\n");
}

test "parse integer value" {
    var result = try testParse(
        \\count = 42
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "count", 42);
}

test "parse negative integer value" {
    var result = try testParse(
        \\val = -17
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "val", -17);
}

test "parse positive integer value" {
    var result = try testParse(
        \\val = +99
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "val", 99);
}

test "parse zero integer" {
    var result = try testParse(
        \\val = 0
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "val", 0);
}

test "parse hex integer" {
    var result = try testParse(
        \\val = 0xff
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "val", 255);
}

test "parse octal integer" {
    var result = try testParse(
        \\val = 0o77
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "val", 63);
}

test "parse binary integer" {
    var result = try testParse(
        \\val = 0b11010110
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "val", 214);
}

test "parse integer with underscores" {
    var result = try testParse(
        \\val = 1_000_000
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "val", 1_000_000);
}

test "parse float value" {
    var result = try testParse(
        \\pi = 3.14
        \\
    );
    defer result.deinit();
    try expectFloat(&result.root, "pi", 3.14);
}

test "parse negative float value" {
    var result = try testParse(
        \\val = -0.01
        \\
    );
    defer result.deinit();
    try expectFloat(&result.root, "val", -0.01);
}

test "parse float with exponent" {
    var result = try testParse(
        \\val = 5e+22
        \\
    );
    defer result.deinit();
    try expectFloat(&result.root, "val", 5e+22);
}

test "parse inf" {
    var result = try testParse(
        \\val = inf
        \\
    );
    defer result.deinit();
    try expectFloat(&result.root, "val", std.math.inf(f64));
}

test "parse negative inf" {
    var result = try testParse(
        \\val = -inf
        \\
    );
    defer result.deinit();
    try expectFloat(&result.root, "val", -std.math.inf(f64));
}

test "parse nan" {
    var result = try testParse(
        \\val = nan
        \\
    );
    defer result.deinit();
    const val = result.root.getPtr("val") orelse return error.TestExpectedEqual;
    switch (val.*) {
        .float => |f| try std.testing.expect(std.math.isNan(f)),
        else => return error.TestExpectedEqual,
    }
}

test "parse true" {
    var result = try testParse(
        \\flag = true
        \\
    );
    defer result.deinit();
    try expectBool(&result.root, "flag", true);
}

test "parse false" {
    var result = try testParse(
        \\flag = false
        \\
    );
    defer result.deinit();
    try expectBool(&result.root, "flag", false);
}

test "parse offset datetime" {
    var result = try testParse(
        \\dt = 1979-05-27T07:32:00Z
        \\
    );
    defer result.deinit();
    try expectDatetime(&result.root, "dt", .{
        .year = 1979,
        .month = 5,
        .day = 27,
        .hour = 7,
        .minute = 32,
        .second = 0,
        .nano = null,
        .tz = 0,
    });
}

test "parse offset datetime with offset" {
    var result = try testParse(
        \\dt = 1979-05-27T07:32:00-07:00
        \\
    );
    defer result.deinit();
    try expectDatetime(&result.root, "dt", .{
        .year = 1979,
        .month = 5,
        .day = 27,
        .hour = 7,
        .minute = 32,
        .second = 0,
        .nano = null,
        .tz = -7 * 60,
    });
}

test "parse local datetime" {
    var result = try testParse(
        \\dt = 1979-05-27T07:32:00
        \\
    );
    defer result.deinit();
    try expectLocalDatetime(&result.root, "dt", .{
        .year = 1979,
        .month = 5,
        .day = 27,
        .hour = 7,
        .minute = 32,
        .second = 0,
        .nano = null,
        .tz = null,
    });
}

test "parse local date" {
    var result = try testParse(
        \\d = 1979-05-27
        \\
    );
    defer result.deinit();
    try expectLocalDate(&result.root, "d", .{
        .year = 1979,
        .month = 5,
        .day = 27,
    });
}

test "parse local time" {
    var result = try testParse(
        \\t = 07:32:00
        \\
    );
    defer result.deinit();
    try expectLocalTime(&result.root, "t", .{
        .hour = 7,
        .minute = 32,
        .second = 0,
        .nano = null,
    });
}

test "parse local time with nanoseconds" {
    var result = try testParse(
        \\t = 07:32:00.123456789
        \\
    );
    defer result.deinit();
    try expectLocalTime(&result.root, "t", .{
        .hour = 7,
        .minute = 32,
        .second = 0,
        .nano = 123456789,
    });
}

test "parse multiple key-value pairs" {
    var result = try testParse(
        \\name = "Tom"
        \\age = 30
        \\active = true
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "name", "Tom");
    try expectInt(&result.root, "age", 30);
    try expectBool(&result.root, "active", true);
    try std.testing.expectEqual(@as(usize, 3), result.root.entries.len);
}

test "parse key-value pairs with comments" {
    var result = try testParse(
        \\# A comment
        \\name = "Tom" # inline comment
        \\age = 30
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "name", "Tom");
    try expectInt(&result.root, "age", 30);
}

test "parse dotted key" {
    var result = try testParse(
        \\a.b = "value"
        \\
    );
    defer result.deinit();
    const a = try expectTable(&result.root, "a");
    try expectString(a, "b", "value");
}

test "parse deeply dotted key" {
    var result = try testParse(
        \\a.b.c = "value"
        \\
    );
    defer result.deinit();
    const a = try expectTable(&result.root, "a");
    const b = try expectTable(a, "b");
    try expectString(b, "c", "value");
}

test "parse multiple dotted keys sharing prefix" {
    var result = try testParse(
        \\a.b = 1
        \\a.c = 2
        \\
    );
    defer result.deinit();
    const a = try expectTable(&result.root, "a");
    try expectInt(a, "b", 1);
    try expectInt(a, "c", 2);
}

test "parse quoted dotted key" {
    var result = try testParse(
        \\"a"."b" = "value"
        \\
    );
    defer result.deinit();
    const a = try expectTable(&result.root, "a");
    try expectString(a, "b", "value");
}

test "parse simple table header" {
    var result = try testParse(
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    );
    defer result.deinit();
    const server = try expectTable(&result.root, "server");
    try expectString(server, "host", "localhost");
    try expectInt(server, "port", 8080);
}

test "parse nested table header" {
    var result = try testParse(
        \\[a.b]
        \\key = "value"
        \\
    );
    defer result.deinit();
    const a = try expectTable(&result.root, "a");
    const b = try expectTable(a, "b");
    try expectString(b, "key", "value");
}

test "parse multiple table headers" {
    var result = try testParse(
        \\[server]
        \\host = "localhost"
        \\
        \\[database]
        \\name = "mydb"
        \\
    );
    defer result.deinit();
    const server = try expectTable(&result.root, "server");
    try expectString(server, "host", "localhost");
    const database = try expectTable(&result.root, "database");
    try expectString(database, "name", "mydb");
}

test "parse table header extending implicit table" {
    var result = try testParse(
        \\[a.b]
        \\key1 = "val1"
        \\
        \\[a.c]
        \\key2 = "val2"
        \\
    );
    defer result.deinit();
    const a = try expectTable(&result.root, "a");
    const b = try expectTable(a, "b");
    try expectString(b, "key1", "val1");
    const c = try expectTable(a, "c");
    try expectString(c, "key2", "val2");
}

test "parse table header with dotted keys inside" {
    var result = try testParse(
        \\[fruit]
        \\apple.color = "red"
        \\apple.taste = "sweet"
        \\
    );
    defer result.deinit();
    const fruit = try expectTable(&result.root, "fruit");
    const apple = try expectTable(fruit, "apple");
    try expectString(apple, "color", "red");
    try expectString(apple, "taste", "sweet");
}

test "parse super-table after sub-table" {
    var result = try testParse(
        \\[a.b]
        \\val = 1
        \\
        \\[a]
        \\val = 2
        \\
    );
    defer result.deinit();
    const a = try expectTable(&result.root, "a");
    try expectInt(a, "val", 2);
    const b = try expectTable(a, "b");
    try expectInt(b, "val", 1);
}

test "parse duplicate table header fails" {
    try testParseFails(
        \\[a]
        \\key = 1
        \\
        \\[a]
        \\key = 2
        \\
    , error.InvalidTable);
}

test "parse table overwriting key fails" {
    try testParseFails(
        \\a = 1
        \\
        \\[a]
        \\key = 2
        \\
    , error.InvalidTable);
}

test "parse array table" {
    var result = try testParse(
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "products");
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    const t0 = try expectArrayTable(arr, 0);
    try expectString(t0, "name", "Hammer");
    const t1 = try expectArrayTable(arr, 1);
    try expectString(t1, "name", "Nail");
}

test "parse nested array table" {
    var result = try testParse(
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[[fruits]]
        \\name = "banana"
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "fruits");
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    const t0 = try expectArrayTable(arr, 0);
    try expectString(t0, "name", "apple");
    const t1 = try expectArrayTable(arr, 1);
    try expectString(t1, "name", "banana");
}

test "parse array table with sub-tables" {
    var result = try testParse(
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[fruits.physical]
        \\color = "red"
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "fruits");
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    const t0 = try expectArrayTable(arr, 0);
    try expectString(t0, "name", "apple");
    const phys = try expectTable(t0, "physical");
    try expectString(phys, "color", "red");
}

test "parse empty inline array" {
    var result = try testParse(
        \\arr = []
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "arr");
    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "parse inline array of integers" {
    var result = try testParse(
        \\arr = [1, 2, 3]
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "arr");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try expectArrayInt(arr, 0, 1);
    try expectArrayInt(arr, 1, 2);
    try expectArrayInt(arr, 2, 3);
}

test "parse inline array of strings" {
    var result = try testParse(
        \\arr = ["a", "b", "c"]
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "arr");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try expectArrayString(arr, 0, "a");
    try expectArrayString(arr, 1, "b");
    try expectArrayString(arr, 2, "c");
}

test "parse inline array with trailing comma" {
    var result = try testParse(
        \\arr = [1, 2, 3,]
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "arr");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
}

test "parse inline array with newlines" {
    var result = try testParse(
        \\arr = [
        \\  1,
        \\  2,
        \\  3
        \\]
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "arr");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try expectArrayInt(arr, 0, 1);
    try expectArrayInt(arr, 1, 2);
    try expectArrayInt(arr, 2, 3);
}

test "parse nested inline arrays" {
    var result = try testParse(
        \\arr = [[1, 2], [3, 4]]
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "arr");
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    const inner0 = try expectArrayArray(arr, 0);
    try expectArrayInt(inner0, 0, 1);
    try expectArrayInt(inner0, 1, 2);
    const inner1 = try expectArrayArray(arr, 1);
    try expectArrayInt(inner1, 0, 3);
    try expectArrayInt(inner1, 1, 4);
}

test "parse mixed-type inline array" {
    var result = try testParse(
        \\arr = [1, "two", true]
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "arr");
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try expectArrayInt(arr, 0, 1);
    try expectArrayString(arr, 1, "two");
    try expectArrayBool(arr, 2, true);
}

test "parse empty inline table" {
    var result = try testParse(
        \\tbl = {}
        \\
    );
    defer result.deinit();
    const tbl = try expectTable(&result.root, "tbl");
    try std.testing.expectEqual(@as(usize, 0), tbl.entries.len);
}

test "parse inline table with values" {
    var result = try testParse(
        \\point = {x = 1, y = 2}
        \\
    );
    defer result.deinit();
    const point = try expectTable(&result.root, "point");
    try expectInt(point, "x", 1);
    try expectInt(point, "y", 2);
}

test "parse inline table with string values" {
    var result = try testParse(
        \\name = {first = "Tom", last = "Preston-Werner"}
        \\
    );
    defer result.deinit();
    const name = try expectTable(&result.root, "name");
    try expectString(name, "first", "Tom");
    try expectString(name, "last", "Preston-Werner");
}

test "parse nested inline table" {
    var result = try testParse(
        \\point = {x = 1, y = 2, meta = {created = true}}
        \\
    );
    defer result.deinit();
    const point = try expectTable(&result.root, "point");
    try expectInt(point, "x", 1);
    try expectInt(point, "y", 2);
    const meta = try expectTable(point, "meta");
    try expectBool(meta, "created", true);
}

test "parse inline table with dotted keys" {
    var result = try testParse(
        \\fruit = {apple.color = "red"}
        \\
    );
    defer result.deinit();
    const fruit = try expectTable(&result.root, "fruit");
    const apple = try expectTable(fruit, "apple");
    try expectString(apple, "color", "red");
}

test "parse inline table trailing comma fails in TOML 1.0.0" {
    try testParseFailsWithOpts(
        \\tbl = {a = 1,}
        \\
    , .{ .toml_version = .@"1.0.0" }, error.UnexpectedToken);
}

test "parse inline table trailing comma succeeds in TOML 1.1.0" {
    var result = try testParseWithOpts(
        \\tbl = {a = 1,}
        \\
    , .{ .toml_version = .@"1.1.0" });
    defer result.deinit();
    const tbl = try expectTable(&result.root, "tbl");
    try expectInt(tbl, "a", 1);
}

test "parse extending inline table fails" {
    try testParseFails(
        \\tbl = {a = 1}
        \\tbl.b = 2
        \\
    , error.ExtendedInlineTable);
}

test "parse extending inline table with table header fails" {
    try testParseFails(
        \\tbl = {a = 1}
        \\
        \\[tbl]
        \\b = 2
        \\
    , error.ExtendedInlineTable);
}

test "parse duplicate key fails" {
    try testParseFails(
        \\name = "a"
        \\name = "b"
        \\
    , error.DuplicateKey);
}

test "parse duplicate key in table fails" {
    try testParseFails(
        \\[server]
        \\host = "a"
        \\host = "b"
        \\
    , error.DuplicateKey);
}

test "parse duplicate key via dotted key fails" {
    try testParseFails(
        \\a.b = 1
        \\a.b = 2
        \\
    , error.DuplicateKey);
}

test "parse string with escape sequences" {
    var result = try testParse(
        \\val = "hello\tworld\n"
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "val", "hello\tworld\n");
}

test "parse string with unicode escape" {
    var result = try testParse(
        \\val = "\u0041"
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "val", "A");
}

test "parse string with backslash escape" {
    var result = try testParse(
        \\val = "a\\b"
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "val", "a\\b");
}

test "parse string with quote escape" {
    var result = try testParse(
        \\val = "a\"b"
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "val", "a\"b");
}

test "parse bare key" {
    var result = try testParse(
        \\bare-key = 1
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "bare-key", 1);
}

test "parse bare key with underscores" {
    var result = try testParse(
        \\bare_key = 1
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "bare_key", 1);
}

test "parse quoted key" {
    var result = try testParse(
        \\"quoted key" = 1
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "quoted key", 1);
}

test "parse literal string key" {
    var result = try testParse(
        \\'literal key' = 1
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "literal key", 1);
}

test "parse empty quoted key" {
    var result = try testParse(
        \\"" = 1
        \\
    );
    defer result.deinit();
    try expectInt(&result.root, "", 1);
}

test "parse complex document" {
    var result = try testParse(
        \\title = "TOML Example"
        \\
        \\[owner]
        \\name = "Tom"
        \\
        \\[database]
        \\server = "192.168.1.1"
        \\ports = [8001, 8001, 8002]
        \\enabled = true
        \\
    );
    defer result.deinit();
    try expectString(&result.root, "title", "TOML Example");

    const owner = try expectTable(&result.root, "owner");
    try expectString(owner, "name", "Tom");

    const db = try expectTable(&result.root, "database");
    try expectString(db, "server", "192.168.1.1");
    try expectBool(db, "enabled", true);

    const ports = try expectArray(db, "ports");
    try std.testing.expectEqual(@as(usize, 3), ports.len);
    try expectArrayInt(ports, 0, 8001);
    try expectArrayInt(ports, 1, 8001);
    try expectArrayInt(ports, 2, 8002);
}

test "parse document with array tables and sub-tables" {
    var result = try testParse(
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[fruits.physical]
        \\color = "red"
        \\shape = "round"
        \\
        \\[[fruits]]
        \\name = "banana"
        \\
        \\[fruits.physical]
        \\color = "yellow"
        \\shape = "curved"
        \\
    );
    defer result.deinit();
    const arr = try expectArray(&result.root, "fruits");
    try std.testing.expectEqual(@as(usize, 2), arr.len);

    const apple = try expectArrayTable(arr, 0);
    try expectString(apple, "name", "apple");
    const apple_phys = try expectTable(apple, "physical");
    try expectString(apple_phys, "color", "red");
    try expectString(apple_phys, "shape", "round");

    const banana = try expectArrayTable(arr, 1);
    try expectString(banana, "name", "banana");
    const banana_phys = try expectTable(banana, "physical");
    try expectString(banana_phys, "color", "yellow");
    try expectString(banana_phys, "shape", "curved");
}

test "parse missing value fails" {
    try testParseFails(
        \\key =
        \\
    , error.UnexpectedToken);
}

test "parse missing equals fails" {
    try testParseFails(
        \\key "value"
        \\
    , error.UnexpectedToken);
}

test "parse table header without closing bracket fails" {
    try testParseFails("[server\nhost = 1\n", error.UnexpectedToken);
}

test "parse value after table header on same line fails" {
    try testParseFails("[server] extra\n", error.UnexpectedToken);
}

test "parse dotted key overwriting non-table fails" {
    try testParseFails(
        \\a = 1
        \\a.b = 2
        \\
    , error.InvalidTable);
}
