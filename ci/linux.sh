#!/bin/sh
# SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
# SPDX-License-Identifier: Apache-2.0

set -eux

./zig build fetch-toml-test
./zig build test --summary all
