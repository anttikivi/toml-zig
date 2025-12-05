const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Date = @import("value.zig").Date;
const Datetime = @import("value.zig").Datetime;
const Position = @import("decoder.zig").Position;
const Scanner = @import("Scanner.zig");
const Time = @import("value.zig").Time;
const Token = @import("Scanner.zig").Token;

allocator: Allocator,
scanner: *Scanner,
root_table: *ParsingValue = undefined,
current_table: *ParsingValue = undefined,

var stderr_buffer: [4096]u8 = undefined;

pub const ParsingArray = ArrayList(ParsingValue);
pub const ParsingTable = std.StringArrayHashMap(ParsingValue);
pub const ParsingValue = struct {
    flag: ValueFlag = .{ .inlined = false, .standard = false, .explicit = false },
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
};

const ParseError = Allocator.Error || std.fmt.ParseIntError || std.Io.Writer.Error || error{
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,

    EmptyArray,
    NotArrayOfTables,
    NoTableFound,
    DuplicateKey,

    InvalidDate,
    InvalidDatetime,
    InvalidNumber,
    InvalidTime,
    SyntaxError,
    UnexpectedEndOfInput,
    UnexpectedToken,

    Reported,
};

const ValueFlag = packed struct {
    inlined: bool,
    standard: bool,
    explicit: bool,
};

pub fn init(self: *@This(), arena: Allocator, scanner: *Scanner, root: *ParsingValue) void {
    self.* = .{
        .allocator = arena,
        .scanner = scanner,
        .root_table = root,
        .current_table = root,
    };
}

/// Parse standard table header expression and set the new table as the current
/// table in the parser.
pub fn parseTableExpression(self: *@This()) !void {
    const keys = try self.parseKey();

    assert(keys.len > 0);

    const next_token = try self.scanner.nextKey();
    if (next_token != .right_bracket) {
        return self.fail("expected closing ']' after table header");
    }

    const after_bracket = try self.scanner.nextKey();
    if (after_bracket != .line_feed and after_bracket != .end_of_file) {
        return self.fail("table header must be followed by newline");
    }

    const last_key = keys[keys.len - 1];
    var table = try self.descendToTable(keys[0 .. keys.len - 1], self.root_table, true);

    if (table.value.table.getPtr(last_key)) |value| {
        // Disallow redefining an inline table or array as a standard table
        switch (value.value) {
            .array => {
                return self.fail("cannot redefine array as table");
            },
            .table => {},
            else => {
                return self.fail("cannot redefine value as table");
            },
        }

        table = value;
        if (table.flag.explicit or table.flag.inlined or !table.flag.standard) {
            // Table cannot be defined more than once and inline tables cannot
            // be extended.
            return self.fail("table cannot be defined more than once");
        }
    } else {
        // Add the missing table.
        if (table.flag.inlined) {
            // Inline table may not be extended.
            return self.fail("cannot extend inline table");
        }

        var next_value = try self.addTable(&table.value.table, last_key);
        next_value.flag.standard = true;

        assert(next_value.value == .table);

        switch (next_value.value) {
            .table => table = next_value,
            else => unreachable,
        }
    }

    table.flag.explicit = true;
    self.current_table = table;
}

