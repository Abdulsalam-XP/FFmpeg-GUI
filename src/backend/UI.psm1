# Console-era UI module. Everything that printed to a terminal (banners, animated
# lines, the blocking progress bar and file picker, Invoke-FFmpegProcess) went away with
# the WPF rewrite; the app now runs with no console at all. Only the pure progress-line
# parser survives, because both the GUI process runner and its tests still need it.

function ConvertFrom-FFmpegProgressLine {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][double]$TotalSeconds,
        [Parameter(Mandatory = $true)][double]$ElapsedSeconds
    )

    if ($Line -notmatch "time=(\d{2}):(\d{2}):(\d{2}\.\d{2})") {
        return $null
    }

    $hours, $minutes, $seconds = [int]$matches[1], [int]$matches[2], [double]$matches[3]
    $currentPos = ($hours * 3600) + ($minutes * 60) + $seconds

    if ($TotalSeconds -le 0) {
        return @{ Percent = 0; EtaString = "--:--:--" }
    }

    $percent = [math]::Min(100, [math]::Round(($currentPos / $TotalSeconds) * 100, 1))

    if ($percent -gt 0) {
        $totalEstimatedSeconds = ($ElapsedSeconds / $percent) * 100
        $remaining = [timespan]::FromSeconds($totalEstimatedSeconds - $ElapsedSeconds)
        $etaString = $remaining.ToString("hh\:mm\:ss")
    } else {
        $etaString = "--:--:--"
    }

    return @{ Percent = $percent; EtaString = $etaString }
}

# Presentation-only formatting for the selected-video card. Kept here with the other
# pure helpers so it is unit-testable: everything that touches a window is not.
function Format-VideoMetadata {
    param([hashtable]$Properties)

    $dash = "-"
    $result = @{ Resolution = $dash; FrameRate = $dash; Length = $dash; Size = $dash }
    if (-not $Properties) { return $result }

    # ffprobe gives "2560x1440"; the card spaces it out for legibility.
    if ($Properties.Resolution) {
        $result.Resolution = ($Properties.Resolution -replace 'x', ' x ')
    }

    # ffprobe reports "N/A" rather than a number when the stream has no usable rate.
    if ($null -ne $Properties.FrameRate -and $Properties.FrameRate -ne "N/A") {
        $result.FrameRate = "$($Properties.FrameRate) fps"
    }

    if ($Properties.Duration -is [timespan]) {
        $d = $Properties.Duration
        # Floor, not [int]: a PowerShell int cast rounds to nearest, so 2 min 50 sec
        # would otherwise present itself as "3 min 50 sec".
        $result.Length = if ($d.TotalHours -ge 1) {
            "{0} hr {1} min" -f [int][Math]::Floor($d.TotalHours), $d.Minutes
        } elseif ($d.TotalMinutes -ge 1) {
            "{0} min {1} sec" -f [int][Math]::Floor($d.TotalMinutes), $d.Seconds
        } else {
            "{0} sec" -f [int][Math]::Floor($d.TotalSeconds)
        }
    }

    if ($null -ne $Properties.FileSizeBytes) {
        $bytes = [double]$Properties.FileSizeBytes
        $result.Size = if ($bytes -ge 1GB) {
            "{0:N2} GB" -f ($bytes / 1GB)
        } else {
            "{0:N0} MB" -f ($bytes / 1MB)
        }
    }

    return $result
}

# Where a finished job goes: beside the video it came from.
#
# Every job used to name its output with the bare file name and no directory, which ffmpeg
# resolves against its working directory -- so compressing D:\RECORDINGS\clip.mp4 dropped
# clip-balanced.mp4 into the app's own folder, with nothing in the UI saying where it went.
# For anyone who unzipped into Program Files that write also fails outright.
function Get-JobOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $directory = [System.IO.Path]::GetDirectoryName($InputFile)
    $name = "$base-$Suffix.mp4"

    # A bare file name has no directory to sit beside, so keep it relative as before.
    if ([string]::IsNullOrEmpty($directory)) { return $name }
    return (Join-Path $directory $name)
}

# 5% in clears the black lead-in that screen recordings usually start with, while
# scaling with length. Capped so a multi-hour file does not seek halfway across disk.
function Get-ThumbnailSeconds {
    param([timespan]$Duration)

    if (-not $Duration -or $Duration.TotalSeconds -le 0) { return 0 }
    return [Math]::Min([Math]::Round($Duration.TotalSeconds * 0.05, 2), 300)
}

Export-ModuleMember -Function ConvertFrom-FFmpegProgressLine, Format-VideoMetadata, Get-ThumbnailSeconds, Get-JobOutputPath
