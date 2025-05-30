# Script Version
$scriptVersion = "1.0.1"
$repoOwner = "Abdulsalam-XP"
$repoName = "FFmpeg-GUI"
$scriptName = "Video-Audio-Tool.ps1"

function Check-ForUpdates {
    try {
        # Get the latest version from GitHub
        $apiUrl = "https://api.github.com/repos/$repoOwner/$repoName/contents/$scriptName"
        $response = Invoke-RestMethod -Uri $apiUrl -Headers @{
            "Accept" = "application/vnd.github.v3.raw"
        }

        # Extract version from the downloaded content
        if ($response -match '# Script Version\s*\$scriptVersion = "([\d\.]+)"') {
            $latestVersion = $matches[1]
            
            if ([version]$latestVersion -gt [version]$scriptVersion) {
                # Get commit history to show changes
                $commitsUrl = "https://api.github.com/repos/$repoOwner/$repoName/commits?path=$scriptName"
                $commits = Invoke-RestMethod -Uri $commitsUrl -Headers @{
                    "Accept" = "application/vnd.github.v3+json"
                }

                # Create a Windows Forms popup
                Add-Type -AssemblyName System.Windows.Forms
                $form = New-Object System.Windows.Forms.Form
                $form.Text = "Update Available!"
                $form.Size = New-Object System.Drawing.Size(600,400)
                $form.StartPosition = "CenterScreen"
                $form.BackColor = [System.Drawing.Color]::White

                # Create rich text box for changes
                $textBox = New-Object System.Windows.Forms.RichTextBox
                $textBox.Location = New-Object System.Drawing.Point(10,10)
                $textBox.Size = New-Object System.Drawing.Size(560,300)
                $textBox.ReadOnly = $true
                $textBox.BackColor = [System.Drawing.Color]::White
                $textBox.Font = New-Object System.Drawing.Font("Consolas", 10)

                # Add version info
                $textBox.AppendText("New version $latestVersion is available!`n")
                $textBox.AppendText("Current version: $scriptVersion`n`n")
                $textBox.AppendText("Recent Changes:`n")
                $textBox.AppendText("----------------`n")

                # Add commit messages
                foreach ($commit in $commits) {
                    $textBox.AppendText("• $($commit.commit.message)`n")
                }

                # Create buttons
                $updateButton = New-Object System.Windows.Forms.Button
                $updateButton.Location = New-Object System.Drawing.Point(400,320)
                $updateButton.Size = New-Object System.Drawing.Size(80,30)
                $updateButton.Text = "Update"
                $updateButton.DialogResult = [System.Windows.Forms.DialogResult]::Yes

                $cancelButton = New-Object System.Windows.Forms.Button
                $cancelButton.Location = New-Object System.Drawing.Point(490,320)
                $cancelButton.Size = New-Object System.Drawing.Size(80,30)
                $cancelButton.Text = "Cancel"
                $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::No

                # Add controls to form
                $form.Controls.Add($textBox)
                $form.Controls.Add($updateButton)
                $form.Controls.Add($cancelButton)

                # Show the form
                $result = $form.ShowDialog()

                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Write-Host "`nDownloading update..." -ForegroundColor Cyan
                    
                    # Backup current script
                    $backupPath = "$PSScriptRoot\$scriptName.backup"
                    Copy-Item -Path $PSCommandPath -Destination $backupPath -Force
                    
                    # Download and save the new version
                    $response | Out-File -FilePath $PSCommandPath -Force
                    
                    Write-Host "Update successful! The script will now restart.`n" -ForegroundColor Green
                    Start-Sleep -Seconds 2
                    
                    # Start the new version and exit the current one
                    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
                    Stop-Process $PID
                }
            }
        }
    }
    catch {
        Write-Host "Unable to check for updates. Continuing with current version..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
}

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
    Write-Host "|                       SELECT AN OPTION                         |" -ForegroundColor Yellow
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "|  [1] Analyze Video & Compress                                  |" -ForegroundColor White
    Write-Host "|  [2] Extract & Merge Audio Streams                             |" -ForegroundColor White
    Write-Host "|  [3] Download YouTube MP3                                      |" -ForegroundColor White
    Write-Host "|  [4] Download YouTube MP4                                      |" -ForegroundColor White
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
        if (-not (Test-Path -LiteralPath $inputFile)) {
            throw "Input file does not exist: $inputFile"
        }

        Write-Host "Analyzing video file..." -ForegroundColor Cyan
        
        # Use -v error to only show errors, and redirect stderr to stdout
        $ffprobeCmd = "ffprobe -v error -print_format json -show_format -show_streams `"$inputFile`" 2>&1"
        Write-Host "Running command: $ffprobeCmd" -ForegroundColor Gray
        
        $videoInfoJson = & ffprobe -v error -print_format json -show_format -show_streams "$inputFile" 2>&1
        
        if (-not $videoInfoJson) {
            throw "ffprobe returned no output"
        }
        
        Write-Host "Raw ffprobe output:" -ForegroundColor Gray
        Write-Host $videoInfoJson -ForegroundColor Gray
        
        $videoInfo = $videoInfoJson | ConvertFrom-Json
        
        if (-not $videoInfo) {
            throw "Failed to parse ffprobe JSON output"
        }

        # Find video stream
        $videoStream = $videoInfo.streams | Where-Object { $_.'codec_type' -eq 'video' } | Select-Object -First 1

        if (-not $videoStream) {
            Write-Host "Available streams:" -ForegroundColor Yellow
            $videoInfo.streams | ForEach-Object {
                Write-Host "Stream type: $($_.codec_type), codec: $($_.codec_name)" -ForegroundColor Yellow
            }
            throw "No video stream found in file. Please ensure this is a valid video file."
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
            FileSize = [math]::Round((Get-Item -LiteralPath $inputFile).Length / 1GB, 2)
        }

        return $properties
    }
    catch {
        Write-Host "Error analyzing video: $_" -ForegroundColor Red
        Write-Host "Full error details:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host "Stack trace:" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
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

function Download-YouTubeMP3 {
    Write-Host "`nYouTube MP3 Downloader" -ForegroundColor Cyan
    Write-Host "--------------------" -ForegroundColor Cyan
    Write-Host "This will download and extract audio from YouTube videos in MP3 format."
    Write-Host "Please enter the YouTube URL (or 'B' to go back): " -ForegroundColor Yellow -NoNewline
    
    $url = Read-Host
    
    if ($url.ToUpper() -eq "B") {
        return
    }
    
    try {
        # Create a Downloads directory if it doesn't exist
        $downloadPath = Join-Path (Get-Location) "MP3 Downloads"
        if (-not (Test-Path $downloadPath)) {
            New-Item -ItemType Directory -Path $downloadPath | Out-Null
        }
        
        # Show download animation
        Show-FilmStripBorder -message "DOWNLOADING FROM YOUTUBE" -frameCount 30
        
        # Download and convert to MP3
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

function Download-YouTubeMP4 {
    Write-Host "`nYouTube MP4 Downloader" -ForegroundColor Cyan
    Write-Host "--------------------" -ForegroundColor Cyan
    Write-Host "This will download videos from YouTube in MP4 format."
    Write-Host "Please enter the YouTube URL (or 'B' to go back): " -ForegroundColor Yellow -NoNewline
    
    $url = Read-Host
    
    if ($url.ToUpper() -eq "B") {
        return
    }
    
    try {
        # Get video title first
        Write-Host "`n" -NoNewline
        Show-AnimatedIcon -iconType "loading" -message "Fetching video info..." -duration 0.8
        $videoTitle = & yt-dlp --get-title $url 2>&1
        Write-Host "`nVideo Found: " -NoNewline -ForegroundColor Cyan
        Write-Host "$videoTitle" -ForegroundColor Yellow
        Write-Host ""

        # Create a Downloads directory if it doesn't exist
        $downloadPath = Join-Path (Get-Location) "MP4 Downloads"
        if (-not (Test-Path $downloadPath)) {
            New-Item -ItemType Directory -Path $downloadPath | Out-Null
        }

        # Show loading animation while fetching formats
        Show-AnimatedIcon -iconType "loading" -message "Fetching available video formats..." -duration 1.2
        Write-Host ""

        # Get available formats
        $formats = & yt-dlp -F $url 2>&1 | Out-String
        
        # Define resolutions to check
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

        # Store available resolutions
        $availableResolutions = @()
        foreach ($res in $resolutions) {
            if ($formats -match "$($res.height)p" -or $formats -match "$($res.height)") {
                $availableResolutions += $res
            }
        }

        Write-Host "`nQuality Options" -ForegroundColor Yellow
        Write-Host "---------------" -ForegroundColor Yellow
        Start-Sleep -Milliseconds 200

        # Show only available options
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
            
            # Show download animation
            Show-FilmStripBorder -message "DOWNLOADING FROM YOUTUBE ($($selectedResolution.name))" -frameCount 30
            
            # Download with selected format and include resolution in filename
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

# Set ffmpeg path (if ffmpeg is in PATH, just use "ffmpeg")
$ffmpeg = "ffmpeg"

# Main script execution
Check-ForUpdates
Show-AsciiBanner
Write-Host ""
Write-Host ""
Show-RotatingFFmpegLogo

do {
    Show-Banner
    Write-Host "`nEnter your choice (1-4, or B to exit): " -ForegroundColor Yellow -NoNewline
    $choice = Read-Host

    switch ($choice.ToUpper()) {
        "1" {
            # Get the current directory and list MP4 files
            $currentDir = Get-Location
            $videoFiles = Get-ChildItem -Path $currentDir -Filter *.mp4 | Sort-Object Name

            if ($videoFiles.Count -eq 0) {
                Write-Host "`nNo .mp4 files found in the current directory: $currentDir" -ForegroundColor Red
                Write-Host "Please make sure you have .mp4 files in this directory and try again." -ForegroundColor Yellow
                Write-Host "`nPress any key to continue..."
                [void][System.Console]::ReadKey($true)
                continue
            }

            Write-Host "`nAvailable .mp4 files in $currentDir :" -ForegroundColor Yellow
            Write-Host ""

            for ($i = 0; $i -lt $videoFiles.Count; $i++) {
                $size = [math]::Round($videoFiles[$i].Length / 1MB, 2)
                Write-Host "[$($i + 1)] $($videoFiles[$i].Name) ($size MB)"
            }

            Write-Host "`n[B] Go Back" -ForegroundColor White
            Write-Host ""
            
            Write-Host "Enter the number of the video file to use (or B to go back): " -ForegroundColor Yellow -NoNewline
            $selection = Read-Host
            
            if ($selection -eq "B" -or $selection -eq "b") {
                continue
            }

            $valid = ($selection -as [int]) -and ($selection -ge 1) -and ($selection -le $videoFiles.Count)
            if (-not $valid) {
                Write-Host "Invalid selection. Please enter a number between 1 and $($videoFiles.Count)." -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }

            Write-Host ""
            $selectedFile = $videoFiles[$selection - 1]
            # Use Resolve-Path to get the correct path format
            $inputVideo = $selectedFile.FullName
            # Ensure the path is properly quoted if it contains spaces
            $inputVideo = [System.Management.Automation.WildcardPattern]::Escape($inputVideo)
            
            Write-Host "You selected: $($selectedFile.Name)" -ForegroundColor Cyan

            Write-Host ""
            Write-Host "File Information:" -ForegroundColor Cyan
            Write-Host "   * Name: $($selectedFile.Name)" -ForegroundColor White
            Write-Host "   * Size: $([math]::Round($selectedFile.Length / 1MB, 2)) MB" -ForegroundColor White
            Write-Host "   * Created: $($selectedFile.CreationTime)" -ForegroundColor White
            Write-Host "   * Full Path: $inputVideo" -ForegroundColor White
            Write-Host ""

            Show-AnimatedIcon -iconType "compress" -message "Analyzing..." -duration 0.8
            Write-Host ""
            
            # Use Test-Path with -LiteralPath to handle special characters
            if (Test-Path -LiteralPath $selectedFile.FullName) {
                Get-CompressionSuggestions -inputFile $inputVideo
                
                Write-Host "`nSelect compression option (1-3, or B to go back): " -ForegroundColor Yellow -NoNewline
                $compressionChoice = Read-Host
                
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
                }
            } else {
                Write-Host "Error: Selected video file no longer exists: $inputVideo" -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
        "2" {
            # Get the current directory and list MP4 files
            $currentDir = Get-Location
            $videoFiles = Get-ChildItem -Path $currentDir -Filter *.mp4 | Sort-Object Name

            if ($videoFiles.Count -eq 0) {
                Write-Host "`nNo .mp4 files found in the current directory: $currentDir" -ForegroundColor Red
                Write-Host "Please make sure you have .mp4 files in this directory and try again." -ForegroundColor Yellow
                Write-Host "`nPress any key to continue..."
                [void][System.Console]::ReadKey($true)
                continue
            }

            Write-Host "`nAvailable .mp4 files in $currentDir :" -ForegroundColor Yellow
            Write-Host ""

            for ($i = 0; $i -lt $videoFiles.Count; $i++) {
                $size = [math]::Round($videoFiles[$i].Length / 1MB, 2)
                Write-Host "[$($i + 1)] $($videoFiles[$i].Name) ($size MB)"
            }

            Write-Host "`n[B] Go Back" -ForegroundColor White
            Write-Host ""
            
            Write-Host "Enter the number of the video file to use (or B to go back): " -ForegroundColor Yellow -NoNewline
            $selection = Read-Host
            
            if ($selection -eq "B" -or $selection -eq "b") {
                continue
            }

            $valid = ($selection -as [int]) -and ($selection -ge 1) -and ($selection -le $videoFiles.Count)
            if (-not $valid) {
                Write-Host "Invalid selection. Please enter a number between 1 and $($videoFiles.Count)." -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }

            Write-Host ""
            $selectedFile = $videoFiles[$selection - 1]
            # Use Resolve-Path to get the correct path format
            $inputVideo = $selectedFile.FullName
            # Ensure the path is properly quoted if it contains spaces
            $inputVideo = [System.Management.Automation.WildcardPattern]::Escape($inputVideo)

            Write-Host "`nAudio Stream Merger" -ForegroundColor Cyan
            Write-Host "----------------" -ForegroundColor Cyan
            Write-Host "This will automatically merge all audio streams from the video into a single mixed audio track."
            Write-Host "The video quality will not be affected as it will be copied without re-encoding."
            
            # Use Test-Path with -LiteralPath to handle special characters
            if (Test-Path -LiteralPath $selectedFile.FullName) {
                Merge-AudioStreams -inputVideo $inputVideo
            } else {
                Write-Host "Error: Selected video file no longer exists: $inputVideo" -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
        "3" {
            Download-YouTubeMP3
        }
        "4" {
            Download-YouTubeMP4
        }
        "B" {
            Write-Host "`nTerminating..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 800
            # Get the current PowerShell process and terminate it
            Stop-Process $PID
        }
        default {
            Write-Host "Invalid choice. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($true)


