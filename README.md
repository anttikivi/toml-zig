# toml-zig

A TOML parser library for Zig.

- Supports both TOML v1.1.0 and v1.0.0.
- Supports optional, more detailed diagnostics.
- Passes the
  [standard `toml-test` suite](https://github.com/toml-lang/toml-test/).

The library currently uses Zig 0.15.2.

## Usage

Parse a TOML document with `toml.decode`. Parsing the document decodes it into
memory as a tree data structure that reflects the document as `toml.Value`. The
`toml.Table` struct provides helper methods for navigating the parsed structure.

### Example

```zig
const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const input =
        \\title = "example"
        \\[server]
        \\port = 8080
    ;

    var parsed = try toml.decode(gpa, input, .{});
    defer parsed.deinit();

    const title = parsed.root.get("title") orelse return error.MissingTitle;
    switch (title) {
        .string => |s| std.debug.print("title: {s}\n", .{s}),
        else => return error.InvalidType,
    }
}
```

### Decode options

The decoder function `toml.decode` accepts `DecodeOptions` for customizing its
behavior:

- `version`: TOML version (`.@"1.1.0"` by default)
- `validate_utf8`: whether to validate input UTF-8 (`true` by default)
- `diagnostics`: optional pointer to diagnostics output object

Example with diagnostics:

```zig
var diagnostics = toml.Diagnostics{};
defer diagnostics.deinit(gpa);

_ = toml.decode(gpa, input, .{
    .diagnostics = &diagnostics,
}) catch |err| {
    std.debug.print(
        "{s}:{d}:{d}: {s}\n{s}\n",
        .{
            "input.toml",
            diagnostics.line orelse 0,
            diagnostics.column orelse 0,
            diagnostics.message orelse @errorName(err),
            diagnostics.snippet orelse "",
        },
    );
    return err;
};
```

## Installing

Add the library to your `build.zig.zon`:

    zig fetch --save git+https://codeberg.org/anttikivi/toml-zig#v0.1.0

In your `build.zig`, add the library as a module like this:

```zig
const toml_dep = b.dependency("toml-zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toml", toml_dep.module("toml"));
```

Now you can use the library in your Zig code by importing it as

```zig
const toml = @import("toml");
```

## Building

The library doesn't currently offer a way to build a static or dynamic library.
Please see Installing section above on how to use the library.

## Running tests

In addition to own unit tests, the library is tested against
[`toml-test`](https://github.com/toml-lang/toml-test). To run all of the tests:

    zig build test

If you need to install `toml-test` locally first, you can run:

    zig build fetch-toml-test

There are also commands for running only the unit tests or the `toml-test`
suite:

    zig build test-unit
    zig build test-toml

## Installing Zig

If you are working on a Zig project, it's highly likely that you have Zig
installed on your system. However, the project includes a utility script that
uses the system Zig if it is available or alternatively installs the correct
version of Zig for you. To use this script, just run [`./zig`](zig) or
[`.\zig.ps1`](zig.ps1) instead of `zig` depending on your system.

## License

Copyright (c) 2026 anttikivi

The library is licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE) for more information.
