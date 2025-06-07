function Save-YouTubeMP3 {
    Write-Host "`nYouTube MP3 Downloader" -ForegroundColor Cyan
    Write-Host "--------------------" -ForegroundColor Cyan
    Write-Host "This will download and extract audio from YouTube videos in MP3 format."
    Write-Host "Please enter the YouTube URL (or 'B' to go back): " -ForegroundColor Yellow -NoNewline
    
    $url = Read-Host
    
    if ($url.ToUpper() -eq "B") {
        return
    }
    
    try {
        $downloadPath = Join-Path (Get-Location) "MP3 Downloads"
        if (-not (Test-Path $downloadPath)) {
            New-Item -ItemType Directory -Path $downloadPath | Out-Null
        }
        
        Show-FilmStripBorder -message "DOWNLOADING FROM YOUTUBE" -frameCount 30
        
        & yt-dlp $url --no-playlist -x --audio-format mp3 -P $downloadPath
        
        if ($LASTEXITCODE -eq 0) {
            Show-CompletionAnimation
            Write-Host "`nDownload completed successfully!" -ForegroundColor Green
            Write-Host "Files are saved in: $downloadPath" -ForegroundColor Cyan
        } else {
            throw "yt-dlp exited with error code $LASTEXITCODE"
        }
        
    } catch {
        Write-Host "`nError during download: $_" -ForegroundColor Red
    }
    
    Write-Host "`nPress any key to continue..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
}

function Save-YouTubeMP4 {
    Write-Host "`nYouTube MP4 Downloader" -ForegroundColor Cyan
    Write-Host "--------------------" -ForegroundColor Cyan
    Write-Host "This will download videos from YouTube in MP4 format."
    Write-Host "Please enter the YouTube URL (or 'B' to go back): " -ForegroundColor Yellow -NoNewline
    
    $url = Read-Host
    
    if ($url.ToUpper() -eq "B") {
        return
    }
    
    try {
        Write-Host "`n" -NoNewline
        Show-AnimatedIcon -iconType "loading" -message "Fetching video info..." -duration 0.8
        $videoTitle = & yt-dlp --get-title $url 2>&1
        Write-Host "`nVideo Found: " -NoNewline -ForegroundColor Cyan
        Write-Host "$videoTitle" -ForegroundColor Yellow
        Write-Host ""

        $downloadPath = Join-Path (Get-Location) "MP4 Downloads"
        if (-not (Test-Path $downloadPath)) {
            New-Item -ItemType Directory -Path $downloadPath | Out-Null
        }

        Show-AnimatedIcon -iconType "loading" -message "Fetching available video formats..." -duration 1.2
        Write-Host ""

        $formats = & yt-dlp -F $url 2>&1 | Out-String
        
        $resolutions = @(
            @{height = "4320"; name = "8K"; code = "2160p60"; formatString = "bestvideo[ext=mp4][height<=4320]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "2160"; name = "4K"; code = "2160p"; formatString = "bestvideo[ext=mp4][height<=2160]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "1440"; name = "2K"; code = "1440p"; formatString = "bestvideo[ext=mp4][height<=1440]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "1080"; name = "Full HD"; code = "1080p"; formatString = "bestvideo[ext=mp4][height<=1080]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "720"; name = "HD"; code = "720p"; formatString = "bestvideo[ext=mp4][height<=720]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "480"; name = "SD"; code = "480p"; formatString = "bestvideo[ext=mp4][height<=480]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "360"; name = "Low"; code = "360p"; formatString = "bestvideo[ext=mp4][height<=360]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "240"; name = "Very Low"; code = "240p"; formatString = "bestvideo[ext=mp4][height<=240]+bestaudio[ext=m4a]/best[ext=mp4]/best"},
            @{height = "144"; name = "Lowest"; code = "144p"; formatString = "bestvideo[ext=mp4][height<=144]+bestaudio[ext=m4a]/best[ext=mp4]/best"}
        )

        $availableResolutions = @()
        foreach ($res in $resolutions) {
            if ($formats -match "$($res.height)p" -or $formats -match "$($res.height)") {
                $availableResolutions += $res
            }
        }

        Write-Host "`nQuality Options" -ForegroundColor Yellow
        Write-Host "---------------" -ForegroundColor Yellow
        Start-Sleep -Milliseconds 200

        $optionNumber = 1
        foreach ($res in $availableResolutions) {
            Write-AnimatedLine "$optionNumber. $($res.name) ($($res.height)p)" "Green" 2
            Start-Sleep -Milliseconds 15
            $optionNumber++
        }
        Write-AnimatedLine "B. Go Back" "White" 2
        
        Write-Host "`nEnter your choice: " -ForegroundColor Yellow -NoNewline
        $qualityChoice = Read-Host

        if ($qualityChoice.ToUpper() -eq "B") {
            return
        }

        $choiceNum = 0
        if ([int]::TryParse($qualityChoice, [ref]$choiceNum) -and $choiceNum -ge 1 -and $choiceNum -le $availableResolutions.Count) {
            $selectedResolution = $availableResolutions[$choiceNum - 1]
            
            Show-FilmStripBorder -message "DOWNLOADING FROM YOUTUBE ($($selectedResolution.name))" -frameCount 30
            
            $downloadOutput = & yt-dlp $url --no-playlist -f $selectedResolution.formatString -o "$downloadPath/%(title)s-$($selectedResolution.height)P.%(ext)s" -P $downloadPath 2>&1 | Out-String
            
            if ($LASTEXITCODE -eq 0) {
                if ($downloadOutput -match "has already been downloaded") {
                    Write-Host "`nFile already exists! Skipping download..." -ForegroundColor Yellow
                } else {
                    Show-CompletionAnimation
                    Write-Host "`nDownload completed successfully!" -ForegroundColor Green
                }
                Write-Host "Files are saved in: $downloadPath" -ForegroundColor Cyan
            } else {
                throw "yt-dlp exited with error code $LASTEXITCODE"
            }
        } else {
            Write-Host "`nInvalid choice. Returning to main menu..." -ForegroundColor Red
            Start-Sleep -Seconds 2
            return
        }
        
    } catch {
        Write-Host "`nError during download: $_" -ForegroundColor Red
    }
    
    Write-Host "`nPress any key to continue..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
}

Export-ModuleMember -Function * 