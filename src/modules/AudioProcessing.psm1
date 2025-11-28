Import-Module (Join-Path $PSScriptRoot "UI.psm1") -Force

$ffmpeg = "ffmpeg"
$ffprobe = "ffprobe"

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

        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $ffmpeg
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
        $pInfo.Arguments = $argList -join " "
        $pInfo.RedirectStandardError = $true
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pInfo
        
        try { [Console]::CursorVisible = $false } catch {}
        $startTime = Get-Date
        $process.Start() | Out-Null
        
        # --- PROGRESS LOOP ---
        while (-not $process.HasExited) {
            $line = $process.StandardError.ReadLine()
            
            if ($line -match "time=(\d{2}):(\d{2}):(\d{2}\.\d{2})") {
                $hours = [int]$matches[1]
                $minutes = [int]$matches[2]
                $seconds = [double]$matches[3]
                $currentPos = ($hours * 3600) + ($minutes * 60) + $seconds
                
                if ($totalSeconds -gt 0) {
                    $percent = [math]::Min(100, [math]::Round(($currentPos / $totalSeconds) * 100, 1))
                    
                    # Calculate ETA
                    $timeElapsed = (Get-Date) - $startTime
                    if ($percent -gt 0) {
                        $totalEstimatedSeconds = ($timeElapsed.TotalSeconds / $percent) * 100
                        $remaining = [timespan]::FromSeconds($totalEstimatedSeconds - $timeElapsed.TotalSeconds)
                        $etaString = $remaining.ToString("hh\:mm\:ss")
                    } else { $etaString = "--:--:--" }

                    Update-ProgressBar -Activity "Merging Audio" -Percent $percent -ETA $etaString -StatusInfo "AAC 256k"
                }
            }
        }
        $process.WaitForExit()
        try { [Console]::CursorVisible = $true } catch {}

        if ($process.ExitCode -eq 0) {
            Show-CompletionAnimation
            Write-Host "`nAll audio streams successfully merged!" -ForegroundColor Green
            Write-Host "Output file: $outputFile"
            Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
            [void][System.Console]::ReadKey($true)
        } else {
            Write-Host "`nError occurred while merging audio streams." -ForegroundColor Red
            Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
            [void][System.Console]::ReadKey($true)
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host "Error during audio merge: $_" -ForegroundColor Red
        Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
    }
}

Export-ModuleMember -Function *