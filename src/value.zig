const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents any TOML value that potentially contains other TOML values.
/// The result for parsing a TOML document is a `Value` that represents the root
/// table of the document.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,
    array: Array,
    table: Table,

    /// Recursively free memory for this value and all nested values.
    /// The allocator must be the same one that was passed to parsing function
    /// that produced this value.
    pub fn deinit(self: *@This(), gpa: Allocator) void {
        switch (self.*) {
            .string => |s| gpa.free(s),
            .array => |*arr| {
                var i: usize = 0;
                while (i < arr.items.len) : (i += 1) {
                    var item = &arr.items[i];
                    item.deinit(gpa);
                }
                arr.deinit(gpa);
            },
            .table => |*t| {
                var it = t.iterator();
                while (it.next()) |entry| {
                    gpa.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(gpa);
                }
                t.deinit();
            },
            else => {}, // no-op
        }
    }
};

/// Represents a TOML array value that is normally wrapped in a `Value`.
///
/// The items are owned by the parent `Value` and freed by `Value.deinit()`.
pub const Array = std.ArrayList(Value);

/// Represents a TOML table value that is normally wrapped in a `Value`.
///
/// The keys and values are owned by the parent `Value` and freed by
/// `Value.deinit()`.
pub const Table = std.StringArrayHashMap(Value);

/// Represents a TOML datetime value.
///
/// The value can be either a normal datetime or a local datetime. When the time
/// zone offset is present, `tz` is minutes from UTC. For local datetimes (no
/// offset), `tz` is `null`.
pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,
    tz: ?i16 = null,

    /// For formatting with std.fmt. Supports only the default format:
    /// RFC3339-like (YYYY-MM-DDTHH:MM:SS[.fffffffff][Z|+hh:mm])
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len != 0) {
            std.fmt.invalidFmtError(fmt, self);
        }

        try writer.print(
            "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );

        if (self.nano) |nano| {
            try writer.print(".{d:0>9}", .{nano});
        }

        if (self.tz) |tz| {
            const t: u16 = @intCast(@abs(tz));
            if (t == 0) {
                try writer.writeAll("Z");
            } else {
                const h: u16 = t / 60;
                const m: u16 = t % 60;
                const sign = if (tz < 0) "-" else "+";
                try writer.print("{s}{d:0>2}:{d:0>2}", .{ sign, h, m });
            }
        }
    }

    pub fn isValid(self: @This()) bool {
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };
        if (self.day == 0 or self.day > days_in_month[self.month - 1]) {
            return false;
        }

        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        if ((self.month == 6 and self.day == 30) or (self.month == 12 and self.day == 31)) {
            if (self.second > 60) {
                return false;
            }
        } else if (self.second > 59) {
            return false;
        }

        if (self.tz == null) {
            return true;
        }

        return isValidTimezone(self.tz.?);
    }
};

/// Represents a local TOML date value.
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    /// For formatting with std.fmt. Supports only default format.
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len != 0) {
            std.fmt.invalidFmtError(fmt, self);
        }

        try writer.print("{d}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }

    pub fn isValid(self: @This()) bool {
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };

        return self.day > 0 and self.day <= days_in_month[self.month - 1];
    }
};

/// Represents a local TOML time value.
pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,

    /// For formatting with std.fmt. Supports only default format.
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len != 0) {
            std.fmt.invalidFmtError(fmt, self);
        }

        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });

        if (self.nano) |nano| {
            try writer.print(".{d:0>9}", .{nano});
        }
    }

    pub fn isValid(self: @This()) bool {
        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        return self.second <= 59;
    }
};

/// Check whether the minutes given as `tz` is a valid time zone.
fn isValidTimezone(tz: i16) bool {
    const t: u16 = @abs(tz);
    const h = t / 60;
    const m = t % 60;

    if (h > 23) {
        return false;
    }

    return m < 60;
}
