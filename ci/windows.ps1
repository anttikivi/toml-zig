# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = "Stop"
Set-PSDebug -Trace 1

.\zig.ps1 build fetch-toml-test
.\zig.ps1 build test --summary all