/// Parse array table header expression and set the new table as the current
/// table in the parser.
pub fn parseArrayTableExpression(self: *@This()) !void {
    const keys = try self.parseKey();

    const next_token = try self.scanner.nextKey();
    if (next_token != .double_right_bracket) {
        return self.fail("expected closing ']]' for array of tables header");
    }

    const after_bracket = try self.scanner.nextKey();
    if (after_bracket != .line_feed and after_bracket != .end_of_file) {
        return self.fail("array table header must be followed by newline");
    }

    const last_key = keys[keys.len - 1];
    var current_value = self.root_table;

    for (keys[0 .. keys.len - 1]) |key| {
        if (current_value.value.table.getPtr(key)) |value| {
            switch (value.value) {
                // For tables, just descend further.
                .table => {
                    current_value = value;
                    continue;
                },

                // For arrays, find the last entry and descend.
                .array => |*array| {
                    if (value.flag.inlined) {
                        return self.fail("cannot extend inline array");
                    }

                    if (array.items.len == 0) {
                        return error.EmptyArray;
                    }

                    const last = &array.items[array.items.len - 1];
                    switch (last.value) {
                        .table => {
                            current_value = last;
                            continue;
                        },
                        else => return error.NotArrayOfTables,
                    }
                },

                else => return error.NoTableFound,
            }
        } else {
            var next_value = try self.addTable(&current_value.value.table, key);
            next_value.flag.standard = true;

            assert(next_value.value == .table);

            switch (next_value.value) {
                .table => current_value = next_value,
                else => unreachable,
            }
            continue;
        }
    }

    if (current_value.value.table.getPtr(last_key)) |value| {
        current_value = value;
    } else {
        // Add the missing array.
        current_value = try self.addArray(&current_value.value.table, last_key);
        assert(current_value.value == .array);
    }

    switch (current_value.value) {
        .array => {}, // continue
        else => return self.fail("unexpected token"),
    }

    if (current_value.flag.inlined) {
        // Cannot extend inline array.
        return self.fail("cannot extend inline array");
    }

    try current_value.value.array.append(self.allocator, .{
        .value = .{
            .table = .init(self.allocator),
        },
    });

    self.current_table = &current_value.value.array.items[current_value.value.array.items.len - 1];
}

/// Parse a key-value expression where the first key token has already been read.
pub fn parseKeyValueExpressionStartingWith(self: *@This(), first: Token) !void {
    const keys = try self.parseKeyStartingWith(first);
    var token = try self.scanner.nextKey();
    if (token != .equal) {
        return self.fail("expected '=' after key");
    }

    token = try self.scanner.nextValue();
    const value = try self.parseValue(token);
    var table = self.current_table;
    for (keys[0 .. keys.len - 1], 0..) |key, i| {
        if (table.value.table.getPtr(key)) |v| {
            switch (v.value) {
                .table => {
                    table = v;
                    continue;
                },
                .array => return error.NotArrayOfTables,
                else => return error.NoTableFound,
            }
        } else {
            if (i > 0 and table.flag.explicit) {
                return self.fail("cannot extend previously defined table using dotted key");
            }

            table = try self.addTable(&table.value.table, key);
            switch (table.value) {
                .table => continue,
                else => unreachable,
            }
        }
    }

    if (table.flag.inlined) {
        return self.fail("cannot extend inline table");
    }

    if (keys.len > 1 and table.flag.explicit) {
        return self.fail("cannot extend previously defined table using dotted key");
    }

    try addValue(&table.value.table, value, keys[keys.len - 1]);
}

/// Add a new array to the given parsing table pointer and return the newly
/// created value.
fn addArray(self: *@This(), table: *ParsingTable, key: []const u8) !*ParsingValue {
    if (table.contains(key)) {
        return self.fail("duplicate key");
    }

    try table.put(
        try self.allocator.dupe(u8, key),
        .{ .value = .{ .array = .empty } },
    );

    return table.getPtr(key).?;
}

/// Add a new table to the given parsing table pointer and return the newly
/// created value.
fn addTable(self: *@This(), table: *ParsingTable, key: []const u8) !*ParsingValue {
    if (table.contains(key)) {
        return self.fail("duplicate key");
    }

    try table.put(
        try self.allocator.dupe(u8, key),
        .{ .value = .{ .table = .init(self.allocator) } },
    );

    return table.getPtr(key).?;
}

/// Add a new value to the given parsing table pointer.
fn addValue(table: *ParsingTable, value: ParsingValue, key: []const u8) !void {
    if (table.contains(key)) {
        return error.DuplicateKey;
    }

    try table.put(key, value);
}

