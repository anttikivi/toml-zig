#!/usr/bin/env pwsh

# SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
#
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$MINISIGN_GITHUB_BASE_URL = "https://github.com/jedisct1/minisign/releases/download"
$MINISIGN_SHA256 = "37b600344e20c19314b2e82813db2bfdcc408b77b876f7727889dbd46d539479"

function New-TempDir {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ParentDir
    )

    if ([string]::IsNullOrEmpty($ParentDir)) {
        throw "no parent directory passed to 'New-TempDir'"
    }

    if (-not (Test-Path $ParentDir -PathType Container)) {
        throw "parent directory in 'New-TempDir' must exist"
    }

    $randomSuffix = [System.IO.Path]::GetRandomFileName().Replace(".", "")
    $tmpDir = Join-Path -Path $ParentDir -ChildPath ".minisign-tmp.$randomSuffix"

    if ($PSCmdlet.ShouldProcess($tmpDir, "Create temporary directory")) {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    }
    return $tmpDir
}

function Save-Archive {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$OutFile
    )

    if ([string]::IsNullOrEmpty($Url)) {
        throw "no URL passed to 'Save-Archive'"
    }

    if ([string]::IsNullOrEmpty($OutFile)) {
        throw "no output passed to 'Save-Archive'"
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "failed to download: $Url"
    }
}

function Test-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string]$File,

        [Parameter(Mandatory)]
        [string]$ExpectedHash
    )

    $actual = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()
    $expected = $ExpectedHash.ToLower()

    if ($actual -ne $expected) {
        throw "SHA256 mismatch for ${File}`n  expected: ${expected}`n  actual:   ${actual}"
    }
}

function Main {
    param(
        [Parameter(Mandatory)]
        [string]$MinisignVersion,

        [Parameter(Mandatory)]
        [string]$DestDir
    )

    if ([string]::IsNullOrEmpty($MinisignVersion)) {
        throw "no minisign version argument passed to 'download_minisign'"
    }

    if ([string]::IsNullOrEmpty($DestDir)) {
        throw "no destination directory argument passed to 'download_minisign'"
    }

    $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        "aarch64"
    }
    else {
        "x86_64"
    }

    $archive = "minisign-${MinisignVersion}-win64.zip"
    $expectedSha256 = $MINISIGN_SHA256

    $archiveDirParent = Split-Path -Parent $DestDir
    if (-not (Test-Path $archiveDirParent)) {
        New-Item -ItemType Directory -Path $archiveDirParent -Force | Out-Null
    }

    $archiveDir = New-TempDir -ParentDir $archiveDirParent

    try {
        $archiveDest = Join-Path -Path $archiveDir -ChildPath $archive

        $url = "${MINISIGN_GITHUB_BASE_URL}/${MinisignVersion}/${archive}"
        Write-Information "downloading minisign from ${url}..."

        Save-Archive -Url $url -OutFile $archiveDest

        Write-Information "verifying ${archive}..."
        Test-Sha256 -File $archiveDest -ExpectedHash $expectedSha256
        Write-Information "SHA256 verification passed"

        Write-Information "extracting ${archiveDest}..."
        Expand-Archive -Path $archiveDest -DestinationPath $archiveDir -Force
        Remove-Item $archiveDest -Force

        $minisignBin = Join-Path -Path (Join-Path -Path (Join-Path -Path $archiveDir -ChildPath "minisign-win64") -ChildPath $arch) -ChildPath "minisign.exe"

        if (-not (Test-Path $minisignBin)) {
            throw "minisign binary not found after extraction"
        }

        if (Test-Path $DestDir) {
            Remove-Item $DestDir -Recurse -Force
        }

        $destParent = Split-Path -Parent $DestDir
        if (-not (Test-Path $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }

        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        Move-Item $minisignBin (Join-Path -Path $DestDir -ChildPath "minisign.exe")

        Write-Information "minisign ${MinisignVersion} available at $(Join-Path -Path $DestDir -ChildPath 'minisign.exe')"
    }
    finally {
        if (Test-Path $archiveDir) {
            Remove-Item $archiveDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Main @args
}
catch {
    Write-Error $_
    exit 1
}
