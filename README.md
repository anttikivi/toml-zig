# TOML-Zig

A TOML 1.0.0 parser written in Zig. This parser implements the complete TOML
specification with optional diagnostics.

> [!NOTE]
> This library does&rsquo;t currently work properly on Windows. Windows support
> will be added in a later release.

## Quick Start

### Prerequisites

- Zig 0.15.1 or later.

### Basic Usage

```zig
const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const input =
        \\name = "TOML"
        \\version = "1.0.0"
        \\authors = ["Tom Preston-Werner", "Pradyun Gedam", "et al."]
        \\
        \\[database]
        \\server = "192.168.1.80"
        \\ports = [8001, 8001, 8002]
        \\connection_max = 5000
        \\enabled = true
        \\
        \\[servers.alpha]
        \\ip = "10.0.0.1"
        \\role = "frontend"
        \\
        \\[[servers.beta]]
        \\ip = "10.0.0.2"
        \\role = "backend"
        \\
        \\[[servers.beta]]
        \\ip = "10.0.0.3"
        \\role = "backend"
    ;

    var root = try toml.parse(gpa, input);
    defer root.deinit(gpa);

    // Access values
    const name = root.table.get("name").?.string;
    const version = root.table.get("version").?.string;
    const authors = root.table.get("authors").?.array;

    std.debug.print("Project: {s} v{s}\n", .{ name, version });
    std.debug.print("Authors: ", .{});
    for (authors.items) |author| {
        std.debug.print("{s} ", .{author.string});
    }
    std.debug.print("\n", .{});

    // Access nested tables
    const database = root.table.get("database").?.table;
    const server = database.get("server").?.string;
    const ports = database.get("ports").?.array;

    std.debug.print("Database server: {s}\n", .{server});
    std.debug.print("Ports: ", .{});
    for (ports.items) |port| {
        std.debug.print("{d} ", .{port.int});
    }
    std.debug.print("\n", .{});

    // Access array of tables
    const beta_servers = root.table.get("servers").?.table.get("beta").?.array;
    std.debug.print("Beta servers:\n", .{});
    for (beta_servers.items, 0..) |s, i| {
        const ip = s.table.get("ip").?.string;
        const role = s.table.get("role").?.string;
        std.debug.print("  {d}: {s} ({s})\n", .{ i + 1, ip, role });
    }
}
```

### Error Handling with Diagnostics

```zig
const std = @import("std");
const toml = @import("toml");

pub fn parseWithErrorHandling(input: []const u8) !void {
    const gpa = std.heap.page_allocator;

    var diag: toml.Diagnostics = undefined;
    const result = toml.parseWithDiagnostics(gpa, input, &diag) catch |err| {
        std.debug.print("{f}\n" .{diag});
        return err;
    };
    defer root.deinit(gpa);
}
```

## API Reference

### Core Functions

- `parse(gpa: Allocator, input: []const u8) !Value` - Parse TOML input
- `parseWithDiagnostics(gpa: Allocator, input: []const u8, diag: ?*Diagnostics) !Value` -
  Parse with detailed error information

### Main Types

- `Value` - Union type representing any TOML value
- `Table` - String-keyed hash map of TOML values
- `Array` - Dynamic array of TOML values
- `Datetime` - TOML datetime with timezone support
- `Date` - Local date representation
- `Time` - Local time representation

### Value Access

```zig
// Check value type
switch (value) {
    .string => |s| std.debug.print("String: {s}\n", .{s}),
    .int => |n| std.debug.print("Integer: {d}\n", .{n}),
    .float => |f| std.debug.print("Float: {d}\n", .{f}),
    .bool => |b| std.debug.print("Boolean: {any}\n", .{b}),
    .datetime => |dt| std.debug.print("Datetime: {f}\n", .{dt}),
    .local_datetime => |dt| std.debug.print("Local datetime: {f}\n", .{dt}),
    .local_date => |d| std.debug.print("Date: {f}\n", .{d}),
    .local_time => |t| std.debug.print("Time: {f}\n", .{t}),
    .array => |arr| std.debug.print("Array with {d} items\n", .{arr.items.len}),
    .table => |tbl| std.debug.print("Table with {d} keys\n", .{tbl.count()}),
}

// Safe access with optional chaining
if (value.table.get("nested")?.table.get("key")?.string) |s| {
    std.debug.print("Nested value: {s}\n", .{s});
}
```

## License

Copyright &copy; 2025 Antti Kivi.

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file
for more information.