/// Descend to the final table represented by `keys` starting from the root
/// table. If a table for a key does not exist, it will be created.
/// The function returns the final table represented by the keys. If
/// the table in question is parsed from a standard table header,
/// `is_standard` should be `true`.
fn descendToTable(
    self: *@This(),
    keys: [][]const u8,
    root: *ParsingValue,
    is_standard: bool,
) !*ParsingValue {
    var table = root;

    for (keys) |key| {
        if (table.value.table.getPtr(key)) |value| {
            switch (value.value) {
                // For tables, just descend further.
                .table => {
                    table = value;
                    continue;
                },

                // For arrays, find the last entry and descend.
                .array => |*array| {
                    if (array.items.len == 0) {
                        return error.EmptyArray;
                    }

                    const last = &array.items[array.items.len - 1];
                    switch (last.value) {
                        .table => {
                            table = last;
                            continue;
                        },
                        else => return error.NotArrayOfTables,
                    }
                },

                else => return error.NoTableFound,
            }
        } else {
            var next_value = try self.addTable(&table.value.table, key);
            next_value.flag.standard = is_standard;

            assert(next_value.value == .table);

            switch (next_value.value) {
                .table => table = next_value,
                else => unreachable,
            }

            continue;
        }
    }

    return table;
}

/// Normalize a string values in got from the TOML document, parsing
/// the escape codes from it. The caller owns the returned string and must
/// call `free` on it.
fn normalizeString(self: *@This(), token: Token) ![]const u8 {
    switch (token) {
        .literal, .literal_string, .multiline_literal_string => |s| return s,
        .string, .multiline_string => {}, // continue
        else => unreachable,
    }

    const orig: []const u8 = switch (token) {
        .string, .multiline_string => |s| s,
        else => unreachable,
    };
    if (std.mem.indexOfScalar(u8, orig, '\\') == null) {
        return orig;
    }

    var dst: ArrayList(u8) = .empty;
    errdefer dst.deinit(self.allocator);

    var i: usize = 0;
    while (i < orig.len) : (i += 1) {
        if (orig[i] != '\\') {
            try dst.append(self.allocator, orig[i]);
            continue;
        }

        i += 1;
        const c = orig[i];
        switch (c) {
            '"', '\\' => try dst.append(self.allocator, c),
            'b' => try dst.append(self.allocator, 8), // \b
            'f' => try dst.append(self.allocator, 12), // \f
            't' => try dst.append(self.allocator, '\t'),
            'r' => try dst.append(self.allocator, '\r'),
            'n' => try dst.append(self.allocator, '\n'),
            'u', 'U' => {
                const len: usize = if (c == 'u') 4 else 8;
                const start = i + 1;
                if (start + len > orig.len) {
                    return error.UnexpectedEndOfInput;
                }

                const s = orig[start .. start + len];
                const codepoint = try std.fmt.parseInt(u21, s, 16);
                var buf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(codepoint, &buf);
                try dst.appendSlice(self.allocator, buf[0..n]);
                i += 1 + len - 1; // -1 because loop will i+=1
            },
            ' ', '\t', '\r', '\n' => {
                // Line-ending backslash: trim all immediately following
                // spaces, tabs, and newlines.
                var idx = i;
                var consumed = false;
                while (idx < orig.len and (orig[idx] == ' ' or orig[idx] == '\t' or
                    orig[idx] == '\r' or orig[idx] == '\n')) : (idx += 1)
                {
                    consumed = true;
                }

                if (!consumed) {
                    return error.UnexpectedToken;
                }

                i = idx - 1; // continue after the whitespace block
            },
            else => try dst.append(self.allocator, c),
        }
    }

    return dst.toOwnedSlice(self.allocator);
}

