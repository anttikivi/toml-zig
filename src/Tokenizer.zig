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

const Tokenizer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("Diagnostics.zig");
const default_version = @import("root.zig").default_version;
const Features = @import("root.zig").Features;
const Utf8State = @import("root.zig").Utf8State;
const Version = @import("root.zig").Version;

buffer: []const u8,
index: usize,
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

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
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
};

pub fn init(buffer: []const u8, options: Options) Tokenizer {
    return .{
        .buffer = buffer,
        .index = if (std.mem.startsWith(u8, buffer, "\xef\xbb\xbf")) 3 else 0,
        .line = 0,
        .features = .init(options.toml_version),
        .diagnostics = options.diagnostics,
    };
}

pub fn next(self: *Tokenizer) Error!Token {
    if (self.index >= self.buffer.len) {
        return .{ .type = .end_of_file, .loc = .{ .start = self.index, .end = self.index } };
    }

    const start = self.index;
    const c = self.buffer[self.index];
    self.index += 1;

    switch (c) {
        '\n' => return .{
            .tag = .newline,
            .loc = .{ .start = start, .end = self.index },
        },
        '\r' => {
            if (self.index >= self.buffer.len or self.buffer[self.index] != '\n') {
                return self.fail(
                    error.InvalidControlCharacter,
                    "carriage return not followed by a line feed",
                );
            }

            self.index += 1;

            return .{
                .tag = .newline,
                .loc = .{ .start = start, .end = self.index },
            };
        },
        '#' => {
            var state: Utf8State = .start;

            while (self.index < self.buffer.len) : (self.index += 1) {
                switch (state) {
                    .start => switch (self.buffer[self.index]) {
                        '\t' => {}, // 9
                        // We can stop the comment at either a newline or
                        // a carriage return and let the next tokenizer run
                        // handle checking it.
                        '\n', '\r' => return .{
                            .tag = .comment,
                            .loc = .{ .start = start, .end = self.index },
                        },
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
                    .a => switch (self.buffer[self.index]) {
                        0x80...0xbf => state = .start,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .b => switch (self.buffer[self.index]) {
                        0x80...0xbf => state = .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .c => switch (self.buffer[self.index]) {
                        0xa0...0xbf => state = .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .d => switch (self.buffer[self.index]) {
                        0x80...0x9f => state = .a,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .e => switch (self.buffer[self.index]) {
                        0x80...0xbf => state = .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .f => switch (self.buffer[self.index]) {
                        0x90...0xbf => state = .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                    .g => switch (self.buffer[self.index]) {
                        0x80...0x8f => state = .b,
                        else => return self.fail(error.InvalidUtf8, null),
                    },
                }
            }

            if (state != .start) {
                return self.fail(error.InvalidUtf8, null);
            }
        },
        '.' => return .{
            .tag = .dot,
            .loc = .{ .start = start, .end = self.index },
        },
        '=' => return .{
            .tag = .equal,
            .loc = .{ .start = start, .end = self.index },
        },
        ',' => return .{
            .tag = .comma,
            .loc = .{ .start = start, .end = self.index },
        },
        '[' => {
            if (self.index < self.buffer.len and self.buffer[self.index] == '[') {
                self.index += 1;
                return .{
                    .tag = .double_left_bracket,
                    .loc = .{ .start = start, .end = self.index },
                };
            }
            return .{
                .tag = .left_bracket,
                .loc = .{ .start = start, .end = self.index },
            };
        },
        ']' => {
            if (self.index < self.buffer.len and self.buffer[self.index] == ']') {
                self.index += 1;
                return .{
                    .tag = .double_right_bracket,
                    .loc = .{ .start = start, .end = self.index },
                };
            }
            return .{
                .tag = .right_bracket,
                .loc = .{ .start = start, .end = self.index },
            };
        },
        '{' => return .{
            .tag = .left_brace,
            .loc = .{ .start = start, .end = self.index },
        },
        '}' => return .{
            .tag = .right_brace,
            .loc = .{ .start = start, .end = self.index },
        },
        '"' => {
            self.index -= 1;
            return try self.nextString();
        },
        else => return error.NotImplemented,
    }
}

fn nextString(self: *Tokenizer) Error!Token {
    assert(self.index < self.buffer.len);
    assert(self.buffer[self.index] == '"');

    if (self.index + 2 < self.buffer.len and self.buffer[self.index + 1] == '"' and self.buffer[self.index + 2] == '"') {
        // multiline string
    }

    self.index += 1;
    const start = self.index;

    var state: Utf8State = .start;

    while (self.index < self.buffer.len) : (self.index += 1) {
        switch (state) {
            .start => switch (self.buffer[self.index]) {
                0...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return self.fail(error.InvalidControlCharacter, null),
                '\t' => {}, // 9
                '\n' => return self.fail(error.UnterminatedString, null),
                '\r' => {
                    if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                        return self.fail(error.UnterminatedString, null);
                    }
                    return self.fail(error.InvalidControlCharacter, null);
                },
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => {}, // printable characters
                '"' => break,
                '\\' => {
                    if (self.index + 1 >= self.buffer.len) {
                        return self.fail(error.InvalidEscapeSequence, null);
                    }

                    self.index += 1;

                    switch (self.buffer[self.index]) {
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
            .a => switch (self.buffer[self.index]) {
                0x80...0xbf => state = .start,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .b => switch (self.buffer[self.index]) {
                0x80...0xbf => state = .a,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .c => switch (self.buffer[self.index]) {
                0xa0...0xbf => state = .a,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .d => switch (self.buffer[self.index]) {
                0x80...0x9f => state = .a,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .e => switch (self.buffer[self.index]) {
                0x80...0xbf => state = .b,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .f => switch (self.buffer[self.index]) {
                0x90...0xbf => state = .b,
                else => return self.fail(error.InvalidUtf8, null),
            },
            .g => switch (self.buffer[self.index]) {
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
    if (self.index >= self.buffer.len or self.buffer[self.index] != '"') {
        return self.fail(error.UnterminatedString, null);
    }

    self.index += 1;

    return .{
        .tag = .string,
        .loc = .{ .start = start, .end = self.index - 1 },
    };
}

fn fail(self: Tokenizer, err: Error, msg: ?[]const u8) Error {
    assert(err != error.NotImplemented);
    assert(err != error.Reported);

    if (self.diagnostics) |diag| {
        const line_number = 1 + std.mem.countScalar(u8, self.buffer[0..self.index], '\n');
        const prev_newline = std.mem.findScalarLast(u8, self.buffer[0..self.index], '\n');
        const start = if (prev_newline) |i| i + 1 else 0;
        const end = std.mem.findScalarPos(u8, self.buffer, self.index, '\n') orelse self.buffer.len;

        diag.* = .{
            .line_number = line_number,
            .column = (self.index - start) + 1,
            .snippet = self.buffer[start..end],
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
