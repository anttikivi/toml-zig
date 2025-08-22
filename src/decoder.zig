const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;

const Date = @import("value.zig").Date;
const Datetime = @import("value.zig").Datetime;
const Scanner = @import("Scanner.zig");
const Time = @import("value.zig").Time;
const Token = @import("Scanner.zig").Token;
const Value = @import("value.zig").Value;

/// Rich diagnostics information for parse failures.
///
/// This structure is populated by `parseWithDiagnostics` when parsing fails.
/// The fields are safe to print directly. `snippet` points into the original
/// `input`, so it remains valid for the lifetime of that slice.
pub const Diagnostics = struct {
    /// A short human‑readable description of the problem.
    message: []const u8 = undefined,

    /// 1‑based line index where the error occurred.
    line: usize = undefined,

    /// 1‑based column (byte offset within the line).
    column: usize = undefined,

    /// The line of text where the error occurred (slice of the original input).
    snippet: []const u8 = undefined,

    /// For formatting with std.fmt. Supports only the default format, and
    /// provides a helpful way to easily print the diagnostics information.
    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print(
            "error parsing TOML document on line {d}, column {d}\n",
            .{ self.line, self.column },
        );

        try writer.print("{s}\n", .{self.snippet});

        // TODO: Is this smart way to do this?
        var i: usize = 1;
        while (i < self.column - 1) : (i += 1) {
            try writer.writeByte(' ');
        }

        try writer.writeByte('^');
        try writer.writeByte(' ');
        try writer.writeAll(self.message);
    }
};

