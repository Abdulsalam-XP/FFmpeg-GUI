# Script Version
$scriptVersion = "1.0.3"
$repoOwner = "Abdulsalam-XP"
$repoName = "FFmpeg-GUI"
$scriptName = "Video-Audio-Tool.ps1"

# Import modules
$modulePath = Join-Path $PSScriptRoot "modules"
Import-Module (Join-Path $modulePath "UI.psm1")
Import-Module (Join-Path $modulePath "VideoProcessing.psm1")
Import-Module (Join-Path $modulePath "AudioProcessing.psm1")
Import-Module (Join-Path $modulePath "YouTubeDownload.psm1")

function Check-ForUpdates {
    try {
        $apiUrl = "https://api.github.com/repos/$repoOwner/$repoName/contents/$scriptName"
        $response = Invoke-RestMethod -Uri $apiUrl -Headers @{
            "Accept" = "application/vnd.github.v3.raw"
        }

        if ($response -match '# Script Version\s*\$scriptVersion = "([\d\.]+)"') {
            $latestVersion = $matches[1]
            
            if ([version]$latestVersion -gt [version]$scriptVersion) {
                $commitsUrl = "https://api.github.com/repos/$repoOwner/$repoName/commits?path=$scriptName"
                $commits = Invoke-RestMethod -Uri $commitsUrl -Headers @{
                    "Accept" = "application/vnd.github.v3+json"
                }

                Add-Type -AssemblyName System.Windows.Forms
                $form = New-Object System.Windows.Forms.Form
                $form.Text = "Update Available!"
                $form.Size = New-Object System.Drawing.Size(600,400)
                $form.StartPosition = "CenterScreen"
                $form.BackColor = [System.Drawing.Color]::White

                $textBox = New-Object System.Windows.Forms.RichTextBox
                $textBox.Location = New-Object System.Drawing.Point(10,10)
                $textBox.Size = New-Object System.Drawing.Size(560,300)
                $textBox.ReadOnly = $true
                $textBox.BackColor = [System.Drawing.Color]::White
                $textBox.Font = New-Object System.Drawing.Font("Consolas", 10)

                $textBox.AppendText("New version $latestVersion is available!`n")
                $textBox.AppendText("Current version: $scriptVersion`n`n")
                $textBox.AppendText("Recent Changes:`n")
                $textBox.AppendText("----------------`n")

                foreach ($commit in $commits) {
                    $textBox.AppendText("• $($commit.commit.message)`n")
                }

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

                $form.Controls.Add($textBox)
                $form.Controls.Add($updateButton)
                $form.Controls.Add($cancelButton)

                $result = $form.ShowDialog()

                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Write-Host "`nDownloading update..." -ForegroundColor Cyan
                    
                    $response | Out-File -FilePath $PSCommandPath -Force
                    
                    Write-Host "Update successful! The script will now restart.`n" -ForegroundColor Green
                    Start-Sleep -Seconds 2
                    
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

# Set ffmpeg path
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
            $inputVideo = $selectedFile.FullName
            $inputVideo = [System.Management.Automation.WildcardPattern]::Escape($inputVideo)
            
            Write-Host "You selected: $($selectedFile.Name)" -ForegroundColor Cyan

            Write-Host ""
            Show-AnimatedIcon -iconType "compress" -message "Analyzing..." -duration 0.8
            Write-Host ""
            
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
            $inputVideo = $selectedFile.FullName
            $inputVideo = [System.Management.Automation.WildcardPattern]::Escape($inputVideo)

            Write-Host "`nAudio Stream Merger" -ForegroundColor Cyan
            Write-Host "----------------" -ForegroundColor Cyan
            Write-Host "This will automatically merge all audio streams from the video into a single mixed audio track."
            Write-Host "The video quality will not be affected as it will be copied without re-encoding."
            
            if (Test-Path -LiteralPath $selectedFile.FullName) {
                Merge-AudioStreams -inputVideo $inputVideo
            } else {
                Write-Host "Error: Selected video file no longer exists: $inputVideo" -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
        "3" {
            Save-YouTubeMP3
        }
        "4" {
            Save-YouTubeMP4
        }
        "B" {
            Write-Host "`nTerminating..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 800
            Stop-Process -Name "cmd" -Force
            Stop-Process -Name "powershell" -Force
        }
        default {
            Write-Host "Invalid choice. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($true) 
