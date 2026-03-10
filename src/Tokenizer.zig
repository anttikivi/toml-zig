// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const Tokenizer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("Diagnostics.zig");

pos: usize,
line: u64,
input: []const u8,
diagnostics: ?*Diagnostics = null,

const Error = Diagnostics.Error || error.NotImplemented || error{ InvalidControlCharacter, InvalidUtf8 };

const TokenType = enum {
    newline,
    comment,
    end_of_file,
};

const Token = struct {
    type: TokenType,
    start: usize,
    end: usize,
};

pub fn init(input: []const u8, diagnostics: ?*Diagnostics) Tokenizer {
    return .{
        .pos = 0,
        .line = 0,
        .input = input,
        .diagnostics = diagnostics,
    };
}

pub fn next(self: *Tokenizer) !Token {
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
            // UTF-8 validation algorithm.
            // https://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
            const Utf8State = enum { start, a, b, c, d, e, f, g };
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
        },
        else => return error.NotImplemented,
    }
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
                error.InvalidUtf8 => "invalid UTF-8 sequence",
                error.NotImplemented, error.Reported => unreachable,
            },
        };

        return error.Reported;
    }

    return err;
}
