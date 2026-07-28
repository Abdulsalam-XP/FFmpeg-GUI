# No -Force: it would demote the globally imported UI module to a nested one,
# hiding UI functions from the main script and the other modules
Import-Module (Join-Path $PSScriptRoot "UI.psm1")
Import-Module (Join-Path $PSScriptRoot "ToolPaths.psm1")

$ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

function Merge-AudioStreamsAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputVideo,
        [double]$SystemVolume = 1.0,
        [double]$MicVolume = 1.0
    )

    $durationOutput = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $InputVideo 2>&1
    $totalSeconds = [double]$durationOutput
    $videoInfo = & $ffprobe -v quiet -print_format json -show_streams -select_streams a $InputVideo 2>&1 | ConvertFrom-Json
    $audioStreams = $videoInfo.streams

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputVideo)
    $outputFile = "$baseName-merged-audio.mp4"

    $filterComplex = ""
    for ($i = 0; $i -lt $audioStreams.Count; $i++) {
        $volume = if ($i -eq 0) { $SystemVolume } else { $MicVolume }
        if ($volume -ne 1.0) { $filterComplex += "[0:a:$i]volume=$volume[a$i];" }
        else { $filterComplex += "[0:a:$i]asetpts=PTS-STARTPTS[a$i];" }
    }
    $mixInputs = (0..($audioStreams.Count - 1) | ForEach-Object { "[a$_]" }) -join ""
    $filterComplex += "$mixInputs amix=inputs=$($audioStreams.Count):duration=longest:normalize=0[aout]"

    $argList = @("-i", "`"$InputVideo`"", "-filter_complex", "`"$filterComplex`"", "-map", "0:v:0", "-map", "`"[aout]`"",
        "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "`"$outputFile`"", "-y")

    $panel = $Context.Panels.MergeAudio
    $progressBar = $panel.FindName("ProgressBarMerge")
    $percentText = $panel.FindName("TextMergePercent")
    $etaText = $panel.FindName("TextMergeEta")
    $cancelButton = $panel.FindName("ButtonMergeCancel")
    # Disabled for the duration of the run -- see Compress-VideoAsync: without this a
    # second click starts a parallel job sharing this panel's output and progress bar.
    $startButton = $panel.FindName("ButtonMergeStart")
    $startTime = Get-Date
    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    # See Compress-VideoAsync in VideoProcessing.psm1 for why this scriptblock capture is
    # necessary: Start-TrackedProcess invokes -OnLine from UI-WPF.psm1's own module scope,
    # where an unqualified call to ConvertFrom-FFmpegProgressLine (imported here from
    # UI.psm1) does not resolve by name. Capturing the function body and invoking it via
    # "& $convertProgressLine" sidesteps command-name lookup entirely.
    $convertProgressLine = ${function:ConvertFrom-FFmpegProgressLine}

    $process = Start-TrackedProcess -Context $Context -FileName $ffmpegPath -Arguments ($argList -join " ") -ReadStream Error `
        -OnLine {
            param($line)
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $progress = & $convertProgressLine -Line $line -TotalSeconds $totalSeconds -ElapsedSeconds $elapsed
            if ($progress) {
                $progressBar.Value = $progress.Percent
                $percentText.Text = "{0:N1}%" -f $progress.Percent
                $etaText.Text = $progress.EtaString
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($startButton) { $startButton.IsEnabled = $true }
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%"; $etaText.Text = "00:00:00" }
        }.GetNewClosure()

    if ($startButton) { $startButton.IsEnabled = $false }
    $cancelButton.IsEnabled = $true
    Set-CancelButtonTarget -Button $cancelButton -Process $process
    return $process
}

Export-ModuleMember -Function Merge-AudioStreamsAsync