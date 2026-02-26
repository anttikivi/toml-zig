#!/bin/sh

set -eux

brew install minisign

./zig build fetch-toml-test
./zig build test --summary all
