# No -Force: it would demote the globally imported UI module to a nested one,
# hiding UI functions from the main script and the other modules
Import-Module (Join-Path $PSScriptRoot "UI.psm1")
Import-Module (Join-Path $PSScriptRoot "ToolPaths.psm1")

$script:YtDlpUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
# downloaded-total-estimate-eta, emitted one line at a time by --newline.
$script:YtDlpProgressTemplate = "%(progress.downloaded_bytes)s-%(progress.total_bytes)s-%(progress.total_bytes_estimate)s-%(progress.eta)s"

function Get-YtDlpPath {
    return Get-ToolPath -Name "yt-dlp" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
}

# Parses one yt-dlp progress line into percent + ETA, or $null when the line carries no
# usable progress. Pure, so the download functions below stay free of parsing logic and
# this can be tested without spawning yt-dlp.
function ConvertFrom-YtDlpProgressLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    if ($Line -notmatch "(\d+)-(\d+|NA)-(\d+|NA)-(\d+|NA)") { return $null }

    $downloaded = [double]$matches[1]
    # total_bytes is absent for streamed formats; total_bytes_estimate is the fallback.
    $total = if ($matches[2] -ne "NA") { [double]$matches[2] }
             elseif ($matches[3] -ne "NA") { [double]$matches[3] }
             else { 0 }
    if ($total -le 0) { return $null }

    $etaString = if ($matches[4] -ne "NA") {
        ([timespan]::FromSeconds([int]$matches[4])).ToString("hh\:mm\:ss")
    } else { "--:--:--" }

    return @{
        Percent   = [math]::Round(($downloaded / $total) * 100, 1)
        EtaString = $etaString
    }
}

# Shared plumbing for both downloaders: same controls, same progress parsing, same
# terminal states. Only the yt-dlp arguments and the panel differ.
function Start-YtDlpDownload {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)]$Panel,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$ControlSuffix,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $progressBar = $Panel.FindName("ProgressBar$ControlSuffix")
    $statusText = $Panel.FindName("Text${ControlSuffix}Status")
    $etaText = $Panel.FindName("Text${ControlSuffix}Eta")
    $cancelButton = $Panel.FindName("Button${ControlSuffix}Cancel")
    # Disabled for the duration of the run -- see Compress-VideoAsync: without this a
    # second click starts a parallel download sharing this panel's progress controls.
    $startButton = $Panel.FindName("Button${ControlSuffix}Start")

    # Captured as a scriptblock rather than called by name: Start-TrackedProcess invokes
    # -OnLine from UI-WPF.psm1's own module scope, where a command imported into *this*
    # module does not resolve. Same fix as Compress-VideoAsync in VideoProcessing.psm1.
    $parseProgressLine = ${function:ConvertFrom-YtDlpProgressLine}

    $progressBar.Value = 0
    $statusText.Text = "Starting..."
    $etaText.Text = "--:--:--"

    $process = Start-TrackedProcess -Context $Context -FileName (Get-YtDlpPath) -Arguments $Arguments -ReadStream Output `
        -OnLine {
            param($line)
            $progress = & $parseProgressLine -Line $line
            if ($progress) {
                $progressBar.Value = $progress.Percent
                $statusText.Text = "{0:N1}% downloaded" -f $progress.Percent
                $etaText.Text = $progress.EtaString
            } elseif ($line -match '^\[(Merger|ExtractAudio|VideoConvertor|Fixup\w*)\]') {
                # yt-dlp's own post-download phases: remuxing the separate video and audio
                # streams, or extracting to mp3. The bar is pegged at 100% throughout and
                # this can run for a while on a long video, so it needs to say something
                # other than "100% downloaded". Matched on yt-dlp's actual phase prefixes
                # rather than inferred from the percentage: an MP4 download hits 100% once
                # per stream, so a percentage test would flash this between them.
                $progressBar.Value = 100
                $statusText.Text = "Download complete -- finalizing..."
                $etaText.Text = "finalizing..."
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($startButton) { $startButton.IsEnabled = $true }
            if ($exitCode -eq 0) {
                $progressBar.Value = 100
                $statusText.Text = "Done -- saved to $DestinationPath"
                $etaText.Text = "done"
            } elseif ($exitCode -eq -1) {
                $statusText.Text = "Cancelled"
            } else {
                $statusText.Text = "Download failed (exit $exitCode)"
            }
        }.GetNewClosure()

    if ($startButton) { $startButton.IsEnabled = $false }
    $cancelButton.IsEnabled = $true
    Set-CancelButtonTarget -Button $cancelButton -Process $process
    return $process
}

function Get-AvailableResolutions {
    param([Parameter(Mandatory = $true)][string]$FormatsText)

    $resolutions = @(
        @{height = "4320"; name = "8K"; code = "2160p60"; formatString = "bestvideo[height<=4320]+bestaudio/best[height<=4320]" },
        @{height = "2160"; name = "4K"; code = "2160p"; formatString = "bestvideo[height<=2160]+bestaudio/best[height<=2160]" },
        @{height = "1440"; name = "2K"; code = "1440p"; formatString = "bestvideo[height<=1440]+bestaudio/best[height<=1440]" },
        @{height = "1080"; name = "Full HD"; code = "1080p"; formatString = "best[height<=1080][ext=mp4]/best[ext=mp4]/best" },
        @{height = "720"; name = "HD"; code = "720p"; formatString = "best[height<=720][ext=mp4]/best[ext=mp4]/best" },
        @{height = "480"; name = "SD"; code = "480p"; formatString = "best[height<=480][ext=mp4]/best[ext=mp4]/best" },
        @{height = "360"; name = "Low"; code = "360p"; formatString = "best[height<=360][ext=mp4]/best[ext=mp4]/best" }
    )

    $available = @()
    foreach ($res in $resolutions) {
        if ($FormatsText -match "$($res.height)p" -or $FormatsText -match "x$($res.height)\b") {
            $available += $res
        }
    }
    return $available
}

function Save-YouTubeMP3Async {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $downloadPath = Join-Path (Get-Location) "MP3 Downloads"
    if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

    $outputTemplate = Join-Path $downloadPath "%(title)s.%(ext)s"
    $arguments = "$Url --no-playlist --no-warnings --socket-timeout 30 --user-agent `"$script:YtDlpUserAgent`" " +
                 "-x --audio-format mp3 -o `"$outputTemplate`" --newline --progress-template ""$script:YtDlpProgressTemplate"""

    return Start-YtDlpDownload -Context $Context -Panel $Context.Panels.YouTubeMP3 -Arguments $arguments `
        -ControlSuffix "YoutubeMP3" -DestinationPath $downloadPath
}

