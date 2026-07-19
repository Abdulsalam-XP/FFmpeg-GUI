function Show-AsciiBanner {
    if (-not $global:ShowAnimations) { return }

    $bannerLines = @(
        "########  ########  ##      ## #######  ########  ######        ##      ##  ######   ######  #########   ########  ",
        "##        ##        ###    ### ##    ## ##       ##    ##       ###    ### ##    ## ##    ##    ##     ##         ",
        "##        ##        ####  #### ##    ## ##       ##             ####  #### ##    ## ##          ##     ##       ",
        "########  ########  ## #### ## ####### ########  ##  ####       ## #### ## ######## ##  ####    ##     ##       ",
        "##        ##        ##  ##  ## ##       ##       ##    ##       ##  ##  ## ##    ## ##    ##    ##     ##       ",
        "##        ##        ##      ## ##       ##       ##    ##       ##      ## ##    ## ##    ##    ##     ##         ",
        "##        ##        ##      ## ##       ########  ######        ##      ## ##    ##  ######  #########   ######## "
    )

    $host.UI.RawUI.BackgroundColor = "Black"
    $host.UI.RawUI.ForegroundColor = "Cyan"
    Clear-Host

    for ($i = 0; $i -lt $bannerLines.Length; $i++) {
        $line = $bannerLines[$i]
        
        for ($j = 0; $j -lt 60 -and $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Blue"
        }

        for ($j = 60; $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Yellow"
        }
        
        Write-Host ""
    }
}

function Show-RotatingFFmpegLogo {
    if (-not $global:ShowAnimations) { return }

    $frames = @(
        @(
            "  #####   #######  ##    ##  #####   #######  ##   ##",
            "    ##    ##   ##   ## ##   ##  ##  ##   ##   ## ## ",
            "    ##    ##   ##    ###    #####   ##   ##    ###  ",
            "##  ##    ##   ##     #     ##  ##  ##   ##     #   ",
            " #####    #######     #     #####   #######     #   "
        ),
        @(
            "  #####   #####    ##   ##  #####   #####    ##   ##",
            "   ##    ##   ##    ## ##   ##  ## ##   ##    ## ## ",
            "   ##    ##   ##    ###    #####  ##   ##     ###  ",
            "## ##    ##   ##      #     ##  ## ##   ##      #   ",
            " ###      #####       #     #####   #####       #   "
        ),
        @(
            "  #####   #######  ##   ##  #####   #######  ##   ##",
            "    ##    ##   ##   ## ##   ##  ##  ##   ##   ## ## ",
            "    ##    ##   ##    ###    #####   ##   ##    ###  ",
            "##  ##    ##   ##     #     ##  ##  ##   ##     #   ",
            " #####    #######     #     #####   #######     #   "
        )
    )

    $colors = @("Yellow", "Blue", "Cyan", "Magenta")
    $originalCursorPosition = $host.UI.RawUI.CursorPosition
    $consoleWidth = $host.UI.RawUI.WindowSize.Width
    $logoWidth = 54
    $padding = [Math]::Max(0, [Math]::Floor(($consoleWidth - $logoWidth) / 2))
    $paddingSpaces = " " * $padding

    for ($i = 0; $i -lt 12; $i++) {
        $frameIndex = $i % $frames.Count
        $colorIndex = $frameIndex % $colors.Count
        $frame = $frames[$frameIndex]
        $color = $colors[$colorIndex]

        if ($i -eq 11) {
            $color = "Magenta"
        }

        $host.UI.RawUI.CursorPosition = $originalCursorPosition

        foreach ($line in $frame) {
            Write-Host "$paddingSpaces$line" -ForegroundColor $color
        }

        Start-Sleep -Milliseconds 85
    }

    Write-Host ""
}

function Show-AnimatedIcon {
    param (
        [string]$iconType,
        [string]$message,
        [double]$duration = 0.8
    )
    
    if (-not $global:ShowAnimations) {
        Write-Host "$message" -ForegroundColor Cyan
        return
    }

    try {
        $spinnerFrames = @("⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏")
        $iterations = [math]::Ceiling($duration * 20)
        
        for ($i = 0; $i -lt $iterations; $i++) {
            $frame = $spinnerFrames[$i % $spinnerFrames.Length]
            Write-Host "`r$frame $message" -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 50
        }
        Write-Host "`r" -NoNewline
    }
    catch {
        Write-Host "$message" -ForegroundColor Cyan
    }
}

