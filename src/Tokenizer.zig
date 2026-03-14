// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

//! The lowest-level parsing API for TOML documents in this library. Emits
//! tokens from the input buffer without allocations.
//!
//! The Tokenizer does not do proper validation of the TOML input it parses.
//! However, it validates that the input buffer is a well-formed code-unit
//! sequence as per Unicode specification. If it encounters an invalid Unicode
//! sequence, it returns an error.
//!
//! Additionally, the Tokenizer returns tokens unaware of the current TOML
//! context. It must be paired with a receiving parser. The parser must ensure
//! that it parses the produced tokens according to the current context.

const Tokenizer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("root.zig").Diagnostics;
const Position = @import("root.zig").Position;
const Utf8State = @import("root.zig").Utf8State;
const default_version = @import("toml.zig").default_version;
const Features = @import("toml.zig").Features;
const Version = @import("toml.zig").Version;

buffer: []const u8,
index: usize,
features: Features,
whitespace_tokens: bool,
comment_tokens: bool,
diagnostics: ?*Diagnostics,

pub const Options = struct {
    toml_version: Version = default_version,
    comment_tokens: bool = false,
    whitespace_tokens: bool = false,
    diagnostics: ?*Diagnostics = null,
};

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        comment,
        whitespace,

        literal,

        string,
        multiline_string,
        literal_string,
        multiline_literal_string,

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
};

pub const Error = Diagnostics.Error || error{
    InvalidControlCharacter,
    InvalidEscapeSequence,
    InvalidUtf8,
    UnexpectedToken,
    UnterminatedString,
};

const State = enum {
    start,
    carriage_return,
    comment,
    whitespace,
    left_bracket,
    right_bracket,
    literal,
    string_start,
    string,
    string_backslash,
    multiline_string_start,
    multiline_string,
    multiline_string_backslash,
    literal_string_start,
    literal_string,
    multiline_literal_string_start,
    multiline_literal_string,
};

pub fn init(buffer: []const u8, options: Options) Tokenizer {
    return .{
        .buffer = buffer,
        .index = if (std.mem.startsWith(u8, buffer, "\xef\xbb\xbf")) 3 else 0,
        .features = .init(options.toml_version),
        .comment_tokens = options.comment_tokens,
        .whitespace_tokens = options.whitespace_tokens,
        .diagnostics = options.diagnostics,
    };
}

