Import-Module "$PSScriptRoot/UI.psm1"
# Module-level preset definitions (remove duplication)
$script:CompressionPresets = @{
    "High Quality" = @{
        Codec     = "libx264"
        CRF       = "18"
        Preset    = "slow"
        MapAll    = $true
        CopyAudio = $true
    }
    "Balanced"     = @{
        Codec     = "libx264"
        CRF       = "23"
        Preset    = "slow"
        MapAll    = $true
        CopyAudio = $true
    }
    "Small Size"   = @{
        Codec     = "libx264"
        CRF       = "28"
        Preset    = "fast"
        MapAll    = $true
        CopyAudio = $true
    }
}

# Common error handler
function Write-ErrorDetails {
    param(
        [string]$Context,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    Write-Host "Error $Context`: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    Write-Host "Full error details:" -ForegroundColor Red
    Write-Host $ErrorRecord.Exception.Message -ForegroundColor Red
    Write-Host "Stack trace:" -ForegroundColor Red
    Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor Red
}

# Common exit handler
function Exit-Application {
    Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 
}

# Common section header formatter
function Write-SectionHeader {
    param(
        [string]$Title,
        [string]$Color = "Cyan"
    )
    
    Write-Host "`n$Title" -ForegroundColor $Color
    Write-Host ("-" * $Title.Length) -ForegroundColor $Color
}

function Get-VideoProperties {
    param (
        [Parameter(Mandatory = $true)]
        [string]$inputFile
    )
    
    try {
        if (-not (Test-Path -LiteralPath $inputFile)) {
            throw "Input file does not exist: $inputFile"
        }

        Write-Host "Analyzing video file..." -ForegroundColor Cyan
        
        $videoInfoJson = & ffprobe -v error -print_format json -show_format -show_streams "$inputFile" 2>&1
        
        if (-not $videoInfoJson) {
            throw "ffprobe returned no output"
        }
        
        $videoInfo = $videoInfoJson | ConvertFrom-Json
        
        if (-not $videoInfo) {
            throw "Failed to parse ffprobe JSON output"
        }

        $videoStream = $videoInfo.streams | Where-Object { $_.'codec_type' -eq 'video' } | Select-Object -First 1

        if (-not $videoStream) {
            Write-Host "Available streams:" -ForegroundColor Yellow
            $videoInfo.streams | ForEach-Object {
                Write-Host "Stream type: $($_.codec_type), codec: $($_.codec_name)" -ForegroundColor Yellow
            }
            throw "No video stream found in file. Please ensure this is a valid video file."
        }

        $properties = @{
            Resolution = "$($videoStream.width)x$($videoStream.height)"
            Codec      = $videoStream.codec_name
            Bitrate    = if ($videoStream.bit_rate) { [math]::Round($videoStream.bit_rate / 1000) } else { "N/A" }
            Duration   = [timespan]::FromSeconds($videoInfo.format.duration)
            FrameRate  = if ($videoStream.r_frame_rate) { 
                $fps = $videoStream.r_frame_rate.Split('/')
                if ($fps.Count -eq 2 -and [decimal]$fps[1] -ne 0) {
                    [math]::Round(([decimal]$fps[0] / [decimal]$fps[1]), 2)
                }
                else { "N/A" }
            }
            else { "N/A" }
            FileSize   = [math]::Round((Get-Item -LiteralPath $inputFile).Length / 1GB, 2)
        }

        return $properties
    }
    catch {
        Write-ErrorDetails -Context "analyzing video" -ErrorRecord $_
        return $null
    }
}

function Get-SystemSpecs {
    try {
        $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
        $gpuInfo = Get-CimInstance Win32_VideoController | Select-Object -First 1
        $ramInfo = Get-CimInstance Win32_ComputerSystem
        $gpuMemory = "Unknown"
        if ($gpuInfo.AdapterRAM) {
            try {
                $gpuMemory = [math]::Round([decimal]$gpuInfo.AdapterRAM / 1GB, 2)
            }
            catch {
                $gpuMemory = "Unknown"
            }
        }

        return @{
            CPU = @{
                Name  = if ($cpuInfo.Name) { $cpuInfo.Name } else { "Unknown" }
                Cores = if ($cpuInfo.NumberOfCores) { $cpuInfo.NumberOfCores } else { 4 }
                Speed = if ($cpuInfo.MaxClockSpeed) { $cpuInfo.MaxClockSpeed } else { 2000 }
            }
            GPU = @{
                Name   = if ($gpuInfo.Name) { $gpuInfo.Name } else { "Unknown" }
                Memory = $gpuMemory
            }
            RAM = @{
                Total = if ($ramInfo.TotalPhysicalMemory) { 
                    [math]::Round($ramInfo.TotalPhysicalMemory / 1GB, 2)
                }
                else { 
                    8
                }
            }
        }
    }
    catch {
        Write-Host "Error getting system specifications: $_" -ForegroundColor Red
        return @{
            CPU = @{
                Name  = "Unknown CPU"
                Cores = 4
                Speed = 2000
            }
            GPU = @{
                Name   = "Unknown GPU"
                Memory = "Unknown"
            }
            RAM = @{
                Total = 8
            }
        }
    }
}

function Get-SmartRecommendation {
    param($systemSpecs, $videoProps)
    
    # Low-end system: prioritize speed
    if ($systemSpecs.CPU.Cores -lt 4 -or $systemSpecs.RAM.Total -lt 8) {
        return "Small Size (Fastest processing)"
    }
    # High-end system: can handle quality
    elseif ($systemSpecs.CPU.Cores -ge 8 -and $systemSpecs.RAM.Total -ge 16) {
        return "High Quality (Your system can handle it)"
    }
    # Most systems: balanced
    else {
        return "Balanced (Best for most users)"
    }
}

function Show-PresetDetails {
    param([string]$PresetName, [int]$Number)
    
    $preset = $script:CompressionPresets[$PresetName]
    $displayName = if ($PresetName -eq "Balanced") { "$PresetName (Recommended for most users)" } else { $PresetName }
    
    Write-Host "`n[$Number] $displayName" -ForegroundColor Green
    Write-AnimatedLine "- CRF: $($preset.CRF) (Lower = Better)" "Gray" 2
    Write-AnimatedLine "- Preset: $($preset.Preset)" "Gray" 2
    Start-Sleep -Milliseconds 15
}

function Get-CompressionSuggestions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$inputFile
    )
    
    try {
        $videoProps = Get-VideoProperties -inputFile $inputFile
        if (-not $videoProps) { throw "Failed to get video properties" }

        $systemSpecs = Get-SystemSpecs
        if (-not $systemSpecs) { throw "Failed to get system specifications" }

        Write-SectionHeader "Video Analysis"
        Start-Sleep -Milliseconds 25

        Write-AnimatedLine "Resolution: $($videoProps.Resolution)" "White" 2
        Write-AnimatedLine "Bitrate: $($videoProps.Bitrate) kbps" "White" 2
        Write-AnimatedLine "Duration: $($videoProps.Duration)" "White" 2
        Write-AnimatedLine "Size: $($videoProps.FileSize) GB" "White" 2
        Start-Sleep -Milliseconds 25

        # Show system capabilities
        Write-SectionHeader "Your System"
        Write-Host "CPU: $($systemSpecs.CPU.Name) ($($systemSpecs.CPU.Cores) cores)"
        Write-Host "RAM: $($systemSpecs.RAM.Total) GB"
        Write-Host "GPU: $($systemSpecs.GPU.Name)"
        
        # Smart recommendations based on system
        $recommendation = Get-SmartRecommendation -systemSpecs $systemSpecs -videoProps $videoProps
        Write-Host "`nRecommendation for your system: $recommendation" -ForegroundColor Yellow

        Write-SectionHeader "Compression Options" "Yellow"
        Start-Sleep -Milliseconds 25

        Show-PresetDetails "High Quality" 1
        Show-PresetDetails "Balanced" 2
        Show-PresetDetails "Small Size" 3

        Write-Host "`n[B] Go Back" -ForegroundColor White
    }
    catch {
        Write-Host "Error generating compression suggestions: $_" -ForegroundColor Red
    }
}