/// Parse a multipart key.
fn parseKey(self: *@This()) ![][]const u8 {
    const key_token = try self.scanner.nextKey();
    switch (key_token) {
        .literal, .string, .literal_string => {},
        else => return error.UnexpectedToken,
    }

    var key_parts: ArrayList([]const u8) = .empty;
    errdefer key_parts.deinit(self.allocator);

    try key_parts.append(self.allocator, try self.normalizeString(key_token));

    while (true) {
        const old_cursor = self.scanner.cursor;
        const old_line = self.scanner.line;

        // If the next part is a dot, eat it.
        const dot = try self.scanner.nextKey();

        if (dot != .dot) {
            self.scanner.cursor = old_cursor;
            self.scanner.line = old_line;
            break;
        }

        const next_token = try self.scanner.nextKey();
        switch (next_token) {
            .literal, .string, .literal_string, .multiline_string => {}, // continue
            else => return error.UnexpectedToken,
        }

        try key_parts.append(self.allocator, try self.normalizeString(next_token));
    }

    return key_parts.toOwnedSlice(self.allocator);
}

/// Parse a multipart key when the first token has already been read by
/// the caller.
fn parseKeyStartingWith(self: *@This(), first: Token) ![][]const u8 {
    switch (first) {
        .literal, .string, .literal_string => {},
        else => return error.UnexpectedToken,
    }

    var key_parts: ArrayList([]const u8) = .empty;
    errdefer key_parts.deinit(self.allocator);

    try key_parts.append(self.allocator, try self.normalizeString(first));

    while (true) {
        const old_cursor = self.scanner.cursor;
        const old_line = self.scanner.line;

        const dot = try self.scanner.nextKey();
        if (dot != .dot) {
            self.scanner.cursor = old_cursor;
            self.scanner.line = old_line;
            break;
        }

        const next_token = try self.scanner.nextKey();
        switch (next_token) {
            .literal, .string, .literal_string, .multiline_string => {},
            else => return error.UnexpectedToken,
        }

        try key_parts.append(self.allocator, try self.normalizeString(next_token));
    }

    return key_parts.toOwnedSlice(self.allocator);
}

fn parseValue(self: *@This(), token: Token) ParseError!ParsingValue {
    switch (token) {
        .string, .multiline_string, .literal_string, .multiline_literal_string => {
            const ret = try self.normalizeString(token);
            return .{ .value = .{ .string = ret } };
        },
        .int => |n| return .{ .value = .{ .int = n } },
        .float => |f| return .{ .value = .{ .float = f } },
        .bool => |b| return .{ .value = .{ .bool = b } },
        .datetime => |dt| return .{ .value = .{ .datetime = dt } },
        .local_datetime => |dt| return .{ .value = .{ .local_datetime = dt } },
        .local_date => |d| return .{ .value = .{ .local_date = d } },
        .local_time => |t| return .{ .value = .{ .local_time = t } },
        .left_bracket => return self.parseInlineArray(),
        .left_brace => return self.parseInlineTable(),
        else => return error.UnexpectedToken,
    }
}

fn parseInlineArray(self: *@This()) !ParsingValue {
    var arr: ParsingArray = .empty;
    errdefer arr.deinit(self.allocator);

    var need_comma = false;

    var i: usize = 0;
    while (i < self.scanner.input.len) : (i += 1) { // upper bound
        var token = try self.scanner.nextValue();
        while (token == .line_feed) {
            token = try self.scanner.nextValue();
        }

        if (token == .right_bracket) {
            break;
        }

        if (token == .comma) {
            if (need_comma) {
                need_comma = false;
                continue;
            }
            return error.SyntaxError;
        }

        if (need_comma) {
            return error.SyntaxError;
        }

        try arr.append(self.allocator, try self.parseValue(token));
        need_comma = true;
    }

    var ret: ParsingValue = .{ .value = .{ .array = arr } };
    setFlagRecursively(&ret, .{ .inlined = true, .standard = false, .explicit = false });
    return ret;
}

