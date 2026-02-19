const Scanner = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const DecodeOptions = @import("decoder.zig").DecodeOptions;
const Diagnostics = @import("decoder.zig").Diagnostics;
const TomlVersion = @import("root.zig").TomlVersion;
const Datetime = @import("value.zig").Datetime;
const Date = @import("value.zig").Date;
const Time = @import("value.zig").Time;

features: Features,

/// The general-purpose allocator used to create the parsing arena. Here it is
/// used for allocating the diagnostics message if the decoding fails.
gpa: Allocator,
input: []const u8,
cursor: usize = 0,
line: usize = 1,
diagnostics: ?*Diagnostics = null,

pub const Token = union(enum) {
    dot,
    equal,
    comma,
    left_bracket, // [
    double_left_bracket, // [[
    right_bracket, // ]
    double_right_bracket, // ]]
    left_brace, // {
    right_brace, // }

    literal: []const u8,
    string: []const u8,
    multiline_string: []const u8,
    literal_string: []const u8,
    multiline_literal_string: []const u8,

    int: i64,
    float: f64,
    bool: bool,

    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,

    line_feed,
    end_of_file,
};

const Error = Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError || error{
    InvalidControlCharacter,
    InvalidDatetime,
    InvalidEscapeSequence,
    InvalidNumber,
    UnexpectedToken,
    UnterminatedString,
    Reported,
};

/// Feature flags that determine which TOML features that have changed since
/// 1.0.0 are supported.
const Features = packed struct {
    escape_e: bool = false,
    escape_xhh: bool = false,
    optional_seconds: bool = false,

    fn init(toml_version: TomlVersion) @This() {
        return switch (toml_version) {
            .@"1.0.0" => .{},
            .@"1.1.0" => .{
                .escape_e = true,
                .escape_xhh = true,
                .optional_seconds = true,
            },
        };
    }
};

pub fn init(gpa: Allocator, input: []const u8, opts: DecodeOptions) Scanner {
    return .{
        .features = Features.init(opts.toml_version),
        .gpa = gpa,
        .input = input,
        .diagnostics = opts.diagnostics,
    };
}

/// Returns the next valid token from the stored TOML input when the parsing is
/// at a key.
pub fn nextKey(self: *Scanner) Error!Token {
    return self.next(true);
}

/// Returns the next valid token from the stored TOML input when the parsing is
/// at a value.
pub fn nextValue(self: *Scanner) Error!Token {
    return self.next(false);
}

/// Returns the next valid token from the stored TOML input.
fn next(self: *Scanner, comptime key_mode: bool) Error!Token {
    while (self.cursor < self.input.len) {
        const c = self.nextChar();
        switch (c) {
            '\n' => return .line_feed,
            ' ', '\t' => continue,
            '#' => {
                while (self.cursor < self.input.len) {
                    switch (self.nextChar()) {
                        // \n, marked as hex to make it clearer that it's one of
                        // the characters that are not permitted.
                        0x0a => break,
                        0...8, 0x0b...0x1f, 0x7f => {
                            return self.fail(.{ .@"error" = error.InvalidControlCharacter });
                        },
                        else => {},
                    }
                }
                continue;
            },
            '.' => return .dot,
            '=' => return .equal,
            ',' => return .comma,
            '[' => {
                if (key_mode and self.cursor < self.input.len and self.input[self.cursor] == '[') {
                    _ = self.nextChar();
                    return .double_left_bracket;
                }

                return .left_bracket;
            },
            ']' => {
                if (key_mode and self.cursor < self.input.len and self.input[self.cursor] == ']') {
                    _ = self.nextChar();
                    return .double_right_bracket;
                }

                return .right_bracket;
            },
            '{' => return .left_brace,
            '}' => return .right_brace,
            '"' => {
                // Move back so that `scanString` finds the first quote.
                self.cursor -= 1;
                return self.scanString();
            },
            '\'' => {
                self.cursor -= 1;
                return self.scanLiteralString();
            },
            else => {
                if (c <= 8 or (0x0a <= c and c <= 0x1f) or c == 0x7f) {
                    return self.fail(.{ .@"error" = error.InvalidControlCharacter });
                }

                self.cursor -= 1;
                return if (key_mode) self.scanLiteral() else self.scanNonstringValue();
            },
        }
    }

    return .end_of_file;
}

/// Moves the Scanner to the next position and returns the valid, read
/// character.
fn nextChar(self: *Scanner) u8 {
    assert(self.cursor < self.input.len);

    var c = self.input[self.cursor];
    self.cursor += 1;

    // CRLF counts as a single newline character.
    if (c == '\r' and self.cursor < self.input.len and self.input[self.cursor] == '\n') {
        c = '\n';
        self.cursor += 1;
    }

    if (c == '\n') {
        self.line += 1;
    }

    return c;
}

fn matchN(self: *const Scanner, c: u8, n: comptime_int) bool {
    comptime if (n < 2) {
        @compileError("calling Scanner.matchN with n < 2");
    };

    assert(c != '\n');

    if (self.cursor + n > self.input.len) {
        return false;
    }

    inline for (0..n) |i| {
        if (self.input[self.cursor + i] != c) {
            return false;
        }
    }

    return true;
}

