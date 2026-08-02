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

foreach ($xamlFile in $requiredXamlFiles) {
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
                    foreach ($xamlFile in $requiredXamlFiles) {
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

$errorBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE0, 0x6C, 0x6C))

try {
    $ctx = Initialize-MainWindow -ScriptRoot $scriptRoot

    $panelCompress = $ctx.Panels.Compress
    $panelMerge    = $ctx.Panels.MergeAudio
    $panelTrim     = $ctx.Panels.Trim
    $panelYtMp3    = $ctx.Panels.YouTubeMP3
    $panelYtMp4    = $ctx.Panels.YouTubeMP4
    $panelSettings = $ctx.Panels.Settings

    # Per-screen selections. Script scope so the event handlers below can share them.
    $script:CompressInputFile = $null
    $script:CompressVideoProps = $null
    $script:MergeInputFile = $null
    $script:TrimInputFile = $null
    $script:YoutubeMP4Resolutions = @()

    # Tracks live child processes so the Settings screen can tell whether replacing a
    # tool right now would fail. A list of processes rather than a boolean flag: it
    # cannot drift out of sync the way a flag set in one handler and cleared in another
    # can, and it needs no exit hook.
    $script:TrackedJobs = New-Object System.Collections.ArrayList

    function Register-Job {
        param($Process)
        if ($Process) { [void]$script:TrackedJobs.Add($Process) }
    }

    function Test-AnyJobRunning {
        # Only a definite $false from HasExited counts as a live job. Start-TrackedProcess
        # disposes the process once it exits, and reading HasExited on a disposed Process
        # yields $null rather than $true -- so the obvious "-not $_.HasExited" would treat
        # every finished job as still running and leave the update buttons disabled for
        # the rest of the session.
        $live = @($script:TrackedJobs | Where-Object {
            if (-not $_) { return $false }
            $exited = $null
            try { $exited = $_.HasExited } catch { $exited = $true }
            return ($exited -eq $false)
        })
        $script:TrackedJobs.Clear()
        foreach ($p in $live) { [void]$script:TrackedJobs.Add($p) }
        return ($live.Count -gt 0)
    }

    $mutedBrush = $ctx.Window.FindResource("BrushTextMuted")

    function Show-PanelMessage {
        param($Block, [string]$Text, [switch]$IsError)
        $Block.Text = $Text
        $Block.Foreground = if ($IsError) { $errorBrush } else { $mutedBrush }
    }

    # Every transition in this app runs 320ms with a CubicEase EaseInOut, from here.
    #
    # Animating from code rather than with storyboards in Theme.xaml is forced: that
    # dictionary is merged into Application.Resources, which freezes it, and a storyboard
    # whose Duration is a DynamicResource cannot be frozen ("Cannot freeze this Storyboard
    # timeline tree for use across threads" at startup). Code also gets to read
    # $global:ShowAnimations directly, which a templated storyboard never can.
    $script:MotionMs = 320

    function Set-AnimatedDouble {
        param($Target, $Property, [double]$To)

        if (-not $global:ShowAnimations) {
            # Clear the clock first: a held animation value silently overrides a plain
            # property set, so without this the control would stay where it was.
            # Established fix from the nav pill in UI-WPF.psm1.
            $Target.BeginAnimation($Property, $null)
            $Target.SetValue($Property, $To)
            return
        }

        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation $To, `
            (New-Object System.Windows.Duration ([timespan]::FromMilliseconds($script:MotionMs)))
        $anim.EasingFunction = $ease
        $Target.BeginAnimation($Property, $anim)
    }

    # Slides a toggle switch's knob instead of letting it jump. Travel distance: the track
    # is 48 wide with a 1px border, so the content area is 46; the knob is 19 wide starting
    # at left edge 3, and the checked state puts its left edge at 46 - 3 - 19 = 24. So X
    # runs 0 to 21.
    function Register-ToggleSwitch {
        param($Toggle)

        $seat = {
            $Toggle.ApplyTemplate() | Out-Null
            $knob = $Toggle.Template.FindName("KnobShift", $Toggle)
            if (-not $knob) { return }
            # Seated without animating: a switch that starts checked must already be over
            # to the right, not slide across on launch.
            $knob.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
            $knob.X = if ($Toggle.IsChecked) { 21 } else { 0 }
        }.GetNewClosure()

        & $seat
        $Toggle.Add_Loaded($seat)

        $move = {
            $knob = $Toggle.Template.FindName("KnobShift", $Toggle)
            if ($knob) { Set-AnimatedDouble -Target $knob -Property ([System.Windows.Media.TranslateTransform]::XProperty) -To $(if ($Toggle.IsChecked) { 21 } else { 0 }) }
        }.GetNewClosure()

        $Toggle.Add_Checked($move)
        $Toggle.Add_Unchecked($move)
    }

    # Fills one video card. The card's children live inside a ControlTemplate, so they
    # are reached through Template.FindName rather than the window's name scope --
    # ApplyTemplate() first, because before the template is realised FindName returns
    # $null and every assignment below would silently do nothing.
    #
    # The card's current temp frame is parked on its own Tag rather than in a script-scoped
    # table: -OnReady is invoked from UI-WPF.psm1's module scope, so a $script: variable
    # written there is a different variable from the one read here and the old jpg is never
    # deleted (confirmed -- two files piled up in %TEMP% after two picks). A property on the
    # captured element has no such ambiguity. Same class of trap as the note in
    # VideoProcessing.psm1 about command lookup inside these callbacks.
    function Set-VideoCard {
        param($Card, [string]$Path, [hashtable]$Properties, $Context)

        $Card.ApplyTemplate() | Out-Null
        $text = Format-VideoMetadata -Properties $Properties

        $Card.Template.FindName("PART_Name", $Card).Text       = [System.IO.Path]::GetFileName($Path)
        $Card.Template.FindName("PART_Resolution", $Card).Text = $text.Resolution
        $Card.Template.FindName("PART_FrameRate", $Card).Text  = $text.FrameRate
        $Card.Template.FindName("PART_Length", $Card).Text     = $text.Length
        $Card.Template.FindName("PART_Size", $Card).Text       = $text.Size

        # Start from the placeholder every time: the previous file's frame must never
        # linger next to a new file's details.
        $image = $Card.Template.FindName("PART_Thumb", $Card)
        $image.Source = $null
        $image.Visibility = "Collapsed"
        $Card.Template.FindName("PART_Placeholder", $Card).Visibility = "Visible"
        $Card.Visibility = "Visible"

        # Drop the previous temp frame for this card now that nothing displays it.
        if ($Card.Tag) {
            Remove-Item -LiteralPath $Card.Tag -Force -ErrorAction SilentlyContinue
            $Card.Tag = $null
        }

        if ($Properties.Duration -is [timespan]) {
            Start-VideoThumbnail -Context $Context -InputFile $Path -Duration $Properties.Duration -OnReady {
                param($jpg)
                # OnLoad copies the bytes into memory and releases the file, so the temp
                # jpg can be deleted later instead of being locked for the session.
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.UriSource = New-Object System.Uri($jpg)
                $bmp.EndInit()
                $image.Source = $bmp
                $image.Visibility = "Visible"
                $Card.Template.FindName("PART_Placeholder", $Card).Visibility = "Collapsed"
                $Card.Tag = $jpg
            }.GetNewClosure() | Out-Null
        }
    }

    function Hide-VideoCard {
        param($Card)
        $Card.Visibility = "Collapsed"
    }

    # Draws the recent-files rows for one panel. Rebuilt from scratch on every call
    # rather than diffed: the list is three items long, and rebuilding means there is
    # no stale-row state to get wrong.
    function Update-RecentList {
        param($Card, $Container, [scriptblock]$OnFile, $MessageBlock)

        # An install updated in place can have new code against old XAML: the
        # self-updater refreshes this script and the modules, but a window built
        # from a stale MainWindow.xaml has no CardRecent*/PanelRecent* elements to
        # find, so FindName returns $null here. Bail out quietly instead of
        # dereferencing null and taking the whole startup down with it.
        if (-not $Card -or -not $Container) { return }

        $Container.Children.Clear()
        $entries = @(Get-RecentFiles)

        # Nothing recorded yet: the whole card goes away so a first run looks exactly
        # like the app did before this feature.
        if ($entries.Count -eq 0) {
            $Card.Visibility = "Collapsed"
            return
        }
        $Card.Visibility = "Visible"

        $now = Get-Date
        $isFirst = $true

        foreach ($entry in $entries) {
            # A hand-edited settings.json can produce an entry with no Path (or a
            # "RecentFiles": "garbage" string value, which @(...) turns into a
            # one-element string array with no .Path at all). Skip it rather than
            # building a nameless row whose click later throws.
            if (-not $entry -or [string]::IsNullOrWhiteSpace($entry.Path)) { continue }

            $row = New-Object System.Windows.Controls.Button
            $row.Style = $ctx.Window.FindResource("RecentRowButtonStyle")

            $grid = New-Object System.Windows.Controls.Grid
            $textColumn = New-Object System.Windows.Controls.ColumnDefinition
            $textColumn.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            $pillColumn = New-Object System.Windows.Controls.ColumnDefinition
            $pillColumn.Width = [System.Windows.GridLength]::Auto
            $grid.ColumnDefinitions.Add($textColumn)
            $grid.ColumnDefinitions.Add($pillColumn)

            $stack = New-Object System.Windows.Controls.StackPanel

            $name = New-Object System.Windows.Controls.TextBlock
            $name.Text = [System.IO.Path]::GetFileName($entry.Path)
            $name.Foreground = $ctx.Window.FindResource("BrushTextPrimary")
            $name.FontFamily = $ctx.Window.FindResource("FontChrome")
            $name.FontSize = 12.5
            $name.FontWeight = "SemiBold"
            # A long filename must not push the MOST RECENT pill off the card.
            $name.TextTrimming = "CharacterEllipsis"
            $stack.Children.Add($name) | Out-Null

            # A When that will not parse (hand-edited settings.json) must not take the
            # whole list down with it -- the row is still useful without an age.
            $age = ""
            try { $age = " " + [char]0xB7 + " " + (Format-RecentAge -When ([datetime]::Parse($entry.When)) -Now $now) } catch { }

            $sub = New-Object System.Windows.Controls.TextBlock
            $sub.Text = "$($entry.Job)$age"
            $sub.Foreground = $ctx.Window.FindResource("BrushTextMuted")
            $sub.FontFamily = $ctx.Window.FindResource("FontData")
            $sub.FontSize = 10
            $sub.Margin = New-Object System.Windows.Thickness 0, 1, 0, 0
            $stack.Children.Add($sub) | Out-Null

            [System.Windows.Controls.Grid]::SetColumn($stack, 0)
            $grid.Children.Add($stack) | Out-Null

            if ($isFirst) {
                $pill = New-Object System.Windows.Controls.Border
                $pill.Style = $ctx.Window.FindResource("RecentPillStyle")
                $pillText = New-Object System.Windows.Controls.TextBlock
                $pillText.Text = "MOST RECENT"
                # Gold text on a gold tint, matching the DETECTED chip, rather than dark
                # text on solid gold: the filled version dominated the row it labels.
                $pillText.Foreground = $ctx.Window.FindResource("BrushGoldValue")
                $pillText.FontFamily = $ctx.Window.FindResource("FontChrome")
                $pillText.FontSize = 9.5
                $pillText.FontWeight = "SemiBold"
                $pill.Child = $pillText
                [System.Windows.Controls.Grid]::SetColumn($pill, 1)
                $grid.Children.Add($pill) | Out-Null
                $isFirst = $false
            }

            $row.Content = $grid

            # GetNewClosure() is required here and safe: unlike the -OnFile blocks this
            # writes no $script: variables, and without it every row would capture the
            # loop variable's final value and all three would open the same file.
            $rowPath = $entry.Path
            $row.Add_Click({
                # No up-front existence check by design -- the list draws instantly from
                # settings.json. A file that has since moved fails here instead.
                if (-not (Test-Path -LiteralPath $rowPath)) {
                    Show-PanelMessage -Block $MessageBlock -IsError -Text "That file is no longer there."
                    Remove-RecentFile -Path $rowPath
                    Update-AllRecentLists
                    return
                }
                if ((& $OnFile $rowPath) -eq $false) {
                    Remove-RecentFile -Path $rowPath
                    Update-AllRecentLists
                }
            }.GetNewClosure())

            $Container.Children.Add($row) | Out-Null
        }
    }

    # All three panels share one list, so a change on any of them redraws all of them.
    # Cheap enough to do unconditionally: three rows, no disk or ffmpeg work.
    function Update-AllRecentLists {
        Update-RecentList -Card $cardRecentCompress -Container $panelRecentCompress -OnFile $onCompressFile -MessageBlock $textCompressMeta
        Update-RecentList -Card $cardRecentMerge -Container $panelRecentMerge -OnFile $onMergeFile -MessageBlock $textMergeMeta
        Update-RecentList -Card $cardRecentTrim -Container $panelRecentTrim -OnFile $onTrimFile -MessageBlock $textTrimMeta
    }

    # The dropzones say "drag and drop", so they have to actually accept a drop, not just
    # a click. Both routes funnel into the same OnFile handler.
    function Register-Dropzone {
        param($Button, [scriptblock]$OnFile)

        $Button.AllowDrop = $true
        $Button.Add_DragOver({
            param($eventSource, $e)
            $e.Effects = if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
                [System.Windows.DragDropEffects]::Copy
            } else {
                [System.Windows.DragDropEffects]::None
            }
            $e.Handled = $true
        })
        $Button.Add_Drop({
            param($eventSource, $e)
            if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
            $paths = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
            if ($paths.Count -gt 0) { & $OnFile $paths[0] }
            $e.Handled = $true
        }.GetNewClosure())

        $Button.Add_Click({
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Filter = "Video files (*.mp4;*.mkv;*.mov)|*.mp4;*.mkv;*.mov|All files (*.*)|*.*"
            if ($dialog.ShowDialog()) { & $OnFile $dialog.FileName }
        }.GetNewClosure())
    }

    # ---------------- Navigation ----------------
    foreach ($name in @("Compress", "MergeAudio", "Trim", "YouTubeMP3", "YouTubeMP4", "Settings")) {
        $panelName = $name
        $ctx.NavButtons[$panelName].Add_Click({
            Show-Panel -Context $ctx -Name $panelName
            # Settings is the only screen with anything to refresh on entry. Show-Panel
            # itself stays generic -- it is shared by all six screens and must not learn
            # about tool updates.
            if ($panelName -eq "Settings") { Update-ToolsCard }
            if ($panelName -in @("Compress", "MergeAudio", "Trim")) { Update-AllRecentLists }
        }.GetNewClosure())
    }

    # Both the source and the output are recorded, as separate rows: the two common
    # follow-ups are running a different job on the same original, and chaining a
    # second job onto the result. Order matters -- the output is added last so it
    # lands on top with the MOST RECENT pill.
    $recordJob = {
        param($JobName, $SourcePath, $OutputPath)
        # -NoSave on the source: two Save-Settings calls per finished job means two
        # disk writes right as the UI thread would otherwise be busy redrawing, and
        # Save-Settings' failure handler can block the window for seconds. Adding
        # the output without -NoSave saves once, after both entries are recorded.
        Add-RecentFile -Path $SourcePath -Job $JobName -NoSave
        Add-RecentFile -Path $OutputPath -Job $JobName
        Update-AllRecentLists
    }

    # ---------------- Compress ----------------
    $textCompressMeta = $panelCompress.FindName("TextCompressMeta")
    $buttonCompressStart = $panelCompress.FindName("ButtonCompressStart")
    $presetControls = @{
        "High Quality" = $panelCompress.FindName("ButtonPresetHigh")
        "Balanced"     = $panelCompress.FindName("ButtonPresetBalanced")
        "Small Size"   = $panelCompress.FindName("ButtonPresetSmall")
    }
    $presetDetailBlocks = @{
        "High Quality" = $panelCompress.FindName("TextPresetDetailHigh")
        "Balanced"     = $panelCompress.FindName("TextPresetDetailBalanced")
        "Small Size"   = $panelCompress.FindName("TextPresetDetailSmall")
    }

    $presetTravel = $panelCompress.FindName("PresetTravel")
    $presetTravelShift = $panelCompress.FindName("PresetTravelShift")

    # Slides the gold outline onto the chosen card and cross-fades that card's tint and
    # check badge in, the previous card's out. The fade matters as much as the slide: with
    # the outline alone, mid-transition it sits in the gutter between two cards and nothing
    # on screen looks selected.
    function Move-PresetHighlight {
        param($Target)

        if (-not $Target -or $Target.ActualWidth -le 0) { return }

        foreach ($card in $presetControls.Values) {
            $card.ApplyTemplate() | Out-Null
            $fill  = $card.Template.FindName("SelectedFill", $card)
            $badge = $card.Template.FindName("CheckBadge", $card)
            $to = if ($card -eq $Target) { 1 } else { 0 }
            if ($fill)  { Set-AnimatedDouble -Target $fill  -Property ([System.Windows.UIElement]::OpacityProperty) -To $to }
            if ($badge) { Set-AnimatedDouble -Target $badge -Property ([System.Windows.UIElement]::OpacityProperty) -To $to }
        }

        # Measured against the shared parent every time rather than cached, so the outline
        # still lands correctly after the window is resized and the columns change width.
        $origin = $Target.TranslatePoint((New-Object System.Windows.Point 0, 0), $presetTravel.Parent)
        $presetTravel.Height = $Target.ActualHeight
        $presetTravel.Opacity = 1

        Set-AnimatedDouble -Target $presetTravelShift -Property ([System.Windows.Media.TranslateTransform]::XProperty) -To $origin.X
        Set-AnimatedDouble -Target $presetTravel -Property ([System.Windows.FrameworkElement]::WidthProperty) -To $Target.ActualWidth
    }

    foreach ($presetButton in $presetControls.Values) {
        $presetButton.Add_Checked({ param($eventSource, $e) Move-PresetHighlight -Target $eventSource }.GetNewClosure())
    }

    # Puts the outline on the checked card without animating: used for the first paint, and
    # again whenever the cards change width. The outline's width and offset are only
    # recomputed when Move-PresetHighlight runs, so without the resize hook it keeps the
    # geometry it was given and visibly no longer fits its card (confirmed: seated at the
    # default window width, then maximizing left it 21px short of the card's right edge).
    function Reset-PresetHighlight {
        $checkedPreset = ($presetControls.Values | Where-Object { $_.IsChecked } | Select-Object -First 1)
        if (-not $checkedPreset) { return }
        $wasAnimated = $global:ShowAnimations
        $global:ShowAnimations = $false
        Move-PresetHighlight -Target $checkedPreset
        $global:ShowAnimations = $wasAnimated
    }

    $panelCompress.Add_Loaded({ Reset-PresetHighlight }.GetNewClosure())
    $presetTravel.Parent.Add_SizeChanged({ Reset-PresetHighlight }.GetNewClosure())

    # The detail line depends on the active codec, so it is refreshed rather than set once.
    function Update-PresetDetails {
        $details = Get-CompressionPresetDetails
        foreach ($presetName in $details.Keys) {
            $presetDetailBlocks[$presetName].Text = $details[$presetName]
        }
    }

    $cardCompress = $panelCompress.FindName("CardCompressVideo")

    # No GetNewClosure() on these -OnFile blocks, deliberately. It looks harmless -- the
    # handler does capture panel variables -- but it binds the scriptblock to a fresh
    # dynamic module, and then "$script:CompressInputFile = $path" writes into THAT
    # module's scope while the Compress button's own handler reads the real script scope.
    # The button then silently does nothing on every click. Left unbound, the panel
    # variables resolve through the caller's scope chain, which is how $textCompressMeta
    # has always worked here.
    # Extracted to a variable so the recent-files rows can invoke the identical
    # handler. Still no GetNewClosure() -- see the note above about $script: writes
    # landing in a dynamic module and silently disabling the start button.
    $onCompressFile = {
        param($path)
        $props = Get-VideoProperties -inputFile $path
        if (-not $props) {
            Show-PanelMessage -Block $textCompressMeta -IsError `
                -Text "Could not read that file. Is it a valid video?"
            Hide-VideoCard -Card $cardCompress
            $buttonCompressStart.IsEnabled = $false
            return $false
        }
        $script:CompressInputFile = $path
        $script:CompressVideoProps = $props
        Show-PanelMessage -Block $textCompressMeta -Text ""
        Set-VideoCard -Card $cardCompress -Path $path -Properties $props -Context $ctx
        $buttonCompressStart.IsEnabled = $true
        return $true
    }

    Register-Dropzone -Button $panelCompress.FindName("ButtonCompressBrowse") -OnFile $onCompressFile

    $buttonCompressStart.Add_Click({
        if (-not $script:CompressInputFile) { return }
        $selected = ($presetControls.GetEnumerator() | Where-Object { $_.Value.IsChecked } | Select-Object -First 1)
        if (-not $selected) { return }
        Register-Job (Compress-VideoAsync -Context $ctx -InputFile $script:CompressInputFile `
            -Preset $selected.Key -VideoProps $script:CompressVideoProps `
            -OnFinished { param($src, $out) & $recordJob "Compress" $src $out }.GetNewClosure())
    })

    # GPU mode is offered only where it can actually be used, same as the console version.
    $systemSpecs = Get-SystemSpecs
    if ($systemSpecs.GPU.Name -match "NVIDIA") {
        $panelCompress.FindName("TextGpuName").Text = $systemSpecs.GPU.Name
        $panelCompress.FindName("CardGpuMode").Visibility = "Visible"
        $toggleGpu = $panelCompress.FindName("ToggleGpuMode")
        Register-ToggleSwitch -Toggle $toggleGpu
        $toggleGpu.Add_Click({
            Set-CompressionMode -Mode $(if ($toggleGpu.IsChecked) { "NVIDIA" } else { "CPU" })
            Update-PresetDetails
        }.GetNewClosure())
    }
    Update-PresetDetails

    # ---------------- Merge Audio ----------------
    $textMergeMeta = $panelMerge.FindName("TextMergeMeta")
    $cardMerge = $panelMerge.FindName("CardMergeVideo")
    # Extracted to a variable so the recent-files rows can invoke the identical
    # handler. Still no GetNewClosure() -- see the note above about $script: writes
    # landing in a dynamic module and silently disabling the start button.
    $onMergeFile = {
        param($path)
        # Reading the properties is new here: the card needs them. It also means an
        # unreadable file is now caught at pick time rather than by ffmpeg mid-merge.
        $props = Get-VideoProperties -inputFile $path
        if (-not $props) {
            Show-PanelMessage -Block $textMergeMeta -IsError `
                -Text "Could not read that file. Is it a valid video?"
            Hide-VideoCard -Card $cardMerge
            return $false
        }
        $script:MergeInputFile = $path
        Show-PanelMessage -Block $textMergeMeta -Text ""
        Set-VideoCard -Card $cardMerge -Path $path -Properties $props -Context $ctx
        return $true
    }

    Register-Dropzone -Button $panelMerge.FindName("ButtonMergeBrowse") -OnFile $onMergeFile

    $panelMerge.FindName("ButtonMergeStart").Add_Click({
        if (-not $script:MergeInputFile) {
            Show-PanelMessage -Block $textMergeMeta -Text "Pick a video first." -IsError
            return
        }
        # Index-aligned with the ComboBox items in MainWindow.xaml.
        $volumeMap = @(1.0, 2.0, 3.5, 5.0)
        $sysIndex = [Math]::Max(0, $panelMerge.FindName("ComboSystemVolume").SelectedIndex)
        $micIndex = [Math]::Max(0, $panelMerge.FindName("ComboMicVolume").SelectedIndex)
        Register-Job (Merge-AudioStreamsAsync -Context $ctx -InputVideo $script:MergeInputFile `
            -SystemVolume $volumeMap[$sysIndex] -MicVolume $volumeMap[$micIndex] `
            -OnFinished { param($src, $out) & $recordJob "Merge Audio" $src $out }.GetNewClosure())
    })

    # ---------------- Trim ----------------
    $textTrimMeta = $panelTrim.FindName("TextTrimMeta")

    $cardTrimEditor      = $panelTrim.FindName("CardTrimEditor")
    $mediaTrimPreview    = $panelTrim.FindName("MediaTrimPreview")
    $buttonTrimPlay      = $panelTrim.FindName("ButtonTrimPlay")
    $textTrimPosition    = $panelTrim.FindName("TextTrimPosition")
    $canvasTrimTimeline  = $panelTrim.FindName("CanvasTrimTimeline")
    $canvasTrimRuler     = $panelTrim.FindName("CanvasTrimRuler")
    $textTrimPieces      = $panelTrim.FindName("TextTrimPieces")
    $textTrimSelection   = $panelTrim.FindName("TextTrimSelection")
    $textTrimAccuracy    = $panelTrim.FindName("TextTrimAccuracy")
    $buttonTrimSplit     = $panelTrim.FindName("ButtonTrimSplit")
    $buttonTrimDelete    = $panelTrim.FindName("ButtonTrimDelete")
    $buttonTrimUndo      = $panelTrim.FindName("ButtonTrimUndo")
    $buttonTrimExport    = $panelTrim.FindName("ButtonTrimExport")

    # An install updated in place can run new code against old XAML, in which case every
    # lookup above is $null and the first handler to fire takes the app down. Same guard
    # as Update-RecentList carries, for the same reason.
    $script:TrimEditorReady = ($null -ne $cardTrimEditor -and $null -ne $canvasTrimTimeline -and $null -ne $mediaTrimPreview)

    function Format-TrimTime {
        param([double]$Seconds)
        $ts = [timespan]::FromSeconds([math]::Max(0, $Seconds))
        return ("{0:D2}:{1:D2}.{2:D3}" -f $ts.Minutes, $ts.Seconds, $ts.Milliseconds)
    }

    # Compact ruler label -- the full MM:SS.mmm from Format-TrimTime is too busy repeated
    # every tick. Sub-second intervals (deep zoom) keep one decimal; anything coarser drops
    # the fraction entirely.
    function Format-TrimRulerLabel {
        param([double]$Seconds, [double]$Interval)
        $ts = [timespan]::FromSeconds([math]::Max(0, $Seconds))
        # Not [int]$ts.TotalMinutes: PowerShell's [int] cast on a double ROUNDS rather than
        # truncates, so 45s (TotalMinutes 0.75) came out as "1:45" instead of "0:45".
        # Hours*60 + Minutes is exact and needs no cast.
        $totalMinutes = $ts.Hours * 60 + $ts.Minutes
        if ($Interval -lt 1) {
            return ("{0}:{1:D2}.{2}" -f $totalMinutes, $ts.Seconds, [int]($ts.Milliseconds / 100))
        }
        return ("{0}:{1:D2}" -f $totalMinutes, $ts.Seconds)
    }

    # Smallest "nice" interval that still keeps ruler labels legibly apart at the current
    # zoom. $MinPixelGap is a target, not a guarantee -- the last tick before the view's
    # right edge can land closer than that.
    function Get-TrimRulerInterval {
        param([double]$ViewSpanSeconds, [double]$CanvasWidth, [double]$MinPixelGap = 85)
        $niceSteps = @(0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600)
        if ($CanvasWidth -le 0 -or $ViewSpanSeconds -le 0) { return $niceSteps[0] }
        $maxTicks = [math]::Max(1, $CanvasWidth / $MinPixelGap)
        $rawInterval = $ViewSpanSeconds / $maxTicks
        foreach ($step in $niceSteps) {
            if ($step -ge $rawInterval) { return $step }
        }
        return $niceSteps[-1]
    }

    # Time and pixels are converted through the current view window, which is what zoom
    # changes. Everything else in the panel works in seconds and never in pixels.
    function Convert-TrimTimeToX {
        param([double]$Seconds)
        $w = $canvasTrimTimeline.ActualWidth
        if ($script:TrimViewSpan -le 0 -or $w -le 0) { return 0 }
        return (($Seconds - $script:TrimViewStart) / $script:TrimViewSpan) * $w
    }

    function Convert-TrimXToTime {
        param([double]$X)
        $w = $canvasTrimTimeline.ActualWidth
        if ($w -le 0) { return 0 }
        return $script:TrimViewStart + ($X / $w) * $script:TrimViewSpan
    }

    # The timeline is drawn compacted -- surviving pieces sit back-to-back with no gap,
    # matching what Export actually produces, rather than at their real spread-out
    # positions in the source file. These three converters are the seam between that
    # compacted "timeline space" (what's drawn, zoomed, and clicked) and real "source
    # space" (what Find-NearestKeyframe snaps against and what MediaElement.Position
    # seeks). Everything in this panel that touches pixels works in timeline space now;
    # everything that touches the actual file works in source space.
    function Get-TrimTimelinePieces {
        param([object[]]$Pieces)
        $cursor = 0.0
        $result = foreach ($p in @($Pieces)) {
            $duration = $p.End - $p.Start
            [PSCustomObject]@{
                TimelineStart = $cursor
                TimelineEnd   = $cursor + $duration
                SourceStart   = $p.Start
                SourceEnd     = $p.End
            }
            $cursor += $duration
        }
        return ,@($result)
    }

    # A source second that falls inside deleted footage (a "gap") snaps to the end of
    # the nearest surviving piece before it -- there is no timeline position for footage
    # that will not be in the export.
    function Convert-TrimSourceToTimeline {
        param([double]$SourceSeconds, [object[]]$TimelinePieces)
        $pieces = @($TimelinePieces)
        if ($pieces.Count -eq 0) { return 0 }
        foreach ($p in $pieces) {
            if ($SourceSeconds -ge $p.SourceStart -and $SourceSeconds -le $p.SourceEnd) {
                return $p.TimelineStart + ($SourceSeconds - $p.SourceStart)
            }
        }
        $before = @($pieces | Where-Object { $_.SourceEnd -le $SourceSeconds } | Select-Object -Last 1)
        if ($before.Count -gt 0) { return $before[0].TimelineEnd }
        return $pieces[0].TimelineStart
    }

    function Convert-TrimTimelineToSource {
        param([double]$TimelineSeconds, [object[]]$TimelinePieces)
        $pieces = @($TimelinePieces)
        if ($pieces.Count -eq 0) { return 0 }
        foreach ($p in $pieces) {
            if ($TimelineSeconds -ge $p.TimelineStart -and $TimelineSeconds -le $p.TimelineEnd) {
                return $p.SourceStart + ($TimelineSeconds - $p.TimelineStart)
            }
        }
        # Timeline space has no gaps, so only clamping past either edge lands here.
        if ($TimelineSeconds -lt $pieces[0].TimelineStart) { return $pieces[0].SourceStart }
        return $pieces[-1].SourceEnd
    }

    # Single source of truth for "what are the pieces right now" -- every call site that
    # used to read $script:TrimCutList directly now goes through this, so the @(...)
    # unwrap guard (see the note in Update-TrimTimeline) and the timeline-space
    # conversion only have to be right in one place.
    function Get-TrimTimelineState {
        $pieces = @(if ($null -eq $script:TrimCutList) { @() } else { @($script:TrimCutList) })
        $timelinePieces = Get-TrimTimelinePieces -Pieces $pieces
        $totalDuration = if ($timelinePieces.Count -gt 0) { $timelinePieces[-1].TimelineEnd } else { 0 }
        return [PSCustomObject]@{
            Pieces         = $pieces
            TimelinePieces = $timelinePieces
            TotalDuration  = $totalDuration
        }
    }

    # Write-through helpers, for the same reason Set-TrimKeyframes exists: the handlers
    # that call these are inside GetNewClosure()'d blocks (they must be -- they capture a
    # per-piece $index), and a bare $script: write in there lands in the closure's own
    # private module where the drawing code would never see it.
    function Set-TrimSelection {
        param([int]$Index)
        $script:TrimSelected = $Index
    }

    function Set-TrimView {
        param([double]$Start, [double]$Span)
        $script:TrimViewStart = $Start
        $script:TrimViewSpan = $Span
    }

    # Rebuilt from scratch on every change: a handful of pieces, so there is nothing to
    # gain from diffing and no stale-element state to get wrong.
    function Update-TrimTimeline {
        if (-not $script:TrimEditorReady) { return }
        $canvasTrimTimeline.Children.Clear()

        $h = $canvasTrimTimeline.ActualHeight
        if ($h -le 0) { $h = 62 }

        # Not @($script:TrimCutList): before a file is picked that variable is $null, and
        # @($null) is a ONE-element array holding $null, not an empty one. Without this the
        # SizeChanged handler below -- which fires during first layout -- would draw a stray
        # piece from a $null .Start/.End and the readout would claim "1 piece".
        #
        # Outer @(...) is load-bearing, not decorative: an if/else's output flows through
        # the success stream, so a single-element array in either branch collapses back to
        # a bare PSCustomObject on assignment -- then .Count is $null (PS 5.1 has no ETS
        # Count on a scalar), the for-loop below never runs, and Export silently disables.
        # Measured live: this was happening on every fresh file load, before any split.
        $state = Get-TrimTimelineState
        $pieces = $state.Pieces
        $timelinePieces = $state.TimelinePieces

        # A delete shrinks the total timeline duration. The view window (what zoom
        # controls) does not shrink on its own, so without this the ruler and the empty
        # canvas past the last piece would keep showing however much space the OLD,
        # longer timeline used to span.
        if ($state.TotalDuration -gt 0) {
            if ($script:TrimViewSpan -gt $state.TotalDuration) { $script:TrimViewSpan = $state.TotalDuration }
            if ($script:TrimViewStart + $script:TrimViewSpan -gt $state.TotalDuration) {
                $script:TrimViewStart = [math]::Max(0, $state.TotalDuration - $script:TrimViewSpan)
            }
        }

        for ($i = 0; $i -lt $pieces.Count; $i++) {
            $tp = $timelinePieces[$i]
            $x1 = Convert-TrimTimeToX -Seconds $tp.TimelineStart
            $x2 = Convert-TrimTimeToX -Seconds $tp.TimelineEnd
            $width = [math]::Max(1, $x2 - $x1)

            $rect = New-Object System.Windows.Shapes.Rectangle
            $styleName = if ($i -eq $script:TrimSelected) { "TimelinePieceSelectedStyle" } else { "TimelinePieceStyle" }
            $rect.Style = $ctx.Window.FindResource($styleName)
            $rect.Width = $width
            $rect.Height = $h - 8
            $rect.RadiusX = 4; $rect.RadiusY = 4
            [System.Windows.Controls.Canvas]::SetLeft($rect, $x1)
            [System.Windows.Controls.Canvas]::SetTop($rect, 4)

            # GetNewClosure is required: without it every piece captures the loop
            # variable's final value and clicking any piece selects the last one. The
            # selection write goes through Set-TrimSelection for the reason noted there.
            #
            # Deliberately NOT marking the event handled: the pieces cover the whole track,
            # so swallowing it here would mean the canvas handler never runs and the track
            # could not be scrubbed at all. A click both selects the piece and moves the
            # playhead to where it landed.
            $index = $i
            $rect.Add_MouseLeftButtonDown({
                Set-TrimSelection -Index $index
                $buttonTrimDelete.IsEnabled = $true
                Update-TrimSelectionText
                Update-TrimTimeline
            }.GetNewClosure())

            $canvasTrimTimeline.Children.Add($rect) | Out-Null

            # A cut line on every internal boundary.
            if ($i -gt 0) {
                $line = New-Object System.Windows.Shapes.Rectangle
                $line.Style = $ctx.Window.FindResource("TimelineCutLineStyle")
                $line.Height = $h
                [System.Windows.Controls.Canvas]::SetLeft($line, $x1 - 1)
                [System.Windows.Controls.Canvas]::SetTop($line, 0)
                $canvasTrimTimeline.Children.Add($line) | Out-Null
            }
        }

        $playheadTimeline = Convert-TrimSourceToTimeline -SourceSeconds $script:TrimPlayhead -TimelinePieces $timelinePieces
        $playX = Convert-TrimTimeToX -Seconds $playheadTimeline
        if ($playX -ge 0 -and $playX -le $canvasTrimTimeline.ActualWidth) {
            $head = New-Object System.Windows.Shapes.Rectangle
            $head.Style = $ctx.Window.FindResource("TimelinePlayheadStyle")
            $head.Height = $h
            [System.Windows.Controls.Canvas]::SetLeft($head, $playX - 1)
            [System.Windows.Controls.Canvas]::SetTop($head, 0)
            $canvasTrimTimeline.Children.Add($head) | Out-Null
        }

        # Ruler: ticks + compact time labels below the track, the only way to read a
        # position on the timeline without looking at the numeric readout above it.
        # Redrawn from scratch alongside the track for the same reason the track is --
        # a handful of ticks, nothing worth diffing.
        if ($null -ne $canvasTrimRuler) {
            $canvasTrimRuler.Children.Clear()
            $rulerWidth = $canvasTrimTimeline.ActualWidth
            if ($rulerWidth -gt 0 -and $script:TrimViewSpan -gt 0) {
                $interval = Get-TrimRulerInterval -ViewSpanSeconds $script:TrimViewSpan -CanvasWidth $rulerWidth
                $viewEnd = $script:TrimViewStart + $script:TrimViewSpan
                $tickTime = [math]::Ceiling($script:TrimViewStart / $interval) * $interval
                while ($tickTime -le $viewEnd) {
                    $tx = Convert-TrimTimeToX -Seconds $tickTime
                    if ($tx -ge 0 -and $tx -le $rulerWidth) {
                        $tick = New-Object System.Windows.Shapes.Rectangle
                        $tick.Style = $ctx.Window.FindResource("TimelineRulerTickStyle")
                        [System.Windows.Controls.Canvas]::SetLeft($tick, $tx)
                        [System.Windows.Controls.Canvas]::SetTop($tick, 0)
                        $canvasTrimRuler.Children.Add($tick) | Out-Null

                        $label = New-Object System.Windows.Controls.TextBlock
                        $label.Text = Format-TrimRulerLabel -Seconds $tickTime -Interval $interval
                        $label.FontFamily = $ctx.Window.FindResource("FontData")
                        $label.FontSize = 11
                        $label.Foreground = $ctx.Window.FindResource("BrushTextMuted")
                        [System.Windows.Controls.Canvas]::SetLeft($label, $tx + 3)
                        [System.Windows.Controls.Canvas]::SetTop($label, 7)
                        $canvasTrimRuler.Children.Add($label) | Out-Null
                    }
                    $tickTime += $interval
                }
            }
        }

        $textTrimPieces.Text = if ($pieces.Count -eq 1) { "1 piece" } else { "$($pieces.Count) pieces" }
        # The input-file test is not redundant with the count: it keeps Export disabled
        # during the first layout pass, before anything has been picked.
        $buttonTrimExport.IsEnabled = ($pieces.Count -gt 0 -and $null -ne $script:TrimInputFile)
    }

    function Update-TrimSelectionText {
        if (-not $script:TrimEditorReady) { return }
        $state = Get-TrimTimelineState
        if ($script:TrimSelected -lt 0 -or $script:TrimSelected -ge $state.Pieces.Count) {
            $textTrimSelection.Text = "nothing selected"
            return
        }
        # Timeline-space bounds, matching the ruler and the drawn timeline (which are also
        # timeline-space now) -- not the piece's real position in the source file.
        $tp = $state.TimelinePieces[$script:TrimSelected]
        $textTrimSelection.Text = ("selected {0} to {1} ({2:N2}s)" -f (Format-TrimTime $tp.TimelineStart), (Format-TrimTime $tp.TimelineEnd), ($tp.TimelineEnd - $tp.TimelineStart))
    }

    # Snapshot before every change. Cloning matters: the pieces are objects and a shallow
    # copy of the array would let undo hand back a list whose contents were mutated.
    function Push-TrimUndo {
        $snapshot = @(@($script:TrimCutList) | ForEach-Object { [PSCustomObject]@{ Start = $_.Start; End = $_.End } })
        [void]$script:TrimUndoStack.Add(@{ List = $snapshot; Selected = $script:TrimSelected })
        $buttonTrimUndo.IsEnabled = $true
    }

    function Invoke-TrimSplit {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        # Snap first, so the cut line is drawn exactly where the file can be cut.
        $at = Find-NearestKeyframe -Keyframes $script:TrimKeyframes -Seconds $script:TrimPlayhead
        $before = @($script:TrimCutList).Count
        $candidate = Split-CutList -List $script:TrimCutList -AtSeconds $at
        # A split on an existing boundary or in a gap is a no-op; do not spend an undo
        # slot on a keystroke that changed nothing.
        if (@($candidate).Count -eq $before) { return }
        Push-TrimUndo
        $script:TrimCutList = $candidate
        # The old selection indexed the pre-split list, so it now points at the wrong
        # piece. Dropping it is the honest option -- silently keeping the index would
        # arm Delete against footage the user never clicked.
        $script:TrimSelected = -1
        $buttonTrimDelete.IsEnabled = $false
        Update-TrimSelectionText
        Update-TrimTimeline
    }

    function Invoke-TrimDelete {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        if ($script:TrimSelected -lt 0) { return }
        Push-TrimUndo
        $script:TrimCutList = Remove-CutPiece -List $script:TrimCutList -Index $script:TrimSelected
        $script:TrimSelected = -1
        $buttonTrimDelete.IsEnabled = $false

        # The playhead can now be sitting inside the footage that was just removed.
        # Round-tripping it through timeline space snaps it onto the nearest surviving
        # piece -- a no-op if it was already on one -- so the preview never shows a
        # frame that will not be in the export.
        $state = Get-TrimTimelineState
        if ($state.TimelinePieces.Count -gt 0) {
            $tl = Convert-TrimSourceToTimeline -SourceSeconds $script:TrimPlayhead -TimelinePieces $state.TimelinePieces
            $script:TrimPlayhead = Convert-TrimTimelineToSource -TimelineSeconds $tl -TimelinePieces $state.TimelinePieces
            $mediaTrimPreview.Position = [timespan]::FromSeconds($script:TrimPlayhead)
            Update-TrimPosition
        }

        Update-TrimSelectionText
        Update-TrimTimeline
    }

    function Invoke-TrimUndo {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        if ($script:TrimUndoStack.Count -eq 0) { return }
        $last = $script:TrimUndoStack[$script:TrimUndoStack.Count - 1]
        $script:TrimUndoStack.RemoveAt($script:TrimUndoStack.Count - 1)
        $script:TrimCutList = @($last.List)
        $script:TrimSelected = $last.Selected
        $buttonTrimDelete.IsEnabled = ($script:TrimSelected -ge 0)
        $buttonTrimUndo.IsEnabled = ($script:TrimUndoStack.Count -gt 0)
        Update-TrimSelectionText
        Update-TrimTimeline
    }

    function Update-TrimPosition {
        # Timeline-space, matching the ruler and the drawn track: how far into the
        # assembled EXPORT the playhead is, not how far into the raw source file.
        $state = Get-TrimTimelineState
        $tl = Convert-TrimSourceToTimeline -SourceSeconds $script:TrimPlayhead -TimelinePieces $state.TimelinePieces
        $textTrimPosition.Text = "$(Format-TrimTime $tl) / $(Format-TrimTime $state.TotalDuration)"
    }

    # Small write-through so the async-read tick handler below never assigns $script:
    # directly from inside its own GetNewClosure()'d block. GetNewClosure() rebinds bare
    # $script: writes into that block's own private dynamic module -- the same failure
    # mode as the -OnFile note above -- so a plain top-level function is what actually
    # makes the write visible to Update-TrimTimeline and the rest of the panel.
    function Set-TrimKeyframes {
        param([double[]]$Keyframes)
        $script:TrimKeyframes = $Keyframes
    }

    # Reads keyframes off the UI thread: on a long recording this decodes the whole index
    # and would otherwise freeze the window. Until it lands, snapping is inactive and the
    # accuracy line stays blank -- the editor is usable throughout.
    function Start-TrimKeyframeRead {
        param([string]$Path)

        $textTrimAccuracy.Text = "reading keyframes..."
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file)
            Import-Module $modulePath -Force
            Get-KeyframeTimes -InputFile $file
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($Path) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(250)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            # Kept as a local rather than re-read from $script: afterwards -- inside this
            # closure $script: writes and reads both resolve against GetNewClosure()'s own
            # private module, not the real script scope, so re-reading here would risk
            # picking up that private copy instead of what Set-TrimKeyframes just wrote.
            $keyframes = try { @($ps.EndInvoke($handle)) } catch { @() }
            $ps.Dispose()
            Set-TrimKeyframes -Keyframes $keyframes
            if ($keyframes.Count -gt 1) {
                $gaps = for ($i = 1; $i -lt $keyframes.Count; $i++) {
                    $keyframes[$i] - $keyframes[$i-1]
                }
                $avg = ($gaps | Measure-Object -Average).Average
                $textTrimAccuracy.Text = ("cuts land on the nearest keyframe, every {0:N2}s in this file" -f $avg)
            } else {
                $textTrimAccuracy.Text = "keyframes unknown; cuts may shift"
            }
        }.GetNewClosure())
        $watcher.Start()
    }

    # Drives the playhead while playing. A timer rather than a MediaElement event because
    # MediaElement raises nothing per frame -- Position must be polled.
    #
    # No GetNewClosure() here, deliberately -- same reasoning as the tool-install
    # OnComplete block below: this writes $script:TrimPlayhead directly, and a closure
    # would rebind that write into its own private module where Update-TrimPosition (a
    # real top-level function) would never see it. Nothing here needs closure capture
    # anyway: this block is defined at the top-level try scope, which outlives the app,
    # so $mediaTrimPreview and friends resolve through the normal scope chain.
    #
    # Everything below is gated on $script:TrimEditorReady: on XAML that predates Task 4,
    # $buttonTrimPlay and $mediaTrimPreview are $null, and .Add_Click()/.Add_MediaEnded()
    # on a $null reference throws during startup, before the window ever shows.
    if ($script:TrimEditorReady) {
        # Keeps the preview at exactly 16:9 (the source format) and full card width,
        # instead of a fixed height that either letterboxes or crops depending on how
        # wide the card ends up being. Fires on every layout pass, including window
        # resize, so it never drifts back out of sync.
        $mediaTrimPreview.Add_SizeChanged({
            param($eventSource, $e)
            if ($e.NewSize.Width -gt 0) {
                $mediaTrimPreview.Height = $e.NewSize.Width * 9 / 16
            }
        })

        # WPF MediaElement quirk, confirmed live: the very FIRST Play() after a fresh
        # Source assignment always resumes from the start, ignoring any Position set
        # beforehand -- even a plain scrub (no split/delete involved) to 1:43 then Play
        # played from 0. LoadedBehavior="Manual" does not save it; Position while paused
        # is only enough to render a single scrub-preview frame, not to seed the
        # internal cursor real playback resumes from. Playing and immediately pausing
        # once, the moment each file's media actually becomes ready, "warms up" that
        # cursor so every Play() after this -- including the user's very first click --
        # honors Position correctly. Fires once per file load, not once per app launch:
        # a second file gets a fresh Source and needs its own warm-up.
        $mediaTrimPreview.Add_MediaOpened({
            $mediaTrimPreview.Play()
            # A back-to-back Play()/Pause() with no real time between them does not
            # reliably warm up the pipeline either -- gives the decoder a genuine 80ms
            # to actually start producing frames first.
            $warmup = New-Object System.Windows.Threading.DispatcherTimer
            $warmup.Interval = [timespan]::FromMilliseconds(80)
            $warmup.Add_Tick({
                $warmup.Stop()
                $mediaTrimPreview.Pause()
                $mediaTrimPreview.Position = [timespan]::Zero
            }.GetNewClosure())
            $warmup.Start()
        })

        $script:TrimTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:TrimTimer.Interval = [timespan]::FromMilliseconds(50)
        $script:TrimTimer.Add_Tick({
            $script:TrimPlayhead = $mediaTrimPreview.Position.TotalSeconds

            # MediaElement plays the raw source file start to finish -- it has no idea
            # a piece was deleted, so ordinary playback runs straight off the end of one
            # surviving piece and into the deleted footage after it. Catch that here and
            # jump to the next surviving piece (or stop, past the last one) so playback
            # matches what Export will actually produce.
            $state = Get-TrimTimelineState
            $containing = @($state.TimelinePieces | Where-Object {
                $script:TrimPlayhead -ge $_.SourceStart -and $script:TrimPlayhead -lt $_.SourceEnd
            })
            if ($containing.Count -eq 0 -and $state.TimelinePieces.Count -gt 0) {
                $next = @($state.TimelinePieces | Where-Object { $_.SourceStart -gt $script:TrimPlayhead } | Select-Object -First 1)
                if ($next.Count -gt 0) {
                    $script:TrimPlayhead = $next[0].SourceStart
                    $mediaTrimPreview.Position = [timespan]::FromSeconds($script:TrimPlayhead)
                } else {
                    $mediaTrimPreview.Pause()
                    $buttonTrimPlay.Content = "Play"
                    $script:TrimTimer.Stop()
                }
            }

            Update-TrimPosition
            Update-TrimTimeline
        })

        $buttonTrimPlay.Add_Click({
            if ($buttonTrimPlay.Content -eq "Play") {
                $mediaTrimPreview.Play()
                $buttonTrimPlay.Content = "Pause"
                $script:TrimTimer.Start()
            } else {
                $mediaTrimPreview.Pause()
                $buttonTrimPlay.Content = "Play"
                $script:TrimTimer.Stop()
            }
        }.GetNewClosure())

        $mediaTrimPreview.Add_MediaEnded({
            $mediaTrimPreview.Pause()
            $buttonTrimPlay.Content = "Play"
            $script:TrimTimer.Stop()
        }.GetNewClosure())

        # Scrubbing. A click on a piece bubbles down to here too, so one click both selects
        # that piece and moves the playhead -- see the note on the piece handler.
        #
        # No GetNewClosure() on these two, same reason as the timer tick above: they write
        # $script: state, which a closure would rebind into its own private module. Nothing
        # here needs capture -- they are defined at the top-level try scope.
        $canvasTrimTimeline.Add_MouseLeftButtonDown({
            param($eventSource, $e)
            if (-not $script:TrimInputFile) { return }
            $state = Get-TrimTimelineState
            $pos = $e.GetPosition($canvasTrimTimeline)
            # The click lands in timeline (compacted) space; convert to a real source
            # second before seeking, so a click can never target deleted footage.
            $t = Convert-TrimXToTime -X $pos.X
            $tClamped = [math]::Max(0, [math]::Min($state.TotalDuration, $t))
            $script:TrimPlayhead = Convert-TrimTimelineToSource -TimelineSeconds $tClamped -TimelinePieces $state.TimelinePieces
            $mediaTrimPreview.Position = [timespan]::FromSeconds($script:TrimPlayhead)
            Update-TrimPosition
            Update-TrimTimeline
        })

        # Ctrl + wheel zooms around the pointer; a bare wheel is left alone so the panel
        # still scrolls the way every other screen does.
        $canvasTrimTimeline.Add_PreviewMouseWheel({
            param($eventSource, $e)
            if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -eq 0) { return }
            if (-not $script:TrimInputFile) { return }
            $state = Get-TrimTimelineState
            if ($state.TotalDuration -le 0) { return }
            $e.Handled = $true

            # Anchor and span are both timeline (compacted) seconds -- zoom operates on
            # the same space the ruler and track are drawn in.
            $anchor = Convert-TrimXToTime -X ($e.GetPosition($canvasTrimTimeline)).X
            $factor = if ($e.Delta -gt 0) { 0.8 } else { 1.25 }
            # Floor of 0.5s: below that the pieces are narrower than their own borders.
            $newSpan = [math]::Max(0.5, [math]::Min($state.TotalDuration, $script:TrimViewSpan * $factor))

            $ratio = if ($script:TrimViewSpan -gt 0) { ($anchor - $script:TrimViewStart) / $script:TrimViewSpan } else { 0.5 }
            # Keep the window inside the clip.
            $newStart = [math]::Max(0, [math]::Min($state.TotalDuration - $newSpan, $anchor - ($ratio * $newSpan)))
            Set-TrimView -Start $newStart -Span $newSpan
            Update-TrimTimeline
        })

        # The canvas has no width until it is laid out, so the first paint must wait for it,
        # and a resize invalidates every x already computed.
        $canvasTrimTimeline.Add_SizeChanged({ Update-TrimTimeline })

        $buttonTrimSplit.Add_Click({ Invoke-TrimSplit })
        $buttonTrimDelete.Add_Click({ Invoke-TrimDelete })
        $buttonTrimUndo.Add_Click({ Invoke-TrimUndo })

        # Handled at the window, then filtered to the Trim panel: the Canvas cannot hold
        # focus reliably and a panel-level handler would miss keys pressed over the preview.
        # Guarded on TextBox focus so typing a URL on another screen never triggers a split.
        $ctx.Window.Add_PreviewKeyDown({
            param($eventSource, $e)
            if ($ctx.Panels.Trim.Visibility -ne "Visible") { return }
            if (-not $script:TrimInputFile) { return }
            if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }

            $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0

            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::Z) { Invoke-TrimUndo; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::S -and -not $ctrl) { Invoke-TrimSplit; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::Delete) { Invoke-TrimDelete; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::Space) {
                $buttonTrimPlay.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                $e.Handled = $true
            }
        })
    }

    # Extracted to a variable so the recent-files rows can invoke the identical
    # handler. Still no GetNewClosure() -- see the note above about $script: writes
    # landing in a dynamic module and silently disabling the start button.
    $onTrimFile = {
        param($path)
        if (-not $script:TrimEditorReady) { return $false }

        $props = Get-VideoProperties -inputFile $path
        if (-not $props) {
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text "Could not read that file. Is it a valid video?"
            $cardTrimEditor.Visibility = "Collapsed"
            return $false
        }

        $script:TrimInputFile = $path
        $script:TrimDuration = $props.Duration.TotalSeconds
        $script:TrimCutList = New-CutList -Duration $script:TrimDuration
        $script:TrimUndoStack = New-Object System.Collections.ArrayList
        $script:TrimSelected = -1
        $script:TrimPlayhead = 0.0
        $script:TrimViewStart = 0.0
        $script:TrimViewSpan = $script:TrimDuration
        # Empty until the async read lands; Find-NearestKeyframe treats that as "no
        # snapping" rather than "cannot cut".
        $script:TrimKeyframes = @()

        Show-PanelMessage -Block $textTrimMeta -Text ""
        $cardTrimEditor.Visibility = "Visible"
        $mediaTrimPreview.Source = New-Object System.Uri($path)
        $mediaTrimPreview.Pause()
        $buttonTrimExport.IsEnabled = $true
        # Picking a second file must not leave the previous file's selection on screen,
        # nor its Delete button live against an index into a cut list that is now gone.
        $buttonTrimDelete.IsEnabled = $false
        Update-TrimPosition
        Update-TrimSelectionText
        Update-TrimTimeline
        Start-TrimKeyframeRead -Path $path
        return $true
    }

    Register-Dropzone -Button $panelTrim.FindName("ButtonTrimBrowse") -OnFile $onTrimFile

    $cardRecentCompress = $panelCompress.FindName("CardRecentCompress")
    $panelRecentCompress = $panelCompress.FindName("PanelRecentCompress")
    $cardRecentMerge = $panelMerge.FindName("CardRecentMerge")
    $panelRecentMerge = $panelMerge.FindName("PanelRecentMerge")
    $cardRecentTrim = $panelTrim.FindName("CardRecentTrim")
    $panelRecentTrim = $panelTrim.FindName("PanelRecentTrim")

    Update-AllRecentLists

    if ($script:TrimEditorReady) {
        $buttonTrimExport.Add_Click({
            if (-not $script:TrimInputFile) {
                Show-PanelMessage -Block $textTrimMeta -Text "Pick a video first." -IsError
                return
            }
            $pieces = @($script:TrimCutList)
            if ($pieces.Count -eq 0) {
                Show-PanelMessage -Block $textTrimMeta -IsError `
                    -Text "Nothing left to export -- every piece was deleted."
                return
            }
            Show-PanelMessage -Block $textTrimMeta -Text ""
            Register-Job (Export-CutListAsync -Context $ctx -InputFile $script:TrimInputFile -Pieces $pieces `
                -OnFinished { param($src, $out) & $recordJob "Trim" $src $out }.GetNewClosure())
        })
    }

    # ---------------- YouTube MP3 ----------------
    $panelYtMp3.FindName("ButtonYoutubeMP3Start").Add_Click({
        $url = $panelYtMp3.FindName("TextYoutubeMP3Url").Text.Trim()
        $status = $panelYtMp3.FindName("TextYoutubeMP3Status")
        if ($url -notmatch '^https?://') {
            Show-PanelMessage -Block $status -Text "Enter a full video URL starting with http." -IsError
            return
        }
        Register-Job (Save-YouTubeMP3Async -Context $ctx -Url $url)
    })

    # ---------------- YouTube MP4 ----------------
    $comboQuality = $panelYtMp4.FindName("ComboYoutubeMP4Quality")
    $buttonMp4Start = $panelYtMp4.FindName("ButtonYoutubeMP4Start")
    $statusMp4 = $panelYtMp4.FindName("TextYoutubeMP4Status")

    $panelYtMp4.FindName("ButtonYoutubeMP4Fetch").Add_Click({
        $url = $panelYtMp4.FindName("TextYoutubeMP4Url").Text.Trim()
        if ($url -notmatch '^https?://') {
            Show-PanelMessage -Block $statusMp4 -Text "Enter a full video URL starting with http." -IsError
            return
        }

        Show-PanelMessage -Block $statusMp4 -Text "Looking up available qualities..."
        # Blocks the UI thread briefly. Acceptable for a short metadata call, and far
        # simpler than marshalling a background runspace for a one-shot lookup.
        $ctx.Window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $script:YoutubeMP4Resolutions = @(Get-YouTubeResolutions -Url $url)
        } catch {
            $script:YoutubeMP4Resolutions = @()
        } finally {
            $ctx.Window.Cursor = $null
        }

        $comboQuality.Items.Clear()
        foreach ($res in $script:YoutubeMP4Resolutions) {
            $comboQuality.Items.Add("$($res.name) ($($res.height)p)") | Out-Null
        }

        $found = $comboQuality.Items.Count -gt 0
        if ($found) { $comboQuality.SelectedIndex = 0 }
        $comboQuality.IsEnabled = $found
        $buttonMp4Start.IsEnabled = $found
        if ($found) {
            Show-PanelMessage -Block $statusMp4 -Text "$($comboQuality.Items.Count) qualities available"
        } else {
            Show-PanelMessage -Block $statusMp4 -Text "No downloadable formats found for that link." -IsError
        }
    })

    $buttonMp4Start.Add_Click({
        $url = $panelYtMp4.FindName("TextYoutubeMP4Url").Text.Trim()
        $index = $comboQuality.SelectedIndex
        if ($index -lt 0 -or $index -ge $script:YoutubeMP4Resolutions.Count) { return }
        Register-Job (Save-YouTubeMP4Async -Context $ctx -Url $url -Resolution $script:YoutubeMP4Resolutions[$index])
    })

    # ---------------- Settings ----------------
    $checkAnimations = $panelSettings.FindName("CheckShowAnimations")
    $checkAnimations.IsChecked = [bool]$global:ShowAnimations
    Register-ToggleSwitch -Toggle $checkAnimations
    $checkAnimations.Add_Click({
        $global:ShowAnimations = [bool]$checkAnimations.IsChecked
        Save-Settings
    }.GetNewClosure())

    $toolRows = @{
        ffmpeg    = @{ Version = $panelSettings.FindName("TextToolVersionFfmpeg")
                       Path = $panelSettings.FindName("TextToolPathFfmpeg")
                       Button = $panelSettings.FindName("ButtonUpdateFfmpeg") }
        ffprobe   = @{ Version = $panelSettings.FindName("TextToolVersionFfprobe")
                       Path = $panelSettings.FindName("TextToolPathFfprobe")
                       Button = $null }
        "yt-dlp"  = @{ Version = $panelSettings.FindName("TextToolVersionYtDlp")
                       Path = $panelSettings.FindName("TextToolPathYtDlp")
                       Button = $panelSettings.FindName("ButtonUpdateYtDlp") }
    }
    $toolsProgress = $panelSettings.FindName("ProgressBarTools")
    $toolsCancel = $panelSettings.FindName("ButtonToolsCancel")
    $toolsStatus = $panelSettings.FindName("TextToolsStatus")
    $binFolder = Join-Path $scriptRoot "bin"

    $script:LatestReleases = @{}
    $script:ToolInstallRunning = $false
    $script:ToolInstallState = $null
    # Kept as one string so the card can recognise its own stale warning and clear it
    # once the job ends, without clobbering an install result message sitting in the
    # same block.
    $script:JobGuardMessage = "Finish the job that's running before updating a tool."

    function Set-ToolRow {
        param([string]$Name, [hashtable]$Installed, [string]$ButtonText, [bool]$ButtonEnabled)

        $row = $toolRows[$Name]
        $row.Version.Text = $Installed.Display
        $row.Path.Text = switch ($Installed.Source) {
            "bin"    { "app folder" }
            "system" { "found on your PC: $($Installed.Path)" }
            default  { "not found" }
        }
        if ($row.Button) {
            $row.Button.Content = $ButtonText
            $row.Button.IsEnabled = $ButtonEnabled -and -not (Test-AnyJobRunning) -and -not $script:ToolInstallRunning
        }
    }

    # Rendered from cache when the last check was under an hour ago, so reopening
    # Settings costs nothing. -Force is what the "Couldn't check" retry uses.
    # Write-through for the same reason Set-TrimKeyframes exists: the tick handler below
    # is a .GetNewClosure()'d block, and a bare `$script:InstalledVersionsChecked = $true`
    # in there would land in that closure's own private module, invisible to every later
    # call to Update-ToolsCard -- which would then re-spawn all three processes on every
    # visit forever, exactly the bug this flag exists to prevent.
    function Set-InstalledVersionsChecked {
        $script:InstalledVersionsChecked = $true
    }

    # Write-through for the same reason: Update-ToolsCard's tick handler below is
    # .GetNewClosure()'d, and a bare `$script:LatestReleases[$name] = ...` in there
    # reads $script:LatestReleases against the closure's OWN private module -- which,
    # unlike the real script scope, never had it initialized, so the read comes back
    # $null and indexing into it throws "Cannot index into a null array". A plain
    # top-level function's `$script:` always resolves against the real script scope
    # regardless of who calls it, so routing the read through here and mutating the
    # hashtable it returns (a reference, not a copy) reaches the real one.
    function Set-LatestRelease {
        param([string]$Name, $Release)
        $script:LatestReleases[$Name] = $Release
    }

    function Get-LatestRelease {
        param([string]$Name)
        return $script:LatestReleases[$Name]
    }

    # Get-InstalledToolVersion actually launches ffmpeg/ffprobe/yt-dlp and waits for them
    # to exit, and Get-LatestToolRelease is a real network call -- neither is a cheap
    # file read. Both run on a background runspace (same shape as Start-TrimKeyframeRead)
    # so opening Settings never blocks the window, not even on the very first visit:
    # the panel shows "Checking…" instantly and the real values fill in a moment later.
    # The installed-version check is additionally skipped entirely after the first visit
    # each session (unless -Force, used right after an install completes, or when
    # Start-ToolInstall finds no cached release to install) -- installed binaries do not
    # change on their own mid-session, so there is nothing to re-spawn processes for.
    function Update-ToolsCard {
        param([switch]$Force)

        foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
            $placeholder = if ($toolRows[$name].Installed) { $toolRows[$name].Installed } `
                           else { @{ Display = "checking…"; Source = "missing"; Path = $null } }
            Set-ToolRow -Name $name -Installed $placeholder -ButtonText "Checking…" -ButtonEnabled $false
        }

        $useCache = (-not $Force) -and $global:ToolCheckCache -and `
                    (Test-ToolCacheFresh -Timestamp $global:ToolCheckCache.CheckedUtc -MaxAgeMinutes 60)
        $needInstalled = $Force -or -not $script:InstalledVersionsChecked
        $cachedTools = if ($global:ToolCheckCache) { $global:ToolCheckCache.Tools } else { $null }

        # Written into directly by the background script below, rather than returned
        # through EndInvoke -- EndInvoke hands back a PSDataCollection wrapper, and
        # accessing properties through it via PowerShell's single-item collection
        # auto-forwarding proved genuinely unreliable live (one property on it read
        # back fine, a second property on that exact same collection came back $null,
        # and a third run hung rather than reporting either). A plain Hashtable that
        # both runspaces hold the same reference to sidesteps that boundary completely:
        # the background script fills it in directly, and nothing is read from it until
        # $handle.IsCompleted is true, by which point that write has already happened.
        $shared = [hashtable]::Synchronized(@{ Installed = @{}; Latest = @{} })

        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $scriptRoot, $needInstalled, $useCache, $cachedTools, $shared)
            Import-Module $modulePath -Force

            if ($needInstalled) {
                foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
                    $shared.Installed[$name] = Get-InstalledToolVersion -Name $name -ScriptRoot $scriptRoot
                }
            }

            foreach ($name in @("ffmpeg", "yt-dlp")) {
                if ($useCache -and $cachedTools -and $cachedTools.$name) {
                    $cached = $cachedTools.$name
                    # Re-parse the timestamp exactly as Get-LatestToolRelease did, so the
                    # cached and freshly-fetched paths yield the identical value. A plain
                    # [datetime] cast would read ffmpeg's trailing "Z" and convert it to
                    # local time, leaving it hours ahead of the date-only installed build
                    # -- east of UTC that pins ffmpeg on "Update ->" forever, west of it
                    # hides a genuinely newer build.
                    $restored = [datetime]::MinValue
                    [void][datetime]::TryParse($cached.Version,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                        [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$restored)
                    $shared.Latest[$name] = @{ Name = $name; Version = $restored.Date; Display = $cached.Display
                                                DownloadUrl = $cached.DownloadUrl; AssetName = $cached.AssetName }
                } else {
                    # No separate "did it fail" flag: a name simply absent from
                    # $shared.Latest (never assigned, because this threw) means the
                    # same thing.
                    try { $shared.Latest[$name] = Get-LatestToolRelease -Name $name } catch { }
                }
            }
        }).AddArgument((Join-Path $scriptRoot "backend\ToolUpdates.psm1")).AddArgument($scriptRoot).AddArgument($needInstalled).AddArgument($useCache).AddArgument($cachedTools).AddArgument($shared) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(100)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()

            if ($needInstalled) {
                foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
                    $installed = $shared.Installed[$name]
                    $toolRows[$name].Installed = $installed
                    Set-ToolRow -Name $name -Installed $installed -ButtonText "Checking…" -ButtonEnabled $false
                }
                Set-InstalledVersionsChecked
            }

            foreach ($name in @("ffmpeg", "yt-dlp")) {
                $latest = $shared.Latest[$name]
                Set-LatestRelease -Name $name -Release $latest

                if (-not $latest) {
                    Set-ToolRow -Name $name -Installed $toolRows[$name].Installed `
                        -ButtonText "Couldn't check" -ButtonEnabled $true
                    continue
                }

                $verdict = Test-ToolUpdate -Installed $toolRows[$name].Installed -Latest $latest
                switch ($verdict.Status) {
                    "Current"   { Set-ToolRow -Name $name -Installed $verdict.Installed -ButtonText "Up to date" -ButtonEnabled $false }
                    "Available" { Set-ToolRow -Name $name -Installed $verdict.Installed -ButtonText "Update → $($latest.Display)" -ButtonEnabled $true }
                    default     { Set-ToolRow -Name $name -Installed $verdict.Installed -ButtonText "Install" -ButtonEnabled $true }
                }
            }

            if (-not $useCache) {
                $tools = @{}
                foreach ($name in @("ffmpeg", "yt-dlp")) {
                    $r = Get-LatestRelease -Name $name
                    if ($r) {
                        $tools[$name] = @{ Version = $r.Version.ToString("o"); Display = $r.Display
                                           DownloadUrl = $r.DownloadUrl; AssetName = $r.AssetName }
                    }
                }
                if ($tools.Count -gt 0) {
                    $global:ToolCheckCache = @{ CheckedUtc = ([datetime]::UtcNow.ToString("o")); Tools = $tools }
                    Save-Settings
                }
            }

            if (Test-AnyJobRunning) {
                Show-PanelMessage -Block $toolsStatus -Text $script:JobGuardMessage
            } elseif ($toolsStatus.Text -eq $script:JobGuardMessage) {
                # The job has since finished. Clear only this warning -- an "Updated to
                # ..." message set moments earlier by OnComplete must survive.
                Show-PanelMessage -Block $toolsStatus -Text ""
            }
        }.GetNewClosure())
        $watcher.Start()
    }

    function Start-ToolInstall {
        param([string]$Name)

        $release = $script:LatestReleases[$Name]
        if (-not $release) { Update-ToolsCard -Force; return }
        if (Test-AnyJobRunning) {
            Show-PanelMessage -Block $toolsStatus -Text $script:JobGuardMessage -IsError
            return
        }

        $script:ToolInstallRunning = $true
        $toolRows[$Name].Button.IsEnabled = $false
        if ($toolRows["ffmpeg"].Button) { $toolRows["ffmpeg"].Button.IsEnabled = $false }
        if ($toolRows["yt-dlp"].Button) { $toolRows["yt-dlp"].Button.IsEnabled = $false }
        $toolsProgress.Value = 0
        $toolsProgress.Visibility = "Visible"
        $toolsCancel.Visibility = "Visible"
        $toolsCancel.IsEnabled = $true
        Show-PanelMessage -Block $toolsStatus -Text "Downloading $Name…"

        $script:ToolInstallState = Install-ToolUpdate -Context $ctx -Release $release -BinFolder $binFolder `
            -OnProgress {
                param($received, $total)
                if ($total -gt 0) {
                    $toolsProgress.Value = [math]::Round(($received / $total) * 100, 1)
                    $toolRows[$Name].Button.Content = "{0:N0}%" -f $toolsProgress.Value
                } else {
                    $toolRows[$Name].Button.Content = "{0:N1} MB" -f ($received / 1MB)
                }
            }.GetNewClosure() `
            -OnComplete {
                param($success, $message)
                # No .GetNewClosure() on this block, deliberately. Inside a closure,
                # $script: binds to the closure's own dynamic module, so the two resets
                # below would never reach the copies Set-ToolRow reads and every update
                # button would stay disabled until the app restarted. OnProgress above
                # still needs its closure -- it captures $Name, which dies with this
                # function; this block captures nothing.
                $script:ToolInstallRunning = $false
                $script:ToolInstallState = $null
                $toolsProgress.Visibility = "Collapsed"
                $toolsCancel.Visibility = "Collapsed"
                $toolsCancel.IsEnabled = $false
                Show-PanelMessage -Block $toolsStatus -Text $message -IsError:(-not $success)
                # Re-reads the exe from disk, so the version shown is what actually
                # landed rather than what was expected to land.
                Update-ToolsCard
            }
    }

    # Guarded for the same reason as Update-RecentList and $script:TrimEditorReady: an
    # install updated in place can run this code against a MainWindow.xaml that predates
    # these buttons, and Add_Click on a $null reference takes startup down before the
    # window ever shows. ffprobe has no button by design, which is why $toolRows already
    # tolerates a $null there.
    if ($null -ne $toolRows["ffmpeg"].Button) {
        $toolRows["ffmpeg"].Button.Add_Click({ Start-ToolInstall -Name "ffmpeg" })
    }
    if ($null -ne $toolRows["yt-dlp"].Button) {
        $toolRows["yt-dlp"].Button.Add_Click({ Start-ToolInstall -Name "yt-dlp" })
    }

    # Cancelling faults the in-flight copy; Install-ToolUpdate's next tick observes that,
    # deletes the partial file and calls OnComplete, so the reset all happens there.
    $toolsCancel.Add_Click({
        $toolsCancel.IsEnabled = $false
        if ($script:ToolInstallState) { & $script:ToolInstallState.Cancel }
    })

    Show-Panel -Context $ctx -Name "Compress"
    $ctx.Window.ShowDialog() | Out-Null
}
catch {
    # With the console hidden there is nowhere for an unhandled error to surface, so a
    # startup failure would otherwise look like the app simply never opening.
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "FFmpeg GUI could not start.`n`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)",
        "FFmpeg GUI", "OK", "Error") | Out-Null
}
