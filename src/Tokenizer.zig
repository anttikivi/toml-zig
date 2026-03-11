// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const Tokenizer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("Diagnostics.zig");
const default_version = @import("root.zig").default_version;
const Utf8State = @import("root.zig").Utf8State;
const Version = @import("root.zig").Version;

pos: usize,
line: u64,
input: []const u8,
features: Features,
diagnostics: ?*Diagnostics = null,

pub const Options = struct {
    toml_version: Version = default_version,
    diagnostics: ?*Diagnostics = null,
};

const Error = Diagnostics.Error || error.NotImplemented || error{
    InvalidControlCharacter,
    InvalidEscapeSequence,
    InvalidUtf8,
    UnterminatedString,
};

const TokenType = enum {
    comment,

    string,

    dot,
    equal,
    comma,
    left_bracket,
    right_bracket,
    double_left_bracket,
    double_right_bracket,
    left_brace,
    right_brace,

    newline,

    end_of_file,
};

const Token = struct {
    type: TokenType,
    start: usize,
    end: usize,
};

const Features = packed struct {
    escape_e: bool = false,
    escape_xhh: bool = false,

    const Self = @This();

    fn init(toml_version: Version) Self {
        return switch (toml_version) {
            .@"1.0.0" => .{},
            .@"1.1.0" => .{
                .escape_e = true,
                .escape_xhh = true,
            },
        };
    }
};

pub fn init(input: []const u8, options: Options) Tokenizer {
    return .{
        .pos = 0,
        .line = 0,
        .input = input,
        .features = .init(options.toml_version),
        .diagnostics = options.diagnostics,
    };
}

