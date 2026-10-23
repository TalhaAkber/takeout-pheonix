<#
.SYNOPSIS
    One-time Windows setup for Takeout Phoenix.

.DESCRIPTION
    Run once from a normal PowerShell window. It asks for admin rights itself
    (one UAC prompt), only for the long path setting:
      1. Installs Python 3, ExifTool and Android platform-tools (adb) with
         winget -- only the ones that are missing.
      2. Enables Windows long path support, so deep Takeout folders extract
         and process without "path too long" errors.
      3. Lets your user run local PowerShell scripts (execution policy
         RemoteSigned, current user only).
      4. Unblocks this repo's files in case it was downloaded as a ZIP.
    Safe to re-run: anything already in place is skipped.

.PARAMETER SkipInstall
    Only do steps 2-4; install nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\takeout-pheonix\scripts\setup-windows.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$LongPathKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    [ok] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    [!]  $Text" -ForegroundColor Yellow }

function Update-SessionPath {
    # Pick up PATH changes made by installers without opening a new window.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Find-Python {
    # `py` is the launcher python.org installs; plain `python` may just be the
    # Microsoft Store alias, so it isn't a reliable check.
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $version = & py -3 --version 2>$null
        if ($LASTEXITCODE -eq 0) { return "$version (py launcher)" }
    }
    return $null
}

function Find-ExifTool {
    $cmd = Get-Command exiftool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:LOCALAPPDATA\Programs\ExifTool\ExifTool.exe", "$env:ProgramFiles\ExifTool\ExifTool.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-WingetPackage([string]$Id) {
    $base = @('install', '--id', $Id, '--exact', '--source', 'winget',
              '--accept-package-agreements', '--accept-source-agreements', '--silent')
    Write-Host "    winget install $Id ..."
    & winget @($base + @('--scope', 'user'))
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "user-scope install returned $LASTEXITCODE, retrying with the package's default scope"
        & winget @base
    }
    Update-SessionPath
}

function Get-LongPathsEnabled {
    $value = Get-ItemProperty -Path $LongPathKey -Name LongPathsEnabled -ErrorAction SilentlyContinue
    if ($value) { return [int]$value.LongPathsEnabled -eq 1 }
    return $false
}

if ([System.IO.Path]::DirectorySeparatorChar -ne '\') {
    Write-Host 'This setup script is for Windows. On macOS/Linux see the Install section of README.md.'
    exit 1
}

# ---- 1. tools ---------------------------------------------------------------------

Write-Step 'Tools (Python 3, ExifTool, adb)'
$tools = @(
    @{ Name = 'Python 3'; Id = 'Python.Python.3.13'; Find = ${function:Find-Python} },
    @{ Name = 'ExifTool'; Id = 'OliverBetz.ExifTool'; Find = ${function:Find-ExifTool} },
    @{ Name = 'adb'; Id = 'Google.PlatformTools'; Find = ${function:Find-Adb} }
)
$haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

foreach ($t in $tools) {
    $found = & $t.Find
    if ($found) { Write-Ok "$($t.Name): $found"; continue }
    if ($SkipInstall) { Write-Warn "$($t.Name) missing (skipped: -SkipInstall)"; continue }
    if (-not $haveWinget) {
        Write-Warn "$($t.Name) missing and winget isn't available. Install 'App Installer' from the"
        Write-Warn "Microsoft Store (it provides winget), then re-run this script."
        continue
    }
    Install-WingetPackage $t.Id
    $found = & $t.Find
    if ($found) { Write-Ok "$($t.Name): $found" } else { Write-Warn "$($t.Name) still not found after install -- open a new PowerShell window and re-run this script." }
}

# ---- 2. long paths (needs admin) ----------------------------------------------------------

Write-Step 'Windows long path support'
if (Get-LongPathsEnabled) {
    Write-Ok 'already enabled'
} else {
    $setCmd = "New-ItemProperty -Path '$LongPathKey' -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force"
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $null = New-ItemProperty -Path $LongPathKey -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force
    } else {
        Write-Host '    Asking for admin rights (UAC prompt) to enable long paths...'
        try {
            $hostExe = (Get-Process -Id $PID).Path
            Start-Process -FilePath $hostExe -Verb RunAs -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $setCmd)
        } catch {
            Write-Warn 'admin prompt was cancelled'
        }
    }
    if (Get-LongPathsEnabled) {
        Write-Ok 'enabled (applies to newly started programs; reboot if you still hit path-too-long errors)'
    } else {
        Write-Warn 'not enabled -- very deep folders may fail to extract. Re-run this script and accept the UAC prompt.'
    }
}

# ---- 3. execution policy ----------------------------------------------------------------

Write-Step 'PowerShell script permission'
$effective = Get-ExecutionPolicy
if (@('RemoteSigned', 'Unrestricted', 'Bypass') -contains [string]$effective) {
    Write-Ok "execution policy is $effective"
} else {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        Write-Ok 'set to RemoteSigned for your user'
    } catch {
        Write-Warn 'blocked (probably by group policy). Run scripts like this instead:'
        Write-Warn '  powershell -ExecutionPolicy Bypass -File .\takeout-pheonix\scripts\push_next.ps1'
    }
}

# ---- 4. unblock downloaded files ------------------------------------------------------------

Write-Step 'Unblock repo files (only matters if downloaded as a ZIP)'
Get-ChildItem -LiteralPath $RepoRoot -Recurse -File | Unblock-File
Write-Ok $RepoRoot

# ---- next steps ----------------------------------------------------------------------------

Write-Step 'Next'
Write-Host '    1. Close this window and open a NEW PowerShell window (so PATH changes apply).'
Write-Host '    2. Phone: enable USB debugging, plug it in, tap Allow. Check with:  adb devices'
Write-Host '       Empty list? Install your phone''s USB driver (Pixel: "Google USB Driver",'
Write-Host '       Samsung: "Samsung Android USB Driver"), then re-plug the cable.'
Write-Host '    3. Follow "Quickstart (Windows)" in README.md.'
Write-Host ''