function Show-Banner {
    Write-Host ""
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "|                ADVANCED VIDEO PROCESSING TOOL                   |" -ForegroundColor Yellow
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                         SELECT AN OPTION                       |" -ForegroundColor Yellow
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "|  [1] Analyze Video & Compress                                  |" -ForegroundColor White
    Write-Host "|  [2] Extract & Merge Audio Streams                             |" -ForegroundColor White
    Write-Host "|  [3] Download YouTube MP3                                      |" -ForegroundColor White
    Write-Host "|  [4] Download YouTube MP4                                      |" -ForegroundColor White
    Write-Host "|  [5] Trim Video                                                |" -ForegroundColor White
    Write-Host "|  [6] Convert File to MP4 (Coming Soon....)                     |" -ForegroundColor DarkGray
    Write-Host "|  [7] Settings                                                  |" -ForegroundColor White
    Write-Host "|  [B] Exit                                                      |" -ForegroundColor White
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
}

function Write-AnimatedLine {
    param (
        [string]$text,
        [string]$color = "White",
        [int]$delayMs = 3
    )
    
    if (-not $global:ShowAnimations) {
        Write-Host "  $text" -ForegroundColor $color
        return
    }

    Write-Host -NoNewline "  "
    foreach ($char in $text.ToCharArray()) {
        Write-Host -NoNewline $char -ForegroundColor $color
        Start-Sleep -Milliseconds $delayMs
    }
    Write-Host ""
}

function Update-ProgressBar {
    param(
        [string]$Activity,   
        [double]$Percent,   
        [string]$ETA = "--:--:--",
        [string]$StatusInfo = "" 
    )

    $width = 30
    $filled = [math]::Round(($Percent / 100) * $width)
    if ($filled -gt $width) { $filled = $width }
    $empty = $width - $filled
    
    $charFilled = "=" 
    $charEmpty  = "-" 

    Write-Host "`r" -NoNewline
    
    Write-Host "$Activity " -NoNewline -ForegroundColor Yellow
    
    Write-Host "[" -NoNewline -ForegroundColor White
    
    if ($filled -gt 0) { Write-Host ($charFilled * $filled) -NoNewline -ForegroundColor Green }
    if ($empty -gt 0)  { Write-Host ($charEmpty * $empty) -NoNewline -ForegroundColor Gray }
    
    Write-Host "] " -NoNewline -ForegroundColor White
    
    $percentStr = "{0,5:N1}" -f $Percent
    Write-Host "$percentStr%" -NoNewline -ForegroundColor Cyan
    
    Write-Host " | ETA: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$ETA   " -NoNewline -ForegroundColor White
    
    if ($StatusInfo) {
        Write-Host "| $StatusInfo" -NoNewline -ForegroundColor DarkGray
    }
    
    Write-Host "    " -NoNewline
}

function Show-CompletionAnimation {
    if (-not $global:ShowAnimations) {
        Write-Host "`r* Completed!               " -ForegroundColor Green
        return
    }

    $frames = "/", "-", "\", "|"
    $colors = "Yellow", "Green", "Cyan", "Magenta"
    
    for ($i = 0; $i -lt 20; $i++) {
        $frame = $frames[$i % $frames.Length]
        $color = $colors[$i % $colors.Length]
        Write-Host "`r$frame Processing... " -NoNewline -ForegroundColor $color
        Start-Sleep -Milliseconds 100
    }
    
    Write-Host "`r* Completed!               " -ForegroundColor Green
}

function Wait-KeyPress {
    param([string]$Message = "Press any key to return to the menu...")

    Write-Host "`n$Message" -ForegroundColor Yellow
    # ReadKey throws when console input is redirected (e.g. automation); fall back to Read-Host
    try { [void][System.Console]::ReadKey($true) } catch { Read-Host | Out-Null }
}

