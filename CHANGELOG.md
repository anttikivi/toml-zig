# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add `table_hash_index_threshold` to `DecodeOptions` to allow controlling the
  hash table threshold in runtime.
- Add `min_table_index_capacity` to `DecodeOptions` to allow controlling the
  minimum capacity reserved for the hash tables in runtime.
- Add a benchmarking suite for measuring the parser's performance in different
  scenarios: `array_tables`, `flat_kv`, `inline_heavy`, `mixed_realistic`,
  `nested_tables`, and `string_escapes`.
- Add five different benchmark sizes: `tiny`, `small`, `medium`, `large`, and
  `xlarge`.
- Add benchmarking utility that compares the benchmark result of the current
  HEAD against select revisions.
- Make the project [REUSE-compliant](https://reuse.software/).

### Changed

- Change the license of the library to Apache-2.0.
- Clean up the allocations made in the `Parser`.
- Use temporary arena allocator for the intermediate allocations when parsing.

### Removed

- Remove `table-index-threshold` from build options in favor of turning the
  value into runtime configuration option.
- Remove `min-index-capacity` from build options in favor of turning the value
  into runtime configuration option.

### Fixed

- Make `DecodeOptions`, `Diagnostics`, and `Parsed` public from the library
  root.
- Populate the `diagnostics` field in the parser correctly to export the
  diagnostics information from it as it was previously missing.
- Fix possible out-of-bounds access to the input slice in the scanner when
  parsing multiline literal strings.
- Fix the table hash lookup not probing the last bucket.
- Fix off-by-one error in `Diagnostics` when getting the code snippet and line
  of an error.

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
