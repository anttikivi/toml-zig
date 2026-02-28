#!/bin/sh
# SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
# SPDX-License-Identifier: Apache-2.0

echo `# <#` >/dev/null 2>&1
SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/minisign" "$@"
exit
#> > $null
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
& "$ScriptDir/minisign.win.ps1" @args
exit $LASTEXITCODE