function Select-VideoFile {
    param([string]$Prompt = "Enter the number of the video file to use (or B to go back)")

    $currentDir = Get-Location
    $localFiles = @(Get-ChildItem -Path $currentDir -Filter *.mp4 | Sort-Object Name)

    $downloadsPath = Join-Path $currentDir "MP4 Downloads"
    $downloadFiles = @()
    if (Test-Path -LiteralPath $downloadsPath) {
        $downloadFiles = @(Get-ChildItem -Path $downloadsPath -Filter *.mp4 | Sort-Object Name)
    }

    $videoFiles = $localFiles + $downloadFiles

    if ($videoFiles.Count -eq 0) {
        Write-Host "`nNo .mp4 files found in:" -ForegroundColor Red
        Write-Host "- $currentDir" -ForegroundColor Gray
        if (Test-Path -LiteralPath $downloadsPath) { Write-Host "- $downloadsPath" -ForegroundColor Gray }
        Write-Host "`nPlease make sure you have .mp4 files in these directories and try again." -ForegroundColor Yellow
        Wait-KeyPress -Message "Press any key to continue..."
        return $null
    }

    Write-Host "`nAvailable .mp4 files:" -ForegroundColor Yellow
    Write-Host ""

    for ($i = 0; $i -lt $localFiles.Count; $i++) {
        $size = [math]::Round($localFiles[$i].Length / 1MB, 2)
        Write-Host "[$($i + 1)] $($localFiles[$i].Name) ($size MB)"
    }

    if ($downloadFiles.Count -gt 0) {
        Write-Host "`n==============" -ForegroundColor Cyan
        Write-Host "MP4 Downloads Folder" -ForegroundColor Cyan
        Write-Host "==============`n" -ForegroundColor Cyan

        for ($j = 0; $j -lt $downloadFiles.Count; $j++) {
            $size = [math]::Round($downloadFiles[$j].Length / 1MB, 2)
            Write-Host "[$($localFiles.Count + $j + 1)] $($downloadFiles[$j].Name) ($size MB)"
        }
    }

    Write-Host "`n[B] Go Back" -ForegroundColor White
    Write-Host ""

    Write-Host "$Prompt`: " -ForegroundColor Yellow -NoNewline
    $selection = Read-Host

    if ($selection -eq "B" -or $selection -eq "b") { return $null }

    $selectionNumber = $selection -as [int]
    if ($null -eq $selectionNumber -or $selectionNumber -lt 1 -or $selectionNumber -gt $videoFiles.Count) {
        Write-Host "Invalid selection. Please enter a number between 1 and $($videoFiles.Count)." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return $null
    }

    return $videoFiles[$selectionNumber - 1]
}

function Invoke-FFmpegProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$Activity = "Processing",
        [string]$StatusInfo = "",
        [double]$TotalSeconds = 0
    )

    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = "ffmpeg"
    $pInfo.Arguments = $ArgumentList -join " "
    # Child processes inherit the process cwd, not PowerShell's Set-Location,
    # so relative output paths would otherwise land in the wrong folder
    $pInfo.WorkingDirectory = (Get-Location).Path
    $pInfo.RedirectStandardError = $true
    $pInfo.UseShellExecute = $false
    $pInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pInfo

    try { [Console]::CursorVisible = $false } catch {}
    $startTime = Get-Date
    $process.Start() | Out-Null

    while (-not $process.HasExited) {
        $line = $process.StandardError.ReadLine()

        if ($line -match "time=(\d{2}):(\d{2}):(\d{2}\.\d{2})") {
            $hours, $minutes, $seconds = [int]$matches[1], [int]$matches[2], [double]$matches[3]
            $currentPos = ($hours * 3600) + ($minutes * 60) + $seconds

            if ($TotalSeconds -gt 0) {
                $percent = [math]::Min(100, [math]::Round(($currentPos / $TotalSeconds) * 100, 1))

                $timeElapsed = (Get-Date) - $startTime
                if ($percent -gt 0) {
                    $totalEstimatedSeconds = ($timeElapsed.TotalSeconds / $percent) * 100
                    $remaining = [timespan]::FromSeconds($totalEstimatedSeconds - $timeElapsed.TotalSeconds)
                    $etaString = $remaining.ToString("hh\:mm\:ss")
                } else { $etaString = "--:--:--" }

                Update-ProgressBar -Activity $Activity -Percent $percent -ETA $etaString -StatusInfo $StatusInfo
            }
        }
    }
    $process.WaitForExit()
    try { [Console]::CursorVisible = $true } catch {}

    return $process.ExitCode
}

Export-ModuleMember -Function Show-AsciiBanner, Show-RotatingFFmpegLogo, Show-AnimatedIcon, Show-Banner, Write-AnimatedLine, Update-ProgressBar, Show-CompletionAnimation, Wait-KeyPress, Select-VideoFile, Invoke-FFmpegProcess