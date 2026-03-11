// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

//! TOML specification related types and values. They are collected into their
//! own namespace to reuse in build.zig.

/// The default TOML version used by the library.
pub const default_version: Version = .@"1.1.0";

/// TOML versions that this parser supports.
pub const Version = enum {
    @"1.1.0",
    @"1.0.0",
};

/// Configuration of TOML features added after version 1.0.0. It is used
/// internally by the library while parsing to check which features are allowed
/// based on the selected TOML version.
pub const Features = packed struct {
    escape_e: bool = false,
    escape_xhh: bool = false,

    const Self = @This();

    pub fn init(toml_version: Version) Self {
        return switch (toml_version) {
            .@"1.0.0" => .{},
            .@"1.1.0" => .{
                .escape_e = true,
                .escape_xhh = true,
            },
        };
    }
};
