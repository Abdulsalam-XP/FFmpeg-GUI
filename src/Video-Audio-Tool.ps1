# Process-scope only: required because Launcher.exe hosts this script in a runspace
# that inherits the machine policy (Restricted by default), which blocks Import-Module.
try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force } catch {}

$scriptVersion = "2.1.0"
$repoOwner = "Abdulsalam-XP"
$repoName = "FFmpeg-GUI"
$scriptName = "src/Video-Audio-Tool.ps1"
$branch = "main"

$scriptRoot = if ($PSScriptRoot -ne "") { $PSScriptRoot } else { Split-Path -Parent ([Environment]::GetCommandLineArgs()[0]) }
$assetsPath = Join-Path $scriptRoot "assets"

$shortcutPath = Join-Path $scriptRoot "FFmpeg-Tool.lnk"
if (Test-Path $shortcutPath) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    
    $expectedTarget = Join-Path $assetsPath "Launcher Config.bat"
    $expectedIcon = Join-Path $assetsPath "Icon.ico"
    
    if ($shortcut.TargetPath -ne $expectedTarget) {
        $shortcut.TargetPath = $expectedTarget
        $shortcut.WorkingDirectory = $assetsPath
        
        # Fix icon path if icon exists
        if (Test-Path $expectedIcon) {
            $shortcut.IconLocation = $expectedIcon
        }
        
        $shortcut.Save()
    }
}

if (-not (Test-Path $assetsPath)) { New-Item -ItemType Directory -Path $assetsPath | Out-Null }

# Paths are relative to src\ and include their folder, because the modules are split
# across frontend\ (the window and everything that touches it) and backend\ (the ffmpeg
# and yt-dlp work). Every module must be listed here, not merely imported: this list is
# what pulls missing files down on a fresh install and what the self-updater refreshes,
# so omitting one would leave updated installs broken.
$requiredModules = @(
    "backend\ToolPaths.psm1",
    "backend\ToolUpdates.psm1",
    "backend\UI.psm1",
    "frontend\UI-WPF.psm1",
    "backend\Settings.psm1",
    "backend\RecentFiles.psm1",
    "backend\CutList.psm1",
    "backend\VideoProcessing.psm1",
    "backend\AudioProcessing.psm1",
    "backend\YouTubeDownload.psm1",
    "backend\Captions.psm1",
    "backend\Zooms.psm1",
    "backend\ProjectFile.psm1",
    "backend\Tracks.psm1",
    "backend\VideoTrimmer.psm1"
)

# The window's markup, not a .psm1, so it lives outside $requiredModules -- but it
# is loaded by path (Initialize-MainWindow) exactly like a module, needs the same
# missing-file self-heal on a partial install, and needs the same refresh from the
# self-updater so code and markup never drift apart (see Test-ScriptUpdates below).
$requiredXamlFiles = @(
    "frontend\MainWindow.xaml",
    "frontend\Theme.xaml"
)

# The UI body's dot-sourced section files (see the block inside the try below). They
# ride the same missing-file self-heal and self-updater refresh as the XAML: they are
# fetched-by-path text files the script cannot start without, not modules.
$requiredSectionFiles = @(
    "sections\10-shell-panels.ps1",
    "sections\15-editor-state.ps1",
    "sections\20-timeline-math.ps1",
    "sections\25-timeline-strip.ps1",
    "sections\30-lanes-model.ps1",
    "sections\35-lane-rows.ps1",
    "sections\40-zoom-preview.ps1",
    "sections\45-preview-pools.ps1",
    "sections\50-media-add.ps1",
    "sections\55-overlays.ps1",
    "sections\60-undo-captions.ps1",
    "sections\65-media-cache.ps1",
    "sections\70-editor-wiring.ps1",
    "sections\75-panels-look.ps1",
    "sections\80-look-nebula.ps1",
    "sections\85-tools-card.ps1"
)

