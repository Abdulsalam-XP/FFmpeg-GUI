Import-Module "$PSScriptRoot/UI.psm1"

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

        # ffmpeg reports progress against the OUTPUT duration, which is shorter
        # than the source: up to the timestamp for "After", the remainder for "Before"
        $trimSeconds = [timespan]::Parse($timestamp).TotalSeconds
        $targetSeconds = if ($mode -eq "After") { $trimSeconds }
        elseif ($totalSeconds -gt 0) { $totalSeconds - $trimSeconds }
        else { 0 }

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

        [void](Invoke-FFmpegProcess -ArgumentList $argList -Activity "Processing" -StatusInfo "Mode: Copy (Multi-Track)" -TotalSeconds $targetSeconds)

        if (Test-Path -LiteralPath $outputFile) {
            Show-CompletionAnimation
            Write-Host "`nTrim Complete!" -ForegroundColor Green
            Write-Host "Output File: $outputFile" -ForegroundColor White

            Wait-KeyPress
        } else {
            throw "FFmpeg failed to create the output file. Check timestamp format (HH:MM:SS)."
        }
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host "`nError during trim operation: $($_.Exception.Message)" -ForegroundColor Red
        Wait-KeyPress -Message "Press any key to continue..."
    }
}

Export-ModuleMember -Function Split-Video