#!/bin/sh

# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
#
# SPDX-License-Identifier: Apache-2.0

ROOT_DIR="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)"
exec "${ROOT_DIR}/tools/zig.sh" "$@"