foreach ($mod in $requiredModules) {
    $localModPath = Join-Path $scriptRoot $mod
    if (-not (Test-Path $localModPath)) {
        Write-Host "Detected missing module: $mod. Downloading..." -ForegroundColor Cyan
        try {
            $modParent = Split-Path $localModPath -Parent
            if (-not (Test-Path $modParent)) { New-Item -ItemType Directory -Path $modParent | Out-Null }
            # GitHub raw URLs are forward-slashed regardless of the local separator.
            $modUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/src/$($mod -replace '\\', '/')"
            Invoke-RestMethod -Uri $modUrl -OutFile $localModPath
        }
        catch {
            Write-Host "Failed to download $mod. Please check your internet connection." -ForegroundColor Red
        }
    }
}

foreach ($xamlFile in ($requiredXamlFiles + $requiredSectionFiles)) {
    $localXamlPath = Join-Path $scriptRoot $xamlFile
    if (-not (Test-Path $localXamlPath)) {
        Write-Host "Detected missing UI file: $xamlFile. Downloading..." -ForegroundColor Cyan
        try {
            $xamlParent = Split-Path $localXamlPath -Parent
            if (-not (Test-Path $xamlParent)) { New-Item -ItemType Directory -Path $xamlParent | Out-Null }
            # Same forward-slash rule as the module loop above.
            $xamlUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/src/$($xamlFile -replace '\\', '/')"
            Invoke-RestMethod -Uri $xamlUrl -OutFile $localXamlPath
        }
        catch {
            Write-Host "Failed to download $xamlFile. Please check your internet connection." -ForegroundColor Red
        }
    }
}

foreach ($mod in $requiredModules) {
    Import-Module (Join-Path $scriptRoot $mod) -Force
}

Import-Config

# A BrushConverter that speaks the active Look: every code-built color goes through
# Convert-LookColorText (UI-WPF.psm1), so the Petalfall hue map covers the dynamic UI
# exactly as it covers the XAML. Same ConvertFromString shape as the real converter --
# the dozens of call sites did not have to change, only the allocations.
function New-LookBrushConverter {
    $wrapper = New-Object PSObject
    $wrapper | Add-Member -MemberType NoteProperty -Name Inner -Value (New-Object "System.Windows.Media.BrushConverter")
    $wrapper | Add-Member -MemberType ScriptMethod -Name ConvertFromString -Value {
        param([string]$Hex)
        return $this.Inner.ConvertFromString((Convert-LookColorText -Text $Hex))
    }
    return $wrapper
}

# Left behind by a previous update: a replaced exe cannot be deleted while the old
# process still holds it, so cleanup happens on the next launch instead.
Clear-StaleToolFiles -BinFolder (Join-Path $scriptRoot "bin")

