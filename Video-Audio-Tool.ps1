function Show-AsciiBanner {
    $bannerLines = @(
        "########  ########  ##      ## #######  ########  ######        ##      ##  ######   ######  #########   ########  ",
        "##        ##        ###    ### ##    ## ##       ##    ##       ###    ### ##    ## ##    ##    ##     ##         ",
        "##        ##        ####  #### ##    ## ##       ##             ####  #### ##    ## ##          ##     ##       ",
        "########  ########  ## #### ## ####### ########  ##  ####       ## #### ## ######## ##  ####    ##     ##       ",
        "##        ##        ##  ##  ## ##       ##       ##    ##       ##  ##  ## ##    ## ##    ##    ##     ##       ",
        "##        ##        ##      ## ##       ##       ##    ##       ##      ## ##    ## ##    ##    ##     ##         ",
        "##        ##        ##      ## ##       ########  ######        ##      ## ##    ##  ######  #########   ######## "
    )

    # Set console colors and clear screen
    $host.UI.RawUI.BackgroundColor = "Black"
    $host.UI.RawUI.ForegroundColor = "Cyan"
    Clear-Host

    Clear-Host
    for ($i = 0; $i -lt $bannerLines.Length; $i++) {
        $line = $bannerLines[$i]
        
        # Display FFMPEG part in green (was purple)
        for ($j = 0; $j -lt 60 -and $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Blue"
            Start-Sleep -Milliseconds 0.5  # Faster typing effect
        }
        
        # Display MAGIC part in yellow
        for ($j = 60; $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Yellow"
            Start-Sleep -Milliseconds 0.5  # Faster typing effect
        }
        
        Write-Host ""  # New line after each banner line
    }
}


