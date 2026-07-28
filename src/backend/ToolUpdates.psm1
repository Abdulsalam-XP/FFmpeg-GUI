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
    $match = [regex]::Match($Line, 'ffmpeg version \S*?(?<!\d)(20\d{6})(?!\d)')
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

Export-ModuleMember -Function ConvertFrom-FfmpegVersionString, ConvertFrom-YtDlpVersionString
