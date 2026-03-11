#!/usr/bin/env pwsh

# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
#
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepositoryRoot = Split-Path -Parent $ScriptDir
$BuildZigZon = Join-Path $RepositoryRoot "build.zig.zon"
$ToolsDir = Join-Path $RepositoryRoot "tools"
$LocalZigDir = Join-Path $ToolsDir ".zig"
$LocalZigBin = Join-Path $LocalZigDir "zig.exe"

function Get-ZigVersion {
    param(
        [string]$BuildZigZonPath
    )

    if (-not (Test-Path -LiteralPath $BuildZigZonPath -PathType Leaf)) {
        throw "missing build metadata file: $BuildZigZonPath"
    }

    foreach ($line in Get-Content -LiteralPath $BuildZigZonPath) {
        if ($line -match '\.minimum_zig_version\s*=\s*"([^"]+)"') {
            return $Matches[1]
        }
    }

    throw "failed to read .minimum_zig_version from $BuildZigZonPath"
}

$ZIG_VERSION = Get-ZigVersion $BuildZigZon

function Test-RightVersion {
    param(
        [string]$ZigPath
    )

    if ([string]::IsNullOrEmpty($ZigPath)) {
        return $false
    }

    $command = Get-Command $ZigPath -ErrorAction Ignore
    if (-not $command) {
        return $false
    }

    try {
        $foundVersion = & $ZigPath version 2>$null
        return ($foundVersion.Trim() -eq $ZIG_VERSION)
    }
    catch {
        return $false
    }
}

function Find-Zig {
    if (Test-RightVersion $LocalZigBin) {
        return $LocalZigBin
    }

    if (Test-RightVersion "zig") {
        return "zig"
    }

    return $null
}

function Main {
    $zigBin = Find-Zig

    if (-not $zigBin) {
        $downloadScript = Join-Path $ScriptDir "download_zig.ps1"
        & $downloadScript $ZIG_VERSION $LocalZigDir
        if ((Test-Path variable:LASTEXITCODE) -and $LASTEXITCODE -ne 0) {
            throw "failed to download Zig"
        }

        $zigBin = $LocalZigBin

        if (-not (Test-RightVersion $zigBin)) {
            throw "downloaded Zig is missing or has wrong version: $zigBin"
        }
    }

    $exitCode = 0
    & $zigBin @args
    $exitCode = $LASTEXITCODE
    exit $exitCode
}

try {
    Main @args
}
catch {
    Write-Error $_
    exit 1
}
