Import-Module "$PSScriptRoot/UI.psm1"
# Split-VideoAsync calls Get-VideoProperties (from VideoProcessing.psm1) directly, so this
# module needs its own import of it -- module command resolution only sees what a module
# imports itself, not whatever another module has exported into the global session state
# (the same rule behind the ConvertFrom-FFmpegProgressLine closure fix used below).
Import-Module "$PSScriptRoot/VideoProcessing.psm1"
Import-Module "$PSScriptRoot/ToolPaths.psm1"

function Split-VideoAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $videoProps = Get-VideoProperties -inputFile $InputFile
    $totalSeconds = if ($videoProps) { $videoProps.Duration.TotalSeconds } else { 0 }
    $cleanTimestamp = $Timestamp -replace ':', '-'
    $trimSeconds = [timespan]::Parse($Timestamp).TotalSeconds
    $targetSeconds = if ($Mode -eq "After") { $trimSeconds } elseif ($totalSeconds -gt 0) { $totalSeconds - $trimSeconds } else { 0 }

    $argList = @()
    if ($Mode -eq "Before") {
        $outputFile = Get-JobOutputPath -InputFile $InputFile -Suffix "Trimmed-From-$cleanTimestamp"
        $argList += "-ss", $Timestamp, "-i", "`"$InputFile`"", "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
    } else {
        $outputFile = Get-JobOutputPath -InputFile $InputFile -Suffix "Trimmed-Until-$cleanTimestamp"
        $argList += "-i", "`"$InputFile`"", "-to", $Timestamp, "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
    }

    $panel = $Context.Panels.Trim
    $progressBar = $panel.FindName("ProgressBarTrim")
    $percentText = $panel.FindName("TextTrimPercent")
    $etaText = $panel.FindName("TextTrimEta")
    $cancelButton = $panel.FindName("ButtonTrimCancel")
    # Disabled for the duration of the run -- see Compress-VideoAsync: without this a
    # second click starts a parallel job sharing this panel's output and progress bar.
    $startButton = $panel.FindName("ButtonTrimStart")
    # Locked alongside it -- see Compress-VideoAsync. AllowDrop must be cleared too:
    # IsEnabled=False stops clicks but a drop still raises Drop on a disabled Button.
    $dropzone = $panel.FindName("ButtonTrimBrowse")
    $dropCaption = $panel.FindName("TextTrimDropCaption")
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
            $progress = & $convertProgressLine -Line $line -TotalSeconds $targetSeconds -ElapsedSeconds $elapsed
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
            if ($dropzone) { $dropzone.IsEnabled = $true; $dropzone.AllowDrop = $true }
            if ($dropCaption) { $dropCaption.Text = "Drag and drop your video here" }
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%"; $etaText.Text = "00:00:00" }
        }.GetNewClosure()

    if ($startButton) { $startButton.IsEnabled = $false }
    if ($dropzone) { $dropzone.IsEnabled = $false; $dropzone.AllowDrop = $false }
    if ($dropCaption) { $dropCaption.Text = "Trimming... cancel to pick a different video" }
    $cancelButton.IsEnabled = $true
    Set-CancelButtonTarget -Button $cancelButton -Process $process
    return $process
}

Export-ModuleMember -Function Split-VideoAsync