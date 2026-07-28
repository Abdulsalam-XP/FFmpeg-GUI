# src/backend/ToolUpdates.psm1
# Checks for, downloads and installs newer ffmpeg/ffprobe/yt-dlp binaries into src/bin/.

Import-Module (Join-Path $PSScriptRoot "ToolPaths.psm1")

# BtbN stamps its master builds as N-<rev>-g<hash>-<yyyyMMdd>-<variant>. That trailing
# date is the only comparable thing these builds carry, because the remote release they
# come from is tagged with the literal string "latest" and has no version at all.
# Release builds (7.1.1, n7.1) carry no date, so they deliberately return $null rather
# than a guess -- see Test-ToolUpdate, which treats null as "Unknown" and offers the
# install instead of silently claiming the user is up to date.
function ConvertFrom-FfmpegVersionString {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    # (?<!\d) and (?!\d) pin the match to an exactly-8-digit run, so a longer digit
    # sequence is rejected rather than having a date read out of the middle of it.
    $match = [regex]::Match($Line, '(?:ffmpeg|ffprobe) version \S*?(?<!\d)(20\d{6})(?!\d)')
    if (-not $match.Success) { return $null }

    return ConvertTo-DateOrNull -Text $match.Groups[1].Value -Format "yyyyMMdd"
}

