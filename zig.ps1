#!/bin/sh
echo `# <#` >/dev/null 2>&1
ROOT_DIR="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)"
exec "${ROOT_DIR}/tools/zig.sh" "$@"
exit
#> > $null
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
& "$RootDir/tools/zig.ps1" @args
exit $LASTEXITCODE