function Save-YouTubeMP4Async {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][hashtable]$Resolution
    )

    $downloadPath = Join-Path (Get-Location) "MP4 Downloads"
    if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

    $outputTemplate = Join-Path $downloadPath "%(title)s-$($Resolution.height)P.%(ext)s"
    $arguments = "$Url --no-playlist --no-warnings --socket-timeout 30 --user-agent `"$script:YtDlpUserAgent`" " +
                 "--newline --progress-template ""$script:YtDlpProgressTemplate"" -f $($Resolution.formatString) " +
                 "-o `"$outputTemplate`" --merge-output-format mp4 --postprocessor-args ""Merger: -c:v copy -c:a aac"""

    return Start-YtDlpDownload -Context $Context -Panel $Context.Panels.YouTubeMP4 -Arguments $arguments `
        -ControlSuffix "YoutubeMP4" -DestinationPath $downloadPath
}

# Queries yt-dlp for the formats a video actually offers. Synchronous: it is a short
# metadata call, not a download, and the caller needs the list back before the user can
# pick anything. Returns the Get-AvailableResolutions hashtables.
function Get-YouTubeResolutions {
    param([Parameter(Mandatory = $true)][string]$Url)

    $commonArgs = @("--no-playlist", "--no-warnings", "--socket-timeout", "30",
                    "--user-agent", $script:YtDlpUserAgent)
    $formats = & (Get-YtDlpPath) -F $Url @commonArgs 2>&1 | Out-String
    return Get-AvailableResolutions -FormatsText $formats
}

Export-ModuleMember -Function Get-AvailableResolutions, Save-YouTubeMP3Async, Save-YouTubeMP4Async, `
    Get-YouTubeResolutions, ConvertFrom-YtDlpProgressLine