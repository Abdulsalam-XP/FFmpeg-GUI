# Function Definitions
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

    $host.UI.RawUI.BackgroundColor = "Black"
    $host.UI.RawUI.ForegroundColor = "Cyan"
    Clear-Host

    for ($i = 0; $i -lt $bannerLines.Length; $i++) {
        $line = $bannerLines[$i]
        
        for ($j = 0; $j -lt 60 -and $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Blue"
            Start-Sleep -Milliseconds 0.5
        }
        
        for ($j = 60; $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Yellow"
            Start-Sleep -Milliseconds 0.5
        }
        
        Write-Host ""
    }
}

function Show-RotatingFFmpegLogo {
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

    $colors = @("Yellow", "Cyan", "Green", "Red", "Blue", "Magenta")
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
}

function Show-Menu {
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                       SELECT AN OPTION                         |" -ForegroundColor Yellow
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "|  [1] Analyze Video & Compress                                  |" -ForegroundColor White
    Write-Host "|  [2] Extract & Merge Audio Streams                             |" -ForegroundColor White
    Write-Host "|  [B] Go Back                                                   |" -ForegroundColor White
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
}

function Write-AnimatedLine {
    param (
        [string]$text,
        [string]$color = "White",
        [int]$delayMs = 3
    )
    
    Write-Host -NoNewline "  "
    foreach ($char in $text.ToCharArray()) {
        Write-Host -NoNewline $char -ForegroundColor $color
        Start-Sleep -Milliseconds $delayMs
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
            # Write each Processing... line on a new line
            Write-Host "Processing..." -ForegroundColor Cyan
            Start-Sleep -Milliseconds 200
            # Remove the overwriting line
            # Write-Host "`r           " -NoNewline
            Start-Sleep -Milliseconds 200
        }
    }
    catch {
        # Fallback if any errors occur
        Write-Host "`n$message`n" -ForegroundColor Yellow
    }
}