/// Returns the next token from the input buffer. This function is not aware of
/// the current TOML context, and it is left for the parser to interpret
/// the produced tokens according to the correct context. The most notable
/// example of this is that when a TOML document contains bare keys separated by
/// dots, this function returns them as the single literal token.
pub fn next(self: *Tokenizer) Error!Token {
    var result: Token = .{
        .tag = undefined,
        .loc = .{
            .start = self.index,
            .end = undefined,
        },
    };

    state: switch (State.start) {
        .start => switch (self.nextByte()) {
            0 => if (self.index >= self.buffer.len) {
                result.tag = .end_of_file;
                result.loc = .{
                    .start = self.index,
                    .end = self.index,
                };
            } else {
                return self.fail(error.InvalidControlCharacter, "unexpected null character");
            },
            '\n' => {
                result.tag = .newline;
                self.index += 1;
            },
            '\r' => continue :state .carriage_return,
            '#' => continue :state .comment,
            '\t', ' ' => continue :state .whitespace,
            '.' => {
                result.tag = .dot;
                self.index += 1;
            },
            '=' => {
                result.tag = .equal;
                self.index += 1;
            },
            ',' => {
                result.tag = .comma;
                self.index += 1;
            },
            '[' => continue :state .left_bracket,
            ']' => continue :state .right_bracket,
            '{' => {
                result.tag = .left_brace;
                self.index += 1;
            },
            '}' => {
                result.tag = .right_brace;
                self.index += 1;
            },
            '"' => continue :state .string_start,
            '\'' => continue :state .literal_string_start,
            '+', '-', '0'...'9', 'A'...'Z', '_', 'a'...'z' => continue :state .literal,
            else => return self.fail(error.UnexpectedToken, null),
        },
        .carriage_return => {
            self.index += 1;
            switch (self.nextByte()) {
                '\n' => {
                    result.tag = .newline;
                    self.index += 1;
                },
                else => return self.fail(error.InvalidControlCharacter, "carriage return not followed by a line feed"),
            }
        },
        .comment => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == '#');

            result.tag = .comment;
            utf: switch (Utf8State.start) {
                .start => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0 => if (self.index < self.buffer.len) {
                            return self.fail(error.InvalidControlCharacter, "unexpected null character");
                        } else if (!self.comment_tokens) {
                            continue :state .start;
                        },
                        // We can stop the comment at either a newline or
                        // a carriage return and let the next tokenizer run
                        // handle checking it.
                        '\n', '\r' => if (!self.comment_tokens) {
                            result.loc.start = self.index;
                            continue :state .start;
                        },
                        '\t', 0x20...0x7e => continue :utf .start, // printable characters
                        1...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                        0xc2...0xdf => continue :utf .a,
                        0xe1...0xec, 0xee...0xef => continue :utf .b,
                        0xe0 => continue :utf .c,
                        0xed => continue :utf .d,
                        0xf1...0xf3 => continue :utf .e,
                        0xf0 => continue :utf .f,
                        0xf4 => continue :utf .g,
                        0x80...0xbf, 0xc0...0xc1, 0xf5...0xff => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .a => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .start,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .b => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .c => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0xa0...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .d => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x9f => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .e => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .f => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x90...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .g => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x8f => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
            }
        },
        .whitespace => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == '\t' or self.nextByte() == ' ');

            result.tag = .whitespace;
            self.index += 1;
            switch (self.nextByte()) {
                '\t', ' ' => continue :state .whitespace,
                else => if (!self.whitespace_tokens) {
                    result.loc.start = self.index;
                    continue :state .start;
                },
            }
        },
        .literal => {
            assert(self.index < self.buffer.len);

            result.tag = .literal;
            self.index += 1;
            switch (self.nextByte()) {
                '+', '-', '.', '0'...'9', ':', 'A'...'Z', '_', 'a'...'z' => continue :state .literal,
                else => {}, // return
            }
        },
        .left_bracket => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == '[');

            self.index += 1;
            switch (self.nextByte()) {
                '[' => {
                    result.tag = .double_left_bracket;
                    self.index += 1;
                },
                else => result.tag = .left_bracket,
            }
        },
        .right_bracket => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == ']');

            self.index += 1;
            switch (self.nextByte()) {
                ']' => {
                    result.tag = .double_right_bracket;
                    self.index += 1;
                },
                else => result.tag = .right_bracket,
            }
        },
        .string_start => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == '"');

            // Do not advance the index here, as it's done in the proper string
            // or multiline string handling.

            if (self.index + 2 < self.buffer.len and
                self.buffer[self.index + 1] == '"' and
                self.buffer[self.index + 2] == '"')
            {
                continue :state .multiline_string_start;
            }

            result.tag = .string;
            continue :state .string;
        },
        .string => {
            assert(self.index < self.buffer.len);

            utf: switch (Utf8State.start) {
                .start => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0 => return self.fail(error.InvalidControlCharacter, "unexpected null character"),
                        '\n' => return self.fail(error.UnterminatedString, null),
                        '\r' => if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                            return self.fail(error.UnterminatedString, null);
                        } else {
                            return self.fail(error.InvalidControlCharacter, null);
                        },
                        '"' => self.index += 1,
                        '\\' => continue :state .string_backslash,
                        '\t', 0x20...0x21, 0x23...0x5b, 0x5d...0x7e => continue :utf .start, // printable characters
                        1...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                        0xc2...0xdf => continue :utf .a,
                        0xe1...0xec, 0xee...0xef => continue :utf .b,
                        0xe0 => continue :utf .c,
                        0xed => continue :utf .d,
                        0xf1...0xf3 => continue :utf .e,
                        0xf0 => continue :utf .f,
                        0xf4 => continue :utf .g,
                        0x80...0xbf, 0xc0...0xc1, 0xf5...0xff => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .a => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .start,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .b => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .c => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0xa0...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .d => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x9f => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .e => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .f => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x90...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .g => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x8f => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
            }
        },
        .string_backslash => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == '\\');

            self.index += 1;
            switch (self.nextByte()) {
                '"', '\\', 'b', 'f', 'n', 'r', 't' => continue :state .string,
                'e' => if (self.features.escape_e) {
                    continue :state .string;
                } else {
                    return self.fail(error.InvalidEscapeSequence, null);
                },
                'x' => if (self.features.escape_xhh) {
                    if (self.index + 2 >= self.buffer.len) {
                        return self.fail(
                            error.InvalidEscapeSequence,
                            "escape sequence '\\xHH' must contain two hex characters",
                        );
                    }

                    inline for (1..3) |i| {
                        if (!std.ascii.isHex(self.buffer[self.index + i])) {
                            return self.fail(
                                error.InvalidEscapeSequence,
                                "escape sequence '\\xHH' must contain two hex characters",
                            );
                        }
                    }

                    self.index += 2;
                    continue :state .string;
                } else {
                    return self.fail(error.InvalidEscapeSequence, null);
                },
                'u' => {
                    if (self.index + 4 >= self.buffer.len) {
                        return self.fail(
                            error.InvalidEscapeSequence,
                            "escape sequence '\\uHHHH' must contain four hex characters",
                        );
                    }

                    inline for (1..5) |i| {
                        if (!std.ascii.isHex(self.buffer[self.index + i])) {
                            return self.fail(
                                error.InvalidEscapeSequence,
                                "escape sequence '\\uHHHH' must contain four hex characters",
                            );
                        }
                    }

                    self.index += 4;
                    continue :state .string;
                },
                'U' => {
                    if (self.index + 8 >= self.buffer.len) {
                        return self.fail(
                            error.InvalidEscapeSequence,
                            "escape sequence '\\UHHHHHHHH' must contain eight hex characters",
                        );
                    }

                    inline for (1..9) |i| {
                        if (!std.ascii.isHex(self.buffer[self.index + i])) {
                            return self.fail(
                                error.InvalidEscapeSequence,
                                "escape sequence '\\UHHHHHHHH' must contain eight hex characters",
                            );
                        }
                    }

                    self.index += 8;
                    continue :state .string;
                },
                else => return self.fail(error.InvalidEscapeSequence, null),
            }
        },
        .multiline_string_start => {
            assert(self.index + 2 < self.buffer.len);
            assert(self.buffer[self.index] == '"');
            assert(self.buffer[self.index + 1] == '"');
            assert(self.buffer[self.index + 2] == '"');

            self.index += 2;
            result.tag = .multiline_string;
            continue :state .multiline_string;
        },
        .multiline_string => {
            assert(self.index < self.buffer.len);

            utf: switch (Utf8State.start) {
                .start => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0 => return self.fail(error.InvalidControlCharacter, "unexpected null character"),
                        '\r' => if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                            continue :utf .start;
                        } else {
                            return self.fail(error.InvalidControlCharacter, null);
                        },
                        '"' => if (self.index + 2 < self.buffer.len and
                            self.buffer[self.index + 1] == '"' and
                            self.buffer[self.index + 2] == '"')
                        {
                            self.index += 3;
                            break :utf;
                        } else {
                            continue :utf .start;
                        },
                        '\\' => continue :state .multiline_string_backslash,
                        '\t'...'\n', 0x20...0x21, 0x23...0x5b, 0x5d...0x7e => continue :utf .start, // printable characters
                        1...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                        0xc2...0xdf => continue :utf .a,
                        0xe1...0xec, 0xee...0xef => continue :utf .b,
                        0xe0 => continue :utf .c,
                        0xed => continue :utf .d,
                        0xf1...0xf3 => continue :utf .e,
                        0xf0 => continue :utf .f,
                        0xf4 => continue :utf .g,
                        0x80...0xbf, 0xc0...0xc1, 0xf5...0xff => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .a => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .start,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .b => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .c => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0xa0...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .d => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x9f => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .e => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .f => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x90...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .g => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x8f => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
            }
        },
        .multiline_string_backslash => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == '\\');

            self.index += 1;
            switch (self.nextByte()) {
                '"', '\\', 'b', 'f', 'n', 'r', 't' => continue :state .multiline_string,
                '\n' => continue :state .multiline_string,
                '\r' => if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                    self.index += 1;
                    continue :state .multiline_string;
                } else {
                    return self.fail(error.InvalidControlCharacter, null);
                },
                '\t', ' ' => {
                    self.index += 1;
                    ws: switch (self.nextByte()) {
                        0 => return self.fail(error.InvalidControlCharacter, "unexpected null character"),
                        '\t', ' ' => {
                            self.index += 1;
                            continue :ws self.nextByte();
                        },
                        '\n' => continue :state .multiline_string,
                        '\r' => if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                            self.index += 1;
                            continue :state .multiline_string;
                        } else {
                            return self.fail(error.InvalidControlCharacter, null);
                        },
                        else => return self.fail(
                            error.InvalidEscapeSequence,
                            "only whitespace is allowed after a line-ending backslash",
                        ),
                    }
                },
                'e' => if (self.features.escape_e) {
                    continue :state .multiline_string;
                } else {
                    return self.fail(error.InvalidEscapeSequence, null);
                },
                'x' => if (self.features.escape_xhh) {
                    if (self.index + 2 >= self.buffer.len) {
                        return self.fail(
                            error.InvalidEscapeSequence,
                            "escape sequence '\\xHH' must contain two hex characters",
                        );
                    }

                    inline for (1..3) |i| {
                        if (!std.ascii.isHex(self.buffer[self.index + i])) {
                            return self.fail(
                                error.InvalidEscapeSequence,
                                "escape sequence '\\xHH' must contain two hex characters",
                            );
                        }
                    }

                    self.index += 2;
                    continue :state .multiline_string;
                } else {
                    return self.fail(error.InvalidEscapeSequence, null);
                },
                'u' => {
                    if (self.index + 4 >= self.buffer.len) {
                        return self.fail(
                            error.InvalidEscapeSequence,
                            "escape sequence '\\uHHHH' must contain four hex characters",
                        );
                    }

                    inline for (1..5) |i| {
                        if (!std.ascii.isHex(self.buffer[self.index + i])) {
                            return self.fail(
                                error.InvalidEscapeSequence,
                                "escape sequence '\\uHHHH' must contain four hex characters",
                            );
                        }
                    }

                    self.index += 4;
                    continue :state .multiline_string;
                },
                'U' => {
                    if (self.index + 8 >= self.buffer.len) {
                        return self.fail(
                            error.InvalidEscapeSequence,
                            "escape sequence '\\UHHHHHHHH' must contain eight hex characters",
                        );
                    }

                    inline for (1..9) |i| {
                        if (!std.ascii.isHex(self.buffer[self.index + i])) {
                            return self.fail(
                                error.InvalidEscapeSequence,
                                "escape sequence '\\UHHHHHHHH' must contain eight hex characters",
                            );
                        }
                    }

                    self.index += 8;
                    continue :state .multiline_string;
                },
                else => return self.fail(error.InvalidEscapeSequence, null),
            }
        },
        .literal_string_start => {
            assert(self.index < self.buffer.len);
            assert(self.nextByte() == '\'');

            if (self.index + 2 < self.buffer.len and
                self.buffer[self.index + 1] == '\'' and
                self.buffer[self.index + 2] == '\'')
            {
                continue :state .multiline_literal_string_start;
            }

            result.tag = .literal_string;
            continue :state .literal_string;
        },
        .literal_string => {
            assert(self.index < self.buffer.len);

            utf: switch (Utf8State.start) {
                .start => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0 => return self.fail(error.InvalidControlCharacter, "unexpected null character"),
                        '\n' => return self.fail(error.UnterminatedString, null),
                        '\r' => if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                            return self.fail(error.UnterminatedString, null);
                        } else {
                            return self.fail(error.InvalidControlCharacter, null);
                        },
                        '\'' => self.index += 1,
                        '\t', 0x20...0x26, 0x28...0x7e => continue :utf .start, // printable characters
                        1...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                        0xc2...0xdf => continue :utf .a,
                        0xe1...0xec, 0xee...0xef => continue :utf .b,
                        0xe0 => continue :utf .c,
                        0xed => continue :utf .d,
                        0xf1...0xf3 => continue :utf .e,
                        0xf0 => continue :utf .f,
                        0xf4 => continue :utf .g,
                        0x80...0xbf, 0xc0...0xc1, 0xf5...0xff => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .a => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .start,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .b => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .c => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0xa0...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .d => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x9f => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .e => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .f => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x90...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .g => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x8f => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
            }
        },
        .multiline_literal_string_start => {
            assert(self.index + 2 < self.buffer.len);
            assert(self.buffer[self.index] == '\'');
            assert(self.buffer[self.index + 1] == '\'');
            assert(self.buffer[self.index + 2] == '\'');

            self.index += 2;
            result.tag = .multiline_literal_string;
            continue :state .multiline_literal_string;
        },
        .multiline_literal_string => {
            assert(self.index < self.buffer.len);

            utf: switch (Utf8State.start) {
                .start => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0 => return self.fail(error.InvalidControlCharacter, "unexpected null character"),
                        '\r' => if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                            self.index += 1;
                            continue :utf .start;
                        } else {
                            return self.fail(error.InvalidControlCharacter, null);
                        },
                        '\'' => if (self.index + 2 < self.buffer.len and
                            self.buffer[self.index + 1] == '\'' and
                            self.buffer[self.index + 2] == '\'')
                        {
                            self.index += 3;
                            break :utf;
                        } else {
                            continue :utf .start;
                        },
                        '\t'...'\n', 0x20...0x26, 0x28...0x7e => continue :utf .start, // printable characters
                        1...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                        0xc2...0xdf => continue :utf .a,
                        0xe1...0xec, 0xee...0xef => continue :utf .b,
                        0xe0 => continue :utf .c,
                        0xed => continue :utf .d,
                        0xf1...0xf3 => continue :utf .e,
                        0xf0 => continue :utf .f,
                        0xf4 => continue :utf .g,
                        0x80...0xbf, 0xc0...0xc1, 0xf5...0xff => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .a => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .start,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .b => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .c => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0xa0...0xbf => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .d => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x9f => continue :utf .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .e => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .f => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x90...0xbf => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
                .g => {
                    self.index += 1;
                    switch (self.nextByte()) {
                        0x80...0x8f => continue :utf .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    }
                },
            }
        },
    }

    result.loc.end = self.index;
    return result;
}

