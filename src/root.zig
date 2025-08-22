//! TOML document parser and value model. This parser implements the full TOML
//! 1.0.0 specification.
//!
//! The parser can be used with either `parse` or `parseWithDiagnostics`.
//! The latter of the functions offers additional diagnostics for the caller
//! when the parser fails.
//!
//! Quick start:
//! ```zig
//! const std = @import("std");
//! const toml = @import("toml.zig");
//!
//! pub fn main() !void {
//!     const gpa = std.heap.page_allocator;
//!     const input = "name = \"TOML\"\nworkers = 4\n";
//!
//!     var root = try toml.parse(gpa, input);
//!     defer root.deinit(gpa);
//!
//!     const tbl = root.table; // the root of a TOML document is always a table
//!     const workers = tbl.get("workers").?.int;
//!     std.debug.print("workers: {d}\n", .{workers});
//! }
//! ```

const std = @import("std");

pub const Value = @import("value.zig").Value;
pub const Array = @import("value.zig").Array;
pub const Table = @import("value.zig").Table;
pub const Datetime = @import("value.zig").Datetime;
pub const Date = @import("value.zig").Date;
pub const Time = @import("value.zig").Time;

pub const Diagnostics = @import("decoder.zig").Diagnostics;
pub const parse = @import("decoder.zig").parse;
pub const parseWithDiagnostics = @import("decoder.zig").parseWithDiagnostics;

test {
    std.testing.refAllDecls(@This());
}