function Test-ScriptUpdates {
    try {
        $apiUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/$scriptName"
        $response = Invoke-RestMethod -Uri $apiUrl -Headers @{
            "Accept" = "application/vnd.github.v3.raw"
        }

        if ($response -match '\$scriptVersion\s*=\s*"([\d\.]+)"') {
            $latestVersion = $matches[1]

            if ([version]$latestVersion -gt [version]$scriptVersion) {

                $whatsNewPath = Join-Path $assetsPath "WHATS_NEW.txt"
                try {
                    $whatsNewUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/WHATS_NEW.txt"
                    Invoke-RestMethod -Uri $whatsNewUrl -OutFile $whatsNewPath -ErrorAction SilentlyContinue
                } catch {}

                if (Test-Path $whatsNewPath) {
                    $changesSummary = Get-Content -Path $whatsNewPath -Raw
                } else {
                    $changesSummary = "What's New in This Update:`n`n• General improvements and optimizations`n• New features added`n"
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
                $textBox.AppendText($changesSummary)

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
                    
                    # Downloaded text keeps the file's BOM as a leading character; strip it
                    # so self-updates don't stack BOM chars at the top of the script
                    $response.TrimStart([char]0xFEFF) | Out-File -FilePath $PSCommandPath -Force
                    
                    Write-Host "Updating modules..." -ForegroundColor Cyan
                    $modulesUrlBase = "https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/src"

                    foreach ($mod in $requiredModules) {
                        try {
                            $target = Join-Path $scriptRoot $mod
                            $targetParent = Split-Path $target -Parent
                            if (-not (Test-Path $targetParent)) { New-Item -ItemType Directory -Path $targetParent | Out-Null }
                            $modUri = "$modulesUrlBase/$($mod -replace '\\', '/')"
                            Invoke-RestMethod -Uri $modUri -OutFile $target -ErrorAction Stop
                        } catch {
                            Write-Host "Warning: Could not update module $mod" -ForegroundColor Yellow
                        }
                    }

                    Write-Host "Updating UI definitions..." -ForegroundColor Cyan
                    # New script code can reference XAML elements ($requiredModules alone
                    # never updates these two) that don't exist in an old MainWindow.xaml/
                    # Theme.xaml -- that mismatch is exactly what took startup down before
                    # Update-RecentList grew its null guard. Refresh them the same way, on
                    # the same restart, so code and markup move together.
                    foreach ($xamlFile in ($requiredXamlFiles + $requiredSectionFiles)) {
                        try {
                            $target = Join-Path $scriptRoot $xamlFile
                            $targetParent = Split-Path $target -Parent
                            if (-not (Test-Path $targetParent)) { New-Item -ItemType Directory -Path $targetParent | Out-Null }
                            $xamlUri = "$modulesUrlBase/$($xamlFile -replace '\\', '/')"
                            Invoke-RestMethod -Uri $xamlUri -OutFile $target -ErrorAction Stop
                        } catch {
                            Write-Host "Warning: Could not update $xamlFile" -ForegroundColor Yellow
                        }
                    }

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


Test-ScriptUpdates

# ---------------------------------------------------------------------------
# WPF application. The console menu this replaced is gone entirely, and the
# launcher starts PowerShell with a hidden window, so nothing here may block on
# console input or rely on Write-Host reaching a user.
# ---------------------------------------------------------------------------

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

try {
    # The whole UI body lives in dot-sourced section files (sections\*.ps1). Dot-
    # sourcing runs each file IN THIS SCOPE, inside this try -- identical semantics
    # to the code being inline. A .psm1 split is impossible here (dynamic scoping:
    # every $script: write from a GetNewClosure block and every cross-function
    # variable would land in the wrong module scope). Order matters: later sections
    # call functions and read variables the earlier ones define.
    . (Join-Path $scriptRoot "sections\10-shell-panels.ps1")
    . (Join-Path $scriptRoot "sections\15-editor-state.ps1")
    . (Join-Path $scriptRoot "sections\20-timeline-math.ps1")
    . (Join-Path $scriptRoot "sections\25-timeline-strip.ps1")
    . (Join-Path $scriptRoot "sections\30-lanes-model.ps1")
    . (Join-Path $scriptRoot "sections\35-lane-rows.ps1")
    . (Join-Path $scriptRoot "sections\40-zoom-preview.ps1")
    . (Join-Path $scriptRoot "sections\45-preview-pools.ps1")
    . (Join-Path $scriptRoot "sections\50-media-add.ps1")
    . (Join-Path $scriptRoot "sections\55-overlays.ps1")
    . (Join-Path $scriptRoot "sections\60-undo-captions.ps1")
    . (Join-Path $scriptRoot "sections\65-media-cache.ps1")
    . (Join-Path $scriptRoot "sections\70-editor-wiring.ps1")
    . (Join-Path $scriptRoot "sections\75-panels-look.ps1")
    . (Join-Path $scriptRoot "sections\80-look-nebula.ps1")
    . (Join-Path $scriptRoot "sections\85-tools-card.ps1")
    $ctx.Window.ShowDialog() | Out-Null
}
catch {
    # With the console hidden there is nowhere for an unhandled error to surface, so a
    # startup failure would otherwise look like the app simply never opening. The log
    # file exists for the same reason: a dialog can be dismissed and its text lost.
    try {
        Set-Content -Path (Join-Path $env:TEMP "ffgui-crash.txt") -Encoding UTF8 -Value (
            "{0}`n{1}`n{2}" -f (Get-Date -Format o), $_.Exception.Message, $_.ScriptStackTrace)
    } catch { }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "FFmpeg GUI could not start.`n`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)",
        "FFmpeg GUI", "OK", "Error") | Out-Null
}
