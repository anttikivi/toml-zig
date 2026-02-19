const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const DecodeOptions = @import("decoder.zig").DecodeOptions;
const Diagnostics = @import("decoder.zig").Diagnostics;
const Scanner = @import("Scanner.zig");
const Token = @import("Scanner.zig").Token;

arena: Allocator,
scanner: Scanner,
diagnostics: ?*Diagnostics = null,

const Error = Scanner.Error || error{ Utf8CannotEncodeSurrogateHalf, CodepointTooLarge };

const ParsingTable = struct {};

pub fn init(arena: Allocator, gpa: Allocator, input: []const u8, opts: DecodeOptions) Parser {
    return .{
        .arena = arena,
        .scanner = Scanner.init(gpa, input, opts),
    };
}

pub fn parse(self: *Parser) Error!ParsingTable {
    const root: ParsingTable = .{};
    const current: *ParsingTable = &root;
    _ = current;

    while (self.scanner.cursor < self.scanner.input.len) {
        const token = try self.scanner.nextKey();

        switch (token) {
            .end_of_file => break,
            else => error.UnexpectedToken,
        }
    }

    return root;
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
            error.InvalidEscapeSequence => "invalid escape sequence",
            error.UnexpectedToken => "unexpected token",
            error.Reported => unreachable,
        };
        try d.initLineKnown(self.scanner.gpa, msg, self.scanner.input, self.scanner.cursor, self.scanner.line);

        return error.Reported;
    }

    return opts.@"error";
}