function Show-ProgressBar {
    param (
        [int]$PercentComplete,
        [string]$Status
    )
    
    $progressBarWidth = 50
    $completedWidth = [math]::Floor($progressBarWidth * $PercentComplete / 100)
    $remainingWidth = $progressBarWidth - $completedWidth
    
    Write-Host "`r[" -NoNewline
    
    # Gradient effect - Red to Yellow to Green
    for ($i = 0; $i -lt $completedWidth; $i++) {
        # Calculate color based on position in the progress bar
        if ($i -lt ($progressBarWidth * 0.33)) {
            # First third - Red
            Write-Host "#" -NoNewline -ForegroundColor Red
        } 
        elseif ($i -lt ($progressBarWidth * 0.66)) {
            # Middle third - Yellow
            Write-Host "#" -NoNewline -ForegroundColor Yellow
        } 
        else {
            # Last third - Green
            Write-Host "#" -NoNewline -ForegroundColor Green
        }
    }
    
    # Remaining progress bar (empty part)
    Write-Host ("-" * $remainingWidth) -NoNewline -ForegroundColor DarkGray
    
    Write-Host "] $PercentComplete% Complete: $Status                     " -NoNewline -ForegroundColor White
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

function Get-VideoProperties {
    param (
        [Parameter(Mandatory=$true)]
        [string]$inputFile
    )
    
    try {
        # Check if file exists
        if (-not (Test-Path $inputFile)) {
            throw "Input file does not exist: $inputFile"
        }

        # Get file size in GB
        $fileSize = (Get-Item $inputFile).Length / 1GB

        # Use ffprobe to get video properties
        $videoInfo = & ffprobe -v quiet -print_format json -show_format -show_streams $inputFile 2>&1 | ConvertFrom-Json

        # Find video stream
        $videoStream = $videoInfo.streams | Where-Object { $_.'codec_type' -eq 'video' } | Select-Object -First 1

        if (-not $videoStream) {
            throw "No video stream found in file"
        }

        # Extract properties
        $properties = @{
            Resolution = "$($videoStream.width)x$($videoStream.height)"
            Codec = $videoStream.codec_name
            Bitrate = if ($videoStream.bit_rate) { [math]::Round($videoStream.bit_rate / 1000) } else { "N/A" }
            Duration = [timespan]::FromSeconds($videoInfo.format.duration)
            FrameRate = if ($videoStream.r_frame_rate) { 
                $fps = $videoStream.r_frame_rate.Split('/')
                [math]::Round(([decimal]$fps[0] / [decimal]$fps[1]), 2)
            } else { "N/A" }
            FileSize = [math]::Round($fileSize, 2)
        }

        return $properties
    }
    catch {
        Write-Host "Error analyzing video: $_" -ForegroundColor Red
        return $null
    }
}

function Get-SystemSpecs {
    try {
        $cpuInfo = Get-WmiObject Win32_Processor | Select-Object -First 1
        $gpuInfo = Get-WmiObject Win32_VideoController | Select-Object -First 1
        $ramInfo = Get-WmiObject Win32_ComputerSystem

        # Safely get GPU memory, defaulting to "Unknown" if not available
        $gpuMemory = "Unknown"
        if ($gpuInfo.AdapterRAM) {
            try {
                $gpuMemory = [math]::Round([decimal]$gpuInfo.AdapterRAM/1GB, 2)
            } catch {
                $gpuMemory = "Unknown"
            }
        }

        return @{
            CPU = @{
                Name = if ($cpuInfo.Name) { $cpuInfo.Name } else { "Unknown" }
                Cores = if ($cpuInfo.NumberOfCores) { $cpuInfo.NumberOfCores } else { 4 }  # Default to 4 cores if unknown
                Speed = if ($cpuInfo.MaxClockSpeed) { $cpuInfo.MaxClockSpeed } else { 2000 }  # Default to 2GHz if unknown
            }
            GPU = @{
                Name = if ($gpuInfo.Name) { $gpuInfo.Name } else { "Unknown" }
                Memory = $gpuMemory
            }
            RAM = @{
                Total = if ($ramInfo.TotalPhysicalMemory) { 
                    [math]::Round($ramInfo.TotalPhysicalMemory/1GB, 2)
                } else { 
                    8  # Default to 8GB if unknown
                }
            }
        }
    }
    catch {
        Write-Host "Error getting system specifications: $_" -ForegroundColor Red
        # Return default values if we can't get system specs
        return @{
            CPU = @{
                Name = "Unknown CPU"
                Cores = 4  # Conservative default
                Speed = 2000  # Conservative default (2GHz)
            }
            GPU = @{
                Name = "Unknown GPU"
                Memory = "Unknown"
            }
            RAM = @{
                Total = 8  # Conservative default (8GB)
            }
        }
    }
}

function Get-CompressionSuggestions {
    param (
        [Parameter(Mandatory=$true)]
        [string]$inputFile
    )
    
    try {
        # Get video properties
        $videoProps = Get-VideoProperties $inputFile
        if (-not $videoProps) { throw "Failed to analyze video" }

        # Get system specifications
        $systemSpecs = Get-SystemSpecs
        if (-not $systemSpecs) { throw "Failed to get system specifications" }

        # Define compression presets
        $presets = @{
            "High Quality" = @{
                Codec = "libx264"
                CRF = "18"
                Preset = "slow"
            }
            "Balanced" = @{
                Codec = "libx264"
                CRF = "23"
                Preset = "slow"
            }
            "Small Size" = @{
                Codec = "libx264"
                CRF = "28"
                Preset = "fast"
            }
        }

        # Display results with animation
        Write-Host "`nVideo Analysis" -ForegroundColor Cyan
        Write-Host "-------------" -ForegroundColor Cyan
        Start-Sleep -Milliseconds 25

        # Video Properties
        Write-AnimatedLine "Resolution: $($videoProps.Resolution)" "White" 2
        Write-AnimatedLine "Bitrate: $($videoProps.Bitrate) kbps" "White" 2
        Write-AnimatedLine "Duration: $($videoProps.Duration)" "White" 2
        Write-AnimatedLine "Size: $($videoProps.FileSize) GB" "White" 2
        Start-Sleep -Milliseconds 25

        Write-Host "`nCompression Options" -ForegroundColor Yellow
        Write-Host "-----------------" -ForegroundColor Yellow
        Start-Sleep -Milliseconds 25

        Write-Host "`n[1] High Quality" -ForegroundColor Green
        Write-AnimatedLine "- CRF: $($presets['High Quality'].CRF) (Lower = Better)" "Gray" 2
        Write-AnimatedLine "- Preset: $($presets['High Quality'].Preset)" "Gray" 2
        Start-Sleep -Milliseconds 15

        Write-Host "`n[2] Balanced (Recommended for most users)" -ForegroundColor Green
        Write-AnimatedLine "- CRF: $($presets['Balanced'].CRF) (Lower = Better)" "Gray" 2
        Write-AnimatedLine "- Preset: $($presets['Balanced'].Preset)" "Gray" 2
        Start-Sleep -Milliseconds 15

        Write-Host "`n[3] Small Size" -ForegroundColor Green
        Write-AnimatedLine "- CRF: $($presets['Small Size'].CRF) (Lower = Better)" "Gray" 2
        Write-AnimatedLine "- Preset: $($presets['Small Size'].Preset)" "Gray" 2
        Start-Sleep -Milliseconds 15

        Write-Host "`n[B] Go Back" -ForegroundColor White

    }
    catch {
        Write-Host "Error generating compression suggestions: $_" -ForegroundColor Red
    }
}

function Compress-Video {
    param (
        [Parameter(Mandatory=$true)]
        [string]$inputFile,
        [Parameter(Mandatory=$true)]
        [string]$preset
    )
    
    try {
        # Get video properties for the input file
        $videoProps = Get-VideoProperties $inputFile
        if (-not $videoProps) { throw "Failed to analyze video" }

        # Define compression presets
        $presets = @{
            "High Quality" = @{
                Codec = "libx264"
                CRF = "18"
                Preset = "slow"
            }
            "Balanced" = @{
                Codec = "libx264"
                CRF = "23"
                Preset = "slow"  # Changed from medium to slow
                MapAll = $true   # Added flag to use -map 0
                CopyAudio = $true # Added flag to use -c:a copy
            }
            "Small Size" = @{
                Codec = "libx264"
                CRF = "28"
                Preset = "fast"
            }
        }

        if (-not $presets.ContainsKey($preset)) {
            throw "Invalid preset selected: $preset"
        }

        $selectedPreset = $presets[$preset]
        
        # Create output filename
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
        $outputFile = "$baseName-$($preset.ToLower().Replace(' ', '-')).mp4"

        Write-Host "`nStarting video compression with $preset preset" -ForegroundColor Cyan
        Write-Host "-------------------------------------------" -ForegroundColor Cyan
        
        # Show compression settings
        Write-Host "`nCompression Settings:" -ForegroundColor Yellow
        Write-Host "  - Codec: H.264 (Standard Compatible)"
        Write-Host "  - CRF Value: $($selectedPreset.CRF) (Lower = Better Quality)"
        Write-Host "  - Preset: $($selectedPreset.Preset)`n"

        # Show progress animation
        Show-FilmStripBorder -message "COMPRESSING VIDEO" -frameCount 30

        # Build the ffmpeg command based on preset settings
        $ffmpegArgs = @(
            "-i", $inputFile
        )
        
        # Add -map 0 if specified in preset
        if ($selectedPreset.MapAll) {
            $ffmpegArgs += "-map", "0"
        }
        
        $ffmpegArgs += @(
            "-c:v", $selectedPreset.Codec,
            "-crf", $selectedPreset.CRF,
            "-preset", $selectedPreset.Preset
        )
        
        # Handle audio codec based on preset
        if ($selectedPreset.CopyAudio) {
            $ffmpegArgs += "-c:a", "copy"
        } else {
            # Default audio settings for other presets
            $ffmpegArgs += @(
                "-c:a", "aac",
                "-b:a", "128k"
            )
        }
        
        $ffmpegArgs += $outputFile
        
        # Run ffmpeg with constructed arguments
        & $ffmpeg $ffmpegArgs

        # Get file sizes and calculate savings
        $originalSize = (Get-Item $inputFile).Length / 1MB
        $compressedSize = (Get-Item $outputFile).Length / 1MB
        $savingsPercent = [math]::Round(100 - ($compressedSize / $originalSize * 100), 1)

        # Show completion animation
        Show-CompletionAnimation

        # Display results
        Write-Host "`nCompression Results:" -ForegroundColor Green
        Write-Host "-------------------" -ForegroundColor Green
        Write-Host "Original Size: $([math]::Round($originalSize, 2)) MB"
        Write-Host "Compressed Size: $([math]::Round($compressedSize, 2)) MB"
        Write-Host "Space Saved: $savingsPercent%"
        Write-Host "`nOutput File: $outputFile"
        Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
        exit
    }
    catch {
        Write-Host "Error during compression: $_" -ForegroundColor Red
        Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
        exit 1
    }
}

function Merge-AudioStreams {
    param (
        [Parameter(Mandatory=$true)]
        [string]$inputVideo
    )
    
    try {
        # Get video info to check available audio streams
        $videoInfo = & ffprobe -v quiet -print_format json -show_streams -select_streams a $inputVideo 2>&1 | ConvertFrom-Json
        $audioStreams = $videoInfo.streams
        
        if ($audioStreams.Count -lt 2) {
            Write-Host "`nError: This video has less than 2 audio streams to merge." -ForegroundColor Red
            Write-Host "Number of audio streams found: $($audioStreams.Count)" -ForegroundColor Yellow
            return $false
        }

        # Display info about found streams
        Write-Host "`nFound $($audioStreams.Count) audio streams to merge:" -ForegroundColor Cyan
        Write-Host "--------------------------------" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $audioStreams.Count; $i++) {
            $stream = $audioStreams[$i]
            $language = if ($stream.tags.language) { $stream.tags.language } else { "undefined" }
            $title = if ($stream.tags.title) { $stream.tags.title } else { "No title" }
            Write-Host "Stream #$i - Language: $language - Title: $title" -ForegroundColor White
        }

        # Create output filename
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputVideo)
        $outputFile = "$baseName-merged-audio.mp4"

        Write-Host "`nMerging all audio streams..." -ForegroundColor Cyan
        Show-AnimatedIcon -iconType "audio" -message "Merging audio streams..." -duration 0.8

        # Build the filter complex string for all streams
        $filterComplex = ""
        for ($i = 0; $i -lt $audioStreams.Count; $i++) {
            $filterComplex += "[0:a:$i]"
        }
        $filterComplex += "amix=inputs=$($audioStreams.Count):duration=longest[aout]"

        # Merge all audio streams using ffmpeg
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
            exit
        } else {
            Write-Host "`nError occurred while merging audio streams." -ForegroundColor Red
            Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
            [void][System.Console]::ReadKey($true)
            exit 1
        }
    }
    catch {
        Write-Host "Error during audio merge: $_" -ForegroundColor Red
        Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
        exit 1
    }
}