function Compress-Video {
    param (
        [Parameter(Mandatory = $true)]
        [string]$inputFile,
        [Parameter(Mandatory = $true)]
        [string]$preset
    )
    
    try {
        $videoProps = Get-VideoProperties $inputFile
        if (-not $videoProps) { throw "Failed to analyze video" }

        if (-not $script:CompressionPresets.ContainsKey($preset)) {
            throw "Invalid preset selected: $preset"
        }

        $selectedPreset = $script:CompressionPresets[$preset]
        
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
        $outputFile = "$baseName-$($preset.ToLower().Replace(' ', '-')).mp4"

        Write-Host "`nStarting video compression with $preset preset" -ForegroundColor Cyan
        Write-Host "-------------------------------------------" -ForegroundColor Cyan
        
        Write-Host "`nCompression Settings:" -ForegroundColor Yellow
        Write-Host "  - Codec: H.264 (Standard Compatible)"
        Write-Host "  - CRF Value: $($selectedPreset.CRF) (Lower = Better Quality)"
        Write-Host "  - Preset: $($selectedPreset.Preset)`n"

        Show-FilmStripBorder -message "COMPRESSING VIDEO" -frameCount 30

        $ffmpegArgs = @(
            "-i", $inputFile
        )
        
        if ($selectedPreset.MapAll) {
            $ffmpegArgs += "-map", "0"
        }
        
        $ffmpegArgs += @(
            "-c:v", $selectedPreset.Codec,
            "-crf", $selectedPreset.CRF,
            "-preset", $selectedPreset.Preset
        )
        
        if ($selectedPreset.CopyAudio) {
            $ffmpegArgs += "-c:a", "copy"
        }
        else {
            $ffmpegArgs += @(
                "-c:a", "aac",
                "-b:a", "128k"
            )
        }
        
        $ffmpegArgs += $outputFile
        
        & $ffmpeg $ffmpegArgs

        $originalSize = (Get-Item $inputFile).Length / 1MB
        $compressedSize = (Get-Item $outputFile).Length / 1MB
        $savingsPercent = [math]::Round(100 - ($compressedSize / $originalSize * 100), 1)

        Show-CompletionAnimation

        Write-Host "`nCompression Results:" -ForegroundColor Green
        Write-Host "-------------------" -ForegroundColor Green
        Write-Host "Original Size: $([math]::Round($originalSize, 2)) MB"
        Write-Host "Compressed Size: $([math]::Round($compressedSize, 2)) MB"
        Write-Host "Space Saved: $savingsPercent%"
        Write-Host "`nOutput File: $outputFile"
        
        Exit-Application
    }
    catch {
        Write-ErrorDetails -Context "during compression" -ErrorRecord $_
        Exit-Application
    }
}

Export-ModuleMember -Function Get-VideoProperties, Get-SystemSpecs, Get-SmartRecommendation, Get-CompressionSuggestions, Compress-Video