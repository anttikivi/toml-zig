# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Change the license of the library to Apache-2.0.

## [0.1.0] - 2026-02-27

- Initial release of the `toml-zig` parser library.

### Added

- Include `toml.decode` API that parses TOML input into a tree data structure.
- Support TOML `1.0.0` and `1.1.0`, selectable with `DecodeOptions.version`.
- Support diagnostics reporting with line, column, snippet, and message through
  `DecodeOptions.diagnostics`.
- Check that the input is valid UTF-8 by default, configurable with
  `DecodeOptions.validate_utf8`.
- Add table lookup helpers (`contains`, `get`, `getPtr`).
- Add optional index hashing for large tables.
- Test the project against
  [`toml-test`](https://github.com/toml-lang/toml-test).

[Unreleased]: https://codeberg.org/anttikivi/toml-zig/compare/v0.1.0...HEAD
[0.1.0]: https://codeberg.org/anttikivi/toml-zig/releases/tag/v0.1.0
