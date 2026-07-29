<#
.SYNOPSIS
    Builds the distributable FFmpeg-GUI zip.

.DESCRIPTION
    The zip's top level mirrors src\, so unzipping yields one folder with
    Launcher.exe at its root and the app ready to run. Excluded from src\:
    Tests (developer-only), .gitignore/.gitkeep (repo plumbing), and
    assets\settings.json (the developer's own preferences -- the app writes a
    fresh one on first run). The build also refuses to package video/audio
    files: jobs write their output to the app's working directory, so a
    debugging session easily leaves a large clip in src\, and src\.gitignore
    keeps git status quiet about it.

    README.md, WHATS_NEW.txt and THIRD-PARTY-NOTICES.txt are added at the top
    level. src\bin\ must already hold ffmpeg.exe, ffprobe.exe and yt-dlp.exe:
    they are gitignored, so a clean clone will not have them and the script
    stops rather than shipping a package that silently falls back to whatever
    is on the build machine's PATH.

.NOTES
    The v2.0.0 build was done from an uncommitted scratch script and had to be
    reconstructed for v2.1.0. Hence this file.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

$src = Join-Path $RepoRoot "src"
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot "dist" }

# Version is single-sourced from the script the in-app updater scrapes.
$mainScript = Join-Path $src "Video-Audio-Tool.ps1"
$versionMatch = Select-String -Path $mainScript -Pattern '^\$scriptVersion\s*=\s*"([\d\.]+)"'
if (-not $versionMatch) { throw "Could not read `$scriptVersion from $mainScript" }
$version = $versionMatch.Matches[0].Groups[1].Value

$stageName = "FFmpeg-GUI-v$version"
$stage = Join-Path $OutputDir $stageName
$zipPath = Join-Path $OutputDir "$stageName.zip"

Write-Host "Building FFmpeg-GUI v$version" -ForegroundColor Cyan

# Refuse to ship without the bundled tools: "nothing to install" is the whole
# promise of the package.
$requiredBinaries = @("ffmpeg.exe", "ffprobe.exe", "yt-dlp.exe")
$missing = $requiredBinaries | Where-Object { -not (Test-Path (Join-Path $src "bin\$_")) }
if ($missing) {
    throw "src\bin is missing: $($missing -join ', '). These are gitignored; copy them in before building."
}

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# Copy src\ wholesale, then strip what must not ship. Simpler to audit than an
# include-list, which silently omits any file added to the app later.
Copy-Item -Path (Join-Path $src "*") -Destination $stage -Recurse -Force

$strip = @(
    (Join-Path $stage "backend\Tests"),
    (Join-Path $stage "assets\settings.json")
)
foreach ($path in $strip) {
    if (Test-Path $path) { Remove-Item $path -Recurse -Force }
}
Get-ChildItem $stage -Recurse -Force -Include ".gitignore", ".gitkeep" | Remove-Item -Force

foreach ($doc in @("README.md", "WHATS_NEW.txt", "THIRD-PARTY-NOTICES.txt")) {
    $docPath = Join-Path $RepoRoot $doc
    if (-not (Test-Path $docPath)) { throw "Missing $doc at the repo root." }
    Copy-Item $docPath -Destination $stage -Force
}

# Fail loudly if the layout a user depends on is wrong, rather than at their end.
foreach ($expected in @("Launcher.exe", "Video-Audio-Tool.ps1", "bin\ffmpeg.exe",
                        "bin\ffprobe.exe", "bin\yt-dlp.exe", "frontend\MainWindow.xaml",
                        "backend\ToolUpdates.psm1", "WHATS_NEW.txt")) {
    if (-not (Test-Path (Join-Path $stage $expected))) { throw "Staged package is missing $expected" }
}
if (Test-Path (Join-Path $stage "backend\Tests")) { throw "Tests leaked into the package" }
if (Test-Path (Join-Path $stage "assets\settings.json")) { throw "settings.json leaked into the package" }

# Media never belongs in the package, and src\.gitignore hides exactly this class of file
# from git status, so nothing else would catch it. A v2.1.0 build shipped a 111 MB gameplay
# clip this way: a compressed test output left in src\ by a debugging session, which the
# wholesale src\* copy picked up and no check questioned. Fails rather than stripping
# silently, because a stray recording in src\ means the working tree needs cleaning.
$mediaExtensions = @(".mp4", ".mkv", ".mov", ".mp3", ".m4a", ".webm", ".wav", ".avi")
$strays = Get-ChildItem $stage -Recurse -File -Force |
    Where-Object { $mediaExtensions -contains $_.Extension.ToLower() }
if ($strays) {
    $list = ($strays | ForEach-Object {
        "  {0} ({1} MB)" -f $_.FullName.Substring($stage.Length + 1), [math]::Round($_.Length / 1MB, 1)
    }) -join "`n"
    throw "Media files would ship in the package. Remove them from src\ and rebuild:`n$list"
}

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal

$zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "Staged : $stage" -ForegroundColor Green
Write-Host "Zip    : $zipPath ($zipMB MB)" -ForegroundColor Green
Write-Host ""
Write-Host "Next: verify the zip the way a user meets it -- unzip somewhere unrelated to" -ForegroundColor Yellow
Write-Host "the repo, with ffmpeg/yt-dlp stripped from PATH, and run Launcher.exe." -ForegroundColor Yellow
