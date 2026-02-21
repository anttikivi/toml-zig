#!/bin/sh
echo `# <#` >/dev/null 2>&1
SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/zig" "$@"
exit
#> > $null
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
& "$ScriptDir/zig.win.ps1" @args
exit $LASTEXITCODE
