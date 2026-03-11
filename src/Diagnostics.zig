// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const Diagnostics = @This();

const std = @import("std");

line_number: usize = 1,
column: usize = 0,
snippet: []const u8 = "",
message: []const u8 = "",

pub const Error = error{Reported};
