const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

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

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        switch (self.*) {
            .string => |s| gpa.free(s),
            .array => |*array| {
                var i: usize = 0;
                while (i < array.items.len) : (i += 1) {
                    var item = &array.items[i];
                    item.deinit(gpa);
                }
                array.deinit(gpa);
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

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        switch (self) {
            .string => |s| try writer.print("{s}", .{s}),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .datetime, .local_datetime => |dt| {
                assert(dt.isValid());
                try writer.print("{f}", .{dt});
            },
            .local_date => |d| {
                assert(d.isValid());
                try writer.print("{f}", .{d});
            },
            .local_time => |t| {
                assert(t.isValid());
                try writer.print("{f}", .{t});
            },
            .array => |array| {
                try writer.writeByte('[');
                for (array.items, 0..) |item, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }
                    try writer.print("{f}", .{item});
                }
                try writer.writeByte(']');
            },
            .table => |t| {
                try writer.writeByte('{');
                var it = t.iterator();
                var i: usize = 0;
                while (it.next()) |entry| : (i += 1) {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }
                    try writer.print("{s} = {f}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                try writer.writeByte('}');
            },
        }
    }
};

pub const Array = std.ArrayList(Value);
pub const Table = std.StringArrayHashMap(Value);

pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,
    tz: ?i16 = null,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        assert(self.isValid());

        try writer.print(
            "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );

        if (self.nano) |nano| {
            assert(nano <= 999999999);
            try writer.print(".{d:0>9}", .{nano});
        }

        if (self.tz) |tz| {
            assert(tz >= -1440 and tz <= 1440);

            const t: u16 = @intCast(@abs(tz));
            if (t == 0) {
                try writer.writeAll("Z");
            } else {
                const h: u16 = t / 60;
                const m: u16 = t % 60;
                assert(h <= 23);
                assert(m <= 59);

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

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        assert(self.isValid());
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

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        assert(self.isValid());
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });

        if (self.nano) |nano| {
            assert(nano <= 999999999);
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

fn isValidTimezone(tz: i16) bool {
    const t: u16 = @abs(tz);
    const h = t / 60;
    const m = t % 60;

    if (h > 23) {
        return false;
    }

    return m < 60;
}
