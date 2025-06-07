function Merge-AudioStreams {
    param (
        [Parameter(Mandatory=$true)]
        [string]$inputVideo
    )
    
    try {
        $videoInfo = & ffprobe -v quiet -print_format json -show_streams -select_streams a $inputVideo 2>&1 | ConvertFrom-Json
        $audioStreams = $videoInfo.streams
        
        if ($audioStreams.Count -lt 2) {
            Write-Host "`nError: This video has less than 2 audio streams to merge." -ForegroundColor Red
            Write-Host "Number of audio streams found: $($audioStreams.Count)" -ForegroundColor Yellow
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
        Show-AnimatedIcon -iconType "audio" -message "Merging audio streams..." -duration 0.8

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

        & $ffmpeg -i $inputVideo `
            -filter_complex "$filterComplex" `
            -map 0:v:0 `
            -map "[aout]" `
            -c:v copy `
            -c:a aac `
            -b:a 256k `
            $outputFile

        if ($LASTEXITCODE -eq 0) {
            Write-Host "`nAll audio streams successfully merged!" -ForegroundColor Green
            Write-Host "Output file: $outputFile"
            Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
            [void][System.Console]::ReadKey($true)
            Stop-Process -Name "cmd" -Force
            Stop-Process -Name "powershell" -Force
        } else {
            Write-Host "`nError occurred while merging audio streams." -ForegroundColor Red
            Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
            [void][System.Console]::ReadKey($true)
            Stop-Process -Name "cmd" -Force
            Stop-Process -Name "powershell" -Force
        }
    }
    catch {
        Write-Host "Error during audio merge: $_" -ForegroundColor Red
        Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
        Stop-Process -Name "cmd" -Force
        Stop-Process -Name "powershell" -Force
    }
}

Export-ModuleMember -Function * 