pub fn next(self: *Tokenizer) Error!Token {
    if (self.pos >= self.input.len) {
        return .{ .type = .end_of_file, .start = self.pos, .end = self.pos };
    }

    const start = self.pos;
    const c = self.input[self.pos];
    self.pos += 1;

    switch (c) {
        '\n' => return .{ .type = .newline, .start = start, .end = self.pos },
        '\r' => {
            if (self.pos >= self.input.len or self.input[self.pos] != '\n') {
                return self.fail(
                    error.InvalidControlCharacter,
                    "carriage return not followed by a line feed",
                );
            }

            self.pos += 1;

            return .{ .type = .newline, .start = start, .end = self.pos };
        },
        '#' => {
            var state: Utf8State = .start;

            while (self.pos < self.input.len) : (self.pos += 1) {
                switch (state) {
                    .start => switch (self.input[self.pos]) {
                        '\t' => {}, // 9
                        // We can stop the comment at either a newline or
                        // a carriage return and let the next tokenizer run
                        // handle checking it.
                        '\n', '\r' => return .{ .type = .comment, .start = start, .end = self.pos },
                        0x20...0x7e => {}, // printable characters
                        0...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                        0xc2...0xdf => state = .a,
                        0xe1...0xec, 0xee...0xef => state = .b,
                        0xe0 => state = .c,
                        0xed => state = .d,
                        0xf1...0xf3 => state = .e,
                        0xf0 => state = .f,
                        0xf4 => state = .g,
                        0x80...0xbf, 0xc0...0xc1, 0xf5...0xff => return self.fail(error.InvalidUtf8, null),
                    },
                    .a => switch (self.input[self.pos]) {
                        0x80...0xbf => state = .start,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .b => switch (self.input[self.pos]) {
                        0x80...0xbf => state = .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .c => switch (self.input[self.pos]) {
                        0xa0...0xbf => state = .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .d => switch (self.input[self.pos]) {
                        0x80...0x9f => state = .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .e => switch (self.input[self.pos]) {
                        0x80...0xbf => state = .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .f => switch (self.input[self.pos]) {
                        0x90...0xbf => state = .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .g => switch (self.input[self.pos]) {
                        0x80...0x8f => state = .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                }
            }

            if (state != .start) {
                return self.fail(error.InvalidUtf8, null);
            }
        },
        '.' => return .{ .type = .dot, .start = start, .end = self.pos },
        '=' => return .{ .type = .equal, .start = start, .end = self.pos },
        ',' => return .{ .type = .comma, .start = start, .end = self.pos },
        '[' => {
            if (self.pos < self.input.len and self.input[self.pos] == '[') {
                self.pos += 1;
                return .{ .type = .double_left_bracket, .start = start, .end = self.pos };
            }
            return .{ .type = .left_bracket, .start = start, .end = self.pos };
        },
        ']' => {
            if (self.pos < self.input.len and self.input[self.pos] == ']') {
                self.pos += 1;
                return .{ .type = .double_right_bracket, .start = start, .end = self.pos };
            }
            return .{ .type = .right_bracket, .start = start, .end = self.pos };
        },
        '{' => return .{ .type = .left_brace, .start = start, .end = self.pos },
        '}' => return .{ .type = .right_brace, .start = start, .end = self.pos },
        '"' => {
            self.pos -= 1;
            return try self.nextString();
        },
        else => return error.NotImplemented,
    }
}

fn nextString(self: *Tokenizer) Error!Token {
    assert(self.pos < self.input.len);
    assert(self.input[self.pos] == '"');

    if (self.pos + 2 < self.input.len and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
        // multiline string
    }

    self.pos += 1;
    const start = self.pos;

    var state: Utf8State = .start;

    while (self.pos < self.input.len) : (self.pos += 1) {
        switch (state) {
            .start => switch (self.input[self.pos]) {
                0...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                '\t' => {}, // 9
                '\n' => return self.fail(error.UnterminatedString, null),
                '\r' => {
                    if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\n') {
                        return self.fail(error.UnterminatedString, null);
                    }
                    return self.fail(error.InvalidControlCharacter, null);
                },
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => {}, // printable characters
                '"' => break,
                '\\' => {
                    if (self.pos + 1 >= self.input.len) {
                        return self.fail(error.InvalidEscapeSequence, null);
                    }

                    self.pos += 1;

                    switch (self.input[self.pos]) {
                        '"', '\\', 'b', 'f', 'n', 'r', 't', 'u', 'U' => {},
                        'e' => if (!self.features.escape_e) {
                            return self.fail(error.InvalidEscapeSequence, null);
                        },
                        'x' => if (!self.features.escape_xhh) {
                            return self.fail(error.InvalidEscapeSequence, null);
                        },
                        else => return self.fail(error.InvalidEscapeSequence, null),
                    }
                },
                0xc2...0xdf => state = .a,
                0xe1...0xec, 0xee...0xef => state = .b,
                0xe0 => state = .c,
                0xed => state = .d,
                0xf1...0xf3 => state = .e,
                0xf0 => state = .f,
                0xf4 => state = .g,
                0x80...0xbf, 0xc0...0xc1, 0xf5...0xff => return self.fail(error.InvalidUtf8, null),
            },
            .a => switch (self.input[self.pos]) {
                0x80...0xbf => state = .start,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .b => switch (self.input[self.pos]) {
                0x80...0xbf => state = .a,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .c => switch (self.input[self.pos]) {
                0xa0...0xbf => state = .a,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .d => switch (self.input[self.pos]) {
                0x80...0x9f => state = .a,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .e => switch (self.input[self.pos]) {
                0x80...0xbf => state = .b,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .f => switch (self.input[self.pos]) {
                0x90...0xbf => state = .b,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .g => switch (self.input[self.pos]) {
                0x80...0x8f => state = .b,
                else => return self.fail(error.InvalidUtf8, null),
            },
        }
    }

    if (state != .start) {
        return self.fail(error.InvalidUtf8, null);
    }

    // Do a double-check here. The alternative would be to include check for
    // the terminating double quote in the loop condition, but that would
    // essentially double-check on every iteration. Here it possible redundant
    // work is done only once.
    if (self.pos >= self.input.len or self.input[self.pos] != '"') {
        return self.fail(error.UnterminatedString, null);
    }

    self.pos += 1;

    return .{ .type = .string, .start = start, .end = self.pos - 1 };
}

fn fail(self: Tokenizer, err: Error, msg: ?[]const u8) Error {
    assert(err != error.NotImplemented);
    assert(err != error.Reported);

    if (self.diagnostics) |diag| {
        const prev_newline = std.mem.findScalarLast(u8, self.input[0..self.pos], '\n');
        const start = if (prev_newline) |i| i + 1 else 0;
        const end = std.mem.findScalarPos(u8, self.input, self.pos, '\n') orelse self.input.len;

        diag.* = .{
            .line_number = self.line,
            .column = (self.pos - start) + 1,
            .snippet = self.input[start..end],
            .message = if (msg) |m| m else switch (err) {
                error.InvalidControlCharacter => "invalid control character",
                error.InvalidEscapeSequence => "invalid escape sequence",
                error.InvalidUtf8 => "invalid UTF-8 sequence",
                error.NotImplemented, error.Reported => unreachable,
            },
        };

        return error.Reported;
    }

    return err;
}
