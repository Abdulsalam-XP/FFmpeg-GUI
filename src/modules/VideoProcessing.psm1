Import-Module "$PSScriptRoot/UI.psm1"
$ffprobe = "ffprobe"

$script:CompressionPresets = @{}

function Set-CompressionMode {
    param(
        [string]$Mode = "CPU" 
    )

    if ($Mode -eq "NVIDIA") {
        Write-Host "Configuring for NVIDIA Standard (H.264/NVENC) High Compatibility..." -ForegroundColor Cyan
        
        $script:CompressionPresets = @{
            "High Quality" = @{
                Codec  = "h264_nvenc"
                CRF    = "21"
                Preset = "p7"
                MapAll = $true
            }
            "Balanced"     = @{
                Codec  = "h264_nvenc"
                CRF    = "24"
                Preset = "p5"
                MapAll = $true
            }
            "Small Size"   = @{
                Codec  = "h264_nvenc"
                CRF    = "30"
                Preset = "p3"
                MapAll = $true
            }
        }
    }
    else {
        $script:CompressionPresets = @{
            "High Quality" = @{
                Codec  = "libx264"
                CRF    = "18"
                Preset = "slow"
                MapAll = $true
            }
            "Balanced"     = @{
                Codec  = "libx264"
                CRF    = "23"
                Preset = "slow"
                MapAll = $true
            }
            "Small Size"   = @{
                Codec  = "libx264"
                CRF    = "28"
                Preset = "fast"
                MapAll = $true
            }
        }
    }
}

Set-CompressionMode -Mode "CPU"

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
        
        $videoInfoJson = & $ffprobe -v error -print_format json -show_format -show_streams "$inputFile" 2>&1
        
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
        # Prefer a dedicated NVIDIA adapter: on laptops the first controller is usually the iGPU
        $gpus = @(Get-CimInstance Win32_VideoController)
        $gpuInfo = $gpus | Where-Object { $_.Name -match "NVIDIA" } | Select-Object -First 1
        if (-not $gpuInfo) { $gpuInfo = $gpus | Select-Object -First 1 }
        $ramInfo = Get-CimInstance Win32_ComputerSystem

        return @{
            CPU = @{
                Name  = if ($cpuInfo.Name) { $cpuInfo.Name } else { "Unknown" }
                Cores = if ($cpuInfo.NumberOfCores) { $cpuInfo.NumberOfCores } else { 4 }
                Speed = if ($cpuInfo.MaxClockSpeed) { $cpuInfo.MaxClockSpeed } else { 2000 }
            }
            GPU = @{
                Name = if ($gpuInfo.Name) { $gpuInfo.Name } else { "Unknown" }
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
                Name = "Unknown GPU"
            }
            RAM = @{
                Total = 8
            }
        }
    }
}

function Show-PresetDetails {
    param([string]$PresetName, [int]$Number)
    
    $preset = $script:CompressionPresets[$PresetName]
    $displayName = if ($PresetName -eq "Balanced") { "$PresetName (Recommended for most users)" } else { $PresetName }
    
    Write-Host "`n[$Number] $displayName" -ForegroundColor Green
    Write-AnimatedLine "- CRF: $($preset.CRF) (Lower = Better)" "Gray" 1
    Write-AnimatedLine "- Preset: $($preset.Preset)" "Gray" 1
    Start-Sleep -Milliseconds 15
}

