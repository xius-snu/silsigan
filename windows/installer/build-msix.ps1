# Builds the Windows app and packages it as a Microsoft Store MSIX
# (dist\Silsigan.msix). The Store signs the package, so no certificate
# is involved. Config lives under `msix_config:` in pubspec.yaml.
#
# Requires: Flutter, Visual Studio C++ workload, nuget.exe on PATH
# (flutter_tts), and the Windows 10 SDK (makeappx.exe is bundled with the
# msix pub package, so the SDK is only needed by the Flutter build itself).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File windows/installer/build-msix.ps1
#   powershell -ExecutionPolicy Bypass -File windows/installer/build-msix.ps1 -SkipFlutterBuild

param(
    # Reuse build\windows\x64\runner\Release instead of running `flutter build windows`.
    [switch]$SkipFlutterBuild
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ReleaseDir = Join-Path $RepoRoot "build\windows\x64\runner\Release"
$DistDir = Join-Path $RepoRoot "dist"

$pubspec = Get-Content (Join-Path $RepoRoot "pubspec.yaml") -Raw

if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw "Could not read version from pubspec.yaml"
}
$version = $Matches[1]

# The Store rejects packages whose identity doesn't match Partner Center.
if ($pubspec -match 'REPLACE_ME') {
    throw @"
pubspec.yaml still has REPLACE_ME placeholders under msix_config.
Reserve the app name in Partner Center, then copy Package/Identity/Name,
Package/Identity/Publisher and Package/Properties/PublisherDisplayName from
Product management -> Product identity into identity_name, publisher and
publisher_display_name.
"@
}

# flutter_tts's Windows CMake step shells out to nuget.exe.
$nugetDir = Join-Path $env:LOCALAPPDATA "Programs\nuget"
if (Test-Path (Join-Path $nugetDir "nuget.exe")) {
    $env:Path = "$nugetDir;$env:Path"
}

# dart/msix and flutter.bat look up %PROGRAMFILES(X86)%. Some hosts
# (including Cursor's agent shell) omit that variable even when the
# directory exists.
$pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
if (-not $pf86 -or $pf86.Trim().Length -eq 0) {
    $pf86 = "C:\Program Files (x86)"
}
[Environment]::SetEnvironmentVariable("PROGRAMFILES(X86)", $pf86, "Process")
[Environment]::SetEnvironmentVariable("ProgramFiles(x86)", $pf86, "Process")
$common86 = [Environment]::GetEnvironmentVariable("CommonProgramFiles(x86)")
if (-not $common86 -or $common86.Trim().Length -eq 0) {
    $common86 = Join-Path $pf86 "Common Files"
    [Environment]::SetEnvironmentVariable("CommonProgramFiles(x86)", $common86, "Process")
}

Write-Host "Silsigan $version -> Store package version $version.0"

if ($SkipFlutterBuild) {
    if (-not (Test-Path (Join-Path $ReleaseDir "silsigan.exe"))) {
        throw "No Release build at $ReleaseDir; drop -SkipFlutterBuild."
    }
    Write-Host "Using existing Release build at $ReleaseDir"
}

# Never ship a local SQLite file created by running the exe from Release.
$dartTool = Join-Path $ReleaseDir ".dart_tool"
if (Test-Path $dartTool) {
    Remove-Item -Recurse -Force $dartTool
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

Push-Location $RepoRoot
try {
    $args = @("run", "msix:create", "--store")
    if ($SkipFlutterBuild) { $args += @("--build-windows", "false") }
    & dart @args
    if ($LASTEXITCODE -ne 0) { throw "dart run msix:create failed" }
}
finally {
    Pop-Location
}

$msix = Join-Path $DistDir "Silsigan.msix"
if (-not (Test-Path $msix)) { throw "Expected output missing: $msix" }
Write-Host "Store package: $msix"
Write-Host ("Size: {0:N1} MB" -f ((Get-Item $msix).Length / 1MB))
Write-Host "Upload it at Partner Center -> Silsigan -> Submissions -> Packages."
