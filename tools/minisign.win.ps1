#!/usr/bin/env pwsh
# SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$MINISIGN_VERSION = "0.12"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepositoryRoot = Split-Path -Parent $ScriptDir
$ToolsDir = Join-Path $RepositoryRoot "tools"
$LocalMinisignDir = Join-Path $ToolsDir ".minisign"
$LocalMinisignBin = Join-Path $LocalMinisignDir "minisign.exe"

function Test-RightVersion {
    param(
        [string]$MinisignPath
    )

    if ([string]::IsNullOrEmpty($MinisignPath)) {
        return $false
    }

    $command = Get-Command $MinisignPath -ErrorAction Ignore
    if (-not $command) {
        return $false
    }

    $strictVersion = $false
    $strictEnv = $env:MINISIGN_REQUIRE_STRICT_VERSION
    if ($null -ne $strictEnv) {
        $strictEnvLower = $strictEnv.ToLowerInvariant()
        $strictVersion = ($strictEnvLower -eq "1" -or $strictEnvLower -eq "true" -or $strictEnvLower -eq "yes")
    }

    if (-not $strictVersion) {
        return $true
    }

    try {
        $foundVersion = & $MinisignPath -v 2>$null
        return ($foundVersion -match [regex]::Escape($MINISIGN_VERSION))
    }
    catch {
        return $false
    }
}

function Find-Minisign {
    if (Test-RightVersion $LocalMinisignBin) {
        return $LocalMinisignBin
    }

    if (Test-RightVersion "minisign") {
        return "minisign"
    }

    return $null
}

function Main {
    $minisignBin = Find-Minisign

    if (-not $minisignBin) {
        $downloadScript = Join-Path $ScriptDir "download_minisign.ps1"
        & $downloadScript $MINISIGN_VERSION $LocalMinisignDir
        if ((Test-Path variable:LASTEXITCODE) -and $LASTEXITCODE -ne 0) {
            throw "failed to download minisign"
        }

        $minisignBin = $LocalMinisignBin

        if (-not (Test-RightVersion $minisignBin)) {
            throw "downloaded minisign is missing or has wrong version: $minisignBin"
        }
    }

    $exitCode = 0
    & $minisignBin @args
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