# Set ffmpeg path (if ffmpeg is in PATH, just use "ffmpeg")
$ffmpeg = "ffmpeg"

# Main script execution
Show-AsciiBanner
Write-Host ""
Write-Host ""
Show-RotatingFFmpegLogo
Show-Banner

do {
    # Get the current directory
    $currentDir = Get-Location
    $videoFiles = Get-ChildItem -Path $currentDir -Filter *.mp4 | Sort-Object Name

    if ($videoFiles.Count -eq 0) {
        Write-Host "No .mp4 files found in the current directory: $currentDir" -ForegroundColor Red
        Write-Host "Please make sure you have .mp4 files in this directory and try again." -ForegroundColor Yellow
        Write-Host "`nPress any key to exit..."
        [void][System.Console]::ReadKey($true)
        exit 1
    }

    Write-Host "Available .mp4 files in $currentDir :" -ForegroundColor Yellow
    Write-Host ""

    for ($i = 0; $i -lt $videoFiles.Count; $i++) {
        $size = [math]::Round($videoFiles[$i].Length / 1MB, 2)
        Write-Host "[$($i + 1)] $($videoFiles[$i].Name) ($size MB)"
    }

    Write-Host "`n[B] Exit Program" -ForegroundColor White
    Write-Host ""
    
    $selection = Read-Host "Enter the number of the video file to use (or B to exit)"
    
    if ($selection -eq "B" -or $selection -eq "b") {
        Write-Host "`nTerminating..." -ForegroundColor Yellow
        Start-Sleep -Milliseconds 800
        exit
    }

    $valid = ($selection -as [int]) -and ($selection -ge 1) -and ($selection -le $videoFiles.Count)
    if (-not $valid) {
        Write-Host "Invalid selection. Please enter a number between 1 and $($videoFiles.Count)." -ForegroundColor Red
        continue
    }

    Write-Host ""
    $selectedFile = $videoFiles[$selection - 1]
    $inputVideo = $selectedFile.FullName
    Write-Host "You selected: $($selectedFile.Name)" -ForegroundColor Green

    Write-Host ""
    Write-Host "File Information:" -ForegroundColor Green
    Write-Host "   * Name: $($selectedFile.Name)" -ForegroundColor White
    Write-Host "   * Size: $([math]::Round($selectedFile.Length / 1MB, 2)) MB" -ForegroundColor White
    Write-Host "   * Created: $($selectedFile.CreationTime)" -ForegroundColor White
    Write-Host "   * Full Path: $inputVideo" -ForegroundColor White
    Write-Host ""

    $processingComplete = $false
    while (-not $processingComplete) {
        Show-Menu
        $choice = Read-Host "`nEnter your choice (1-2, or B to go back to file selection)"

        switch ($choice.ToUpper()) {
            "1" {
                Write-Host ""
                Show-AnimatedIcon -iconType "compress" -message "Analyzing..." -duration 0.8
                Write-Host ""
                
                if (Test-Path $inputVideo) {
                    Get-CompressionSuggestions -inputFile $inputVideo
                    
                    $compressionChoice = Read-Host "`nSelect compression option (1-3, or B to go back)"
                    
                    $preset = switch ($compressionChoice.ToUpper()) {
                        "1" { "High Quality" }
                        "2" { "Balanced" }
                        "3" { "Small Size" }
                        "B" { 
                            Write-Host "`nReturning to menu..." -ForegroundColor Yellow
                            $null 
                        }
                        default { 
                            Write-Host "`nInvalid choice. Returning to menu..." -ForegroundColor Red
                            Start-Sleep -Seconds 1
                            $null 
                        }
                    }
                    
                    if ($preset) {
                        Compress-Video -inputFile $inputVideo -preset $preset
                        $processingComplete = $true
                    }
                } else {
                    Write-Host "Error: Selected video file no longer exists: $inputVideo" -ForegroundColor Red
                    $processingComplete = $true
                }
            }
            "2" {
                Write-Host "`nAudio Stream Merger" -ForegroundColor Cyan
                Write-Host "----------------" -ForegroundColor Cyan
                Write-Host "This will automatically merge all audio streams from the video into a single mixed audio track."
                Write-Host "The video quality will not be affected as it will be copied without re-encoding."
                
                if (Test-Path $inputVideo) {
                    Merge-AudioStreams -inputVideo $inputVideo
                    $processingComplete = $true
                } else {
                    Write-Host "Error: Selected video file no longer exists: $inputVideo" -ForegroundColor Red
                    $processingComplete = $true
                }
            }
            "B" {
                $processingComplete = $true
            }
            default {
                Write-Host "Invalid choice. Please try again." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
} while ($true)
