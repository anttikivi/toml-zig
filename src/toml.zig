// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

//! TOML specification related types and values. They are collected into their own namespace to
//! reuse in build.zig.

/// The default TOML version used by the library.
pub const default_version: Version = .@"1.1.0";

/// Integer type used by this TOML implementation.
pub const Int = i64;

/// Float type used by this TOML implementation.
pub const Float = f64;

/// TOML versions that this parser supports.
pub const Version = enum {
    @"1.1.0",
    @"1.0.0",
};

/// Configuration of TOML features added after version 1.0.0. It is used internally by the library
/// while parsing to check which features are allowed based on the selected TOML version.
pub const Features = struct {
    escape_e: bool = false,
    escape_xhh: bool = false,
    inline_table_newlines: bool = false,
    inline_table_trailing_comma: bool = false,
    optional_seconds: bool = false,

    const Self = @This();

    pub fn init(toml_version: Version) Self {
        return switch (toml_version) {
            .@"1.0.0" => .{},
            .@"1.1.0" => .{
                .escape_e = true,
                .escape_xhh = true,
                .inline_table_newlines = true,
                .inline_table_trailing_comma = true,
                .optional_seconds = true,
            },
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
