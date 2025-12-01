Import-Module (Join-Path $PSScriptRoot "UI.psm1") -Force

function Save-YouTubeMP3 {
    Write-Host "`nYouTube MP3 Downloader" -ForegroundColor Cyan
    Write-Host "--------------------" -ForegroundColor Cyan
    Write-Host "This will download and extract audio from YouTube videos in MP3 format."
    Write-Host "Please enter the YouTube URL (or 'B' to go back): " -ForegroundColor Yellow -NoNewline

    $url = Read-Host
    if ($url.ToUpper() -eq "B") { return }

    try {
        $downloadPath = Join-Path (Get-Location) "MP3 Downloads"
        if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

        if ($url -notmatch '^https?://') {
            Write-Host "Invalid URL format." -ForegroundColor Red
            return
        }

        $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        $outputTemplate = Join-Path $downloadPath "%(title)s.%(ext)s"

        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = "yt-dlp"
        
        # Template includes total_bytes_estimate for better reliability
        $progressTemplate = "%(progress.downloaded_bytes)s-%(progress.total_bytes)s-%(progress.total_bytes_estimate)s-%(progress.eta)s"
        
        $pInfo.Arguments = "$url --no-playlist --no-warnings --socket-timeout 30 --user-agent `"$ua`" -x --audio-format mp3 -o `"$outputTemplate`" --newline --progress-template ""$progressTemplate"""
        $pInfo.RedirectStandardOutput = $true
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pInfo

        try { [Console]::CursorVisible = $false } catch {}
        $process.Start() | Out-Null

        while ($true) {
            $line = $process.StandardOutput.ReadLine()
            
            if ($null -eq $line) { break } 
            
            if ($line -match "(\d+)-(\d+|NA)-(\d+|NA)-(\d+|NA)") {
                $downloaded = [double]$matches[1]
                $totalExact = $matches[2]
                $totalEst = $matches[3]
                $etaRaw = $matches[4]

                $total = if ($totalExact -ne "NA") { [double]$totalExact } 
                elseif ($totalEst -ne "NA") { [double]$totalEst } 
                else { 0 }

                if ($total -gt 0) {
                    $percent = [math]::Round(($downloaded / $total) * 100, 1)
                    
                    if ($etaRaw -ne "NA") {
                        $eta = [timespan]::FromSeconds([int]$etaRaw)
                        $etaString = $eta.ToString("hh\:mm\:ss")
                    }
                    else {
                        $etaString = "--:--:--"
                    }

                    Update-ProgressBar -Activity "Downloading" -Percent $percent -ETA $etaString -StatusInfo "Audio"
                }
            }
        }
        $process.WaitForExit()
        try { [Console]::CursorVisible = $true } catch {}

        if ($process.ExitCode -eq 0) {
            Show-CompletionAnimation
            Write-Host "`nDownload completed successfully!" -ForegroundColor Green
            Write-Host "Files are saved in: $downloadPath" -ForegroundColor Cyan
        }
        else {
            Write-Host "`nDownload failed with exit code $($process.ExitCode)" -ForegroundColor Red
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
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
    if ($url.ToUpper() -eq "B") { return }
    
    try {
        $downloadPath = Join-Path (Get-Location) "MP4 Downloads"
        if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

        if ($url -notmatch '^https?://') {
            Write-Host "Invalid URL format." -ForegroundColor Red
            return
        }

        Write-Host "`n" -NoNewline
        Show-AnimatedIcon -iconType "loading" -message "Fetching video info..." -duration 0.8
        
        $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        $commonArgs = "--no-playlist --no-warnings --socket-timeout 30 --user-agent `"$ua`""
        
        $videoTitle = & yt-dlp --get-title $url $commonArgs.Split(' ') 2>&1
        Write-Host "`nVideo Found: " -NoNewline -ForegroundColor Cyan
        Write-Host "$videoTitle" -ForegroundColor Yellow
        Write-Host ""

        $formats = & yt-dlp -F $url $commonArgs.Split(' ') 2>&1 | Out-String
        
        $resolutions = @(
            @{height = "4320"; name = "8K"; code = "2160p60"; formatString = "bestvideo[height<=4320]+bestaudio/best[height<=4320]" },
            @{height = "2160"; name = "4K"; code = "2160p"; formatString = "bestvideo[height<=2160]+bestaudio/best[height<=2160]" },
            @{height = "1440"; name = "2K"; code = "1440p"; formatString = "bestvideo[height<=1440]+bestaudio/best[height<=1440]" },
            @{height = "1080"; name = "Full HD"; code = "1080p"; formatString = "best[height<=1080][ext=mp4]/best[ext=mp4]/best" },
            @{height = "720"; name = "HD"; code = "720p"; formatString = "best[height<=720][ext=mp4]/best[ext=mp4]/best" },
            @{height = "480"; name = "SD"; code = "480p"; formatString = "best[height<=480][ext=mp4]/best[ext=mp4]/best" },
            @{height = "360"; name = "Low"; code = "360p"; formatString = "best[height<=360][ext=mp4]/best[ext=mp4]/best" }
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

        if ($qualityChoice.ToUpper() -eq "B") { return }

        $choiceNum = 0
        if ([int]::TryParse($qualityChoice, [ref]$choiceNum) -and $choiceNum -ge 1 -and $choiceNum -le $availableResolutions.Count) {
            $selectedResolution = $availableResolutions[$choiceNum - 1]
            
            $outputTemplate = Join-Path $downloadPath "%(title)s-$($selectedResolution.height)P.%(ext)s"
            
            $pInfo = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName = "yt-dlp"
            
            $progressTemplate = "%(progress.downloaded_bytes)s-%(progress.total_bytes)s-%(progress.total_bytes_estimate)s-%(progress.eta)s"
            
            $pInfo.Arguments = "$url $commonArgs --newline --progress-template ""$progressTemplate"" -f $($selectedResolution.formatString) -o `"$outputTemplate`" --merge-output-format mp4 --postprocessor-args ""Merger: -c:v copy -c:a aac"""
            $pInfo.RedirectStandardOutput = $true
            $pInfo.UseShellExecute = $false
            $pInfo.CreateNoWindow = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $pInfo
            
            try { [Console]::CursorVisible = $false } catch {}
            $process.Start() | Out-Null

            while ($true) {
                $line = $process.StandardOutput.ReadLine()
                
                # FIX: $null is now on the left side
                if ($null -eq $line) { break }
                
                if ($line -match "(\d+)-(\d+|NA)-(\d+|NA)-(\d+|NA)") {
                    $downloaded = [double]$matches[1]
                    $totalExact = $matches[2]
                    $totalEst = $matches[3]
                    $etaRaw = $matches[4]
                    
                    $total = if ($totalExact -ne "NA") { [double]$totalExact } 
                    elseif ($totalEst -ne "NA") { [double]$totalEst } 
                    else { 0 }
                    
                    if ($total -gt 0) {
                        $percent = [math]::Round(($downloaded / $total) * 100, 1)
                        
                        if ($etaRaw -ne "NA") {
                            $eta = [timespan]::FromSeconds([int]$etaRaw)
                            $etaString = $eta.ToString("hh\:mm\:ss")
                        }
                        else {
                            $etaString = "--:--:--"
                        }
                        
                        Update-ProgressBar -Activity "Downloading" -Percent $percent -ETA $etaString -StatusInfo "$($selectedResolution.name)"
                    }
                }
            }
            $process.WaitForExit()
            try { [Console]::CursorVisible = $true } catch {}

            if ($process.ExitCode -eq 0) {
                Show-CompletionAnimation
                Write-Host "`nDownload completed successfully!" -ForegroundColor Green
                Write-Host "Files are saved in: $downloadPath" -ForegroundColor Cyan
            }
            else {
                Write-Host "`nDownload failed with exit code $($process.ExitCode)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "`nInvalid choice." -ForegroundColor Red
            Start-Sleep -Seconds 2
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host "`nError during download: $_" -ForegroundColor Red
    }
    
    Write-Host "`nPress any key to continue..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
}

Export-ModuleMember -Function *