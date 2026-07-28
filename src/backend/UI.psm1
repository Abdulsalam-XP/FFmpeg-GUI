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

Export-ModuleMember -Function ConvertFrom-FFmpegProgressLine