# yt-dlp reports yyyy.MM.dd, with nightly builds appending a .HHmmss field that is
# ignored -- day resolution is enough to decide whether an update exists.
function ConvertFrom-YtDlpVersionString {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $match = [regex]::Match($Line.Trim(), '^(\d{4})\.(\d{2})\.(\d{2})')
    if (-not $match.Success) { return $null }

    return ConvertTo-DateOrNull -Text ("{0}{1}{2}" -f `
        $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value) -Format "yyyyMMdd"
}

# ParseExact rather than [datetime] casting: a well-formed but impossible date such as
# 20260231 must fail rather than roll over into March.
function ConvertTo-DateOrNull {
    param([string]$Text, [string]$Format)

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Text, $Format,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed)

    if ($ok) { return $parsed }
    return $null
}

# Pure comparison, no I/O -- this is the decision the whole feature turns on, so it is
# kept free of network and filesystem access to stay fully unit-testable.
function Test-ToolUpdate {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Installed,
        [hashtable]$Latest
    )

    $result = @{ Status = "Unknown"; Installed = $Installed; Latest = $Latest }

    # A tool resolved from PATH is never "updated": the app does not own that copy and
    # must not touch it. The offered action is to place a managed copy in bin/, which
    # then wins in Get-ToolPath -- so it is Missing (i.e. "Install"), regardless of how
    # the versions compare.
    if ($Installed.Source -eq "missing" -or $Installed.Source -eq "system") {
        $result.Status = "Missing"
        return $result
    }

    if ($null -eq $Latest -or $null -eq $Latest.Version) { return $result }
    if ($null -eq $Installed.Version) { return $result }

    if ($Installed.Version -ge $Latest.Version) {
        $result.Status = "Current"
    } else {
        $result.Status = "Available"
    }

    return $result
}

# A future timestamp counts as stale: a clock that jumps forward (or a hand-edited
# settings.json) would otherwise pin the cache as permanently fresh.
function Test-ToolCacheFresh {
    param(
        [string]$Timestamp,
        [datetime]$Now = ([datetime]::UtcNow),
        [int]$MaxAgeMinutes = 60
    )

    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return $false }

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParse($Timestamp, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
        [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
    if (-not $ok) { return $false }

    $age = $Now - $parsed
    if ($age.TotalMinutes -lt 0) { return $false }
    return $age.TotalMinutes -le $MaxAgeMinutes
}

# Runs the tool and parses what it prints. Never throws: a missing, corrupt or
# non-responding exe is a normal state the Settings card has to render, not an error.
function Get-InstalledToolVersion {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("ffmpeg", "ffprobe", "yt-dlp")][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    $result = @{ Name = $Name; Path = $null; Source = "missing"; Version = $null; Display = "not installed" }

    $path = Get-ToolPath -Name $Name -ScriptRoot $ScriptRoot
    $result.Path = $path

    # Get-ToolPath returns the bare name when nothing was found in bin/, which means
    # "let Windows resolve it on PATH". Resolve it here so the card can distinguish a
    # system copy from nothing at all.
    if ($path -eq $Name) {
        $onPath = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        if (-not $onPath) { return $result }
        $result.Source = "system"
        $result.Path = $onPath.Source
    } else {
        if (-not (Test-Path -LiteralPath $path)) { return $result }
        $result.Source = "bin"
    }

    $arguments = if ($Name -eq "yt-dlp") { "--version" } else { "-version" }

    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $result.Path
        $pInfo.Arguments = $arguments
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::Start($pInfo)

        # Read stdout fully *before* WaitForExit. Waiting first can deadlock if the child
        # fills the redirected pipe buffer, which is the standard trap with redirection.
        # Also drain stderr to prevent it from blocking.
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit(10000) | Out-Null

        # Kill the process if it's still running after timeout, and prevent handle leak
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(1000) | Out-Null
        }

        $firstLine = ($stdout -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
        if (-not $firstLine) { $firstLine = "" }
        $result.Display = $firstLine.Trim()

        if ($Name -eq "yt-dlp") {
            $result.Version = ConvertFrom-YtDlpVersionString -Line $firstLine
            if ($result.Version) { $result.Display = $result.Version.ToString("yyyy.MM.dd") }
        } else {
            $result.Version = ConvertFrom-FfmpegVersionString -Line $firstLine
            if ($result.Version) { $result.Display = $result.Version.ToString("yyyy-MM-dd") + " build" }
        }

        if (-not $result.Version -and $result.Display.Length -gt 40) {
            $result.Display = $result.Display.Substring(0, 40) + "…"
        }
    }
    catch {
        $result.Display = "unreadable"
    }
    finally {
        if ($process) { $process.Dispose() }
    }

    return $result
}

$script:ReleaseApi = @{
    "yt-dlp" = @{
        Uri   = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
        Asset = "yt-dlp.exe"
    }
    "ffmpeg" = @{
        # BtbN publishes one rolling release whose tag is the literal string "latest",
        # so there is no version number on the remote side -- published_at is the only
        # comparable value, which is why the ffmpeg path is date-based throughout.
        Uri   = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest"
        Asset = "ffmpeg-master-latest-win64-gpl.zip"
    }
}

function Get-LatestToolRelease {
    param([Parameter(Mandatory = $true)][ValidateSet("ffmpeg", "yt-dlp")][string]$Name)

    $api = $script:ReleaseApi[$Name]

    # GitHub rejects API requests without a User-Agent. TLS 1.2 is forced because 5.1
    # defaults to SSL3/TLS1.0 on some machines, which api.github.com refuses outright.
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.ServicePointManager]::SecurityProtocol

    $response = Invoke-RestMethod -Uri $api.Uri -Headers @{
        "User-Agent" = "FFmpeg-GUI"
        "Accept"     = "application/vnd.github+json"
    } -TimeoutSec 20

    $asset = $response.assets | Where-Object { $_.name -eq $api.Asset } | Select-Object -First 1
    if (-not $asset) {
        throw "The $Name release does not contain the expected file '$($api.Asset)'."
    }

    if ($Name -eq "yt-dlp") {
        $version = ConvertFrom-YtDlpVersionString -Line $response.tag_name
        if (-not $version) { throw "Could not read a version from the yt-dlp tag '$($response.tag_name)'." }
        $display = $version.ToString("yyyy.MM.dd")
    } else {
        $published = [datetime]::MinValue
        $ok = [datetime]::TryParse($response.published_at,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$published)
        if (-not $ok) { throw "Could not read a build date from the ffmpeg release." }
        # Compared against a date-only installed build, so the time of day is dropped.
        $version = $published.Date
        $display = $version.ToString("yyyy-MM-dd") + " build"
    }

    return @{
        Name        = $Name
        Version     = $version
        Display     = $display
        DownloadUrl = $asset.browser_download_url
        AssetName   = $asset.name
    }
}

Export-ModuleMember -Function ConvertFrom-FfmpegVersionString, ConvertFrom-YtDlpVersionString, `
    Test-ToolUpdate, Test-ToolCacheFresh, Get-InstalledToolVersion, Get-LatestToolRelease
