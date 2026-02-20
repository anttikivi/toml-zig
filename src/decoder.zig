const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const TomlVersion = @import("root.zig").TomlVersion;

pub const DecodeOptions = struct {
    /// Optional diagnostics object that contains additional information if
    /// the decoder fails.
    diagnostics: ?*Diagnostics = null,

    /// The version of TOML to accept in the decoding.
    toml_version: TomlVersion = .@"1.1.0",

    /// Whether to check that the input is a valid UTF-8 string.
    validate_utf8: bool = true,
};

/// Diagnostics can contain additional information about errors in decoding. To
/// enable diagnostics, initialize the diagnostics object by
/// `var diagnostics = Diagnostics{};` and pass it with the decoding options:
/// `const opts = DecodeOptions{ .diagnostics = &diagnostics };`.
///
/// The caller must call `deinit` on the diagnostics object. It owns
/// the `snippet` and `message` strings if the decoder has failed, and it is
/// allocated using the general-purpose allocator that was passed in to
/// `toml.decode`. This is done so that the diagnostics object can be safely
/// deallocated as the arena is not returned from `toml.decode` on errors.
pub const Diagnostics = struct {
    line: ?usize = null,
    column: ?usize = null,
    snippet: ?[]const u8 = null,
    message: ?[]const u8 = null,

    /// Initialize the given Diagnostics with the appropriate information when
    /// the current line is not known. The Diagnostics is modified in place and
    /// the line is calculated from the cursor position and the input.
    pub fn init(
        self: *@This(),
        gpa: Allocator,
        msg: []const u8,
        input: []const u8,
        cursor: usize,
    ) Allocator.Error!void {
        const line = 1 + std.mem.count(u8, input[0..cursor], "\n");
        try self.initLineKnown(gpa, msg, input, cursor, line);
    }

    /// Initialize the given Diagnostics with the appropriate information.
    pub fn initLineKnown(
        self: *@This(),
        gpa: Allocator,
        msg: []const u8,
        input: []const u8,
        cursor: usize,
        line: usize,
    ) Allocator.Error!void {
        const start = std.mem.lastIndexOfScalar(u8, input[0..cursor], '\n') orelse 0;
        const end = std.mem.indexOfScalarPos(u8, input, cursor, '\n') orelse input.len;
        const col = (cursor - start) + 1;
        self.line = line;
        self.column = col;
        self.snippet = try gpa.dupe(u8, input[(if (start > 0) start + 1 else start)..end]);
        self.message = try gpa.dupe(u8, msg);
    }

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        if (self.snippet) |s| {
            gpa.free(s);
        }

        if (self.message) |m| {
            gpa.free(m);
        }
    }
};

const Utf8Error = Allocator.Error || error{ InvalidUtf8, Reported };

const Parsed = struct {
    arena: std.heap.ArenaAllocator,

    // The input buffer of the parsed TOML document. It is either borrowed or
    // owned by the arena depending on `DecodeOptions`.
    // input: []const u8,
};

pub fn decode(gpa: Allocator, input: []const u8, options: DecodeOptions) !Parsed {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const allocator = arena.allocator();

    if (options.validate_utf8) {
        try validateUtf8(gpa, input, options.diagnostics);
    }

    var parser: Parser = .init(allocator, gpa, input, options);
    _ = try parser.parse();

    return .{
        .arena = arena,
        // .input = owned_input,
    };
}

/// Check if the input is a valid UTF-8 string. The function goes through
/// the whole input and checks each byte. It may be skipped if working under
/// strict constraints.
///
/// See: http://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
fn validateUtf8(gpa: Allocator, input: []const u8, diagnostics: ?*Diagnostics) Utf8Error!void {
    const Utf8State = enum { start, a, b, c, d, e, f, g };
    var state: Utf8State = .start;

    for (input, 0..) |c, i| {
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
                0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return failUtf8(gpa, input, i, diagnostics),
            },
            .a => switch (c) {
                0x80...0xBF => state = .start,
                else => return failUtf8(gpa, input, i, diagnostics),
            },
            .b => switch (c) {
                0x80...0xBF => state = .a,
                else => return failUtf8(gpa, input, i, diagnostics),
            },
            .c => switch (c) {
                0xA0...0xBF => state = .a,
                else => return failUtf8(gpa, input, i, diagnostics),
            },
            .d => switch (c) {
                0x80...0x9F => state = .a,
                else => return failUtf8(gpa, input, i, diagnostics),
            },
            .e => switch (c) {
                0x80...0xBF => state = .b,
                else => return failUtf8(gpa, input, i, diagnostics),
            },
            .f => switch (c) {
                0x90...0xBF => state = .b,
                else => return failUtf8(gpa, input, i, diagnostics),
            },
            .g => switch (c) {
                0x80...0x8F => state = .b,
                else => return failUtf8(gpa, input, i, diagnostics),
            },
        }
    }

    if (state != .start) {
        return failUtf8(gpa, input, input.len - 1, diagnostics);
    }
}

fn failUtf8(gpa: Allocator, input: []const u8, cursor: usize, diagnostics: ?*Diagnostics) Utf8Error {
    if (diagnostics) |d| {
        try d.init(gpa, "invalid UTF-8 sequence", input, cursor);
        return error.Reported;
    }

    return error.InvalidUtf8;
}
