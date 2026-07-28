# No -Force: it would demote the globally imported UI module to a nested one,
# hiding UI functions from the main script and the other modules
Import-Module (Join-Path $PSScriptRoot "UI.psm1")
Import-Module (Join-Path $PSScriptRoot "ToolPaths.psm1")

$ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

function Merge-AudioStreams {
    param (
        [Parameter(Mandatory=$true)]
        [string]$inputVideo
    )
    
    try {
        $durationOutput = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $inputVideo 2>&1
        $totalSeconds = [double]$durationOutput
        
        $videoInfo = & $ffprobe -v quiet -print_format json -show_streams -select_streams a $inputVideo 2>&1 | ConvertFrom-Json
        $audioStreams = $videoInfo.streams
        
        if ($audioStreams.Count -lt 2) {
            Write-Host "`nError: This video has less than 2 audio streams to merge." -ForegroundColor Red
            Write-Host "Number of audio streams found: $($audioStreams.Count)" -ForegroundColor Yellow
            return
        }

        Write-Host "`nFound $($audioStreams.Count) audio streams to merge:" -ForegroundColor Cyan
        Write-Host "--------------------------------" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $audioStreams.Count; $i++) {
            $stream = $audioStreams[$i]
            $language = if ($stream.tags.language) { $stream.tags.language } else { "undefined" }
            $title = if ($stream.tags.title) { $stream.tags.title } else { "No title" }
            Write-Host "Stream #$i - Language: $language - Title: $title" -ForegroundColor White
        }

        Write-Host "`nWould you like to adjust the volume of any audio streams? (Y/N)" -ForegroundColor Yellow
        $adjustVolume = Read-Host

        $systemVolume = 1.0
        $micVolume = 1.0

        if ($adjustVolume.ToUpper() -eq "Y") {
            Write-Host "`nAdjust System Sound Volume:" -ForegroundColor Cyan
            Write-Host "[1] 200% (2.0x)"
            Write-Host "[2] 350% (3.5x)"
            Write-Host "[3] 500% (5.0x)"
            Write-Host "[4] No change"
            Write-Host "Enter your choice (1-4): " -ForegroundColor Yellow -NoNewline
            $systemChoice = Read-Host

            switch ($systemChoice) {
                "1" { $systemVolume = 2.0 }
                "2" { $systemVolume = 3.5 }
                "3" { $systemVolume = 5.0 }
                default { $systemVolume = 1.0 }
            }

            Write-Host "`nAdjust Microphone Volume:" -ForegroundColor Cyan
            Write-Host "[1] 200% (2.0x)"
            Write-Host "[2] 350% (3.5x)"
            Write-Host "[3] 500% (5.0x)"
            Write-Host "[4] No change"
            Write-Host "Enter your choice (1-4): " -ForegroundColor Yellow -NoNewline
            $micChoice = Read-Host

            switch ($micChoice) {
                "1" { $micVolume = 2.0 }
                "2" { $micVolume = 3.5 }
                "3" { $micVolume = 5.0 }
                default { $micVolume = 1.0 }
            }
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputVideo)
        $outputFile = "$baseName-merged-audio.mp4"

        Write-Host "`nMerging all audio streams..." -ForegroundColor Cyan
        
        $filterComplex = ""
        for ($i = 0; $i -lt $audioStreams.Count; $i++) {
            if ($i -eq 0) {
                if ($systemVolume -ne 1.0) {
                    $filterComplex += "[0:a:$i]volume=$systemVolume[a$i];"
                } else {
                    $filterComplex += "[0:a:$i]asetpts=PTS-STARTPTS[a$i];"
                }
            } else {
                if ($micVolume -ne 1.0) {
                    $filterComplex += "[0:a:$i]volume=$micVolume[a$i];"
                } else {
                    $filterComplex += "[0:a:$i]asetpts=PTS-STARTPTS[a$i];"
                }
            }
        }
        
        $mixInputs = ""
        for ($i = 0; $i -lt $audioStreams.Count; $i++) {
            $mixInputs += "[a$i]"
        }
        $filterComplex += "$mixInputs amix=inputs=$($audioStreams.Count):duration=longest:normalize=0[aout]"

        $argList = @(
            "-i", "`"$inputVideo`"",
            "-filter_complex", "`"$filterComplex`"",
            "-map", "0:v:0",
            "-map", "`"[aout]`"",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "256k",
            "`"$outputFile`"",
            "-y"
        )

        $exitCode = Invoke-FFmpegProcess -ArgumentList $argList -Activity "Merging Audio" -StatusInfo "AAC 256k" -TotalSeconds $totalSeconds

        if ($exitCode -eq 0) {
            Show-CompletionAnimation
            Write-Host "`nAll audio streams successfully merged!" -ForegroundColor Green
            Write-Host "Output file: $outputFile"
            Wait-KeyPress
        } else {
            Write-Host "`nError occurred while merging audio streams." -ForegroundColor Red
            Wait-KeyPress
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host "Error during audio merge: $_" -ForegroundColor Red
        Wait-KeyPress
    }
}

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
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%"; $etaText.Text = "00:00:00" }
        }.GetNewClosure()

    $cancelButton.IsEnabled = $true
    $cancelButton.Add_Click({ if (-not $process.HasExited) { $process.Kill() } }.GetNewClosure())
    return $process
}

Export-ModuleMember -Function Merge-AudioStreams, Merge-AudioStreamsAsync