// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const ArrayList = std.ArrayList;

const Parsed = @import("Decoder.zig").Parsed;
const Span = @import("root.zig").Span;
const Float = @import("toml.zig").Float;
const Int = @import("toml.zig").Int;

pub const TableIndex = enum(u32) {
    root = 0,
    _,
};

pub const Value = union(enum) {
    string: []const u8,
    int: Int,
    float: Float,
    boolean: bool,
    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,
    array: u32,
    table: TableIndex,
};

pub const Table = struct {
    entries: Span,

    pub const Entry = struct {
        key: String,
        value: Value,
    };
};

/// Span representing a string. Differentiates between borrowed and owned strings.
pub const String = union(enum) {
    borrowed: Span,
    owned: Span,

    pub fn slice(self: @This(), doc: Parsed) []const u8 {
        return switch (self) {
            .borrowed => |s| doc.input[s.start..s.end],
            .owned => |s| doc.strings.items[s.start..s.end],
        };
    }
};

pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,
    /// Timezone offset in minutes from UTC. `null` means local datetime.
    tz: ?i16 = null,
};

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,
};
