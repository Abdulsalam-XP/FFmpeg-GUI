function Get-VideoProperties {
    param (
        [Parameter(Mandatory=$true)]
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
                Cores = if ($cpuInfo.NumberOfCores) { $cpuInfo.NumberOfCores } else { 4 }
                Speed = if ($cpuInfo.MaxClockSpeed) { $cpuInfo.MaxClockSpeed } else { 2000 }
            }
            GPU = @{
                Name = if ($gpuInfo.Name) { $gpuInfo.Name } else { "Unknown" }
                Memory = $gpuMemory
            }
            RAM = @{
                Total = if ($ramInfo.TotalPhysicalMemory) { 
                    [math]::Round($ramInfo.TotalPhysicalMemory/1GB, 2)
                } else { 
                    8
                }
            }
        }
    }
    catch {
        Write-Host "Error getting system specifications: $_" -ForegroundColor Red
        return @{
            CPU = @{
                Name = "Unknown CPU"
                Cores = 4
                Speed = 2000
            }
            GPU = @{
                Name = "Unknown GPU"
                Memory = "Unknown"
            }
            RAM = @{
                Total = 8
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
        $videoProps = Get-VideoProperties -inputFile $inputFile
        if (-not $videoProps) { throw "Failed to get video properties" }

        $systemSpecs = Get-SystemSpecs
        if (-not $systemSpecs) { throw "Failed to get system specifications" }

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

        Write-Host "`nVideo Analysis" -ForegroundColor Cyan
        Write-Host "-------------" -ForegroundColor Cyan
        Start-Sleep -Milliseconds 25

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
        $videoProps = Get-VideoProperties $inputFile
        if (-not $videoProps) { throw "Failed to analyze video" }

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
                MapAll = $true
                CopyAudio = $true
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
        } else {
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
        Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
        Stop-Process -Name "cmd" -Force
        Stop-Process -Name "powershell" -Force
    }
    catch {
        Write-Host "Error during compression: $_" -ForegroundColor Red
        Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
        Stop-Process -Name "cmd" -Force
        Stop-Process -Name "powershell" -Force
    }
}

Export-ModuleMember -Function * 