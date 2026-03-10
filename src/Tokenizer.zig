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

const Error = Diagnostics.Error || error.NotImplemented || error.InvalidControlCharacter;

const TokenType = enum {
    newline,
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
        '#' => {},
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
                error.NotImplemented, error.Reported => unreachable,
            },
        };

        return error.Reported;
    }

    return err;
}
