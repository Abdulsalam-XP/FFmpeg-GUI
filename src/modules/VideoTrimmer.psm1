Import-Module "$PSScriptRoot/UI.psm1"
$ffmpeg = "ffmpeg"

function Split-Video {
    param (
        [Parameter(Mandatory = $true)][string]$inputFile,
        [Parameter(Mandatory = $true)][string]$mode, 
        [Parameter(Mandatory = $true)][string]$timestamp
    )
    
    try {
        if (Get-Command "Get-VideoProperties" -ErrorAction SilentlyContinue) {
            $videoProps = Get-VideoProperties -inputFile $inputFile
            if ($videoProps) {
                $totalSeconds = $videoProps.Duration.TotalSeconds
            } else {
                $totalSeconds = 0
            }
        } else {
            $totalSeconds = 0
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
        $cleanTimestamp = $timestamp -replace ':', '-'
        $outputFile = ""
        
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $ffmpeg
        $pInfo.RedirectStandardError = $true
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true

        $argList = @()

        if ($mode -eq "Before") {
            $outputFile = "$baseName-Trimmed-From-$cleanTimestamp.mp4"
            $argList += "-ss", $timestamp, "-i", "`"$inputFile`"", "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
            
            Write-Host "`nTrimming video (Removing content before $timestamp)..." -ForegroundColor Cyan
        }
        elseif ($mode -eq "After") {
            $outputFile = "$baseName-Trimmed-Until-$cleanTimestamp.mp4"
            $argList += "-i", "`"$inputFile`"", "-to", $timestamp, "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
            
            Write-Host "`nTrimming video (Removing content after $timestamp)..." -ForegroundColor Cyan
        }

        Write-Host "----------------------------------------------------" -ForegroundColor Cyan

        $pInfo.Arguments = $argList -join " "
        
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
                
                if ($totalSeconds -gt 0) {
                    $percent = [math]::Min(100, [math]::Round(($currentPos / $totalSeconds) * 100, 1))
                    if ($mode -eq "After") {
                        $targetSeconds = [timespan]::Parse($timestamp).TotalSeconds
                        if ($targetSeconds -gt 0) {
                             $percent = [math]::Min(100, [math]::Round(($currentPos / $targetSeconds) * 100, 1))
                        }
                    }
                    
                    $timeElapsed = (Get-Date) - $startTime
                    if ($percent -gt 0) {
                        $totalEstimatedSeconds = ($timeElapsed.TotalSeconds / $percent) * 100
                        $remaining = [timespan]::FromSeconds($totalEstimatedSeconds - $timeElapsed.TotalSeconds)
                        $etaString = $remaining.ToString("hh\:mm\:ss")
                    } else { $etaString = "--:--:--" }

                    Update-ProgressBar -Activity "Processing" -Percent $percent -ETA $etaString -StatusInfo "Mode: Copy (Multi-Track)"
                }
            }
        }
        $process.WaitForExit()
        try { [Console]::CursorVisible = $true } catch {}

        if (Test-Path $outputFile) {
            Show-CompletionAnimation
            Write-Host "`nTrim Complete!" -ForegroundColor Green
            Write-Host "Output File: $outputFile" -ForegroundColor White
            
            Write-Host "`nPress any key to return to the menu..." -ForegroundColor Yellow
            [void][System.Console]::ReadKey($true)
        } else {
            throw "FFmpeg failed to create the output file. Check timestamp format (HH:MM:SS)."
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host "`nError during trim operation: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Press any key to continue..."
        [void][System.Console]::ReadKey($true)
    }
}

Export-ModuleMember -Function Split-Video