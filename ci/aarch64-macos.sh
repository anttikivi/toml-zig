#!/bin/sh

set -eux

./zig build fetch-toml-test
./zig build test --summary all
