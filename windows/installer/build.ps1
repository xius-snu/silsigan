# Builds the Windows app (if needed) and compiles Silsigan-Setup-<version>.exe
# with Inno Setup. Requires: Flutter, Visual Studio C++ workload, nuget.exe
# on PATH (flutter_tts), and Inno Setup 6.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File windows/installer/build.ps1
#   powershell -ExecutionPolicy Bypass -File windows/installer/build.ps1 -RebuildApp

param(
    [switch]$RebuildApp
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ReleaseExe = Join-Path $RepoRoot "build\windows\x64\runner\Release\silsigan.exe"
$IssPath = Join-Path $PSScriptRoot "silsigan.iss"
$VcRedistPath = Join-Path $PSScriptRoot "vc_redist.x64.exe"
$DistDir = Join-Path $RepoRoot "dist"

function Get-AppVersion {
    $pubspec = Get-Content (Join-Path $RepoRoot "pubspec.yaml") -Raw
    if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
        throw "Could not read version from pubspec.yaml"
    }
    return $Matches[1]
}

function Find-Iscc {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 7\ISCC.exe",
        "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    $cmd = Get-Command iscc -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# flutter_tts's Windows CMake step shells out to nuget.exe.
$nugetDir = Join-Path $env:LOCALAPPDATA "Programs\nuget"
if (Test-Path (Join-Path $nugetDir "nuget.exe")) {
    $env:Path = "$nugetDir;$env:Path"
}

$version = Get-AppVersion
Write-Host "Silsigan $version"

if ($RebuildApp -or -not (Test-Path $ReleaseExe)) {
    Write-Host "Building Windows release..."
    Push-Location $RepoRoot
    try {
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "Using existing Release build at $ReleaseExe"
}

# Never ship a local SQLite file created by running the exe from Release.
$dartTool = Join-Path $RepoRoot "build\windows\x64\runner\Release\.dart_tool"
if (Test-Path $dartTool) {
    Remove-Item -Recurse -Force $dartTool
}

if (-not (Test-Path $VcRedistPath)) {
    Write-Host "Downloading Visual C++ Redistributable..."
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $VcRedistPath
}

$iscc = Find-Iscc
if (-not $iscc) {
    throw "Inno Setup compiler (ISCC.exe) not found. Install Inno Setup 6 and re-run."
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Write-Host "Compiling installer with $iscc"
& $iscc /DMyAppVersion=$version $IssPath
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }

$setup = Join-Path $DistDir "Silsigan-Setup-$version.exe"
if (-not (Test-Path $setup)) { throw "Expected output missing: $setup" }
Write-Host "Installer: $setup"
Write-Host ("Size: {0:N1} MB" -f ((Get-Item $setup).Length / 1MB))
