Import-Module "$PSScriptRoot/UI.psm1"
Import-Module "$PSScriptRoot/ToolPaths.psm1"
$ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

$script:CompressionPresets = @{}

function Set-CompressionMode {
    param(
        [string]$Mode = "CPU" 
    )

    if ($Mode -eq "NVIDIA") {
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
            FileSize      = [math]::Round((Get-Item -LiteralPath $inputFile).Length / 1GB, 2)
            FileSizeBytes = (Get-Item -LiteralPath $inputFile).Length
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

# Returns the encoder settings each preset will actually use, keyed by preset name.
# Replaces the console-era Get-CompressionSuggestions/Show-PresetDetails pair, which
# printed this straight to the terminal; the GUI needs the values, not the printing.
# Depends on the current Set-CompressionMode, so callers must refresh after toggling GPU.
function Get-CompressionPresetDetails {
    $details = @{}
    foreach ($name in @("High Quality", "Balanced", "Small Size")) {
        $preset = $script:CompressionPresets[$name]
        # NVENC calls its quality knob CQ rather than CRF.
        $qualityLabel = if ($preset.Codec -like "*nvenc") { "CQ" } else { "CRF" }
        $details[$name] = "$qualityLabel $($preset.CRF) / $($preset.Preset)"
    }
    return $details
}

function Compress-VideoAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$Preset,
        [hashtable]$VideoProps
    )

    if (-not $VideoProps) { $VideoProps = Get-VideoProperties -inputFile $InputFile }
    $totalSeconds = $VideoProps.Duration.TotalSeconds
    $selectedPreset = $script:CompressionPresets[$Preset]
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $outputFile = "$baseName-$($Preset.ToLower().Replace(' ', '-')).mp4"

    $argList = @("-i", "`"$InputFile`"")
    if ($selectedPreset.MapAll) { $argList += "-map", "0" }
    if ($selectedPreset.Codec -like "*nvenc") {
        $argList += "-c:v", $selectedPreset.Codec, "-rc", "vbr", "-cq", $selectedPreset.CRF, "-preset", $selectedPreset.Preset, "-b:v", "0"
    } else {
        $argList += "-c:v", $selectedPreset.Codec, "-crf", $selectedPreset.CRF, "-preset", $selectedPreset.Preset
    }
    $argList += "-c:a", "copy", "`"$outputFile`"", "-y"

    $panel = $Context.Panels.Compress
    $progressBar = $panel.FindName("ProgressBarCompress")
    $percentText = $panel.FindName("TextCompressPercent")
    $etaText = $panel.FindName("TextCompressEta")
    $cancelButton = $panel.FindName("ButtonCompressCancel")
    # Held so the run can disable it: nothing else stops a second click from launching a
    # parallel ffmpeg that writes the same output file and the same progress controls.
    $startButton = $panel.FindName("ButtonCompressStart")
    $startTime = Get-Date

    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    # Captured as a scriptblock (rather than calling the command by name inside the
    # -OnLine closure below) because Start-TrackedProcess invokes -OnLine from
    # UI-WPF.psm1's own module scope. GetNewClosure() copies variables into the
    # closure, but does not make VideoProcessing.psm1's imported command table
    # resolvable from that foreign invocation context, so an unqualified call to
    # ConvertFrom-FFmpegProgressLine there fails with "not recognized" -- confirmed
    # empirically while verifying this function against real ffmpeg runs. Grabbing
    # the function's own scriptblock here and invoking it via "& $convertProgressLine"
    # sidesteps command-name lookup entirely.
    $convertProgressLine = ${function:ConvertFrom-FFmpegProgressLine}

    $process = Start-TrackedProcess -Context $Context -FileName $ffmpegPath -Arguments ($argList -join " ") -ReadStream Error `
        -OnLine {
            param($line)
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $progress = & $convertProgressLine -Line $line -TotalSeconds $totalSeconds -ElapsedSeconds $elapsed
            if ($progress) {
                $progressBar.Value = $progress.Percent
                $percentText.Text = "{0:N1}%" -f $progress.Percent
                $etaText.Text = $progress.EtaString
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($startButton) { $startButton.IsEnabled = $true }
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%"; $etaText.Text = "00:00:00" }
        }.GetNewClosure()

    if ($startButton) { $startButton.IsEnabled = $false }
    $cancelButton.IsEnabled = $true
    Set-CancelButtonTarget -Button $cancelButton -Process $process

    return $process
}

# Grabs one frame for the selected-video card.
#
# Runs through Start-TrackedProcess so the UI thread never blocks: on a 1.6 GB source
# this still takes a moment, and the card is supposed to appear instantly with the
# picture arriving after. Deliberately NOT registered with Register-Job -- it is not a
# user job and must not make the Settings screen think a job is running.
#
# -ss BEFORE -i is an input seek: ffmpeg jumps straight to the keyframe instead of
# decoding from the start, which is the difference between instant and ten seconds.
function Start-VideoThumbnail {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][timespan]$Duration,
        [Parameter(Mandatory = $true)][scriptblock]$OnReady
    )

    $seconds = Get-ThumbnailSeconds -Duration $Duration
    $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-thumb-{0}.jpg" -f ([guid]::NewGuid().ToString("N")))
    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    # scale=-2 keeps the height even, which the jpeg encoder requires.
    $argList = @(
        "-ss", $seconds, "-i", "`"$InputFile`"", "-frames:v", "1",
        "-vf", "scale=336:-2", "-q:v", "3", "`"$outputPath`"", "-y"
    )

    try {
        return Start-TrackedProcess -Context $Context -FileName $ffmpegPath -Arguments ($argList -join " ") -ReadStream Error `
            -OnLine { param($line) } `
            -OnExit {
                param($exitCode)
                # A missing preview must never block compressing, so failure is silent
                # and the card keeps its placeholder.
                if ($exitCode -eq 0 -and (Test-Path -LiteralPath $outputPath)) {
                    & $OnReady $outputPath
                }
            }.GetNewClosure()
    } catch {
        return $null
    }
}

Export-ModuleMember -Function Get-VideoProperties, Get-SystemSpecs, Get-CompressionPresetDetails, Set-CompressionMode, Compress-VideoAsync, Start-VideoThumbnail