function Get-CompressionSuggestions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$inputFile,
        [hashtable]$systemSpecs
    )

    try {
        $videoProps = Get-VideoProperties -inputFile $inputFile
        if (-not $videoProps) { throw "Failed to get video properties" }

        if (-not $systemSpecs) { $systemSpecs = Get-SystemSpecs }
        if (-not $systemSpecs) { throw "Failed to get system specifications" }

        Write-SectionHeader "Video Analysis"
        Start-Sleep -Milliseconds 25

        Write-AnimatedLine "Resolution: $($videoProps.Resolution)" "White" 1
        Write-AnimatedLine "Bitrate: $($videoProps.Bitrate) kbps" "White" 1
        Write-AnimatedLine "Duration: $($videoProps.Duration)" "White" 1
        Write-AnimatedLine "Size: $($videoProps.FileSize) GB" "White" 1
        Start-Sleep -Milliseconds 25

        Write-SectionHeader "Your System"
        Write-Host "CPU: $($systemSpecs.CPU.Name) ($($systemSpecs.CPU.Cores) cores)"
        Write-Host "RAM: $($systemSpecs.RAM.Total) GB"
        Write-Host "GPU: $($systemSpecs.GPU.Name)"
        
        Write-SectionHeader "Compression Options" "Yellow"
        Start-Sleep -Milliseconds 25

        Show-PresetDetails "High Quality" 1
        Show-PresetDetails "Balanced" 2
        Show-PresetDetails "Small Size" 3

        Write-Host "`n[B] Go Back" -ForegroundColor White

        return $videoProps
    }
    catch {
        Write-Host "Error generating compression suggestions: $_" -ForegroundColor Red
        return $null
    }
}

function Compress-Video {
    param (
        [Parameter(Mandatory = $true)][string]$inputFile,
        [Parameter(Mandatory = $true)][string]$preset,
        [hashtable]$videoProps
    )

    try {
        if (-not $videoProps) { $videoProps = Get-VideoProperties -inputFile $inputFile }
        if (-not $videoProps) { throw "Failed to analyze video" }
        $totalSeconds = $videoProps.Duration.TotalSeconds
        $selectedPreset = $script:CompressionPresets[$preset]
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
        $outputFile = "$baseName-$($preset.ToLower().Replace(' ', '-')).mp4"

        Write-Host "`nStarting video compression ($preset)..." -ForegroundColor Cyan
        Write-Host "-------------------------------------------" -ForegroundColor Cyan

        $argList = @("-i", "`"$inputFile`"")
        if ($selectedPreset.MapAll) { $argList += "-map", "0" }

        if ($selectedPreset.Codec -like "*nvenc") {
            $argList += "-c:v", $selectedPreset.Codec, "-rc", "vbr", "-cq", $selectedPreset.CRF, "-preset", $selectedPreset.Preset, "-b:v", "0"
        } else {
            $argList += "-c:v", $selectedPreset.Codec, "-crf", $selectedPreset.CRF, "-preset", $selectedPreset.Preset
        }
        $argList += "-c:a", "copy", "`"$outputFile`"", "-y"

        [void](Invoke-FFmpegProcess -ArgumentList $argList -Activity "Compressing" -StatusInfo "Speed: $($selectedPreset.Preset)" -TotalSeconds $totalSeconds)

        if (Test-Path -LiteralPath $outputFile) {
            $originalSize = (Get-Item -LiteralPath $inputFile).Length / 1MB
            $compressedSize = (Get-Item -LiteralPath $outputFile).Length / 1MB
            $savingsPercent = [math]::Round(100 - ($compressedSize / $originalSize * 100), 1)

            Show-CompletionAnimation

            Write-Host "`nCompression Results:" -ForegroundColor Green
            Write-Host "-------------------" -ForegroundColor Green
            Write-Host "Original Size: $([math]::Round($originalSize, 2)) MB"
            Write-Host "Compressed Size: $([math]::Round($compressedSize, 2)) MB"
            Write-Host "Space Saved: $savingsPercent%"
            Write-Host "`nOutput File: $outputFile"

            Wait-KeyPress
        } else {
            throw "FFmpeg failed to create the output file. Please check if the codec is supported on your system."
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
        Write-ErrorDetails -Context "compression" -ErrorRecord $_
    }
}

Export-ModuleMember -Function Get-VideoProperties, Get-SystemSpecs, Get-CompressionSuggestions, Compress-Video, Set-CompressionMode