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
    $script:TrimTotalSeconds = $null
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
    $cardTrim = $panelTrim.FindName("CardTrimVideo")
    # Extracted to a variable so the recent-files rows can invoke the identical
    # handler. Still no GetNewClosure() -- see the note above about $script: writes
    # landing in a dynamic module and silently disabling the start button.
    $onTrimFile = {
        param($path)
        $script:TrimInputFile = $path
        $props = Get-VideoProperties -inputFile $path
        # Still set even when null: the timestamp validation reads it and treats a null
        # total as "length unknown" rather than rejecting outright.
        $script:TrimTotalSeconds = if ($props) { $props.Duration.TotalSeconds } else { $null }
        if (-not $props) {
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text "Could not read that file. Is it a valid video?"
            Hide-VideoCard -Card $cardTrim
            return $false
        }
        Show-PanelMessage -Block $textTrimMeta -Text ""
        Set-VideoCard -Card $cardTrim -Path $path -Properties $props -Context $ctx
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

    $panelTrim.FindName("ButtonTrimStart").Add_Click({
        if (-not $script:TrimInputFile) {
            Show-PanelMessage -Block $textTrimMeta -Text "Pick a video first." -IsError
            return
        }

        # Same validation the console version did before handing the timestamp to ffmpeg:
        # a malformed or out-of-range value otherwise produces an empty output file.
        $timestamp = $panelTrim.FindName("TextTrimTimestamp").Text.Trim()
        if ($timestamp -notmatch '^\d{2}:\d{2}:\d{2}$') {
            Show-PanelMessage -Block $textTrimMeta -Text "Timestamp must look like HH:MM:SS." -IsError
            return
        }

        $seconds = ([timespan]::Parse($timestamp)).TotalSeconds
        if ($seconds -le 0) {
            Show-PanelMessage -Block $textTrimMeta -Text "Timestamp must be later than 00:00:00." -IsError
            return
        }
        if ($null -ne $script:TrimTotalSeconds -and $seconds -ge $script:TrimTotalSeconds) {
            $total = [timespan]::FromSeconds($script:TrimTotalSeconds)
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text ("Timestamp is past the end of the video (" + $total.ToString("hh\:mm\:ss") + ").")
            return
        }

        $mode = if ($panelTrim.FindName("RadioTrimBefore").IsChecked) { "Before" } else { "After" }
        Register-Job (Split-VideoAsync -Context $ctx -InputFile $script:TrimInputFile -Mode $mode -Timestamp $timestamp `
            -OnFinished { param($src, $out) & $recordJob "Trim" $src $out }.GetNewClosure())
    })

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
    function Update-ToolsCard {
        param([switch]$Force)

        foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
            $installed = Get-InstalledToolVersion -Name $name -ScriptRoot $scriptRoot
            $toolRows[$name].Installed = $installed
            Set-ToolRow -Name $name -Installed $installed -ButtonText "Checking…" -ButtonEnabled $false
        }

        $useCache = (-not $Force) -and $global:ToolCheckCache -and `
                    (Test-ToolCacheFresh -Timestamp $global:ToolCheckCache.CheckedUtc -MaxAgeMinutes 60)

        foreach ($name in @("ffmpeg", "yt-dlp")) {
            $latest = $null
            $failed = $false

            if ($useCache -and $global:ToolCheckCache.Tools.$name) {
                $cached = $global:ToolCheckCache.Tools.$name
                # Re-parse the timestamp exactly as Get-LatestToolRelease did, so the cached
                # and freshly-fetched paths yield the identical value. A plain [datetime]
                # cast would read ffmpeg's trailing "Z" and convert it to local time, leaving
                # it hours ahead of the date-only installed build -- east of UTC that pins
                # ffmpeg on "Update ->" forever, west of it hides a genuinely newer build.
                $restored = [datetime]::MinValue
                [void][datetime]::TryParse($cached.Version,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                    [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$restored)
                $latest = @{ Name = $name; Version = $restored.Date; Display = $cached.Display
                             DownloadUrl = $cached.DownloadUrl; AssetName = $cached.AssetName }
            } else {
                # The window is unresponsive for the ~0.5s this takes. That is deliberate:
                # a 58-82 KB request is far too small to justify a second async path, and
                # the cursor change makes the pause legible.
                $ctx.Window.Cursor = [System.Windows.Input.Cursors]::Wait
                try { $latest = Get-LatestToolRelease -Name $name }
                catch { $failed = $true }
                finally { $ctx.Window.Cursor = $null }
            }

            $script:LatestReleases[$name] = $latest

            if ($failed) {
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
                $r = $script:LatestReleases[$name]
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
            # The job has since finished. Clear only this warning -- an "Updated to ..."
            # message set moments earlier by OnComplete must survive.
            Show-PanelMessage -Block $toolsStatus -Text ""
        }
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

    $toolRows["ffmpeg"].Button.Add_Click({ Start-ToolInstall -Name "ffmpeg" })
    $toolRows["yt-dlp"].Button.Add_Click({ Start-ToolInstall -Name "yt-dlp" })

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