fn parseInlineTable(self: *@This()) ParseError!ParsingValue {
    var ret: ParsingValue = .{ .value = .{ .table = .init(self.allocator) } };
    var need_comma = false;
    var was_comma = false;

    var i: usize = 0;
    while (i < self.scanner.input.len) : (i += 1) { // upper bound
        var token = try self.scanner.nextKey();
        if (token == .right_brace) {
            if (was_comma) {
                return self.fail("trailing comma before '}' in inline table");
            }
            // Allow closing immediately after a key-value without requiring
            // a comma.
            break;
        }

        if (token == .comma) {
            if (need_comma) {
                need_comma = false;
                was_comma = true;
                continue;
            }

            return self.fail("unexpected ',' in inline table");
        }

        if (need_comma) {
            return self.fail("missing ',' between inline table entries");
        }

        if (token == .line_feed) {
            return self.fail("newline not allowed inside inline table");
        }

        const keys = try self.parseKeyStartingWith(token);
        var current_table = try self.descendToTable(keys[0 .. keys.len - 1], &ret, false);
        if (current_table.flag.inlined) {
            return self.fail("cannot extend inline table");
        }

        current_table.flag.explicit = true;

        token = try self.scanner.nextValue();
        if (token != .equal) {
            if (token == .line_feed) {
                return self.fail("newline not allowed after key in inline table (expected '=')");
            }

            return self.fail("expected '=' after key in inline table");
        }

        token = try self.scanner.nextValue();
        const parsed_val = try self.parseValue(token);
        try switch (current_table.value) {
            .table => |*t| addValue(
                t,
                parsed_val,
                try self.allocator.dupe(u8, keys[keys.len - 1]),
            ),
            else => return error.UnexpectedToken,
        };

        need_comma = true;
        was_comma = false;
    }

    setFlagRecursively(&ret, .{ .inlined = true, .standard = false, .explicit = false });
    return ret;
}

/// Parse a key-value expression and set the value to the current table.
fn parseKeyValueExpression(self: *@This()) !void {
    const keys = try self.parseKey();
    var token = try self.scanner.nextKey();
    if (token != .equal) {
        return self.fail("expected '=' after key");
    }

    token = try self.scanner.nextValue();
    const value = try self.parseValue(token);
    var table = self.current_table;
    for (keys[0 .. keys.len - 1], 0..) |key, i| {
        if (table.value.table.getPtr(key)) |v| {
            switch (v.value) {
                // For tables, just descend further.
                .table => {
                    table = v;
                    continue;
                },
                .array => return error.NotArrayOfTables,
                else => return error.NoTableFound,
            }
        } else {
            if (i > 0 and table.flag.explicit) {
                return self.fail("cannot extend previously defined table using dotted key");
            }

            table = try self.addTable(&table.value.table, key);
            switch (table.value) {
                .table => continue,
                else => unreachable,
            }
        }
    }

    if (table.flag.inlined) {
        return self.fail("cannot extend inline table");
    }

    if (keys.len > 1 and table.flag.explicit) {
        return self.fail("cannot extend previously defined table using dotted key");
    }

    try addValue(&table.value.table, value, keys[keys.len - 1]);
}

fn setFlagRecursively(value: *ParsingValue, flag: ValueFlag) void {
    if (flag.inlined) {
        value.flag.inlined = true;
    }

    if (flag.standard) {
        value.flag.standard = true;
    }

    if (flag.explicit) {
        value.flag.explicit = true;
    }

    switch (value.value) {
        .array => |*arr| for (arr.items) |*item| {
            setFlagRecursively(item, flag);
        },
        .table => |*table| for (table.values()) |*item| {
            setFlagRecursively(item, flag);
        },
        else => {},
    }
}

fn fail(self: *const @This(), msg: []const u8) error{ Reported, WriteFailed } {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print("{f}", .{Position.findLineKnown(
        self.scanner.input,
        self.scanner.cursor,
        self.scanner.line,
    )});
    try stderr.writeByte(' ');
    try stderr.writeAll(msg);
    try stderr.writeByte('\n');
    try stderr.flush();

    return error.Reported;
}