fn scanString(self: *Scanner) !Token {
    assert(self.cursor < self.input.len);
    assert(self.input[self.cursor] == '"');

    if (self.matchN('"', 3)) {
        return self.scanMultilineString();
    }

    _ = self.nextChar(); // skip opening quote
    const start = self.cursor;

    while (self.cursor < self.input.len and self.input[self.cursor] != '"') {
        var c = self.input[self.cursor];
        if (c == '\n' or c == '\r') {
            return self.fail(.{ .@"error" = error.UnterminatedString });
        }

        if (c == '\\') {
            self.cursor += 1;

            if (self.cursor >= self.input.len) {
                return self.fail(.{ .@"error" = error.UnterminatedString });
            }

            c = self.input[self.cursor];

            switch (c) {
                // Skip the "normal" escape sequences.
                '"', '\\', 'b', 'f', 'n', 'r', 't' => self.cursor += 1,

                // Escape character in TOML 1.1.0.
                'e' => if (self.features.escape_e) {
                    self.cursor += 1;
                } else {
                    return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                },

                // \xHH for Unicode codepoints < 256.
                'x' => if (self.features.escape_xhh) {
                    self.cursor += 1;

                    if (self.cursor + 2 > self.input.len) {
                        return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                    }

                    for (0..2) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                } else {
                    return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                },

                'u' => {
                    self.cursor += 1;

                    if (self.cursor + 4 > self.input.len) {
                        return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                    }

                    for (0..4) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                'U' => {
                    self.cursor += 1;

                    if (self.cursor + 8 > self.input.len) {
                        return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                    }

                    for (0..8) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                else => return self.fail(.{ .@"error" = error.InvalidEscapeSequence }),
            }
        } else if (isValidChar(c) or c == ' ' or c == '\t') {
            // TODO: See the uses for `isValidChar` and determine if
            // the whitespaces should be included in it.
            self.cursor += 1;
        } else {
            return self.fail(.{ .@"error" = error.InvalidControlCharacter });
        }
    }

    // TODO: Do we compare self.input[self.cursor] != '"' here?
    if (self.cursor >= self.input.len) {
        return self.fail(.{ .@"error" = error.UnterminatedString });
    }

    assert(self.input[self.cursor] == '"');

    const result = self.input[start..self.cursor];
    self.cursor += 1;

    return .{ .string = result };
}

fn scanMultilineString(self: *Scanner) !Token {
    assert(self.matchN('"', 3));

    self.cursor += 3; // skip opening """

    // Newline that immediately follows """ is trimmed.
    if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
        self.cursor += 1;
        self.line += 1;
    } else if (self.cursor + 1 < self.input.len and
        self.input[self.cursor] == '\r' and
        self.input[self.cursor + 1] == '\n')
    {
        self.cursor += 2;
        self.line += 1;
    }

    const start = self.cursor;

    while (self.cursor < self.input.len) {
        var c = self.input[self.cursor];

        if (c == '"') {
            var i: usize = 0;

            while (self.cursor + i < self.input.len and self.input[self.cursor + i] == '"') {
                i += 1;
            }

            if (i >= 3) {
                if (i > 5) {
                    return self.fail(.{
                        .@"error" = error.UnexpectedToken,
                        .msg = "invalid closing quotes",
                    });
                }

                const extra = i - 3;
                const result = self.input[start .. self.cursor + extra];
                self.cursor += i;

                assert(!std.mem.startsWith(u8, result, "\"\"\""));
                assert(!std.mem.endsWith(u8, result, "\"\"\""));

                return .{ .multiline_string = result };
            } else {
                self.cursor += i; // eat the non-closing quotes
            }
        } else if (c == '\\') {
            self.cursor += 1;

            if (self.cursor >= self.input.len) {
                return self.fail(.{ .@"error" = error.UnterminatedString });
            }

            c = self.input[self.cursor];

            switch (c) {
                '"', '\\', 'b', 'f', 'n', 'r', 't' => self.cursor += 1,

                'e' => if (self.features.escape_e) {
                    self.cursor += 1;
                } else {
                    return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                },

                'x' => if (self.features.escape_xhh) {
                    self.cursor += 1;

                    if (self.cursor + 2 > self.input.len) {
                        return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                    }

                    for (0..2) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                } else {
                    return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                },

                'u' => {
                    self.cursor += 1;

                    if (self.cursor + 4 > self.input.len) {
                        return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                    }

                    for (0..4) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                'U' => {
                    self.cursor += 1;

                    if (self.cursor + 8 > self.input.len) {
                        return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                    }

                    for (0..8) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                // Line-ending backslash.
                '\n' => {
                    self.cursor += 1;
                    self.line += 1;
                    try self.skipLineEndingWhitespace();
                },

                '\r' => if (self.cursor + 1 < self.input.len and
                    self.input[self.cursor + 1] == '\n')
                {
                    self.cursor += 2;
                    self.line += 1;
                    try self.skipLineEndingWhitespace();
                } else {
                    return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                },

                ' ', '\t' => {
                    while (self.cursor < self.input.len) {
                        c = self.input[self.cursor];
                        if (c == ' ' or c == '\t') {
                            self.cursor += 1;
                        } else if (c == '\n') {
                            self.cursor += 1;
                            self.line += 1;
                            break;
                        } else if (c == '\r' and self.cursor + 1 < self.input.len and
                            self.input[self.cursor + 1] == '\n')
                        {
                            self.cursor += 2;
                            self.line += 1;
                            break;
                        } else {
                            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
                        }
                    }

                    // After finding newline, eat the rest of the whitespace chars.
                    try self.skipLineEndingWhitespace();
                },

                else => return self.fail(.{ .@"error" = error.InvalidEscapeSequence }),
            }
        } else if (c == '\n') {
            self.cursor += 1;
            self.line += 1;
        } else if (c == '\r' and self.cursor + 1 < self.input.len and
            self.input[self.cursor + 1] == '\n')
        {
            self.cursor += 2;
            self.line += 1;
        } else if (isValidChar(c) or c == ' ' or c == '\t') {
            self.cursor += 1;
        } else {
            return self.fail(.{ .@"error" = error.InvalidControlCharacter });
        }
    }

    return self.fail(.{ .@"error" = error.UnterminatedString });
}

fn scanLiteralString(self: *Scanner) Error!Token {
    assert(self.cursor < self.input.len);
    assert(self.input[self.cursor] == '\'');

    if (self.matchN('\'', 3)) {
        return self.scanMultilineLiteralString();
    }

    _ = self.nextChar();
    const start = self.cursor;

    while (self.cursor < self.input.len and self.input[self.cursor] != '\'') : (self.cursor += 1) {
        const c = self.input[self.cursor];
        if (c == '\n' or c == '\r') {
            return self.fail(.{ .@"error" = error.UnterminatedString });
        }

        if (!isValidChar(c) and c != '\t') {
            return self.fail(.{ .@"error" = error.InvalidControlCharacter });
        }
    }

    // TODO: Do we compare self.input[self.cursor] != '\'' here?
    if (self.cursor >= self.input.len) {
        return self.fail(.{ .@"error" = error.UnterminatedString });
    }

    assert(self.input[self.cursor] == '\'');

    const result = self.input[start..self.cursor];
    self.cursor += 1;

    return .{ .literal_string = result };
}

fn scanMultilineLiteralString(self: *Scanner) Error!Token {
    assert(self.matchN('\'', 3));

    self.cursor += 3;

    if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
        self.cursor += 1;
        self.line += 1;
    } else if (self.cursor + 1 < self.input.len and
        self.input[self.cursor] == '\r' and
        self.input[self.cursor + 1] == '\n')
    {
        self.cursor += 2;
        self.line += 1;
    }

    const start = self.cursor;

    while (self.cursor < self.input.len) {
        const c = self.input[self.cursor];

        if (c == '\'') {
            var i: usize = 0;
            while (self.cursor < self.input.len and self.input[self.cursor + i] == '\'') {
                i += 1;
            }

            if (i >= 3) {
                if (i > 5) {
                    return self.fail(.{
                        .@"error" = error.UnexpectedToken,
                        .msg = "invalid closing quotes",
                    });
                }

                const extra = i - 3;
                const result = self.input[start .. self.cursor + extra];
                self.cursor += i;

                assert(!std.mem.startsWith(u8, result, "'''"));
                assert(!std.mem.endsWith(u8, result, "'''"));

                return .{ .multiline_literal_string = result };
            } else {
                self.cursor += i;
            }
        } else if (c == '\n') {
            self.cursor += 1;
            self.line += 1;
        } else if (c == '\r' and self.cursor + 1 < self.input.len and
            self.input[self.cursor + 1] == '\n')
        {
            self.cursor += 2;
            self.line += 1;
        } else if (isValidChar(c) or c == ' ' or c == '\t') {
            self.cursor += 1;
        } else {
            return self.fail(.{ .@"error" = error.InvalidEscapeSequence });
        }
    }

    return self.fail(.{ .@"error" = error.UnterminatedString });
}

fn scanLiteral(self: *Scanner) Error!Token {
    const start = self.cursor;

    while (self.cursor < self.input.len) {
        const c = self.input[self.cursor];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            self.cursor += 1;
        } else {
            break;
        }
    }

    return .{ .literal = self.input[start..self.cursor] };
}

// TODO: Could we simplify the comparison---now there are multiple instances of
// `startsWith`?
fn scanNonstringValue(self: *Scanner) Error!Token {
    assert(self.cursor < self.input.len);
    assert(self.input[self.cursor] != '"');
    assert(self.input[self.cursor] != '\'');

    if (std.mem.startsWith(u8, self.input[self.cursor..], "true")) {
        if (self.cursor + 4 >= self.input.len or isValueTerminator(self.input[self.cursor + 4])) {
            self.cursor += 4;
            return .{ .bool = true };
        }
    }

    if (std.mem.startsWith(u8, self.input[self.cursor..], "false")) {
        if (self.cursor + 5 >= self.input.len or isValueTerminator(self.input[self.cursor + 5])) {
            self.cursor += 5;
            return .{ .bool = false };
        }
    }

    if (std.mem.startsWith(u8, self.input[self.cursor..], "inf") or
        std.mem.startsWith(u8, self.input[self.cursor..], "+inf"))
    {
        const len: usize = if (self.input[self.cursor] == '+') 4 else 3;
        if (self.cursor + len >= self.input.len or
            isValueTerminator(self.input[self.cursor + len]))
        {
            self.cursor += len;
            return .{ .float = std.math.inf(f64) };
        }
    }

    if (std.mem.startsWith(u8, self.input[self.cursor..], "-inf")) {
        if (self.cursor + 4 >= self.input.len or isValueTerminator(self.input[self.cursor + 4])) {
            self.cursor += 4;
            return .{ .float = -std.math.inf(f64) };
        }
    }

    if (std.mem.startsWith(u8, self.input[self.cursor..], "nan") or
        std.mem.startsWith(u8, self.input[self.cursor..], "+nan"))
    {
        const len: usize = if (self.input[self.cursor] == '+') 4 else 3;
        if (self.cursor + len >= self.input.len or
            isValueTerminator(self.input[self.cursor + len]))
        {
            self.cursor += len;
            return .{ .float = std.math.nan(f64) };
        }
    }

    if (std.mem.startsWith(u8, self.input[self.cursor..], "-nan")) {
        if (self.cursor + 4 >= self.input.len or isValueTerminator(self.input[self.cursor + 4])) {
            self.cursor += 4;
            return .{ .float = -std.math.nan(f64) };
        }
    }

    if (self.cursor + 4 < self.input.len and
        std.ascii.isDigit(self.input[self.cursor]) and
        std.ascii.isDigit(self.input[self.cursor + 1]) and
        std.ascii.isDigit(self.input[self.cursor + 2]) and
        std.ascii.isDigit(self.input[self.cursor + 3]) and
        self.input[self.cursor + 4] == '-')
    {
        return self.scanDatetime();
    }

    if (self.cursor + 2 < self.input.len and
        std.ascii.isDigit(self.input[self.cursor]) and
        std.ascii.isDigit(self.input[self.cursor + 1]) and
        self.input[self.cursor + 2] == ':')
    {
        return self.scanLocalTime();
    }

    return self.scanNumber();
}

fn scanDatetime(self: *Scanner) Error!Token {
    assert(self.cursor + 4 < self.input.len);
    assert(std.ascii.isDigit(self.input[self.cursor]));

    const date = try self.readDate();

    if (self.cursor >= self.input.len) {
        return .{ .local_date = date };
    }

    const c = self.input[self.cursor];
    if (c != 'T' and c != 't' and c != ' ') {
        return .{ .local_date = date };
    }

    if (self.cursor + 3 >= self.input.len or
        !std.ascii.isDigit(self.input[self.cursor + 1]) or
        !std.ascii.isDigit(self.input[self.cursor + 2]) or
        self.input[self.cursor + 3] != ':')
    {
        return .{ .local_date = date };
    }

    self.cursor += 1;

    const time = try self.readTime(false);
    const dt: Datetime = .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = time.hour,
        .minute = time.minute,
        .second = time.second,
        .nano = time.nano,
        .tz = if (self.cursor >= self.input.len) null else try self.readTimezone(),
    };

    if (!dt.isValid()) {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    return if (dt.tz == null) .{ .local_datetime = dt } else .{ .datetime = dt };
}

fn scanLocalTime(self: *Scanner) Error!Token {
    assert(self.cursor + 2 < self.input.len);
    assert(std.ascii.isDigit(self.input[self.cursor]));
    assert(std.ascii.isDigit(self.input[self.cursor + 1]));
    assert(self.input[self.cursor + 2] == ':');

    const t = try self.readTime(true);

    assert(t.isValid());

    return .{ .local_time = t };
}

fn readDate(self: *Scanner) Error!Date {
    assert(self.cursor + 4 < self.input.len);
    assert(std.ascii.isDigit(self.input[self.cursor]));

    const year = try self.readDatetimeDigits(u16, 4);

    if (self.cursor >= self.input.len or self.input[self.cursor] != '-') {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    self.cursor += 1;

    const month = try self.readDatetimeDigits(u8, 2);

    if (self.cursor >= self.input.len or self.input[self.cursor] != '-') {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    self.cursor += 1;

    const day = try self.readDatetimeDigits(u8, 2);

    const result: Date = .{
        .year = year,
        .month = month,
        .day = day,
    };
    if (!result.isValid()) {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    return result;
}

fn readTime(self: *Scanner, comptime local_time: bool) Error!Time {
    assert(self.cursor + 1 < self.input.len);
    assert(std.ascii.isDigit(self.input[self.cursor]));
    assert(std.ascii.isDigit(self.input[self.cursor + 1]));

    const hour = try self.readDatetimeDigits(u8, 2);

    if (self.cursor >= self.input.len or self.input[self.cursor] != ':') {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    self.cursor += 1;

    const minute = try self.readDatetimeDigits(u8, 2);

    var second: u8 = 0;
    var seconds_read = false;
    if (self.cursor < self.input.len and self.input[self.cursor] == ':') {
        self.cursor += 1;
        second = try self.readDatetimeDigits(u8, 2);
        seconds_read = true;
    } else if (!self.features.optional_seconds or !local_time) {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    var nano: ?u32 = null;
    if (self.cursor < self.input.len and self.input[self.cursor] == '.') {
        if (!seconds_read) {
            return self.fail(.{ .@"error" = error.InvalidDatetime });
        }

        self.cursor += 1;

        if (self.cursor >= self.input.len or !std.ascii.isDigit(self.input[self.cursor])) {
            return self.fail(.{ .@"error" = error.InvalidDatetime });
        }

        var n: u32 = 0;
        var i: usize = 0;
        while (self.cursor < self.input.len and
            std.ascii.isDigit(self.input[self.cursor]) and
            i < 9) : (i += 1)
        {
            n = n * 10 + (self.input[self.cursor] - '0');
            self.cursor += 1;
        }

        while (i < 9) : (i += 1) {
            n *= 10;
        }

        nano = n;
    }

    const time: Time = .{ .hour = hour, .minute = minute, .second = second, .nano = nano };

    if (!time.isValid()) {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    return time;
}

fn readTimezone(self: *Scanner) Error!?i16 {
    assert(self.cursor < self.input.len);

    const c = self.input[self.cursor];
    if (c == 'Z' or c == 'z') {
        self.cursor += 1;
        return 0;
    }

    if (c != '+' and c != '-') {
        return null;
    }

    const sign: i16 = if (c == '-') -1 else 1;
    self.cursor += 1;

    const hour: i16 = try self.readDatetimeDigits(u8, 2);

    if (self.cursor >= self.input.len or self.input[self.cursor] != ':') {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    self.cursor += 1;

    const minute: i16 = try self.readDatetimeDigits(u8, 2);

    if (hour > 23 or minute > 59) {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    return sign * (hour * 60 + minute);
}

fn readDatetimeDigits(self: *Scanner, comptime T: type, comptime n: usize) Error!T {
    comptime {
        if (n < 1) {
            @compileError("number of digits must be greater than 0");
        }

        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .unsigned) {
            @compileError("readDatetimeDigits requires an unsigned integer type");
        }

        const max_digits = switch (T) {
            u8 => 2,
            u16 => 4,
            u32 => 9,
            else => @compileError("readDatetimeDigits requires u8, u16, or u32"),
        };

        if (n > max_digits) {
            @compileError(std.fmt.comptimePrint(
                "{s} is too small for {d} digits",
                .{
                    @typeName(T),
                    n,
                },
            ));
        }
    }

    if (self.cursor + n > self.input.len) {
        return self.fail(.{ .@"error" = error.InvalidDatetime });
    }

    var result: T = 0;
    inline for (0..n) |_| {
        const c = self.input[self.cursor];
        if (!std.ascii.isDigit(c)) {
            return self.fail(.{ .@"error" = error.InvalidDatetime });
        }

        result = result * 10 + @as(T, c - '0');
        self.cursor += 1;
    }

    assert(result <= std.math.pow(u64, 10, n) - 1);

    return result;
}

// TODO: Make this more robust so that the parser shows the correct position
// when it encounters an invalid character. Probably implementing the integer
// parsing myself is the best way to do this.
fn scanNumber(self: *Scanner) Error!Token {
    const start = self.cursor;
    var has_sign = false;

    if (self.cursor < self.input.len and
        (self.input[self.cursor] == '+' or self.input[self.cursor] == '-'))
    {
        has_sign = true;
        self.cursor += 1;
    }

    var has_base = false;

    if (self.cursor + 1 < self.input.len and self.input[self.cursor] == '0') {
        // Disallow capital letter for denoting the base according to the TOML
        // spec.
        const c = self.input[self.cursor + 1];
        if (c == 'B' or c == 'O' or c == 'X') {
            return self.fail(.{ .@"error" = error.InvalidNumber });
        }

        if (c == 'b' or c == 'o' or c == 'x') {
            if (has_sign) {
                return self.fail(.{ .@"error" = error.InvalidNumber });
            }

            has_base = true;
            self.cursor += 2;
        }
    }
    while (self.cursor < self.input.len and
        (self.input[self.cursor] == '+' or
            self.input[self.cursor] == '-' or
            self.input[self.cursor] == '.' or
            self.input[self.cursor] == '_' or
            std.ascii.isHex(self.input[self.cursor])))
    {
        self.cursor += 1;
    }

    const buf = self.input[start..self.cursor];
    var try_float = false;

    const int = std.fmt.parseInt(i64, buf, 0) catch |err| switch (err) {
        error.InvalidCharacter => blk: {
            try_float = true;
            break :blk 0;
        },
        error.Overflow => return self.fail(.{ .@"error" = error.Overflow }),
    };

    if (!try_float) {
        if (buf[0] == '0' and buf.len > 1 and !has_base) {
            return self.fail(.{ .@"error" = error.InvalidNumber });
        }

        return .{ .int = int };
    }

    if (buf[0] == '.' or buf[buf.len - 1] == '.') {
        return self.fail(.{ .@"error" = error.InvalidNumber });
    }

    const float = std.fmt.parseFloat(f64, buf) catch return self.fail(.{
        .@"error" = error.InvalidNumber,
    });

    return .{ .float = float };
}

/// Skips the whitespace after a line-ending backslash in a multiline string.
fn skipLineEndingWhitespace(self: *Scanner) !void {
    while (self.cursor < self.input.len) {
        const c = self.input[self.cursor];
        if (c == ' ' or c == '\t') {
            self.cursor += 1;
        } else if (c == '\n') {
            self.cursor += 1;
            self.line += 1;
        } else if (c == '\r' and self.cursor + 1 < self.input.len and
            self.input[self.cursor + 1] == '\n')
        {
            self.cursor += 2;
            self.line += 1;
        } else {
            return;
        }
    }

    return self.fail(.{ .@"error" = error.UnterminatedString });
}

/// Fail the parsing in the Scanner. This either fills the Diagnostics with
/// the appropriate information and returns `error.Reported` or returns
/// the given error.
fn fail(self: *const Scanner, opts: struct { @"error": Error, msg: ?[]const u8 = null }) Error {
    assert(opts.@"error" != error.InvalidCharacter);
    assert(opts.@"error" != error.OutOfMemory);
    assert(opts.@"error" != error.Reported);

    if (self.diagnostics) |d| {
        const msg = if (opts.msg) |m| m else switch (opts.@"error") {
            error.InvalidControlCharacter => "invalid control character",
            error.InvalidDatetime => "invalid datetime",
            error.InvalidEscapeSequence => "invalid escape sequence",
            error.InvalidNumber => "invalid number",
            error.Overflow => "integer overflow",
            error.UnexpectedToken => "unexpected token",
            error.UnterminatedString => "unterminated string",
            error.InvalidCharacter, error.Reported, error.OutOfMemory => unreachable,
        };
        try d.initLineKnown(self.gpa, msg, self.input, self.cursor, self.line);

        return error.Reported;
    }

    return opts.@"error";
}

fn isValidChar(c: u8) bool {
    return std.ascii.isPrint(c) or (c & 0x80) != 0;
}

fn isValueTerminator(c: u8) bool {
    return std.mem.indexOfScalar(u8, "# \r\n\t,}]", c) != null;
}

const TestToken = union(enum) {
    dot,
    equal,
    comma,
    left_bracket, // [
    double_left_bracket, // [[
    right_bracket, // ]
    double_right_bracket, // ]]
    left_brace, // {
    right_brace, // }

    literal: []const u8,
    string: []const u8,
    multiline_string: []const u8,
    literal_string: []const u8,
    multiline_literal_string: []const u8,

    int: i64,
    float: f64,
    nan,
    bool: bool,

    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,

    line_feed,
    end_of_file,

    @"error": Error,
};

const NextTestCase = struct { disabled: bool = false, input: []const u8, seq: []const TestToken };

/// Common test cases for scanning with `nextKey` and `nextValue`.
const next_test_cases = [_]NextTestCase{
    .{
        .input =
        \\
        \\
        ,
        .seq = &[_]TestToken{
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\# This is comment
        \\
        ,
        .seq = &[_]TestToken{
            .end_of_file,
        },
    },
    .{
        .input =
        \\# This is comment
        \\
        \\
        ,
        .seq = &[_]TestToken{
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is a string"
        ,
        .seq = &[_]TestToken{
            .{ .string = "This is a string" },
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is a string"
        \\
        ,
        .seq = &[_]TestToken{
            .{ .string = "This is a string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is a string
        \\
        ,
        .seq = &[_]TestToken{.{ .@"error" = error.UnterminatedString }},
    },
    .{
        .input =
        \\"This is \uFFFF a string"
        \\
        ,
        .seq = &[_]TestToken{
            .{ .string = "This is \\uFFFF a string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is \uFFF a string"
        \\
        ,
        .seq = &[_]TestToken{.{ .@"error" = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \uFFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a\n   multiline \\uFFFF string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \uFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .@"error" = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \UFFFFFFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a\n   multiline \\UFFFFFFFF string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \UFFFFFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .@"error" = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a \
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a \\\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a \word
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .@"error" = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a \ word
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .@"error" = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""
        \\This is a multiline string"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a multiline string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""
        \\This is a multiline string""
        \\
        ,
        .seq = &[_]TestToken{.{ .@"error" = error.UnterminatedString }},
    },
    .{
        .input =
        \\"""
        \\This is a multiline
        \\
        \\string"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a multiline\n\nstring" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a multiline string"""""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a multiline string\"\"" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'This is a literal string'
        \\
        ,
        .seq = &[_]TestToken{
            .{ .literal_string = "This is a literal string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'This \\ is a literal string'
        \\
        ,
        .seq = &[_]TestToken{
            .{ .literal_string = "This \\\\ is a literal string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input = "'This is\ta literal string'",
        .seq = &[_]TestToken{
            .{ .literal_string = "This is\ta literal string" },
            .end_of_file,
        },
    },
    .{
        .input = "'This is\\ta literal string'",
        .seq = &[_]TestToken{
            .{ .literal_string = "This is\\ta literal string" },
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is a
        \\   multiline string
        \\'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is a ''multiline string'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a ''multiline string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is a ''multiline string'''''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a ''multiline string''" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is \\a multiline string'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is \\\\a multiline string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''
        \\This is a
        \\   multiline string
        \\'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''
        \\  This is a
        \\   multiline string
        \\'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "  This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
};

const next_key_test_cases = next_test_cases ++ [_]NextTestCase{
    .{
        .input =
        \\literal
        \\
        ,
        .seq = &[_]TestToken{
            .{ .literal = "literal" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\[literal]
        \\
        ,
        .seq = &[_]TestToken{
            .left_bracket,
            .{ .literal = "literal" },
            .right_bracket,
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\[[literal]]
        \\
        ,
        .seq = &[_]TestToken{
            .double_left_bracket,
            .{ .literal = "literal" },
            .double_right_bracket,
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\[[literal]]
        \\
        \\[second-literal]
        \\
        ,
        .seq = &[_]TestToken{
            .double_left_bracket,
            .{ .literal = "literal" },
            .double_right_bracket,
            .line_feed,
            .line_feed,
            .left_bracket,
            .{ .literal = "second-literal" },
            .right_bracket,
            .line_feed,
            .end_of_file,
        },
    },
};

const next_value_test_cases = next_test_cases ++ [_]NextTestCase{
    .{
        .input =
        \\true
        ,
        .seq = &[_]TestToken{
            .{ .bool = true },
            .end_of_file,
        },
    },
    .{
        .input =
        \\true
        \\
        ,
        .seq = &[_]TestToken{
            .{ .bool = true },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\false
        ,
        .seq = &[_]TestToken{
            .{ .bool = false },
            .end_of_file,
        },
    },
    .{
        .input =
        \\false
        \\
        ,
        .seq = &[_]TestToken{
            .{ .bool = false },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27T07:32:00Z
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = null,
                    .tz = 0,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27T07:32:00.123456789Z
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = 123456789,
                    .tz = 0,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27T07:32:00-07:00
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = null,
                    .tz = -7 * 60,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27T07:32:00.123456789+11:00
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = 123456789,
                    .tz = 11 * 60,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27t07:32:00Z
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = null,
                    .tz = 0,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27t07:32:00.123456789Z
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = 123456789,
                    .tz = 0,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27t07:32:00-07:00
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = null,
                    .tz = -7 * 60,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27t07:32:00.123456789+11:00
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = 123456789,
                    .tz = 11 * 60,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27 07:32:00Z
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = null,
                    .tz = 0,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27 07:32:00.123456789Z
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = 123456789,
                    .tz = 0,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27 07:32:00-07:00
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = null,
                    .tz = -7 * 60,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27 07:32:00.123456789+11:00
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = 123456789,
                    .tz = 11 * 60,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27T07:32:00
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .local_datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = null,
                    .tz = null,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\1979-05-27T07:32:00.123456789
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .local_datetime = .{
                    .year = 1979,
                    .month = 5,
                    .day = 27,
                    .hour = 7,
                    .minute = 32,
                    .second = 0,
                    .nano = 123456789,
                    .tz = null,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\2001-04-12
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .local_date = .{
                    .year = 2001,
                    .month = 4,
                    .day = 12,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\13:24:18.123456789
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .local_time = .{
                    .hour = 13,
                    .minute = 24,
                    .second = 18,
                    .nano = 123456789,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\13:24:18
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .local_time = .{
                    .hour = 13,
                    .minute = 24,
                    .second = 18,
                    .nano = null,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\18:12
        \\
        ,
        .seq = &[_]TestToken{
            .{
                .local_time = .{
                    .hour = 18,
                    .minute = 12,
                    .second = 0,
                    .nano = null,
                },
            },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\18:12.123456789
        \\
        ,
        .seq = &[_]TestToken{
            .{ .@"error" = error.InvalidDatetime },
        },
    },
    .{
        .input =
        \\1979-05-27T07:32
        \\
        ,
        .seq = &[_]TestToken{
            .{ .@"error" = error.InvalidDatetime },
        },
    },
    .{
        .input =
        \\inf
        \\
        ,
        .seq = &[_]TestToken{
            .{ .float = std.math.inf(f64) },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\inf
        ,
        .seq = &[_]TestToken{
            .{ .float = std.math.inf(f64) },
            .end_of_file,
        },
    },
    .{
        .input =
        \\+inf
        \\
        ,
        .seq = &[_]TestToken{
            .{ .float = std.math.inf(f64) },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\+inf
        ,
        .seq = &[_]TestToken{
            .{ .float = std.math.inf(f64) },
            .end_of_file,
        },
    },
    .{
        .input =
        \\-inf
        \\
        ,
        .seq = &[_]TestToken{
            .{ .float = -std.math.inf(f64) },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\-inf
        ,
        .seq = &[_]TestToken{
            .{ .float = -std.math.inf(f64) },
            .end_of_file,
        },
    },
    .{
        .input =
        \\nan
        \\
        ,
        .seq = &[_]TestToken{
            .nan,
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\nan
        ,
        .seq = &[_]TestToken{
            .nan,
            .end_of_file,
        },
    },
    .{
        .input =
        \\+nan
        \\
        ,
        .seq = &[_]TestToken{
            .nan,
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\+nan
        ,
        .seq = &[_]TestToken{
            .nan,
            .end_of_file,
        },
    },
    .{
        .input =
        \\-nan
        \\
        ,
        .seq = &[_]TestToken{
            .nan,
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\-nan
        ,
        .seq = &[_]TestToken{
            .nan,
            .end_of_file,
        },
    },
    .{
        .input =
        \\0
        ,
        .seq = &[_]TestToken{
            .{ .int = 0 },
            .end_of_file,
        },
    },
    .{
        .input =
        \\01
        ,
        .seq = &[_]TestToken{
            .{ .@"error" = error.InvalidNumber },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0b011011
        ,
        .seq = &[_]TestToken{
            .{ .int = 27 },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0o041
        ,
        .seq = &[_]TestToken{
            .{ .int = 33 },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0xAF
        ,
        .seq = &[_]TestToken{
            .{ .int = 175 },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0x_AFAB
        ,
        .seq = &[_]TestToken{
            .{ .@"error" = error.InvalidNumber },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0xAFAB_
        ,
        .seq = &[_]TestToken{
            .{ .@"error" = error.InvalidNumber },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0.1
        ,
        .seq = &[_]TestToken{
            .{ .float = 0.1 },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0.1_
        ,
        .seq = &[_]TestToken{
            .{ .@"error" = error.InvalidNumber },
            .end_of_file,
        },
    },
    .{
        .input =
        \\0.1e
        ,
        .seq = &[_]TestToken{
            .{ .@"error" = error.InvalidNumber },
            .end_of_file,
        },
    },
    .{
        .input =
        \\1.0e3
        ,
        .seq = &[_]TestToken{
            .{ .float = 1.0e3 },
            .end_of_file,
        },
    },
};

fn convertUnion(source: anytype, comptime Dest: type) Dest {
    if (!builtin.is_test) {
        @compileError("convertUnion may only be used in tests");
    }

    const Source = @TypeOf(source);
    const info = @typeInfo(Source);

    if (info != .@"union" or info.@"union".tag_type == null) {
        @compileError("convertUnion only works on tagged unions");
    }

    return switch (source) {
        inline else => |payload, tag| {
            const field_name = @tagName(tag);
            if (!@hasField(Dest, field_name)) {
                @compileError(
                    "destination " ++ @typeName(Dest) ++ " is missing field: " ++ field_name,
                );
            }
            return @unionInit(Dest, field_name, payload);
        },
    };
}

fn testNextKey(self: *Scanner) Error!TestToken {
    if (!builtin.is_test) {
        @compileError("testNextKey may only be used in tests");
    }

    const result = try self.nextKey();
    return convertUnion(result, TestToken);
}

fn testNextValue(self: *Scanner) Error!TestToken {
    if (!builtin.is_test) {
        @compileError("testNextValue may only be used in tests");
    }

    const result = try self.nextValue();
    return convertUnion(result, TestToken);
}

fn runNextKeyValueTests(test_cases: anytype, comptime key_mode: bool) !void {
    for (test_cases) |case| {
        if (case.disabled) {
            continue;
        }

        var scanner = init(std.testing.allocator, case.input, .{});

        for (case.seq) |expected| {
            switch (expected) {
                .@"error" => |err| {
                    try std.testing.expectError(
                        err,
                        if (key_mode) scanner.testNextKey() else scanner.testNextValue(),
                    );
                },
                else => {
                    const actual = try if (key_mode) blk: {
                        break :blk scanner.testNextKey();
                    } else blk: {
                        break :blk scanner.testNextValue();
                    };
                    switch (actual) {
                        .literal => |actual_str| {
                            try std.testing.expect(expected == .literal);
                            try std.testing.expectEqualStrings(expected.literal, actual_str);
                        },
                        .string => |actual_str| {
                            try std.testing.expect(expected == .string);
                            try std.testing.expectEqualStrings(expected.string, actual_str);
                        },
                        .multiline_string => |actual_str| {
                            try std.testing.expect(expected == .multiline_string);
                            try std.testing.expectEqualStrings(
                                expected.multiline_string,
                                actual_str,
                            );
                        },
                        .literal_string => |actual_str| {
                            try std.testing.expect(expected == .literal_string);
                            try std.testing.expectEqualStrings(expected.literal_string, actual_str);
                        },
                        .multiline_literal_string => |actual_str| {
                            try std.testing.expect(expected == .multiline_literal_string);
                            try std.testing.expectEqualStrings(
                                expected.multiline_literal_string,
                                actual_str,
                            );
                        },
                        .datetime => |actual_dt| {
                            try std.testing.expect(expected == .datetime);
                            try std.testing.expectEqual(expected.datetime, actual_dt);
                        },
                        .local_datetime => |actual_dt| {
                            try std.testing.expect(expected == .local_datetime);
                            try std.testing.expectEqual(expected.local_datetime, actual_dt);
                        },
                        .local_date => |actual_dt| {
                            try std.testing.expect(expected == .local_date);
                            try std.testing.expectEqual(expected.local_date, actual_dt);
                        },
                        .local_time => |actual_dt| {
                            try std.testing.expect(expected == .local_time);
                            try std.testing.expectEqual(expected.local_time, actual_dt);
                        },
                        .float => |actual_float| if (expected == .nan) {
                            try std.testing.expect(std.math.isNan(actual_float));
                        } else {
                            try std.testing.expectEqual(expected, actual);
                        },
                        else => try std.testing.expectEqual(expected, actual),
                    }
                },
            }
        }
    }
}

test nextKey {
    try runNextKeyValueTests(next_key_test_cases, true);
}

test nextValue {
    try runNextKeyValueTests(next_value_test_cases, false);
}

test readDatetimeDigits {
    {
        var s = Scanner.init(std.testing.allocator, "0", .{});
        try std.testing.expectEqual(0, try s.readDatetimeDigits(u8, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "0", .{});
        try std.testing.expectEqual(0, try s.readDatetimeDigits(u16, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "0", .{});
        try std.testing.expectEqual(0, try s.readDatetimeDigits(u32, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "1", .{});
        try std.testing.expectEqual(1, try s.readDatetimeDigits(u8, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "1", .{});
        try std.testing.expectEqual(1, try s.readDatetimeDigits(u16, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "1", .{});
        try std.testing.expectEqual(1, try s.readDatetimeDigits(u32, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "4", .{});
        try std.testing.expectEqual(4, try s.readDatetimeDigits(u8, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "4", .{});
        try std.testing.expectEqual(4, try s.readDatetimeDigits(u16, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "4", .{});
        try std.testing.expectEqual(4, try s.readDatetimeDigits(u32, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "10", .{});
        try std.testing.expectEqual(10, try s.readDatetimeDigits(u8, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, "10", .{});
        try std.testing.expectEqual(10, try s.readDatetimeDigits(u16, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, "10", .{});
        try std.testing.expectEqual(10, try s.readDatetimeDigits(u32, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, "13", .{});
        try std.testing.expectEqual(13, try s.readDatetimeDigits(u8, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, "13", .{});
        try std.testing.expectEqual(13, try s.readDatetimeDigits(u16, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, "13", .{});
        try std.testing.expectEqual(13, try s.readDatetimeDigits(u32, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, "123", .{});
        try std.testing.expectEqual(123, try s.readDatetimeDigits(u16, 3));
    }
    {
        var s = Scanner.init(std.testing.allocator, "123", .{});
        try std.testing.expectEqual(123, try s.readDatetimeDigits(u32, 3));
    }
    {
        var s = Scanner.init(std.testing.allocator, "1000", .{});
        try std.testing.expectEqual(1000, try s.readDatetimeDigits(u16, 4));
    }
    {
        var s = Scanner.init(std.testing.allocator, "1000", .{});
        try std.testing.expectEqual(1000, try s.readDatetimeDigits(u32, 4));
    }
    {
        var s = Scanner.init(std.testing.allocator, "82305", .{});
        try std.testing.expectEqual(82305, try s.readDatetimeDigits(u32, 5));
    }
    {
        var s = Scanner.init(std.testing.allocator, "100000000", .{});
        try std.testing.expectEqual(100000000, try s.readDatetimeDigits(u32, 9));
    }
    {
        var s = Scanner.init(std.testing.allocator, "0", .{});
        try std.testing.expectError(error.InvalidDatetime, s.readDatetimeDigits(u8, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, "1", .{});
        try std.testing.expectError(error.InvalidDatetime, s.readDatetimeDigits(u8, 2));
    }
    {
        var s = Scanner.init(std.testing.allocator, " ", .{});
        try std.testing.expectError(error.InvalidDatetime, s.readDatetimeDigits(u8, 1));
    }
    {
        var s = Scanner.init(std.testing.allocator, "abcd", .{});
        try std.testing.expectError(error.InvalidDatetime, s.readDatetimeDigits(u16, 4));
    }
    {
        var s = Scanner.init(std.testing.allocator, "0xFF", .{});
        try std.testing.expectError(error.InvalidDatetime, s.readDatetimeDigits(u32, 4));
    }
}