/// The parsing state.
const Parser = struct {
    allocator: Allocator,
    scanner: *Scanner,
    root_table: *ParsingValue = undefined,
    current_table: *ParsingValue = undefined,

    const ParseError = Allocator.Error || std.fmt.ParseIntError || error{
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
    };

    const ValueFlag = packed struct {
        inlined: bool,
        standard: bool,
        explicit: bool,
    };

    const ParsingArray = ArrayList(ParsingValue);
    const ParsingTable = std.StringArrayHashMap(ParsingValue);
    const ParsingValue = struct {
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

    fn init(arena: Allocator, scanner: *Scanner, root: *ParsingValue) @This() {
        return .{
            .allocator = arena,
            .scanner = scanner,
            .root_table = root,
            .current_table = root,
        };
    }

    /// Add a new array to the given parsing table pointer and return the newly
    /// created value.
    fn addArray(self: *@This(), table: *ParsingTable, key: []const u8) !*ParsingValue {
        if (table.contains(key)) {
            return error.DuplicateKey;
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
            return error.DuplicateKey;
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
        if (mem.indexOfScalar(u8, orig, '\\') == null) {
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

    /// Parse a multipart key when the first token has already been read by the caller.
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

        // TODO: Add a limit.
        while (true) {
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

        // TODO: Add a limit.
        while (true) {
            var token = try self.scanner.nextKey();
            if (token == .right_brace) {
                if (was_comma) {
                    // Trailing comma before closing brace is invalid.
                    self.scanner.setErrorMessage("trailing comma before '}' in inline table");
                    return error.UnexpectedToken;
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
                self.scanner.setErrorMessage("unexpected ',' in inline table");
                return error.UnexpectedToken;
            }

            if (need_comma) {
                self.scanner.setErrorMessage("missing ',' between inline table entries");
                return error.UnexpectedToken;
            }

            if (token == .line_feed) {
                self.scanner.setErrorMessage("newline not allowed inside inline table");
                return error.UnexpectedToken;
            }

            const keys = try self.parseKeyStartingWith(token);
            var current_table = try self.descendToTable(keys[0 .. keys.len - 1], &ret, false);
            if (current_table.flag.inlined) {
                // Cannot extend inline table.
                self.scanner.setErrorMessage("cannot extend inline table");
                return error.UnexpectedToken;
            }

            current_table.flag.explicit = true;

            token = try self.scanner.nextValue();
            if (token != .equal) {
                if (token == .line_feed) {
                    // Unexpected newline.
                    self.scanner.setErrorMessage("newline not allowed after key in inline table (expected '=')");
                    return error.UnexpectedToken;
                }

                // Missing `=`.
                self.scanner.setErrorMessage("expected '=' after key in inline table");
                return error.UnexpectedToken;
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

    /// Parse standard table header expression and set the new table as
    /// the current table in the parser.
    fn parseTableExpression(self: *@This()) !void {
        const keys = try self.parseKey();

        const next_token = try self.scanner.nextKey();
        if (next_token != .right_bracket) {
            self.scanner.setErrorMessage("expected closing ']' for table header");
            return error.UnexpectedToken;
        }

        const after_bracket = try self.scanner.nextKey();
        if (after_bracket != .line_feed and after_bracket != .end_of_file) {
            self.scanner.setErrorMessage("table header must be followed by newline");
            return error.UnexpectedToken;
        }

        const last_key = keys[keys.len - 1];
        var table = try self.descendToTable(keys[0 .. keys.len - 1], self.root_table, true);

        if (table.value.table.getPtr(last_key)) |value| {
            // Disallow redefining an inline table or array as a standard table
            switch (value.value) {
                .array => {
                    self.scanner.setErrorMessage("cannot redefine array as table");
                    return error.UnexpectedToken;
                },
                .table => {},
                else => {
                    self.scanner.setErrorMessage("cannot redefine value as table");
                    return error.UnexpectedToken;
                },
            }

            table = value;
            if (table.flag.explicit or table.flag.inlined or !table.flag.standard) {
                // Table cannot be defined more than once and inline tables cannot be extended.
                self.scanner.setErrorMessage("table cannot be defined more than once");
                return error.UnexpectedToken;
            }
        } else {
            // Add the missing table.
            if (table.flag.inlined) {
                // Inline table may not be extended.
                self.scanner.setErrorMessage("cannot extend inline table");
                return error.UnexpectedToken;
            }

            var next_value = try self.addTable(&table.value.table, last_key);
            next_value.flag.standard = true;
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
    fn parseArrayTableExpression(self: *@This()) !void {
        const keys = try self.parseKey();

        const next_token = try self.scanner.nextKey();
        if (next_token != .double_right_bracket) {
            self.scanner.setErrorMessage("expected closing ']]' for array of tables header");
            return error.UnexpectedToken;
        }

        const after_bracket = try self.scanner.nextKey();
        if (after_bracket != .line_feed and after_bracket != .end_of_file) {
            self.scanner.setErrorMessage("array table header must be followed by newline");
            return error.UnexpectedToken;
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
                            // Cannot expand array.
                            self.scanner.setErrorMessage("cannot extend inline array");
                            return error.UnexpectedToken;
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
            assert(mem.eql(u8, @tagName(current_value.value), "array"));
        }

        switch (current_value.value) {
            .array => {}, // continue
            else => return error.UnexpectedToken,
        }

        if (current_value.flag.inlined) {
            // Cannot extend inline array.
            self.scanner.setErrorMessage("cannot extend inline array");
            return error.UnexpectedToken;
        }

        try current_value.value.array.append(self.allocator, .{ .value = .{ .table = .init(self.allocator) } });
        self.current_table = &current_value.value.array.items[current_value.value.array.items.len - 1];
    }

    /// Parse a key-value expression and set the value to the current table.
    fn parseKeyValueExpression(self: *@This()) !void {
        const keys = try self.parseKey();
        var token = try self.scanner.nextKey();
        if (token != .equal) {
            self.scanner.setErrorMessage("expected '=' after key");
            return error.UnexpectedToken;
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
                    // Cannot extend a previously defined table using dotted
                    // expression.
                    self.scanner.setErrorMessage(
                        "cannot extend previously defined table using dotted key",
                    );
                    return error.UnexpectedToken;
                }
                table = try self.addTable(&table.value.table, key);
                switch (table.value) {
                    .table => continue,
                    else => unreachable,
                }
            }
        }

        if (table.flag.inlined) {
            // Inline table cannot be extended.
            self.scanner.setErrorMessage("cannot extend inline table");
            return error.UnexpectedToken;
        }

        if (keys.len > 1 and table.flag.explicit) {
            // Cannot extend a previously defined table using dotted expression.
            self.scanner.setErrorMessage("cannot extend previously defined table using dotted key");
            return error.UnexpectedToken;
        }

        try addValue(&table.value.table, value, keys[keys.len - 1]);
    }

    /// Parse a key-value expression where the first key token has already been read.
    fn parseKeyValueExpressionStartingWith(self: *@This(), first: Token) !void {
        const keys = try self.parseKeyStartingWith(first);
        var token = try self.scanner.nextKey();
        if (token != .equal) {
            self.scanner.setErrorMessage("expected '=' after key");
            return error.UnexpectedToken;
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
                    self.scanner.setErrorMessage(
                        "cannot extend previously defined table using dotted key",
                    );
                    return error.UnexpectedToken;
                }
                table = try self.addTable(&table.value.table, key);
                switch (table.value) {
                    .table => continue,
                    else => unreachable,
                }
            }
        }

        if (table.flag.inlined) {
            self.scanner.setErrorMessage("cannot extend inline table");
            return error.UnexpectedToken;
        }

        if (keys.len > 1 and table.flag.explicit) {
            self.scanner.setErrorMessage("cannot extend previously defined table using dotted key");
            return error.UnexpectedToken;
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
};

/// Parse a TOML document. On success, returns the root `Value` (always
/// a `.table`). The returned `Value` tree is allocated from `allocator` and
/// must be freed by calling `Value.deinit()`.
pub fn parse(allocator: Allocator, input: []const u8) !Value {
    // TODO: Maybe add an option to skip the UTF-8 validation for faster
    // parsing.
    if (!utf8Validate(input)) {
        return error.InvalidUtf8;
    }

    // Use a temporary arena for all intermediate parsing allocations.
    var arena_instance: std.heap.ArenaAllocator = .init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var parsing_root: Parser.ParsingValue = .{ .value = .{ .table = .init(arena) } };
    var scanner = Scanner.initCompleteInput(arena, input);
    var parser = Parser.init(arena, &scanner, &parsing_root);

    // Set an upper limit for the loop for safety. There cannot be more tokens
    // than there are characters in the input. If the input is streamed, this
    // needs changing.
    // TODO: See about setting the limit back.
    while (true) {
        var token = try scanner.nextKey();
        if (token == .end_of_file) {
            break;
        }

        switch (token) {
            .line_feed => continue,
            .left_bracket => {
                try parser.parseTableExpression();
                continue;
            },
            .double_left_bracket => {
                try parser.parseArrayTableExpression();
                continue;
            },
            .end_of_file => unreachable,
            .literal,
            .string,
            .literal_string,
            => try parser.parseKeyValueExpressionStartingWith(token),
            else => return error.UnexpectedToken,
        }

        token = try scanner.nextKey();
        if (token == .line_feed or token == .end_of_file) {
            continue;
        }

        return error.UnexpectedToken;
    }

    return parseResult(allocator, parsing_root);
}

/// Parse a TOML document with better diagnostics output. On success, returns
/// the root `Value` (always a `.table`). On failure, returns an error and, if
/// `diag` is non-null, fills it with a human‑readable message and the exact
/// source location (line, column, snippet).
///
/// The returned `Value` tree is allocated from `allocator` and must be freed by
/// calling `Value.deinit()`.
pub fn parseWithDiagnostics(allocator: Allocator, input: []const u8, diag: ?*Diagnostics) !Value {
    if (!utf8Validate(input)) {
        if (diag) |outp| {
            const pos = computePlace(input, 0);
            outp.* = .{
                .message = "input is not valid UTF-8",
                .line = pos.line,
                .column = pos.column,
                .snippet = pos.snippet,
            };
        }
        return error.InvalidUtf8;
    }

    var arena_instance: std.heap.ArenaAllocator = .init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var parsing_root: Parser.ParsingValue = .{ .value = .{ .table = .init(arena) } };
    var scanner = Scanner.initCompleteInput(arena, input);
    scanner.last_error_message = null;
    var parser = Parser.init(arena, &scanner, &parsing_root);

    // TODO: See about setting the limit back.
    while (true) {
        var token = scanner.nextKey() catch |e| {
            if (diag) |outp| {
                const pos = computePlace(input, scanner.cursor);
                outp.* = .{
                    .message = scanner.last_error_message orelse defaultErrorMessage(e),
                    .line = pos.line,
                    .column = pos.column,
                    .snippet = pos.snippet,
                };
            }
            return e;
        };
        if (token == .end_of_file) {
            break;
        }

        const step_err: ?anyerror = switch (token) {
            .line_feed => null,
            .left_bracket => blk: {
                parser.parseTableExpression() catch |e| break :blk e;
                break :blk null;
            },
            .double_left_bracket => blk: {
                parser.parseArrayTableExpression() catch |e| break :blk e;
                break :blk null;
            },
            .literal, .string, .literal_string => blk: {
                parser.parseKeyValueExpressionStartingWith(token) catch |e| break :blk e;
                break :blk null;
            },
            else => error.UnexpectedToken,
        };
        if (step_err) |e| {
            if (diag) |outp| {
                const pos = computePlace(input, scanner.cursor);
                outp.* = .{
                    .message = scanner.last_error_message orelse defaultErrorMessage(e),
                    .line = pos.line,
                    .column = pos.column,
                    .snippet = pos.snippet,
                };
            }
            return e;
        }

        if (token == .literal or token == .string or token == .literal_string) {
            token = scanner.nextKey() catch |e| {
                if (diag) |outp| {
                    const pos = computePlace(input, scanner.cursor);
                    outp.* = .{
                        .message = scanner.last_error_message orelse defaultErrorMessage(e),
                        .line = pos.line,
                        .column = pos.column,
                        .snippet = pos.snippet,
                    };
                }
                return e;
            };
            if (token == .line_feed or token == .end_of_file) {
                continue;
            }

            if (diag) |outp| {
                const pos = computePlace(input, scanner.cursor);
                outp.* = .{
                    .message = scanner.last_error_message orelse defaultErrorMessage(
                        error.UnexpectedToken,
                    ),
                    .line = pos.line,
                    .column = pos.column,
                    .snippet = pos.snippet,
                };
            }
            return error.UnexpectedToken;
        }
    }

    return parseResult(allocator, parsing_root);
}

fn computePlace(input: []const u8, cursor: usize) struct {
    line: usize,
    column: usize,
    snippet: []const u8,
} {
    var i: usize = 0;
    var line: usize = 1;
    while (i < cursor and i < input.len) : (i += 1) {
        if (input[i] == '\n') line += 1;
    }

    var start: usize = if (cursor > 0) cursor - 1 else 0;
    while (start > 0 and input[start - 1] != '\n') : (start -= 1) {}

    var end: usize = cursor;
    while (end < input.len and input[end] != '\n') : (end += 1) {}

    const col = (cursor - start) + 1;
    return .{ .line = line, .column = col, .snippet = input[start..end] };
}

/// Map an error tag to a short, user‑facing message.
fn defaultErrorMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.UnexpectedToken => "unexpected token",
        error.SyntaxError => "syntax error",
        error.UnexpectedEndOfInput => "unexpected end of input",
        error.InvalidNumber => "invalid number literal",
        error.InvalidDate => "invalid date literal",
        error.InvalidTime => "invalid time literal",
        error.InvalidDatetime => "invalid datetime literal",
        error.DuplicateKey => "duplicate key",
        error.NoTableFound => "invalid dotted key path (no such table)",
        error.NotArrayOfTables => "expected array of tables",
        error.EmptyArray => "array cannot be empty here",
        error.InvalidUtf8 => "input is not valid UTF-8",
        error.InvalidCharacter => "invalid character",
        else => "parse error",
    };
}

/// Convert the intermediate parsing values into the proper TOML return values.
fn parseResult(allocator: Allocator, parsed_value: Parser.ParsingValue) !Value {
    switch (parsed_value.value) {
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .int => |n| return .{ .int = n },
        .float => |f| return .{ .float = f },
        .bool => |b| return .{ .bool = b },
        .datetime => |dt| return .{ .datetime = dt },
        .local_datetime => |dt| return .{ .local_datetime = dt },
        .local_date => |d| return .{ .local_date = d },
        .local_time => |t| return .{ .local_time = t },
        .array => |arr| {
            var val: Value = .{ .array = .empty };
            for (arr.items) |item| {
                try val.array.append(allocator, try parseResult(allocator, item));
            }
            return val;
        },
        .table => |t| {
            var val: Value = .{ .table = .init(allocator) };
            var it = t.iterator();
            while (it.next()) |entry| {
                try val.table.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try parseResult(allocator, entry.value_ptr.*),
                );
            }
            return val;
        },
    }
}

/// Check if the input is a valid UTF-8 string. The function goes through
/// the whole input and checks each byte. It may be skipped if working under
/// strict constraints.
///
/// See: http://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
fn utf8Validate(input: []const u8) bool {
    const Utf8State = enum { start, a, b, c, d, e, f, g };

    var line: usize = 1; // TODO: We need to print actual information and the line number if the string is not UTF-8.
    var state: Utf8State = .start;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (c == '\n') {
            line += 1;
        }

        switch (state) {
            .start => switch (c) {
                0...0x7F => {},
                0xC2...0xDF => state = .a,
                0xE1...0xEC, 0xEE...0xEF => state = .b,
                0xE0 => state = .c,
                0xED => state = .d,
                0xF1...0xF3 => state = .e,
                0xF0 => state = .f,
                0xF4 => state = .g,
                0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return false,
            },
            .a => switch (c) {
                0x80...0xBF => state = .start,
                else => return false,
            },
            .b => switch (c) {
                0x80...0xBF => state = .a,
                else => return false,
            },
            .c => switch (c) {
                0xA0...0xBF => state = .a,
                else => return false,
            },
            .d => switch (c) {
                0x80...0x9F => state = .a,
                else => return false,
            },
            .e => switch (c) {
                0x80...0xBF => state = .b,
                else => return false,
            },
            .f => switch (c) {
                0x90...0xBF => state = .b,
                else => return false,
            },
            .g => switch (c) {
                0x80...0x8F => state = .b,
                else => return false,
            },
        }
    }

    return true;
}

test "parse basic scalars" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "a = 1\n" ++
        "b = \"hello\"\n" ++
        "c = true\n" ++
        "d = 0x10\n" ++
        "e = 1.5\n";

    var root = try parse(alloc, input);
    defer root.deinit(alloc);

    // Access via switch for clarity
    switch (root) {
        .table => |t| {
            try testing.expect(t.contains("a"));
            try testing.expect(t.contains("b"));
            try testing.expect(t.contains("c"));
            try testing.expect(t.contains("d"));
            try testing.expect(t.contains("e"));

            try testing.expectEqual(@as(i64, 1), t.get("a").?.int);
            try testing.expectEqualStrings("hello", t.get("b").?.string);
            try testing.expectEqual(true, t.get("c").?.bool);
            try testing.expectEqual(@as(i64, 16), t.get("d").?.int);
            try testing.expectApproxEqAbs(@as(f64, 1.5), t.get("e").?.float, 1e-12);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parse arrays and inline tables" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "arr = [1, 2, 3]\n" ++
        "obj = { x = \"y\", n = 2 }\n";

    var root = try parse(alloc, input);
    defer root.deinit(alloc);

    switch (root) {
        .table => |t| {
            const arr = t.get("arr").?.array;
            try testing.expectEqual(@as(usize, 3), arr.items.len);
            try testing.expectEqual(@as(i64, 1), arr.items[0].int);
            try testing.expectEqual(@as(i64, 2), arr.items[1].int);
            try testing.expectEqual(@as(i64, 3), arr.items[2].int);

            const obj = t.get("obj").?.table;
            try testing.expectEqualStrings("y", obj.get("x").?.string);
            try testing.expectEqual(@as(i64, 2), obj.get("n").?.int);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parse datetimes and local types" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "dt = 1985-06-18T17:04:07Z\n" ++
        "ld = 1985-06-18\n" ++
        "lt = 17:04:07\n";

    var root = try parse(alloc, input);
    defer root.deinit(alloc);

    switch (root) {
        .table => |t| {
            const dt = t.get("dt").?.datetime;
            try testing.expectEqual(@as(u16, 1985), dt.year);
            try testing.expectEqual(@as(u8, 6), dt.month);
            try testing.expectEqual(@as(u8, 18), dt.day);
            try testing.expectEqual(@as(i16, 0), dt.tz.?);

            const ld = t.get("ld").?.local_date;
            try testing.expectEqual(@as(u16, 1985), ld.year);
            try testing.expectEqual(@as(u8, 6), ld.month);
            try testing.expectEqual(@as(u8, 18), ld.day);

            const lt = t.get("lt").?.local_time;
            try testing.expectEqual(@as(u8, 17), lt.hour);
            try testing.expectEqual(@as(u8, 4), lt.minute);
            try testing.expectEqual(@as(u8, 7), lt.second);
        },
        else => return error.TestExpectedEqual,
    }
}

test "float leading zero and duplicate inline key" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // leading zero float
    try testing.expectError(error.InvalidNumber, parse(alloc, "x = 03.14\n"));

    // duplicate key in inline table
    try testing.expectError(error.DuplicateKey, parse(alloc, "a = { b = 1, b = 2 }\n"));
}
