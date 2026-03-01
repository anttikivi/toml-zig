// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const kib = 1 << 10;
const mib = 1 << 20;

pub const Size = enum {
    tiny,
    small,
    medium,
    large,
    xlarge,

    /// Target size in bytes of the generated file for the given `Size`.
    pub fn targetSize(self: @This()) usize {
        return switch (self) {
            .tiny => kib,
            .small => 16 * kib,
            .medium => 256 * kib,
            .large => 4 * mib,
            .xlarge => 16 * mib,
        };
    }
};

pub const Pattern = enum {
    array_tables,
    flat_kv,
    inline_heavy,
    mixed_realistic,
    nested_tables,
    string_escapes,
};