/// Get the current position for diagnostics.
pub fn position(self: Tokenizer) Position {
    const line_number = 1 + std.mem.countScalar(u8, self.buffer[0..self.index], '\n');
    const prev_newline = std.mem.findScalarLast(u8, self.buffer[0..self.index], '\n');
    const start = if (prev_newline) |i| i + 1 else 0;
    const end = std.mem.findScalarPos(u8, self.buffer, self.index, '\n') orelse self.buffer.len;

    return .{
        .line_number = line_number,
        .column = (self.index - start) + 1,
        .snippet = self.buffer[start..end],
    };
}

fn nextByte(self: Tokenizer) u8 {
    if (self.index >= self.buffer.len) {
        return 0;
    }

    return self.buffer[self.index];
}

fn fail(self: Tokenizer, err: Error, msg: ?[]const u8) Error {
    assert(err != error.Reported);

    if (self.diagnostics) |diag| {
        diag.* = .{
            .position = self.position(),
            .message = if (msg) |m| m else switch (err) {
                error.InvalidControlCharacter => "invalid control character",
                error.InvalidEscapeSequence => "invalid escape sequence",
                error.InvalidUtf8 => "invalid UTF-8 sequence",
                error.UnexpectedToken => "unexpected token",
                error.UnterminatedString => "unterminated string literal",
                error.Reported => unreachable,
            },
        };

        return error.Reported;
    }

    return err;
}

test {
    _ = @import("Tokenizer/test.zig");
}
