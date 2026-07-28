Import-Module "$PSScriptRoot/UI.psm1"
# Split-VideoAsync calls Get-VideoProperties (from VideoProcessing.psm1) directly, so this
# module needs its own import of it -- module command resolution only sees what a module
# imports itself, not whatever another module has exported into the global session state
# (the same rule behind the ConvertFrom-FFmpegProgressLine closure fix used below).
Import-Module "$PSScriptRoot/VideoProcessing.psm1"
Import-Module "$PSScriptRoot/ToolPaths.psm1"

function Split-Video {
    param (
        [Parameter(Mandatory = $true)][string]$inputFile,
        [Parameter(Mandatory = $true)][string]$mode,
        [Parameter(Mandatory = $true)][string]$timestamp
    )

    try {
        if (Get-Command "Get-VideoProperties" -ErrorAction SilentlyContinue) {
            $videoProps = Get-VideoProperties -inputFile $inputFile
            if ($videoProps) {
                $totalSeconds = $videoProps.Duration.TotalSeconds
            } else {
                $totalSeconds = 0
            }
        } else {
            $totalSeconds = 0
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
        $cleanTimestamp = $timestamp -replace ':', '-'
        $outputFile = ""

        # ffmpeg reports progress against the OUTPUT duration, which is shorter
        # than the source: up to the timestamp for "After", the remainder for "Before"
        $trimSeconds = [timespan]::Parse($timestamp).TotalSeconds
        $targetSeconds = if ($mode -eq "After") { $trimSeconds }
        elseif ($totalSeconds -gt 0) { $totalSeconds - $trimSeconds }
        else { 0 }

        $argList = @()

        if ($mode -eq "Before") {
            $outputFile = "$baseName-Trimmed-From-$cleanTimestamp.mp4"
            $argList += "-ss", $timestamp, "-i", "`"$inputFile`"", "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"

            Write-Host "`nTrimming video (Removing content before $timestamp)..." -ForegroundColor Cyan
        }
        elseif ($mode -eq "After") {
            $outputFile = "$baseName-Trimmed-Until-$cleanTimestamp.mp4"
            $argList += "-i", "`"$inputFile`"", "-to", $timestamp, "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"

            Write-Host "`nTrimming video (Removing content after $timestamp)..." -ForegroundColor Cyan
        }

        Write-Host "----------------------------------------------------" -ForegroundColor Cyan

        [void](Invoke-FFmpegProcess -ArgumentList $argList -Activity "Processing" -StatusInfo "Mode: Copy (Multi-Track)" -TotalSeconds $targetSeconds)

        if (Test-Path -LiteralPath $outputFile) {
            Show-CompletionAnimation
            Write-Host "`nTrim Complete!" -ForegroundColor Green
            Write-Host "Output File: $outputFile" -ForegroundColor White

            Wait-KeyPress
        } else {
            throw "FFmpeg failed to create the output file. Check timestamp format (HH:MM:SS)."
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host "`nError during trim operation: $($_.Exception.Message)" -ForegroundColor Red
        Wait-KeyPress -Message "Press any key to continue..."
    }
}

function Split-VideoAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $videoProps = Get-VideoProperties -inputFile $InputFile
    $totalSeconds = if ($videoProps) { $videoProps.Duration.TotalSeconds } else { 0 }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $cleanTimestamp = $Timestamp -replace ':', '-'
    $trimSeconds = [timespan]::Parse($Timestamp).TotalSeconds
    $targetSeconds = if ($Mode -eq "After") { $trimSeconds } elseif ($totalSeconds -gt 0) { $totalSeconds - $trimSeconds } else { 0 }

    $argList = @()
    if ($Mode -eq "Before") {
        $outputFile = "$baseName-Trimmed-From-$cleanTimestamp.mp4"
        $argList += "-ss", $Timestamp, "-i", "`"$InputFile`"", "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
    } else {
        $outputFile = "$baseName-Trimmed-Until-$cleanTimestamp.mp4"
        $argList += "-i", "`"$InputFile`"", "-to", $Timestamp, "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
    }

    $panel = $Context.Panels.Trim
    $progressBar = $panel.FindName("ProgressBarTrim")
    $percentText = $panel.FindName("TextTrimPercent")
    $etaText = $panel.FindName("TextTrimEta")
    $cancelButton = $panel.FindName("ButtonTrimCancel")
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
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%"; $etaText.Text = "00:00:00" }
        }.GetNewClosure()

    $cancelButton.IsEnabled = $true
    $cancelButton.Add_Click({ if (-not $process.HasExited) { $process.Kill() } }.GetNewClosure())
    return $process
}

Export-ModuleMember -Function Split-Video, Split-VideoAsync