function Show-RotatingFFmpegLogo {
    # Stylized JOYBOY logo using only '#'
    $frames = @(
        @(
            "  #####   #######  ##   ##  #####   #######  ##   ##",
            "    ##    ##   ##   ## ##   ##  ##  ##   ##   ## ## ",
            "    ##    ##   ##    ###    #####   ##   ##    ###  ",
            "##  ##    ##   ##     #     ##  ##  ##   ##     #   ",
            " #####    #######     #     #####   #######     #   "
        ),
        @(
            "  #####   #####    ##   ##  #####   #####    ##   ##",
            "   ##    ##   ##    ## ##   ##  ## ##   ##    ## ## ",
            "   ##    ##   ##     ###    #####  ##   ##     ###  ",
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

    # Color cycle for dynamic animation effect - Make sure Purple/Magenta is last
    $colors = @("Yellow", "Cyan", "Green", "Red", "Blue", "Magenta")

    # Save cursor position to reset each frame at same spot
    $originalCursorPosition = $host.UI.RawUI.CursorPosition

    # Calculate center padding to center the logo
    $consoleWidth = $host.UI.RawUI.WindowSize.Width
    $logoWidth = 54  # Width of the JOYBOY logo
    $padding = [Math]::Max(0, [Math]::Floor(($consoleWidth - $logoWidth) / 2))
    $paddingSpaces = " " * $padding

    for ($i = 0; $i -lt 12; $i++) {
        $frameIndex = $i % $frames.Count
        # Match color to frame transition - one color per frame
        $colorIndex = $frameIndex % $colors.Count
        $frame = $frames[$frameIndex]
        $color = $colors[$colorIndex]

        # Make the last frame purple/magenta regardless of the cycle
        if ($i -eq 11) {
            $color = "Magenta"
        }

        # Move cursor to start position
        $host.UI.RawUI.CursorPosition = $originalCursorPosition

        # Display the ASCII frame in the specified color
        foreach ($line in $frame) {
            Write-Host "$paddingSpaces$line" -ForegroundColor $color
        }

        Start-Sleep -Milliseconds 85
    }

    Write-Host ""
}


function Show-FilmStripBorder {
    param (
        [string]$message,
        [int]$frameCount = 20,
        [int]$width = 60
    )
    
    try {
        # Use a simple non-animated border instead of cursor manipulation
        $topBorder = "+" + ("=O=" * [math]::Floor($width/3)) + "+"
        $bottomBorder = "+" + ("=O=" * [math]::Floor($width/3)) + "+"
        
        # Display the border without animation
        Write-Host $topBorder -ForegroundColor Cyan
        Write-Host "|" -NoNewline -ForegroundColor Cyan
        Write-Host (" " * ([math]::Floor(($width - $message.Length) / 2)) + $message + (" " * [math]::Ceiling(($width - $message.Length) / 2))) -NoNewline -ForegroundColor Yellow
        Write-Host "|" -ForegroundColor Cyan
        Write-Host $bottomBorder -ForegroundColor Cyan
        
        # Simple animation that doesn't use cursor positioning
        for ($i = 0; $i -lt 5; $i++) {
            Write-Host "Processing..." -ForegroundColor Cyan
            Start-Sleep -Milliseconds 200
            Write-Host "`r           " -NoNewline
            Start-Sleep -Milliseconds 200
        }
    }
    catch {
        # Fallback if any errors occur
        Write-Host "`n$message`n" -ForegroundColor Yellow
    }
}

function Show-AnimatedIcon {
    param (
        [string]$iconType,
        [string]$message,
        [int]$duration = 10
    )
    
    try {
        # Icon frames using ASCII characters
        $frames = switch ($iconType) {
            "video" { @("[V]", "(V)", "<V>") }
            "audio" { @("[A]", "(A)", "<A>") }
            "compress" { @("[C]", "(C)", "<C>") }
            default { @("[*]", "(*)", "<*>") }
        }
        
        # Simple animation that doesn't use cursor positioning
        foreach ($frame in $frames) {
            Write-Host "$frame $message" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 200
        }
    }
    catch {
        # Fallback if any errors occur
        Write-Host "$message" -ForegroundColor Yellow
    }
}

# Run the animated banner
Show-AsciiBanner

# Add space between banners
Write-Host ""
Write-Host ""

# Show the rotating FFmpeg logo
Show-RotatingFFmpegLogo

function Show-Banner {
    Write-Host ""
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "|                ADVANCED VIDEO PROCESSING TOOL                   |" -ForegroundColor Yellow
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host ""
}

function Show-ProgressBar {
    param (
        [int]$PercentComplete,
        [string]$Status
    )
    
    $progressBarWidth = 50
    $completedWidth = [math]::Floor($progressBarWidth * $PercentComplete / 100)
    $remainingWidth = $progressBarWidth - $completedWidth
    
    $progressBar = "[" + ("#" * $completedWidth) + ("-" * $remainingWidth) + "]"
    
    Write-Host "`r$progressBar $PercentComplete% Complete: $Status                     " -NoNewline -ForegroundColor Green
}

function Show-CompletionAnimation {
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

function Show-Menu {
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                       SELECT AN OPTION                         |" -ForegroundColor Yellow
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "|  [1] Compress Video (Single Operation)                         |" -ForegroundColor White
    Write-Host "|  [2] Extract & Merge Audio/Video Streams                       |" -ForegroundColor White
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
}

# Set ffmpeg path (if ffmpeg is in PATH, just use "ffmpeg")
$ffmpeg = "ffmpeg"

# Display welcome banner
Show-Banner

# ------------------------------
# Replace manual file input with automatic listing and selection
# ------------------------------

# List .mp4 files and prompt user to select one
$videoFiles = Get-ChildItem -Path . -Filter *.mp4 | Sort-Object Name

if ($videoFiles.Count -eq 0) {
    Write-Host "No .mp4 files found in the current directory!" -ForegroundColor Red
    exit 1
}

Write-Host "Available .mp4 files:" -ForegroundColor Yellow
" "

for ($i = 0; $i -lt $videoFiles.Count; $i++) {
    Write-Host "[$($i + 1)] $($videoFiles[$i].Name)"
}
" "
do {
    $selection = Read-Host "Enter the number of the video file to use"
    $valid = ($selection -as [int]) -and ($selection -ge 1) -and ($selection -le $videoFiles.Count)
    if (-not $valid) {
        Write-Host "Invalid selection. Please enter a number between 1 and $($videoFiles.Count)." -ForegroundColor Red
    }
} while (-not $valid)

""
$inputVideo = $videoFiles[$selection - 1].FullName
Write-Host "`nYou selected: $($videoFiles[$selection - 1].Name)" -ForegroundColor Green

# ------------------------------
# End of new input selection code
# ------------------------------

# Get file info
$fileInfo = Get-Item $inputVideo
Write-Host ""
Write-Host "File Information:" -ForegroundColor Green
Write-Host "   * Name: $($fileInfo.Name)" -ForegroundColor White
Write-Host "   * Size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor White
Write-Host "   * Created: $($fileInfo.CreationTime)" -ForegroundColor White
Write-Host ""

# Display menu and get choice
Show-Menu
Write-Host ""

# Valid choice loop with improved visuals
do {
    $choice = Read-Host "   Enter your choice (1 or 2)"
    if ($choice -ne "1" -and $choice -ne "2") {
        Write-Host "Invalid selection. Please enter 1 or 2." -ForegroundColor Red
    }
} while ($choice -ne "1" -and $choice -ne "2")

# Set option flags
$compressEarly = $false
$keepSeparate = $false

switch ($choice) {
    "1" { 
        $compressEarly = $true 
        Write-Host "`n You selected: Compress Video" -ForegroundColor Green
    }
    "2" { 
        $keepSeparate = $true 
        Write-Host "`n You selected: Extract & Merge Audio/Video" -ForegroundColor Green
    }
}

# Get base name without extension
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputVideo)

# Output file names
$audioFile = "$baseName-audio.mp3"
$videoOnlyFile = "$baseName-video.mp4"
$outputFile = "$baseName-final.mp4"
$compressedOutput = "$baseName-compressed.mp4"

Write-Host "`n Starting conversion process for $inputVideo`n" -ForegroundColor Cyan

# START THE TIMER HERE - right before processing begins
$scriptStartTime = Get-Date

# Display a decorative separator
Write-Host "================================================================" -ForegroundColor DarkCyan

if ($compressEarly) {
    # Compress directly from input video - skip audio/video extraction & merging
    Write-Host "`n [1/1] Compressing video using libx264 (preserving quality)..." -ForegroundColor Yellow
    
    # Show animated icon for compression
    Show-AnimatedIcon -iconType "compress" -message "Preparing compression..." -duration 5
    
    # Show a film strip border with message
    Show-FilmStripBorder -message "COMPRESSING VIDEO" -frameCount 30
    
    # Show a fake progress bar - actual compression doesn't report progress
    for ($i = 1; $i -le 100; $i += 5) {
        Show-ProgressBar -PercentComplete $i -Status "Applying compression"
        Start-Sleep -Milliseconds 50
    }
    
    # Run the actual command
    & $ffmpeg -i $inputVideo -map 0 -c:v libx264 -crf 23 -preset slow -c:a copy $compressedOutput
    
    Write-Host "`n"
    Show-CompletionAnimation
    Write-Host "Compression complete! Compressed file: $compressedOutput`n" -ForegroundColor Green
    
    # Show file size comparison
    $originalSize = (Get-Item $inputVideo).Length / 1MB
    $compressedSize = (Get-Item $compressedOutput).Length / 1MB
    $savingsPercent = [math]::Round(100 - ($compressedSize / $originalSize * 100), 1)
    
    Write-Host "Results:" -ForegroundColor Cyan
    Write-Host "   * Original Size: $([math]::Round($originalSize, 2)) MB" -ForegroundColor White
    Write-Host "   * Compressed Size: $([math]::Round($compressedSize, 2)) MB" -ForegroundColor White
    Write-Host "   * Space Saved: $savingsPercent%" -ForegroundColor Green
} 
else {
    # Step 1: Extract audio and convert to MP3
    Write-Host "`n [1/3] Extracting and converting audio to MP3..." -ForegroundColor Yellow
    
    # Show animated icon for audio extraction
    Show-AnimatedIcon -iconType "audio" -message "Preparing audio extraction..." -duration 5
    
    # Show a film strip border with message
    Show-FilmStripBorder -message "EXTRACTING AUDIO" -frameCount 20
    
    for ($i = 1; $i -le 100; $i += 10) {
        Show-ProgressBar -PercentComplete $i -Status "Extracting audio"
        Start-Sleep -Milliseconds 50
    }
    
    & $ffmpeg -i $inputVideo -vn -acodec libmp3lame -q:a 2 $audioFile
    
    Write-Host "`n"
    Show-CompletionAnimation
    
    # Step 2: Extract video only (remove audio)
    Write-Host "`n [2/3] Extracting video only (no audio)..." -ForegroundColor Yellow
    
    # Show animated icon for video extraction
    Show-AnimatedIcon -iconType "video" -message "Preparing video extraction..." -duration 5
    
    # Show a film strip border with message
    Show-FilmStripBorder -message "EXTRACTING VIDEO" -frameCount 20
    
    for ($i = 1; $i -le 100; $i += 10) {
        Show-ProgressBar -PercentComplete $i -Status "Extracting video"
        Start-Sleep -Milliseconds 50
    }
    
    & $ffmpeg -i $inputVideo -an -c:v copy $videoOnlyFile
    
    Write-Host "`n"
    Show-CompletionAnimation
    
    # Step 3: Merging video with new MP3 audio
    Write-Host "`n [3/3] Merging video and MP3 audio into final file..." -ForegroundColor Yellow
    
    # Show animated icons for both video and audio
    Show-AnimatedIcon -iconType "video" -message "Preparing to merge streams..." -duration 3
    Show-AnimatedIcon -iconType "audio" -message "Preparing to merge streams..." -duration 3
    
    # Show a film strip border with message
    Show-FilmStripBorder -message "MERGING STREAMS" -frameCount 20
    
    for ($i = 1; $i -le 100; $i += 5) {
        Show-ProgressBar -PercentComplete $i -Status "Merging streams"
        Start-Sleep -Milliseconds 50
    }
    
    & $ffmpeg -i $videoOnlyFile -i $audioFile -c:v copy -c:a copy $outputFile
    
    Write-Host "`n"
    Show-CompletionAnimation
    Write-Host "Conversion complete! Output file: $outputFile`n" -ForegroundColor Green
    
    # Final compression prompt (only if early compression not chosen)
    Write-Host "+----------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "|  Would you like to compress the final video to reduce    |" -ForegroundColor Yellow
    Write-Host "|  file size? (yes/no)                                     |" -ForegroundColor Yellow
    Write-Host "+----------------------------------------------------------+" -ForegroundColor Yellow
    $compressChoice = Read-Host "   Enter yes/no"
    
    if ($compressChoice -eq "yes") {
        Write-Host "`n [4/4] Compressing final video using libx264..." -ForegroundColor Yellow
        
        # Show animated icon for compression
        Show-AnimatedIcon -iconType "compress" -message "Preparing compression..." -duration 5
        
        # Show a film strip border with message
        Show-FilmStripBorder -message "COMPRESSING VIDEO" -frameCount 30
        
        for ($i = 1; $i -le 100; $i += 3) {
            Show-ProgressBar -PercentComplete $i -Status "Applying compression"
            Start-Sleep -Milliseconds 50
        }
        
        & $ffmpeg -i $outputFile -vcodec libx264 -crf 23 -preset slow -acodec copy $compressedOutput
        
        Write-Host "`n"
        Show-CompletionAnimation
        Write-Host "Compression complete! Compressed file: $compressedOutput`n" -ForegroundColor Green
        
        # Show file size comparison
        $originalSize = (Get-Item $outputFile).Length / 1MB
        $compressedSize = (Get-Item $compressedOutput).Length / 1MB
        $savingsPercent = [math]::Round(100 - ($compressedSize / $originalSize * 100), 1)
        
        Write-Host "Results:" -ForegroundColor Cyan
        Write-Host "   * Original Size: $([math]::Round($originalSize, 2)) MB" -ForegroundColor White
        Write-Host "   * Compressed Size: $([math]::Round($compressedSize, 2)) MB" -ForegroundColor White
        Write-Host "   * Space Saved: $savingsPercent%" -ForegroundColor Green
    }
}

# End timer and show total time elapsed
$scriptEndTime = Get-Date
$elapsed = $scriptEndTime - $scriptStartTime
Write-Host ""
Write-Host "Total processing time: $($elapsed.Hours)h $($elapsed.Minutes)m $($elapsed.Seconds)s" -ForegroundColor Cyan

# Display framed completion message
Write-Host ""
Write-Host "+----------------------------------------------------------------+" -ForegroundColor Green
Write-Host "|                                                                |" -ForegroundColor Green
Write-Host "|               PROCESS COMPLETED SUCCESSFULLY!                  |" -ForegroundColor White
Write-Host "|                                                                |" -ForegroundColor Green
Write-Host "+----------------------------------------------------------------+" -ForegroundColor Green



Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
[void][System.Console]::ReadKey($true)
