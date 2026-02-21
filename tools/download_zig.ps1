#!/usr/bin/env pwsh

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ZIG_PUBLIC_KEY = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"
$ZIG_MIRRORS_URL = "https://ziglang.org/download/community-mirrors.txt"
# The list of mirrors as of 2026-02-21 as a backup if ziglang.org is unavailable
$ZIG_FALLBACK_MIRRORS = @(
    "https://pkg.machengine.org/zig"
    "https://zigmirror.hryx.net/zig"
    "https://zig.linus.dev/zig"
    "https://zig.squirl.dev"
    "https://zig.florent.dev"
    "https://zig.mirror.mschae23.de/zig"
    "https://zigmirror.meox.dev"
    "https://ziglang.freetls.fastly.net"
    "https://zig.tilok.dev"
    "https://zig-mirror.tsimnet.eu/zig"
    "https://zig.karearl.com/zig"
    "https://pkg.earth/zig"
    "https://fs.liujiacai.net/zigbuilds"
)

function Fetch-Url {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    if ([string]::IsNullOrEmpty($Url)) {
        throw "no URL passed to 'Fetch-Url'"
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        return $response.Content
    }
    catch {
        throw "failed to fetch URL: $Url"
    }
}

function New-TempDir {
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
    $tmpDir = Join-Path $ParentDir ".zig-tmp.$randomSuffix"

    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    return $tmpDir
}

function Get-ShuffledLines {
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines
    )

    $filtered = $Lines | Where-Object { $_.Trim().Length -gt 0 }

    return $filtered | Get-Random -Count ([int]$filtered.Count)
}

function Download-Archive {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$OutFile
    )

    if ([string]::IsNullOrEmpty($Url)) {
        throw "no URL passed to 'Download-Archive'"
    }

    if ([string]::IsNullOrEmpty($OutFile)) {
        throw "no output passed to 'Download-Archive'"
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "failed to download: $Url"
    }
}

function Main {
    param(
        [Parameter(Mandatory)]
        [string]$ZigVersion,

        [Parameter(Mandatory)]
        [string]$DestDir
    )

    if ([string]::IsNullOrEmpty($ZigVersion)) {
        throw "no Zig version argument passed to 'download_zig'"
    }

    if ([string]::IsNullOrEmpty($DestDir)) {
        throw "no destination directory argument passed to 'download_zig'"
    }

    $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        "aarch64"
    }
    else {
        "x86_64"
    }

    $os = "windows"
    $archiveExtension = ".zip"

    $archiveDirParent = Split-Path -Parent $DestDir
    if (-not (Test-Path $archiveDirParent)) {
        New-Item -ItemType Directory -Path $archiveDirParent -Force | Out-Null
    }

    $archive = "zig-${arch}-${os}-${ZigVersion}${archiveExtension}"
    $archiveDir = New-TempDir -ParentDir $archiveDirParent

    try {
        $archiveDest = Join-Path $archiveDir $archive

        $mirrorList = @()
        try {
            $mirrorContent = Fetch-Url -Url $ZIG_MIRRORS_URL
            $mirrorList = $mirrorContent -split "`n" | Where-Object {
                $_.Trim().Length -gt 0 -and $_ -notmatch '^\s*#'
            } | ForEach-Object { $_.Trim() }
        }
        catch {
            $mirrorList = $ZIG_FALLBACK_MIRRORS
        }

        $mirrorList = Get-ShuffledLines -Lines $mirrorList

        $selectedMirror = ""
        $maxTries = if ($env:MAX_MIRROR_TRIES) { [int]$env:MAX_MIRROR_TRIES } else { 5 }
        $i = 0

        foreach ($mirror in $mirrorList) {
            $i++
            if ($i -gt $maxTries) { break }

            $url = "${mirror}/${archive}?source=anttikivi%2Ftoml-zig"
            $signatureUrl = "${mirror}/${archive}.minisig?source=anttikivi%2Ftoml-zig"

            Write-Host "trying to download archive from ${url}..."

            if (Test-Path $archiveDest) { Remove-Item $archiveDest -Force }
            if (Test-Path "${archiveDest}.minisig") { Remove-Item "${archiveDest}.minisig" -Force }

            try {
                Download-Archive -Url $url -OutFile $archiveDest
            }
            catch {
                continue
            }

            try {
                Download-Archive -Url $signatureUrl -OutFile "${archiveDest}.minisig"
            }
            catch {
                continue
            }

            Write-Host "verifying ${archive} from ${url}..."

            if (Get-Command minisign -ErrorAction Ignore) {
                try {
                    $null = & minisign -Vm $archiveDest -x "${archiveDest}.minisig" -P $ZIG_PUBLIC_KEY 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $selectedMirror = $mirror
                        break
                    }
                }
                catch {
                    continue
                }
            }
            else {
                Write-Warning "minisign not found, cannot verify signature"
                continue
            }
        }

        if ([string]::IsNullOrEmpty($selectedMirror)) {
            throw "failed to download and verify Zig from $maxTries mirrors"
        }

        Write-Host "downloaded and verified Zig from ${selectedMirror}" -ForegroundColor Green
        if (Test-Path "${archiveDest}.minisig") {
            Remove-Item "${archiveDest}.minisig" -Force
        }

        Write-Host "extracting ${archiveDest}..."
        Expand-Archive -Path $archiveDest -DestinationPath $archiveDir -Force
        Remove-Item $archiveDest -Force

        $extractedDirName = [System.IO.Path]::GetFileNameWithoutExtension($archive)
        $extractedDir = Join-Path $archiveDir $extractedDirName

        if (Test-Path $DestDir) {
            Remove-Item $DestDir -Recurse -Force
        }

        $destParent = Split-Path -Parent $DestDir
        if (-not (Test-Path $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }

        Move-Item $extractedDir $DestDir

        $zigBin = Join-Path $DestDir "zig.exe"
        Write-Host "Zig ${ZigVersion} available at ${zigBin}"
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
