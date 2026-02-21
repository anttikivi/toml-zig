const std = @import("std");

pub const decode = @import("decoder.zig").decode;
pub const Array = @import("value.zig").Array;
pub const Date = @import("value.zig").Date;
pub const Datetime = @import("value.zig").Datetime;
pub const Table = @import("value.zig").Table;
pub const Time = @import("value.zig").Time;
pub const Value = @import("value.zig").Value;

/// Version represents the TOML versions that this parser supports.
pub const Version = enum {
    @"1.1.0",
    @"1.0.0",
};

test {
    std.testing.refAllDecls(@This());
}
