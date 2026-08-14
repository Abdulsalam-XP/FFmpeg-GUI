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
# Finished-successfully green. Distinct from both the error red and the muted grey every
# other panel message uses, so "it worked, here is the file" is not just more grey text.
$successBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x7A, 0xD9, 0xA5))
# Amber for warnings that do not stop anything (missing font, and the like): red implies
# the action failed, grey implies nothing happened -- neither is true for a heads-up.
$warningBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE0, 0xB4, 0x5C))

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
        param($Block, [string]$Text, [switch]$IsError, [switch]$IsSuccess, [switch]$IsWarning)
        $Block.Text = $Text
        # Error wins over success/warning if several are somehow passed -- a wrong "done"
        # is worse than a redundant red. Warning is for "heads up, still proceeding":
        # red on a message that says the export continues reads as a failed export.
        $Block.Foreground = if ($IsError) { $errorBrush } elseif ($IsWarning) { $warningBrush } elseif ($IsSuccess) { $successBrush } else { $mutedBrush }
        # Output paths are long and the meta blocks are single-line by default, so a
        # finished-job message would otherwise be silently truncated at the card edge --
        # cutting off the very thing the message exists to show.
        $Block.TextWrapping = "Wrap"
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
        # The Video Editor hides its recent card (and the dropzone) once a file is open
        # so the whole editor fits on screen; a recents refresh triggered by that very
        # load must not pop the card back up. Children are still rebuilt above, so the
        # list is current if it ever shows again.
        if ($null -ne $cardRecentTrim -and [object]::ReferenceEquals($Card, $cardRecentTrim) -and $script:TrimInputFile) {
            $Card.Visibility = "Collapsed"
        }

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

    # The end-of-job report: what happened, and where the file actually is. Size is read
    # off disk rather than trusted from the job, so a zero-byte output is visible as such
    # instead of being reported as a success.
    function Show-JobDone {
        param($Block, [string]$OutputPath)
        if (-not $Block) { return }
        $size = ""
        try {
            $bytes = (Get-Item -LiteralPath $OutputPath -ErrorAction Stop).Length
            $size = " ({0:N1} MB)" -f ($bytes / 1MB)
        } catch { }
        # Folder and filename on separate lines: the full path on one line wraps
        # mid-directory and is far harder to read back than "here, this file".
        Show-PanelMessage -Block $Block -IsSuccess -Text (
            "Done -- saved{0}`n{1}`n{2}" -f $size,
            [System.IO.Path]::GetFileName($OutputPath),
            (Split-Path $OutputPath -Parent))
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

        # A finished job used to announce itself only as "100.0%", which does not say
        # whether the file was actually written or where it went. Looked up by job name
        # rather than passed in by each call site: these blocks are declared further down
        # this same scope, so a hashtable built here would capture $null.
        $block = switch ($JobName) {
            "Compress"    { $textCompressMeta }
            "Merge Audio" { $textMergeMeta }
            "Trim"        { $textTrimMeta }
            default       { $null }
        }
        if ($block) { Show-JobDone -Block $block -OutputPath $OutputPath }
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

    # Gain sliders, in dB. Both directions: the old combos could only amplify.
    $sliderSystemVolume = $panelMerge.FindName("SliderSystemVolume")
    $sliderMicVolume    = $panelMerge.FindName("SliderMicVolume")
    $textSystemVolume   = $panelMerge.FindName("TextSystemVolume")
    $textMicVolume      = $panelMerge.FindName("TextMicVolume")

    # Older XAML has the ComboBoxes instead, and a stale MainWindow.xaml is a real case
    # here -- see Update-RecentList. Everything below is skipped rather than crashing
    # startup on .Add_ValueChanged against $null.
    $script:MergeSlidersReady = ($null -ne $sliderSystemVolume -and $null -ne $sliderMicVolume)

    if ($script:MergeSlidersReady) {
        # An explicit sign on the positive side: "6.0 dB" and "-6.0 dB" sitting in the
        # same column are easy to misread at a glance, "+6.0 dB" is not.
        $formatGain = {
            param($Value)
            if ($Value -gt 0) { "+{0:N1} dB" -f $Value } else { "{0:N1} dB" -f $Value }
        }

        $sliderSystemVolume.Add_ValueChanged({
            $textSystemVolume.Text = & $formatGain $sliderSystemVolume.Value
        }.GetNewClosure())
        $sliderMicVolume.Add_ValueChanged({
            $textMicVolume.Text = & $formatGain $sliderMicVolume.Value
        }.GetNewClosure())

        # Double-click to return to unity. A 0.5dB-snapped slider is fiddly to land back
        # on exactly 0 by dragging, and 0 is the value most sessions want on one of the
        # two tracks.
        $sliderSystemVolume.Add_MouseDoubleClick({ $sliderSystemVolume.Value = 0 }.GetNewClosure())
        $sliderMicVolume.Add_MouseDoubleClick({ $sliderMicVolume.Value = 0 }.GetNewClosure())
    }

    $panelMerge.FindName("ButtonMergeStart").Add_Click({
        if (-not $script:MergeInputFile) {
            Show-PanelMessage -Block $textMergeMeta -Text "Pick a video first." -IsError
            return
        }
        $systemDb = if ($script:MergeSlidersReady) { $sliderSystemVolume.Value } else { 0 }
        $micDb    = if ($script:MergeSlidersReady) { $sliderMicVolume.Value } else { 0 }
        Register-Job (Merge-AudioStreamsAsync -Context $ctx -InputVideo $script:MergeInputFile `
            -SystemVolumeDb $systemDb -MicVolumeDb $micDb `
            -OnFinished { param($src, $out) & $recordJob "Merge Audio" $src $out }.GetNewClosure())
    })

    # ---------------- Trim ----------------
    $textTrimMeta = $panelTrim.FindName("TextTrimMeta")

    $cardTrimEditor      = $panelTrim.FindName("CardTrimEditor")
    $mediaTrimPreview    = $panelTrim.FindName("MediaTrimPreview")
    $mediaTrimFadePreview = $panelTrim.FindName("MediaTrimFadePreview")
    $buttonTrimPlay      = $panelTrim.FindName("ButtonTrimPlay")
    $textTrimPosition    = $panelTrim.FindName("TextTrimPosition")
    $canvasTrimTimeline  = $panelTrim.FindName("CanvasTrimTimeline")
    $canvasTrimRuler     = $panelTrim.FindName("CanvasTrimRuler")
    $canvasTrimFades     = $panelTrim.FindName("CanvasTrimFades")
    $canvasTrimCaptions  = $panelTrim.FindName("CanvasTrimCaptions")
    $canvasTrimZooms     = $panelTrim.FindName("CanvasTrimZooms")
    $panelTrimLanes      = $panelTrim.FindName("PanelTrimTracks")
    $panelTrimAddTracks  = $panelTrim.FindName("PanelTrimAddTracks")
    $canvasTrimLaneOverlay = $panelTrim.FindName("CanvasTrimLaneOverlay")
    $previewZoomHost     = $panelTrim.FindName("PreviewZoomHost")
    $previewCell         = $panelTrim.FindName("PreviewCell")
    $panelTrimFadeLength = $panelTrim.FindName("PanelTrimFadeLength")
    $textTrimFadeNote    = $panelTrim.FindName("TextTrimFadeNote")
    $textTrimFadeScope   = $panelTrim.FindName("TextTrimFadeScope")
    $panelTrimTrackProps = $panelTrim.FindName("PanelTrimTrackProps")
    $textTrackPropsName  = $panelTrim.FindName("TextTrackPropsName")
    # The strip is CLIP-scoped now (spec 3.2 moved the row's gain/mute/eye/trash into the
    # lane headers), so what it carries is the clip's display mode and its delete.
    $buttonClipDisplayMode = $panelTrim.FindName("ButtonClipDisplayMode")
    $textClipDisplayHint   = $panelTrim.FindName("TextClipDisplayHint")
    $buttonTrackDelete   = $panelTrim.FindName("ButtonTrackDelete")
    $fadeLengthButtons   = @{
        0.25 = $panelTrim.FindName("ButtonFade025")
        0.5  = $panelTrim.FindName("ButtonFade050")
        1.0  = $panelTrim.FindName("ButtonFade100")
    }
    $textTrimPieces      = $panelTrim.FindName("TextTrimPieces")
    $textTrimSelection   = $panelTrim.FindName("TextTrimSelection")
    $textTrimAccuracy    = $panelTrim.FindName("TextTrimAccuracy")
    $buttonTrimSplit     = $panelTrim.FindName("ButtonTrimSplit")
    $buttonTrimDelete    = $panelTrim.FindName("ButtonTrimDelete")
    $buttonTrimUndo      = $panelTrim.FindName("ButtonTrimUndo")
    $buttonTrimRedo      = $panelTrim.FindName("ButtonTrimRedo")
    $buttonTrimExport    = $panelTrim.FindName("ButtonTrimExport")
    $buttonTrimAddCaption = $panelTrim.FindName("ButtonTrimAddCaption")
    $buttonTrimBrowse     = $panelTrim.FindName("ButtonTrimBrowse")
    $buttonTrimOpenAnother = $panelTrim.FindName("ButtonTrimOpenAnother")
    $buttonTrimAddZoom    = $panelTrim.FindName("ButtonTrimAddZoom")
    # Two add buttons (spec 4.3): an EMPTY lane is a first-class thing to want, so "+ track"
    # is no longer the same gesture as "+ media" -- the file dialog moved to the lane header's
    # own "Add media to this track..." (Invoke-TrimAddClip).
    $buttonTrimAddVideoTrack = $panelTrim.FindName("ButtonTrimAddVideoTrack")
    $buttonTrimAddAudioTrack = $panelTrim.FindName("ButtonTrimAddAudioTrack")
    $buttonTrimUnlink     = $panelTrim.FindName("ButtonTrimUnlink")
    # Still null-guarded everywhere (see Update-TrimSnapButton): a stale MainWindow.xaml from
    # an in-place update can predate these controls, the rule this whole block follows.
    $buttonTrimSnap       = $panelTrim.FindName("ButtonTrimSnap")
    $textTrimSnapGlyph    = $panelTrim.FindName("TextTrimSnapGlyph")
    $buttonCaptionDelete  = $panelTrim.FindName("ButtonCaptionDelete")
    $panelCaptionSidebar  = $panelTrim.FindName("PanelCaptionSidebar")
    $canvasCaptionOverlay = $panelTrim.FindName("CanvasCaptionOverlay")
    $textCaptionText      = $panelTrim.FindName("TextCaptionText")
    $comboCaptionFont     = $panelTrim.FindName("ComboCaptionFont")
    $checkCaptionBold     = $panelTrim.FindName("CheckCaptionBold")
    $textCaptionFill      = $panelTrim.FindName("TextCaptionFill")
    $textCaptionOutline   = $panelTrim.FindName("TextCaptionOutline")
    $panelCaptionFillSwatches    = $panelTrim.FindName("PanelCaptionFillSwatches")
    $panelCaptionOutlineSwatches = $panelTrim.FindName("PanelCaptionOutlineSwatches")
    $sliderCaptionOutlineW = $panelTrim.FindName("SliderCaptionOutlineW")
    $checkCaptionBounce   = $panelTrim.FindName("CheckCaptionBounce")
    $textCaptionStart     = $panelTrim.FindName("TextCaptionStart")
    $textCaptionEnd       = $panelTrim.FindName("TextCaptionEnd")

    # An install updated in place can run new code against old XAML, in which case every
    # lookup above is $null and the first handler to fire takes the app down. Same guard
    # as Update-RecentList carries, for the same reason.
    $script:TrimEditorReady = ($null -ne $cardTrimEditor -and $null -ne $canvasTrimTimeline -and $null -ne $mediaTrimPreview)

    # Crossfade state. Declared here, before the first Update-TrimTimeline can run during
    # initial layout: the drawing code reads both on every pass, including the one that
    # fires before any file has been picked.
    # Boundary source time -> that cut's fade length in seconds. $script:TrimFadeSeconds
    # is only the default for the next fade added, not a setting the existing ones follow.
    $script:TrimFades = @{}
    $script:TrimFadeSeconds = 0.5
    $script:TrimActiveFade = $null
    # Rendered crossfades for the preview: key -> file path, plus the in-flight set and
    # the key currently on screen so the overlay is only re-sourced when it really changes.
    $script:TrimFadeProxies = @{}
    $script:TrimFadeProxyPending = @{}
    $script:TrimFadeProxyDir = $null
    $script:TrimFadeOverlayKey = $null

    # Caption state. Declared beside the fade state and for the same reason: the lane is
    # drawn by Update-TrimTimeline, which runs during initial layout before any file has
    # been picked, so both of these have to exist by then.
    # $script:TrimSelectedCaption is a caption Id string (or $null), never an index --
    # indexes shift on add/delete the same way the fade keys avoid.
    $script:TrimCaptions = New-Object System.Collections.ArrayList
    $script:TrimSelectedCaption = $null
    # In-flight lane drag: $null when nothing is being dragged, otherwise a hashtable of
    # Id / Mode ("move" | "start" | "end") / StartX / OrigStart / OrigEnd / Snapshot.
    # The undo snapshot is taken when the drag BEGINS and only pushed on release, so a
    # drag costs exactly one undo step no matter how many MouseMove events it produced.
    $script:TrimCaptionDrag = $null
    # In-flight preview-overlay drag (move or resize), same shape and same one-undo-per-drag
    # rule as the lane drag above.
    $script:CaptionOverlayDrag = $null
    # Set while Show-CaptionSidebar is filling the fields: every control's change handler
    # fires on a programmatic assignment exactly as it does on a user edit, and without this
    # guard selecting a caption would write each field straight back and push undo steps for
    # edits nobody made.
    $script:CaptionSidebarLoading = $false
    # Focus/capture sessions for the two controls that would otherwise produce one undo step
    # per keystroke (the text box) or per slider tick (the outline width). Each holds the
    # snapshot taken when the session began, pushed on the way out only if it changed.
    $script:CaptionTextEdit = $null
    $script:CaptionSliderEdit = $null

    # Zoom keyframe state. Declared here beside the caption state and for exactly the same
    # reason: the zoom lane is drawn from Update-TrimTimeline, which runs during initial
    # layout before any file has been picked, so both of these have to exist by then.
    # $script:TrimSelectedZoom is a keyframe Id string (or $null), never an index --
    # indexes shift on add/delete and a drag re-sorts the list on every move.
    $script:TrimZooms = New-Object System.Collections.ArrayList
    $script:TrimSelectedZoom = $null
    # In-flight diamond drag: $null when nothing is being dragged, otherwise a hashtable of
    # Id / StartX / OrigTime / Snapshot. Snapshot taken when the drag BEGINS and pushed on
    # release only if the keyframe really moved -- one undo step per completed drag, the
    # same rule the caption lane drag follows.
    $script:TrimZoomDrag = $null
    # Spotlight box + floating pill state, declared here for the same "drawn during initial
    # layout" reason as everything above it.
    # The dim rects, the gold frame and the level badge are TRANSIENT: rebuilt from the model
    # on every redraw and tracked here so they can be pulled out of the shared overlay canvas
    # individually -- the captions draw on that same canvas and a blanket Children.Clear()
    # from the zoom side would wipe them.
    $script:ZoomBoxElements = New-Object System.Collections.ArrayList
    # In-flight drag-to-draw: $null, or a hashtable of StartX / StartY / Moved / Rect /
    # Snapshot. Same snapshot-at-down, push-on-release rule as every other drag here.
    $script:ZoomBoxDrag = $null
    # The pill, by contrast, is built ONCE and lives in the canvas for the whole session --
    # see Clear-CaptionOverlayChildren for why it must not be torn out and re-added.
    $script:ZoomPillBorder = $null
    $script:ZoomPillSlider = $null
    $script:ZoomPillValueText = $null
    $script:ZoomPillMagnetButton = $null
    # Magnet ON by default: resizing keeps the box video-shaped (uniform zoom) until the
    # user opts into free-stretch. Session-wide, not per keyframe -- it is a tool mode.
    $script:ZoomMagnet = $true
    # Set while the pill is being filled from the model: WPF raises ValueChanged for a
    # programmatic assignment exactly as it does for a user drag, so without this the redraw
    # that follows a box drag would write the slider's snapped value straight back over it.
    $script:ZoomUiLoading = $false
    # One undo step per slider capture session, not per tick: snapshot taken when the slider
    # grabs the mouse, pushed when it lets go and only if the level really changed.
    $script:ZoomSliderEdit = $null
    # A drag has to beat this before it counts as drawing a box; under it the press falls
    # through to the click behaviour (deselect), so a stray click still deselects.
    $script:ZoomBoxDragThreshold = 4.0
    # And the finished box has to be at least this wide to be committed -- a 12px box is a
    # 100x zoom nobody asked for, and reading it as a click is the safer interpretation.
    $script:ZoomBoxMinWidth = 40.0

    # NLE lane/clip state. Declared here beside the zoom/caption state and for the same
    # reason: the app must never hand -Lanes $null to Export-CutListAsync (the PS 5.1
    # @($null).Count -eq 1 trap), so this is always an ArrayList, never left $null, from
    # the moment the editor exists. Each lane's own Clips is an ArrayList too (see
    # Set-TrimLanes) so a clip can be added/removed in place without rebuilding the lane.
    $script:TrimLanes = New-Object System.Collections.ArrayList
    # A CLIP Id string (or $null), never an index -- same reasoning as TrimSelectedZoom:
    # indexes shift on add/delete and a lane reorder moves whole rows around.
    $script:TrimSelectedClip = $null
    # A LANE Id string (or $null): the header selection, mutually exclusive with the clip
    # selection (single gold selection, spec 3.3 -- see Set-TrimSelectedClip/Lane).
    $script:TrimSelectedLane = $null
    # laneId -> $true for every collapsed group (spec 4.1's caret). A hashtable rather than
    # a list so the render can test membership per row without a scan.
    $script:TrimCollapsedLanes = @{}
    # Timeline snapping (N / the toolbar magnet). Seeded from settings at startup; every
    # write goes through Set-TrimSnapEnabled so the global and settings.json follow.
    # Import-Config has already run by here and always sets the global (both branches and
    # its catch), so the $null check is belt-and-suspenders for a settings load that threw
    # before reaching it -- snapping defaults ON either way.
    $script:TrimSnapEnabled = $(if ($null -ne $global:TrimSnapEnabled) { [bool]$global:TrimSnapEnabled } else { $true })
    # Live clip drag state, same shape of lifecycle as TrimCaptionDrag/TrimZoomDrag: $null
    # when idle, a hashtable (ClipId, Mode, the pre-drag values of every link-group member,
    # the snap point set, a snapshot, and direct Canvas/Border references) while a clip bar
    # is being dragged.
    $script:TrimClipDrag = $null
    # clipId -> @{Border; Canvas} for every clip body Update-TrimLaneRows renders as a
    # single draggable bar. A drag reads it ONCE at mouse-down to find its linked peers'
    # own Borders (on their own row canvases) so the whole link group visibly travels in
    # one gesture. Rebuilt from scratch on every row rebuild, like the rows themselves.
    $script:TrimClipElements = @{}
    # The green snap flash Line (spec 4.8) while a drag is on a lock, else $null. Held so
    # it can be removed again without clearing the overlay canvas the playhead shares.
    $script:TrimSnapFlashLine = $null
    # True while the playhead is being DRAGGED on the timeline canvas (mouse held after a
    # press): every mouse move keeps scrubbing until release.
    $script:TrimScrubDrag = $false
    # Live lane-reorder (⋮⋮) drag state. Same $null-when-idle convention; the rows it moves
    # are whole group blocks, see Move-TrimLaneTo.
    $script:TrimLaneReorderDrag = $null
    # The gold insertion Line a live lane reorder draws between rows, else $null.
    $script:TrimLaneReorderLine = $null
    # Live fader edit on an audio row header. Holds the undo snapshot for the whole
    # gesture (drag or a burst of Up/Down presses) plus a Dragging flag: while a fader
    # drag holds the mouse, Update-TrimLaneRows must not rebuild the very canvas that
    # owns the capture, exactly as it must not during a clip drag.
    $script:TrimLaneGainEdit = $null
    # Debounce for keyboard gain: the undo bracket closes 600ms after the last key,
    # so holding Up is one undo step rather than one per 0.5 dB.
    $script:TrimLaneGainTimer = $null
    # Lane id whose fader had keyboard focus when the rows were last rebuilt, so the
    # rebuild a keyboard gain change triggers does not eat the next key press.
    $script:TrimFaderFocusLane = $null
    # Row media pump (filmstrip frames + per row waveforms). Queue, claimed-key set,
    # the single in-flight job, the pump timer, decoded strip bitmaps, and the
    # "something landed, redraw when the queue drains" flag.
    $script:TrimStripPending = New-Object System.Collections.ArrayList
    $script:TrimRowMediaClaimed = @{}
    $script:TrimRowMediaJob = $null
    $script:TrimRowMediaTimer = $null
    $script:TrimStripImages = @{}
    $script:TrimRowMediaDirty = $false
    # Path -> probed duration (seconds) for every external clip added to the stack. Never
    # left $null for the same reason TrimLanes isn't: it feeds -ClipDurations at
    # Export-CutListAsync's call site and Get-TrimClipSpan's SourceDuration fallback
    # for InEnd = 0 ("to the end of the clip"). Reset per file load alongside TrimLanes.
    $script:TrimClipDurations = @{}
    # The PROBED count of audio streams the loaded source file itself actually has (from
    # Get-TrimAudioStreams at load time), -1 until a file has been probed. Passed as
    # Export-CutListAsync's -SourceAudioStreamCount so a stack whose audio-source tracks
    # were deleted (rather than muted) is recognized as non-trivial (deleting all of a
    # 2-stream file's audio-source tracks leaves 0 != 2) and routes to the rebuild path
    # instead of silently falling through to the trivial "-map 0 -c copy" of the source,
    # which would keep the original audio no matter what the UI shows. -1 (never left
    # unset/$null) is the legacy/unknown sentinel every downstream function treats as
    # "behave exactly as before this existed".
    $script:TrimSourceAudioStreamCount = -1
    # Path -> the clip's own width/height aspect ratio, populated once at add-time
    # (Invoke-TrimAddClip) for every overlay clip so the magnet-locked resize drag can read
    # it without shelling out to ffprobe on every mouse-move.
    $script:TrimClipAspect = @{}
    # PiP preview pools: CLIP Id -> MediaElement. Video-clip elements are inserted into
    # the visual tree (PreviewCell, between PreviewZoomHost and CanvasCaptionOverlay) so
    # they actually render; audio-clip elements are deliberately kept OFF the tree -- they
    # exist only to play sound, never to be seen, and the export is authoritative for the
    # real mix regardless of what the preview does.
    # Every entry is @{ Element; InSpan } -- InSpan is what stops the 20x/sec transport tick
    # from re-seeking an element that is already playing the right thing (see
    # Update-PipPreview's -Seek plumbing); the audio pool has worked this way since Task 8.
    $script:PipMediaElements = @{}
    $script:AudioClipMediaElements = @{}
    # Stills get an Image element rather than a MediaElement (same pool shape, same
    # clip-Id key, same visual-tree slot): a BitmapImage is decoded once at OnLoad and
    # then costs nothing per tick, where a MediaElement on a .png would not play at all.
    $script:ImageElements = @{}
    # The black montage base: one Rectangle sized to the preview box, sitting under every
    # clip element, shown only while the playhead is past V1's own end (spec 4.7). Built
    # lazily by Update-TrimBlackBase because PreviewCell is not resolved yet up here.
    $script:TrimBlackBase = $null
    # Timeline length INCLUDING anything that runs past the cut list, recomputed once per
    # redraw (Update-TrimTimelineLengthCache) rather than per tick: the transport clamps,
    # the ruler's view window and the position readout's denominator all read it 20x a
    # second while playing, and Get-TrimTimelineLength walks every clip on every lane.
    $script:TrimTimelineLengthCache = 0.0
    # How far PAST V1's own end the playhead is, in timeline seconds. 0.0 means "inside the
    # cut list", which is the only state that existed before spec 4.7's montage region:
    # there is no source second out there for $script:TrimPlayhead to hold, so the position
    # lives here and Get-TrimTimelinePlayhead adds the two together.
    $script:TrimExtensionOffset = 0.0
    # Wall-clock stamp of the last extension advance. Out past V1's end the main
    # MediaElement has no frames to give, so its Position cannot drive the transport and
    # DateTime deltas do the job instead.
    $script:TrimExtensionClock = $null
    # In-flight PiP box drag: $null, or a hashtable shaped exactly like $script:ZoomBoxDrag
    # (Mode "pipmove"/"pipresize", StartX/Y, Moved, orig Pip fields, Snapshot).
    $script:PipBoxDrag = $null
    # Magnet ON by default, same convention as $script:ZoomMagnet: resizing the PiP box
    # keeps the clip's own aspect until the user opts into free-stretch.
    $script:PipMagnet = $true
    # Transient shapes for the PiP spotlight box (frame/mover/sizer), tracked the same way
    # $script:ZoomBoxElements is so Remove-PipBoxElements can pull only these out of the
    # shared caption overlay canvas.
    $script:PipBoxElements = New-Object System.Collections.ArrayList

    # Project persistence. The save failure is reported once per file, not once per edit:
    # a read-only folder would otherwise repaint the same error over the panel every
    # second for as long as the user keeps working.
    $script:ProjectSaveWarned = $false

    # One DispatcherTimer, restarted on every edit: the file writes once things go quiet
    # for a second, not on every keystroke of caption typing. A save is cheap, but it is
    # a synchronous disk write on the UI thread, so it must not run per keypress.
    $script:ProjectSaveTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ProjectSaveTimer.Interval = [timespan]::FromSeconds(1)
    $script:ProjectSaveTimer.Add_Tick({
        $script:ProjectSaveTimer.Stop()
        if (-not $script:TrimInputFile) { return }
        $ok = Save-TrimProject -VideoPath $script:TrimInputFile `
            -CutList @($script:TrimCutList) -Fades $script:TrimFades -Captions @($script:TrimCaptions) `
            -Zooms @($script:TrimZooms) -Lanes @($script:TrimLanes)
        if (-not $ok -and -not $script:ProjectSaveWarned) {
            $script:ProjectSaveWarned = $true
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text "Couldn't save the project file next to the video. Edits won't survive closing the app."
        }
    })

    # Zoom-gesture refinement: each Ctrl+wheel notch repaints through the cheap -TickOnly
    # path (no lane-row rebuild), and this timer runs ONE full Update-TrimTimeline shortly
    # after the last notch so the lane rows and thumbnails land at the FINAL zoom instead
    # of being rebuilt on every intermediate step -- rebuilding them per notch is what made
    # zooming feel like it "waits for the frames to render" between notches.
    $script:ZoomRefineTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ZoomRefineTimer.Interval = [timespan]::FromMilliseconds(200)
    $script:ZoomRefineTimer.Add_Tick({
        $script:ZoomRefineTimer.Stop()
        Update-TrimTimeline
    })
    function Request-TrimZoomRefine {
        $script:ZoomRefineTimer.Stop()
        $script:ZoomRefineTimer.Start()
    }

    # Called at the end of every mutating action. A top-level function for the usual
    # reason: several of those actions live inside .GetNewClosure()'d handlers, where a
    # bare $script: write would land in the closure's own private module.
    function Request-TrimProjectSave {
        if (-not $script:TrimEditorReady) { return }
        $script:ProjectSaveTimer.Stop()
        $script:ProjectSaveTimer.Start()
    }

    function Format-TrimTime {
        param([double]$Seconds)
        # 0.0, not 0: an int literal binds [math]::Max's INT overload and truncates the
        # double (trap #8), which zeroed the milliseconds of every displayed time.
        $ts = [timespan]::FromSeconds([math]::Max(0.0, $Seconds))
        return ("{0:D2}:{1:D2}.{2:D3}" -f $ts.Minutes, $ts.Seconds, $ts.Milliseconds)
    }

    # Compact ruler label -- the full MM:SS.mmm from Format-TrimTime is too busy repeated
    # every tick. Sub-second intervals (deep zoom) keep one decimal; anything coarser drops
    # the fraction entirely.
    function Format-TrimRulerLabel {
        param([double]$Seconds, [double]$Interval)
        $ts = [timespan]::FromSeconds([math]::Max(0.0, $Seconds))
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
        $maxTicks = [math]::Max(1.0, $CanvasWidth / $MinPixelGap)
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

    # How far right the VIEW may extend: the content plus breathing room, so there is
    # always empty track to zoom/pan into -- and to drop the NEXT clip onto -- past the
    # last thing on the timeline. A view clamped exactly to the content gave new montage
    # clips nowhere visible to land.
    function Get-TrimViewMax {
        param([double]$TimelineLength)
        return $TimelineLength + [math]::Max(10.0, 0.25 * $TimelineLength)
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

    # Fades are stored against the SOURCE time of the boundary, not the index of the cut
    # they sit on. Indexes shift the moment anything is split or deleted, which would
    # silently move a fade onto a different cut; a source time is the one thing about a
    # boundary that does not move. Boundaries that stop existing leave a stale key behind,
    # which is harmless -- Get-TrimFadeFlags only ever reads keys for boundaries that are
    # actually there, so a stale one is invisible unless the identical cut comes back.
    function Get-TrimFadeKey {
        param([double]$SourceSeconds)
        return ("{0:N3}" -f $SourceSeconds)
    }

    function Test-TrimFade {
        param([double]$SourceSeconds)
        return $script:TrimFades.ContainsKey((Get-TrimFadeKey -SourceSeconds $SourceSeconds))
    }

    # Each cut carries its own length, so a montage can dissolve slowly in one place and
    # snap in another. $script:TrimFadeSeconds is only the default applied to the NEXT
    # fade turned on, not a global setting the existing ones follow.
    function Get-TrimFadeLength {
        param([double]$SourceSeconds)
        $key = Get-TrimFadeKey -SourceSeconds $SourceSeconds
        if ($script:TrimFades.ContainsKey($key)) { return [double]$script:TrimFades[$key] }
        return 0.0
    }

    # Write-through, same reason as Set-TrimSelection: the toggle click handlers are
    # inside GetNewClosure()'d blocks, where a bare $script: write lands in the closure's
    # own private module and the drawing code never sees it.
    function Set-TrimFade {
        param([double]$SourceSeconds, [bool]$Enabled, [double]$Seconds = 0)
        $key = Get-TrimFadeKey -SourceSeconds $SourceSeconds
        if ($Enabled) {
            $length = if ($Seconds -gt 0) { $Seconds } else { $script:TrimFadeSeconds }
            $script:TrimFades[$key] = $length
        } else {
            $script:TrimFades.Remove($key)
        }
    }

    # Which fade the length picker edits. Set by clicking a pill; cleared when that fade
    # is switched off, since there would be nothing left to apply a length to.
    function Set-TrimActiveFade {
        param([double]$SourceSeconds, [bool]$HasFade)
        $script:TrimActiveFade = if ($HasFade) { $SourceSeconds } else { $null }
    }

    # ---- Caption state write-throughs ----
    #
    # Same rule as Set-TrimSelection and Set-TrimFade: every read and write of the caption
    # state goes through a top-level function, because the per-block handlers below are
    # .GetNewClosure()'d (they must be -- each captures its own caption Id) and a bare
    # $script: read OR write inside one of those resolves against the closure's own
    # private dynamic module, not this scope. A read there returns $null and a write is
    # invisible to the drawing code.

    # Flat objects, but each field is copied by name rather than via PSObject.Copy() so it
    # is obvious at the call site that undo gets a genuinely independent caption and not a
    # second reference to the one the sidebar is about to edit.
    function Copy-TrimCaption {
        param($Caption)
        return [PSCustomObject]@{
            Id           = $Caption.Id
            Text         = $Caption.Text
            Start        = [double]$Caption.Start
            End          = [double]$Caption.End
            X            = [double]$Caption.X
            Y            = [double]$Caption.Y
            FontSizeFrac = [double]$Caption.FontSizeFrac
            FontFamily   = $Caption.FontFamily
            Bold         = [bool]$Caption.Bold
            FillColor    = $Caption.FillColor
            OutlineColor = $Caption.OutlineColor
            OutlineWidth = [double]$Caption.OutlineWidth
            BounceIn     = [bool]$Caption.BounceIn
        }
    }

    function Set-TrimCaptions {
        param([object[]]$Captions = @())
        $list = New-Object System.Collections.ArrayList
        foreach ($c in @($Captions)) { if ($null -ne $c) { [void]$list.Add($c) } }
        $script:TrimCaptions = $list
    }

    function Set-TrimSelectedCaption {
        param($Id)
        $script:TrimSelectedCaption = $Id
    }

    function Get-TrimSelectedCaption {
        foreach ($c in $script:TrimCaptions) {
            if ($c.Id -eq $script:TrimSelectedCaption) { return $c }
        }
        return $null
    }

    function Get-TrimCaptionById {
        param([string]$Id)
        foreach ($c in $script:TrimCaptions) { if ($c.Id -eq $Id) { return $c } }
        return $null
    }

    # Pixels on the lane are the same pixels as the timeline track above it (both canvases
    # share the card's width), so a drag reads in the current view's seconds-per-pixel.
    function Convert-TrimPixelsToSeconds {
        param([double]$Pixels)
        $w = $canvasTrimTimeline.ActualWidth
        if ($w -le 0) { return 0.0 }
        return ($Pixels / $w) * $script:TrimViewSpan
    }

    # One length per internal boundary, in piece order -- the shape Export-CutListAsync
    # wants. 0 means a plain cut at that boundary.
    function Get-TrimFadeLengths {
        param([object[]]$Pieces)
        $list = @($Pieces)
        $lengths = @()
        for ($i = 0; $i -lt $list.Count - 1; $i++) {
            $lengths += [double](Get-TrimFadeLength -SourceSeconds $list[$i].End)
        }
        # [double[]] cast, not a bare array: Export-CutListAsync types the parameter, and
        # an empty untyped @() would bind as $null there rather than an empty array.
        return ,([double[]]$lengths)
    }

    # ---- Timeline length + the montage extension past V1's end (spec 4.7) -------------
    #
    # The cut list is no longer the whole timeline: a clip on any lane can start after V1's
    # last frame, and everything from V1's end to that clip's end is the "extension" (the
    # montage region, black under the clips). Recomputed ONCE per redraw and cached,
    # because the transport tick, the ruler and the position readout all want it 20x a
    # second and Get-TrimTimelineLength walks every clip on every lane to produce it.
    function Update-TrimTimelineLengthCache {
        if (-not $script:TrimInputFile) {
            $script:TrimTimelineLengthCache = 0.0
            $script:TrimExtensionOffset = 0.0
            return 0.0
        }
        $state = Get-TrimTimelineState
        $fadeLengths = Get-TrimFadeLengths -Pieces @($state.Pieces)
        $script:TrimTimelineLengthCache = Get-TrimTimelineLength -Lanes @($script:TrimLanes) `
            -Pieces @($state.Pieces) -FadeLengths ([double[]]@($fadeLengths)) `
            -ClipDurations $script:TrimClipDurations -MainPath $script:TrimInputFile
        # An edit can shorten the timeline out from under a playhead that is sitting in the
        # extension (delete the clip that made the montage, undo the add). Clamping here --
        # the one place the length is recomputed -- is what keeps the playhead from hanging
        # past the end of a timeline that no longer reaches it.
        $max = [math]::Max(0.0, [double]$script:TrimTimelineLengthCache - [double]$state.TotalDuration)
        if ($script:TrimExtensionOffset -gt $max) { $script:TrimExtensionOffset = $max }
        return $script:TrimTimelineLengthCache
    }

    # Never shorter than the cut list itself: a stale cache (read before the first redraw)
    # must not clamp the transport to less than V1's own footage.
    function Get-TrimTimelineLengthCached {
        $state = Get-TrimTimelineState
        $len = [double]$script:TrimTimelineLengthCache
        if ($len -lt [double]$state.TotalDuration) { $len = [double]$state.TotalDuration }
        return $len
    }

    # THE timeline position of the playhead. Inside the cut list that is just the source
    # second converted into timeline space, exactly as before; out in the extension there is
    # no source second to convert (the source ran out), so the offset carries it.
    function Get-TrimTimelinePlayhead {
        $state = Get-TrimTimelineState
        if ($script:TrimExtensionOffset -gt 0) {
            return ([double]$state.TotalDuration + [double]$script:TrimExtensionOffset)
        }
        return (Convert-TrimSourceToTimeline -SourceSeconds $script:TrimPlayhead -TimelinePieces $state.TimelinePieces)
    }

    function Test-TrimInExtension { return ([double]$script:TrimExtensionOffset -gt 0) }

    # Write-throughs, so the transport handlers (which ARE GetNewClosure'd blocks) never
    # assign $script: state from inside their own private module -- the same reason
    # Set-TrimKeyframes and Set-TrimSelection exist.
    function Set-TrimExtensionPosition {
        param([double]$Seconds)
        if ($Seconds -gt 0) {
            $script:TrimExtensionOffset = $Seconds
            $script:TrimExtensionClock = [datetime]::UtcNow
        } else {
            $script:TrimExtensionOffset = 0.0
            $script:TrimExtensionClock = $null
        }
    }

    function Reset-TrimExtensionClock { $script:TrimExtensionClock = [datetime]::UtcNow }

    # A crossfade is built from footage the two neighbouring pieces give up, so a piece
    # has to be long enough to donate its neighbours' fade lengths. Reported before the
    # export starts rather than letting ffmpeg produce a zero-length segment and a file
    # that is quietly missing a piece.
    function Get-TrimFadeProblem {
        param([object[]]$Pieces)
        $list = @($Pieces)
        # No @() wrapper -- see the note at the export handler.
        $lengths = Get-TrimFadeLengths -Pieces $list
        for ($i = 0; $i -lt $list.Count; $i++) {
            $needed = 0.0
            if ($i -gt 0 -and $i - 1 -lt $lengths.Count) { $needed += $lengths[$i - 1] }
            if ($i -lt $lengths.Count) { $needed += $lengths[$i] }
            if ($needed -le 0) { continue }
            $length = $list[$i].End - $list[$i].Start
            # A piece reduced to nothing would vanish from the export entirely; require a
            # little real footage to survive on either side of what it donates.
            if ($length -le $needed + 0.05) {
                return ("Piece {0} is only {1:N2}s long and cannot give up {2:N2}s to its fades. Shorten those fades or turn one of them off." -f ($i + 1), $length, $needed)
            }
        }
        return $null
    }

    # Rebuilt from scratch on every change: a handful of pieces, so there is nothing to
    # gain from diffing and no stale-element state to get wrong.
    function Update-TrimTimeline {
        # -TickOnly is the transport tick's path: while the clock is the only thing that
        # moved, the lane rows' STRUCTURE cannot have changed, so the tail repositions the
        # stack-spanning playhead line alone instead of rebuilding every row (headers,
        # faders, filmstrip Images) 20x a second -- the full rebuild saturated the UI
        # thread and dropped the tick rate to ~8/sec. Every edit-driven caller keeps the
        # full rebuild: a split pressed MID-PLAYBACK still comes through Invoke-TrimSplit,
        # which calls this without the switch.
        param([switch]$TickOnly)
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
        #
        # Clamped to the VIEW MAX (content + breathing room), not to the content: a clip
        # past V1's end is part of what this ruler measures (spec 4.7), and the extra
        # slack past the LAST clip is deliberate -- it is the empty track new clips get
        # dropped onto. This is also the piece-edit refresh of the cache -- every
        # split/delete/undo repaints here.
        $timelineLength = Update-TrimTimelineLengthCache
        if ($timelineLength -gt 0) {
            $viewMax = Get-TrimViewMax -TimelineLength $timelineLength
            if ($script:TrimViewSpan -gt $viewMax) { $script:TrimViewSpan = $viewMax }
            if ($script:TrimViewStart + $script:TrimViewSpan -gt $viewMax) {
                $script:TrimViewStart = [math]::Max(0.0, $viewMax - $script:TrimViewSpan)
            }
        }

        # The SRC strip is hidden (V1's own lane row draws the pieces now), so building
        # its piece visuals -- and above all their per-slot Request-TrimThumbnail calls --
        # would be pure waste on every repaint. The canvas itself stays alive purely as
        # the x-axis every strip measures against.
        $buildSrcPieces = $false
        for ($i = 0; $buildSrcPieces -and $i -lt $pieces.Count; $i++) {
            $tp = $timelinePieces[$i]
            $x1 = Convert-TrimTimeToX -Seconds $tp.TimelineStart
            $x2 = Convert-TrimTimeToX -Seconds $tp.TimelineEnd
            $width = [math]::Max(1.0, $x2 - $x1)
            $isSelected = ($i -eq $script:TrimSelected)

            # A Border+Grid of Images instead of a flat Rectangle, so the piece shows the
            # actual footage (a small filmstrip) rather than a solid color block. The
            # style's own Fill color is kept as the Border's Background -- it shows through
            # while thumbnails are still loading, and behind any letterboxing from a
            # thumbnail whose aspect ratio doesn't exactly fill its slot.
            $container = New-Object System.Windows.Controls.Border
            $styleName = if ($isSelected) { "TimelinePieceSelectedStyle" } else { "TimelinePieceStyle" }
            $pieceStyle = $ctx.Window.FindResource($styleName)
            $fillSetter = $pieceStyle.Setters | Where-Object { $_.Property.Name -eq "Fill" }
            $strokeSetter = $pieceStyle.Setters | Where-Object { $_.Property.Name -eq "Stroke" }
            $strokeWidthSetter = $pieceStyle.Setters | Where-Object { $_.Property.Name -eq "StrokeThickness" }
            $container.Background = $fillSetter.Value
            $container.BorderBrush = $strokeSetter.Value
            $container.BorderThickness = New-Object System.Windows.Thickness($strokeWidthSetter.Value)
            $container.CornerRadius = New-Object System.Windows.CornerRadius(4)
            $container.ClipToBounds = $true
            $container.Width = $width
            $container.Height = $h - 8
            [System.Windows.Controls.Canvas]::SetLeft($container, $x1)
            [System.Windows.Controls.Canvas]::SetTop($container, 4)

            # Fixed-width thumbnail slots laid out across the VISIBLE slice of the piece,
            # not N stretched slots across the whole piece.
            #
            # The whole-piece version is what made zoom look broken: zooming does not
            # change a piece's source range, only how many pixels it is drawn across, so
            # at a 32x zoom the piece is ~25,000px wide while the canvas still shows 793
            # of them. Six thumbnails spread over that width meant the viewport held a
            # fraction of a single frame, blown up -- the timeline appeared to zoom into
            # one image instead of resolving into more frames.
            #
            # Anchoring the slots to the viewport instead makes the count depend on
            # visible pixels, so zooming in genuinely subdivides: the same 793px always
            # holds ~8 frames, and each one is sampled from a correspondingly narrower
            # slice of the source. It also caps the work -- the visible region can never
            # exceed the canvas, so no zoom level can ask for more than ~9 thumbnails.
            $inner = New-Object System.Windows.Controls.Canvas
            $visibleLeft = [math]::Max($x1, 0)
            $visibleRight = [math]::Min($x2, $canvasTrimTimeline.ActualWidth)
            $slotWidth = 96
            if ($visibleRight -gt $visibleLeft) {
                $slotCount = [math]::Max(1, [int][math]::Ceiling(($visibleRight - $visibleLeft) / $slotWidth))
                for ($t = 0; $t -lt $slotCount; $t++) {
                    $slotLeft = $visibleLeft + ($t * $slotWidth)
                    # The last slot is a remainder, not a full slot.
                    $thisWidth = [math]::Min($slotWidth, $visibleRight - $slotLeft)
                    if ($thisWidth -le 0) { break }

                    $img = New-Object System.Windows.Controls.Image
                    $img.Stretch = "UniformToFill"
                    $img.Width = $thisWidth
                    $img.Height = $h - 8
                    # Positioned relative to the container, which starts at $x1 -- and
                    # $x1 is negative whenever the piece begins left of the viewport.
                    [System.Windows.Controls.Canvas]::SetLeft($img, $slotLeft - $x1)
                    [System.Windows.Controls.Canvas]::SetTop($img, 0)

                    # Slot midpoint, viewport pixels -> timeline seconds -> source seconds.
                    # Thumbnails are about the real file; the pixels they are drawn into
                    # are timeline (compacted) space.
                    $slotMidTimeline = Convert-TrimXToTime -X ($slotLeft + $thisWidth / 2)
                    $srcTime = Convert-TrimTimelineToSource -TimelineSeconds $slotMidTimeline -TimelinePieces $timelinePieces
                    $key = "{0:N2}" -f $srcTime
                    if ($script:TrimThumbCache.ContainsKey($key)) {
                        $img.Source = $script:TrimThumbCache[$key]
                    } else {
                        Request-TrimThumbnail -File $script:TrimInputFile -Seconds $srcTime
                    }
                    $inner.Children.Add($img) | Out-Null
                }
            }
            $container.Child = $inner

            # GetNewClosure is required: without it every piece captures the loop
            # variable's final value and clicking any piece selects the last one. The
            # selection write goes through Set-TrimSelection for the reason noted there.
            #
            # Deliberately NOT marking the event handled: the pieces cover the whole track,
            # so swallowing it here would mean the canvas handler never runs and the track
            # could not be scrubbed at all. A click both selects the piece and moves the
            # playhead to where it landed.
            $index = $i
            $container.Add_MouseLeftButtonDown({
                Set-TrimSelection -Index $index
                $buttonTrimDelete.IsEnabled = $true
                Update-TrimSelectionText
                Update-TrimTimeline
            }.GetNewClosure())

            $canvasTrimTimeline.Children.Add($container) | Out-Null

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
        $playheadVisible = ($playX -ge 0 -and $playX -le $canvasTrimTimeline.ActualWidth)
        if ($playheadVisible) {
            $head = New-Object System.Windows.Shapes.Rectangle
            $head.Style = $ctx.Window.FindResource("TimelinePlayheadStyle")
            # The filmstrip row is the whole track now that the waveform strip is gone
            # (spec 3.1). The lane rows below get their own playhead line, drawn on
            # CanvasTrimLaneOverlay by Update-TrimLaneOverlay.
            $head.Height = $h
            [System.Windows.Controls.Canvas]::SetLeft($head, $playX - 1)
            [System.Windows.Controls.Canvas]::SetTop($head, 0)
            $canvasTrimTimeline.Children.Add($head) | Out-Null

            # Downward wedge at the top of the track. The 3px line alone disappears against
            # the filmstrip thumbnails; this gives the playhead a shape the eye can find
            # while the frames underneath it are changing.
            $grip = New-Object System.Windows.Shapes.Polygon
            $grip.Style = $ctx.Window.FindResource("TimelinePlayheadGripStyle")
            $points = New-Object System.Windows.Media.PointCollection
            $points.Add((New-Object System.Windows.Point(0, 0)))
            $points.Add((New-Object System.Windows.Point(11, 0)))
            $points.Add((New-Object System.Windows.Point(5.5, 7)))
            $grip.Points = $points
            [System.Windows.Controls.Canvas]::SetLeft($grip, $playX - 5.5)
            [System.Windows.Controls.Canvas]::SetTop($grip, 0)
            $canvasTrimTimeline.Children.Add($grip) | Out-Null
        }

        # Ruler: ticks + compact time labels below the track, the only way to read a
        # position on the timeline without looking at the numeric readout above it.
        # Redrawn from scratch alongside the track for the same reason the track is --
        # a handful of ticks, nothing worth diffing.
        if ($null -ne $canvasTrimRuler) {
            $canvasTrimRuler.Children.Clear()
            $rulerWidth = $canvasTrimTimeline.ActualWidth
            if ($rulerWidth -gt 0 -and $script:TrimViewSpan -gt 0) {
                # Built (but not added) before the ruler labels so its real width is known:
                # a label drawn underneath the badge is unreadable, so the range the badge
                # occupies has to be reserved before any label is placed.
                $badge = $null
                $badgeLeft = 0.0
                $badgeRight = -1.0
                if ($playheadVisible) {
                    $badge = New-Object System.Windows.Controls.Border
                    $badge.Style = $ctx.Window.FindResource("TimelinePlayheadBadgeStyle")
                    $badgeText = New-Object System.Windows.Controls.TextBlock
                    $badgeText.Style = $ctx.Window.FindResource("TimelinePlayheadBadgeTextStyle")
                    $badgeText.Text = Format-TrimTime $playheadTimeline
                    $badge.Child = $badgeText
                    $badge.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
                    $badgeWidth = $badge.DesiredSize.Width
                    # Centred on the playhead, but clamped inside the canvas: at 0:00 and at
                    # the very end an uncentred badge would hang off the edge and be clipped
                    # exactly when the time still needs reading.
                    $badgeLeft = [math]::Max(0.0, [math]::Min($rulerWidth - $badgeWidth, $playX - $badgeWidth / 2))
                    $badgeRight = $badgeLeft + $badgeWidth
                }

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
                        $label.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
                        $labelLeft = $tx + 3
                        $labelRight = $labelLeft + $label.DesiredSize.Width
                        # 4px of air on each side, so a label that merely touches the badge
                        # is dropped too rather than sitting flush against it.
                        $collides = ($labelLeft -lt $badgeRight + 4 -and $labelRight -gt $badgeLeft - 4)
                        if (-not $collides) {
                            [System.Windows.Controls.Canvas]::SetLeft($label, $labelLeft)
                            [System.Windows.Controls.Canvas]::SetTop($label, 7)
                            $canvasTrimRuler.Children.Add($label) | Out-Null
                        }
                    }
                    $tickTime += $interval
                }

                # Added last so it paints over the ticks it straddles.
                if ($badge) {
                    [System.Windows.Controls.Canvas]::SetLeft($badge, $badgeLeft)
                    [System.Windows.Controls.Canvas]::SetTop($badge, 4)
                    $canvasTrimRuler.Children.Add($badge) | Out-Null
                }

                # The playhead's grab wedge, on the RULER: the SRC strip that used to
                # carry it is hidden, and the ruler is the scrub surface now -- the wedge
                # marks where to press. Same shape as the old strip grip.
                if ($playheadVisible) {
                    $rulerGrip = New-Object System.Windows.Shapes.Polygon
                    $rulerGrip.Style = $ctx.Window.FindResource("TimelinePlayheadGripStyle")
                    $rulerGripPoints = New-Object System.Windows.Media.PointCollection
                    $rulerGripPoints.Add((New-Object System.Windows.Point(0, 0)))
                    $rulerGripPoints.Add((New-Object System.Windows.Point(11, 0)))
                    $rulerGripPoints.Add((New-Object System.Windows.Point(5.5, 7)))
                    $rulerGrip.Points = $rulerGripPoints
                    [System.Windows.Controls.Canvas]::SetLeft($rulerGrip, $playX - 5.5)
                    [System.Windows.Controls.Canvas]::SetTop($rulerGrip, 0)
                    $canvasTrimRuler.Children.Add($rulerGrip) | Out-Null
                }
            }
        }

        Update-TrimFadeToggles -Pieces $pieces -TimelinePieces $timelinePieces

        $textTrimPieces.Text = if ($pieces.Count -eq 1) { "1 piece" } else { "$($pieces.Count) pieces" }
        # The input-file test is not redundant with the count: it keeps Export disabled
        # during the first layout pass, before anything has been picked.
        $buttonTrimExport.IsEnabled = ($pieces.Count -gt 0 -and $null -ne $script:TrimInputFile)

        Update-TrimCaptionLane
        # Last: the zoom lane is the bottom row and depends on the same timeline pieces
        # everything above it has just been drawn from.
        Update-TrimZoomLane
        # Same hook point, same reasoning: the track lanes' clip bars are positioned with
        # Convert-TrimTimeToX too, so they need the timeline pieces this pass just drew from.
        if ($TickOnly) {
            Update-TrimLaneOverlay
        } else {
            Update-TrimLaneRows
        }
    }

    # Where waveform strips live on disk: the persistent per-source cache when it was
    # created, the per-launch thumb dir otherwise (identical to the old behavior).
    function Get-TrimWaveDir {
        if ($script:TrimWaveCacheDir) { return $script:TrimWaveCacheDir }
        return $script:TrimThumbDir
    }

    # One toggle per internal cut, in its own row under the ruler, at the cut's x.
    function Update-TrimFadeToggles {
        param([object[]]$Pieces, [object[]]$TimelinePieces)
        if ($null -eq $canvasTrimFades) { return }
        $canvasTrimFades.Children.Clear()

        $list = @($Pieces)
        $tl = @($TimelinePieces)
        # The whole row, including the length picker, is pointless with nothing to fade.
        if ($null -ne $panelTrimFadeLength) {
            $panelTrimFadeLength.Visibility = if ($list.Count -gt 1) { "Visible" } else { "Collapsed" }
        }
        if ($list.Count -lt 2) { return }

        $fadedCount = 0
        $fadedTotal = 0.0
        # Right edge of the last toggle drawn. Two cuts can sit a few pixels apart at a
        # loose zoom, and overlapping toggles are unhittable -- the later one is dropped
        # rather than stacked, and zooming in separates them.
        $lastRight = [double]::NegativeInfinity

        for ($i = 1; $i -lt $list.Count; $i++) {
            $boundarySource = [double]$list[$i - 1].End
            $isOn = Test-TrimFade -SourceSeconds $boundarySource
            $thisLength = Get-TrimFadeLength -SourceSeconds $boundarySource
            $isActive = ($null -ne $script:TrimActiveFade -and
                         [math]::Abs($script:TrimActiveFade - $boundarySource) -lt 0.0005)
            if ($isOn) {
                $fadedCount++
                $fadedTotal += $thisLength
                # Rendered here rather than on the toggle click so it also covers the
                # cases that change what a fade looks like without anyone clicking a
                # toggle: a different fade length, an undo, or a delete that moves which
                # piece a surviving fade now blends into.
                Request-TrimFadeProxy -OutgoingEnd $boundarySource `
                    -IncomingStart ([double]$list[$i].Start) -FadeSeconds $thisLength
            }

            $x = Convert-TrimTimeToX -Seconds $tl[$i].TimelineStart
            if ($x -lt 0 -or $x -gt $canvasTrimTimeline.ActualWidth) { continue }

            $toggle = New-Object System.Windows.Controls.Border
            $toggle.Style = $ctx.Window.FindResource(
                $(if ($isOn) { "TimelineFadeToggleOnStyle" } else { "TimelineFadeToggleStyle" }))
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Style = $ctx.Window.FindResource(
                $(if ($isOn) { "TimelineFadeToggleTextOnStyle" } else { "TimelineFadeToggleTextStyle" }))
            # The length rides on the pill once it is on: it is the number that decides how
            # much footage the cut gives up, and reading it off a separate picker means
            # looking away from the thing it applies to.
            $label.Text = if ($isOn) { "FADE {0:0.##}s" -f $thisLength } else { "+ FADE" }
            $toggle.Child = $label
            # The active fade is the one the length picker edits, so it has to be visible
            # which that is -- otherwise clicking 1s looks like it did nothing, or worse,
            # like it changed a different cut.
            if ($isOn -and $isActive) {
                $toggle.BorderBrush = $ctx.Window.FindResource("BrushGoldValue")
                $toggle.BorderThickness = New-Object System.Windows.Thickness(2)
            }
            $toggle.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
            $toggleWidth = $toggle.DesiredSize.Width
            $left = $x - ($toggleWidth / 2)
            if ($left -lt $lastRight + 4) { continue }
            $lastRight = $left + $toggleWidth

            $stem = New-Object System.Windows.Shapes.Rectangle
            $stem.Style = $ctx.Window.FindResource("TimelineFadeStemStyle")
            $stem.Height = 7
            [System.Windows.Controls.Canvas]::SetLeft($stem, $x)
            [System.Windows.Controls.Canvas]::SetTop($stem, 0)
            $canvasTrimFades.Children.Add($stem) | Out-Null

            [System.Windows.Controls.Canvas]::SetLeft($toggle, $left)
            [System.Windows.Controls.Canvas]::SetTop($toggle, 7)

            # GetNewClosure is required for the same reason the piece handlers need it:
            # without it every toggle captures the loop variable's final value and clicking
            # any of them flips the last cut.
            $thisBoundary = $boundarySource
            $thisState = $isOn
            $toggle.Add_MouseLeftButtonDown({
                $nowOn = -not $thisState
                Set-TrimFade -SourceSeconds $thisBoundary -Enabled $nowOn
                # Clicking a pill also aims the length picker at that cut, so the two
                # controls are never out of step with each other.
                Set-TrimActiveFade -SourceSeconds $thisBoundary -HasFade $nowOn
                Sync-TrimFadeLengthButtons
                Update-TrimTimeline
                # Turning a fade OFF has to take the overlay down straight away; turning
                # one on is picked up by Set-TrimFadeProxy once the render lands.
                Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
                Request-TrimProjectSave
            }.GetNewClosure())

            $canvasTrimFades.Children.Add($toggle) | Out-Null
        }

        if ($null -ne $textTrimFadeNote) {
            $textTrimFadeNote.Text = if ($fadedCount -gt 0) {
                # Summed per fade rather than count x one length: each cut carries its own
                # now. The length change is the surprising part of a crossfade, so it is
                # stated up front rather than discovered after the export.
                "{0} faded cut{1} -- export ends up {2:N2}s shorter" -f `
                    $fadedCount, $(if ($fadedCount -eq 1) { "" } else { "s" }), $fadedTotal
            } else {
                "click FADE under a cut to blend across it"
            }
        }

        # Says out loud which cut the picker is pointed at. Without this the buttons look
        # like a global setting, which is exactly what they used to be.
        if ($null -ne $textTrimFadeScope) {
            $textTrimFadeScope.Text = if ($null -ne $script:TrimActiveFade) {
                "for the cut at {0}" -f (Format-TrimTime (Convert-TrimSourceToTimeline `
                    -SourceSeconds $script:TrimActiveFade -TimelinePieces $tl))
            } else {
                "for the next fade you add"
            }
        }
    }

    # ---- Caption lane ----
    #
    # Captions are stored in SOURCE seconds (the same space Get-CaptionSpans clips them
    # against on export), so a block's x is the same two-step conversion the playhead uses:
    # source -> timeline (compacted) -> pixels. A caption sitting inside deleted footage
    # collapses onto the cut, which is honest -- that is exactly where the export would
    # show it, if at all.
    function Get-TrimCaptionBounds {
        param($Caption, [object[]]$TimelinePieces)
        $tl = @($TimelinePieces)
        $x1 = Convert-TrimTimeToX -Seconds (Convert-TrimSourceToTimeline -SourceSeconds ([double]$Caption.Start) -TimelinePieces $tl)
        $x2 = Convert-TrimTimeToX -Seconds (Convert-TrimSourceToTimeline -SourceSeconds ([double]$Caption.End) -TimelinePieces $tl)
        return [PSCustomObject]@{ Left = $x1; Width = [math]::Max(2.0, $x2 - $x1) }
    }

    # A caption shorter than this is unhittable on the lane and useless on screen, so an
    # edge drag stops here rather than letting a caption be dragged out of existence.
    $script:TrimCaptionMinLength = 0.2

    # Block drag: both ends move together, so the caption keeps its length and only the
    # start is clamped (against duration minus length, not duration).
    function Move-TrimCaption {
        param([string]$Id, [double]$DeltaSeconds, [double]$OrigStart, [double]$OrigEnd)
        $cap = Get-TrimCaptionById -Id $Id
        if ($null -eq $cap) { return }
        $length = $OrigEnd - $OrigStart
        # 0.0 rather than 0, in every clamp below as well: [math]::Max(0, <double>) binds
        # the INT overload and silently truncates, which quantised every caption drag to
        # whole seconds -- the block jumped a second at a time instead of tracking the
        # pointer, and an edge drag could not reach the 0.2s minimum at all.
        $limit = [math]::Max(0.0, $script:TrimDuration - $length)
        $start = [math]::Max(0.0, [math]::Min($limit, $OrigStart + $DeltaSeconds))
        $cap.Start = $start
        $cap.End = $start + $length
    }

    # Absolute retime, used by the edge grips and (from Task 10) the sidebar's time boxes.
    # Rejects rather than silently truncating anything under the minimum length: the caller
    # already clamps, so reaching this guard means the request was not a sane one.
    function Set-TrimCaptionTimes {
        param([string]$Id, [double]$Start, [double]$End)
        $cap = Get-TrimCaptionById -Id $Id
        if ($null -eq $cap) { return }
        $s = [math]::Max(0.0, [math]::Min($script:TrimDuration, $Start))
        $e = [math]::Max(0.0, [math]::Min($script:TrimDuration, $End))
        # 1e-6 of slack, not a bare comparison: an edge drag clamped to exactly the minimum
        # arrives as OrigStart + 0.2, and in binary that subtracts back to 0.19999999999999,
        # so a strict test rejected the very request the clamp had just made safe -- the
        # grip stopped responding a long way short of the minimum instead of at it.
        if ($e - $s -lt $script:TrimCaptionMinLength - 1e-6) { return }
        $cap.Start = $s
        $cap.End = $e
    }

    # The undo snapshot is taken HERE, at the start of the drag, and pushed only if the
    # caption actually ended up somewhere else -- so one drag is one undo step, and a
    # click that merely selects a block costs none.
    function Start-TrimCaptionDrag {
        param([string]$Id, [string]$Mode, [double]$StartX)
        $cap = Get-TrimCaptionById -Id $Id
        if ($null -eq $cap) { return }
        $script:TrimCaptionDrag = @{
            Id        = $Id
            Mode      = $Mode
            StartX    = $StartX
            OrigStart = [double]$cap.Start
            OrigEnd   = [double]$cap.End
            Snapshot  = New-TrimUndoSnapshot
        }
    }

    function Test-TrimCaptionDrag {
        return ($null -ne $script:TrimCaptionDrag)
    }

    # Always applied against the drag's ORIGINAL times rather than the caption's current
    # ones: accumulating per-move deltas would drift, and worse, would let a clamped edge
    # "eat" motion so dragging back out no longer returns to where it started.
    function Update-TrimCaptionDrag {
        param([double]$CurrentX)
        $drag = $script:TrimCaptionDrag
        if ($null -eq $drag) { return }
        $dt = Convert-TrimPixelsToSeconds -Pixels ($CurrentX - $drag.StartX)
        switch ($drag.Mode) {
            "start" {
                $maxStart = $drag.OrigEnd - $script:TrimCaptionMinLength
                $newStart = [math]::Max(0.0, [math]::Min($maxStart, $drag.OrigStart + $dt))
                Set-TrimCaptionTimes -Id $drag.Id -Start $newStart -End $drag.OrigEnd
            }
            "end" {
                $minEnd = $drag.OrigStart + $script:TrimCaptionMinLength
                $newEnd = [math]::Max($minEnd, [math]::Min($script:TrimDuration, $drag.OrigEnd + $dt))
                Set-TrimCaptionTimes -Id $drag.Id -Start $drag.OrigStart -End $newEnd
            }
            default {
                Move-TrimCaption -Id $drag.Id -DeltaSeconds $dt -OrigStart $drag.OrigStart -OrigEnd $drag.OrigEnd
            }
        }
    }

    function Complete-TrimCaptionDrag {
        $drag = $script:TrimCaptionDrag
        $script:TrimCaptionDrag = $null
        if ($null -eq $drag) { return }
        $cap = Get-TrimCaptionById -Id $drag.Id
        if ($null -eq $cap) { return }
        # Sub-millisecond differences are the mouse jitter of a plain click, not a move.
        if ([math]::Abs($cap.Start - $drag.OrigStart) -lt 0.001 -and
            [math]::Abs($cap.End - $drag.OrigEnd) -lt 0.001) { return }
        Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
        # Hooked on release rather than on Update-TrimCaptionDrag: one save per drag
        # instead of one per mouse move, and the early return above means a click that
        # moved nothing does not rewrite the file either.
        Request-TrimProjectSave
    }

    # Rebuilt from scratch like the rest of the timeline. Guarded on the canvas being
    # non-null: it is $null on XAML that predates this task, same stale-XAML rule the
    # waveform and fade rows carry.
    function Update-TrimCaptionLane {
        # Unconditional and first: this is the cheapest correct hook for "a caption changed"
        # (lane drags, sidebar edits, add/delete/undo all pass through here), and the lane's
        # own early returns below must not suppress the preview overlay, which carries its
        # own null/no-file guards.
        Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
        # And right behind it, everywhere: Update-CaptionOverlay clears the shared overlay
        # canvas, so the spotlight box (and the PiP box) have to be put back by whoever
        # cleared it.
        Update-ZoomBoxOverlay
        Update-PipBoxOverlay
        if ($null -eq $canvasTrimCaptions) { return }
        $canvasTrimCaptions.Children.Clear()
        if (-not $script:TrimInputFile) { return }

        $laneWidth = $canvasTrimCaptions.ActualWidth
        if ($laneWidth -le 0) { $laneWidth = $canvasTrimTimeline.ActualWidth }
        $laneHeight = $canvasTrimCaptions.ActualHeight
        if ($laneHeight -le 0) { $laneHeight = 36 }
        $blockHeight = [math]::Max(6.0, $laneHeight - 10)

        $timelinePieces = (Get-TrimTimelineState).TimelinePieces

        foreach ($c in @($script:TrimCaptions)) {
            $bounds = Get-TrimCaptionBounds -Caption $c -TimelinePieces $timelinePieces
            # Fully off-view: nothing to draw, and a block hundreds of thousands of pixels
            # wide at a deep zoom is worth not building at all.
            if ($bounds.Left + $bounds.Width -lt 0 -or $bounds.Left -gt $laneWidth) { continue }

            $isSelected = ($c.Id -eq $script:TrimSelectedCaption)
            $block = New-Object System.Windows.Controls.Border
            $block.Style = $ctx.Window.FindResource(
                $(if ($isSelected) { "CaptionBlockSelectedStyle" } else { "CaptionBlockStyle" }))
            # Never thinner than a clickable chip: a 2s caption on a 5-minute timeline is
            # ~8px by pure scale, which is invisible and undraggable. The visual right
            # edge overstates the true end a little at deep zoom-out; timing precision
            # work happens zoomed in, where width is honest again.
            $block.Width = [math]::Max(28.0, $bounds.Width)
            $block.Height = $blockHeight
            $block.ClipToBounds = $true
            [System.Windows.Controls.Canvas]::SetLeft($block, $bounds.Left)
            [System.Windows.Controls.Canvas]::SetTop($block, 5)

            $inner = New-Object System.Windows.Controls.Grid
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Style = $ctx.Window.FindResource("CaptionBlockTextStyle")
            # A caption is created empty and named later, so a blank block needs to still
            # look like something you can click.
            $label.Text = if ([string]::IsNullOrWhiteSpace($c.Text)) { "(empty)" } else { $c.Text }
            $inner.Children.Add($label) | Out-Null
            $block.Child = $inner

            $thisId = $c.Id

            # GetNewClosure is required, exactly as on the piece and fade handlers: without
            # it every block captures the loop variable's final value and dragging any
            # block moves the last caption. Mouse capture goes on the CANVAS, not on the
            # block: the lane is redrawn on every MouseMove, which destroys the block
            # element mid-drag, and a capture held by a destroyed element is lost.
            $block.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                $x = ($e.GetPosition($canvasTrimCaptions)).X
                Set-TrimSelectedCaption -Id $thisId
                # The other half of the mutual exclusion Set-TrimSelectedZoom carries: only
                # one of a caption and a zoom keyframe is ever selected, so Delete is never
                # ambiguous. Clear- only nulls the zoom selection and redraws its own lane,
                # so this cannot recurse back into here.
                Clear-TrimZoomSelection
                Start-TrimCaptionDrag -Id $thisId -Mode "move" -StartX $x
                $canvasTrimCaptions.CaptureMouse() | Out-Null
                $e.Handled = $true
                Show-CaptionSidebar
                Update-TrimCaptionLane
            }.GetNewClosure())

            # Edge grips: 6px transparent strips inside the block that retime one end
            # instead of moving the whole caption. Transparent rather than unset -- a
            # Rectangle with no Fill is not hit-testable at all. Dropped on blocks too
            # narrow to hold them, where they would leave no draggable middle.
            if ($bounds.Width -ge 20) {
                foreach ($side in @("start", "end")) {
                    $grip = New-Object System.Windows.Shapes.Rectangle
                    $grip.Width = 6
                    $grip.Fill = [System.Windows.Media.Brushes]::Transparent
                    $grip.Cursor = [System.Windows.Input.Cursors]::SizeWE
                    $grip.HorizontalAlignment = if ($side -eq "start") { "Left" } else { "Right" }
                    $grip.VerticalAlignment = "Stretch"
                    $thisSide = $side
                    $grip.Add_MouseLeftButtonDown({
                        param($eventSource, $e)
                        $x = ($e.GetPosition($canvasTrimCaptions)).X
                        Set-TrimSelectedCaption -Id $thisId
                        Clear-TrimZoomSelection
                        Start-TrimCaptionDrag -Id $thisId -Mode $thisSide -StartX $x
                        $canvasTrimCaptions.CaptureMouse() | Out-Null
                        # Handled, so the block's own move-drag handler underneath does not
                        # also fire and overwrite the retime with a move.
                        $e.Handled = $true
                        Show-CaptionSidebar
                        Update-TrimCaptionLane
                    }.GetNewClosure())
                    $inner.Children.Add($grip) | Out-Null
                }
            }

            $canvasTrimCaptions.Children.Add($block) | Out-Null
        }

        # Second playhead, drawn last so it sits above the blocks. The main one cannot be
        # stretched down to here -- the caption lane is a separate Border with its own
        # clip, not another row of the track's grid -- so the line is redrawn at the same
        # x instead. Not hit-testable: it lies across every block, and a hit-testable strip
        # would swallow clicks and drags aimed at the caption underneath it.
        $laneHeadTimeline = Convert-TrimSourceToTimeline -SourceSeconds $script:TrimPlayhead -TimelinePieces $timelinePieces
        $laneHeadX = Convert-TrimTimeToX -Seconds $laneHeadTimeline
        if ($laneHeadX -ge 0 -and $laneHeadX -le $laneWidth) {
            $laneHead = New-Object System.Windows.Shapes.Rectangle
            $laneHead.Style = $ctx.Window.FindResource("TimelinePlayheadStyle")
            $laneHead.Width = 3
            $laneHead.Height = $laneHeight
            $laneHead.IsHitTestVisible = $false
            [System.Windows.Controls.Canvas]::SetLeft($laneHead, $laneHeadX - 1)
            [System.Windows.Controls.Canvas]::SetTop($laneHead, 0)
            $canvasTrimCaptions.Children.Add($laneHead) | Out-Null
        }
    }

    # ---- Zoom keyframes ----
    #
    # Mirrors the caption machinery above function for function, and for the same reasons:
    # a script-scope ArrayList plus an Id selection, write-throughs so nothing inside a
    # .GetNewClosure()'d handler ever assigns $script: directly (a bare write there lands in
    # the closure's own private module and is invisible to the drawing code), a lane rebuilt
    # from scratch on every change, and one undo step per completed drag.

    # Field by field rather than PSObject.Copy(), like Copy-TrimCaption: undo has to hold a
    # genuinely independent keyframe and not a second reference to the one a drag or the
    # Task 7 spotlight is about to mutate in place.
    function Copy-TrimZoom {
        param($Zoom)
        # Get-ZoomKeyframeBox rather than reading W/H raw: an undo snapshot taken before
        # the stretch rework still carries Level-model keyframes, and copying those
        # verbatim would reintroduce the old shape into a session running the new one.
        $box = Get-ZoomKeyframeBox -Keyframe $Zoom
        return [PSCustomObject]@{
            Id   = $Zoom.Id
            Time = [double]$Zoom.Time
            CX   = [double]$Zoom.CX
            CY   = [double]$Zoom.CY
            W    = [double]$box.W
            H    = [double]$box.H
        }
    }

    function Set-TrimZooms {
        param([object[]]$Zooms = @())
        $list = New-Object System.Collections.ArrayList
        foreach ($z in @($Zooms)) { if ($null -ne $z) { [void]$list.Add($z) } }
        $script:TrimZooms = $list
    }

    function Get-TrimZoomById {
        param([string]$Id)
        foreach ($z in $script:TrimZooms) { if ($z.Id -eq $Id) { return $z } }
        return $null
    }

    function Get-TrimSelectedZoom {
        foreach ($z in $script:TrimZooms) {
            if ($z.Id -eq $script:TrimSelectedZoom) { return $z }
        }
        return $null
    }

    # Selecting a zoom drops any caption selection. The two features share the preview
    # surface and the Delete key, so leaving both live would make Delete ambiguous and put
    # the caption sidebar on screen next to a zoom nobody is editing.
    #
    # The two Clear- functions only ever null their OWN selection and redraw their OWN lane;
    # only the Set- functions reach across. That asymmetry is what keeps the pair from
    # recursing into each other.
    function Set-TrimSelectedZoom {
        param($Id)
        $script:TrimSelectedZoom = $Id
        if ($null -ne $Id) { Clear-TrimCaptionSelection }
    }

    function Clear-TrimZoomSelection {
        if ($null -eq $script:TrimSelectedZoom) { return }
        $script:TrimSelectedZoom = $null
        Update-TrimZoomLane
    }

    # Lane/clip write-throughs. Top-level functions for the usual reason: several of the
    # callers below live inside .GetNewClosure()'d handlers, where a bare $script: read or
    # write would land in the closure's own private module and never reach the real state.

    # Field by field rather than PSObject.Copy(), like Copy-TrimZoom/Copy-TrimCaption: undo
    # has to hold a genuinely independent clip and not a second reference to the one a lane
    # drag or the sidebar is about to mutate in place. Pip is a nested hashtable, so it
    # needs its own shallow clone or two clips would share one mutable box.
    function Copy-TrimClipObj {
        param($Clip)
        $pip = $null
        if ($null -ne $Clip.Pip) {
            $pip = @{}
            foreach ($k in $Clip.Pip.Keys) { $pip[$k] = $Clip.Pip[$k] }
        }
        return [PSCustomObject]@{
            Id               = $Clip.Id
            Kind             = $Clip.Kind
            Path             = $Clip.Path
            StreamIdx        = [int]$Clip.StreamIdx
            LinkId           = [string]$Clip.LinkId
            Offset           = [double]$Clip.Offset
            InStart          = [double]$Clip.InStart
            InEnd            = [double]$Clip.InEnd
            DurationOverride = [double]$Clip.DurationOverride
            GainDb           = [double]$Clip.GainDb
            Muted            = [bool]$Clip.Muted
            Pip              = $pip
            Enabled          = [bool]$Clip.Enabled
        }
    }

    # Deep: the lane's Clips list is rebuilt from clip CLONES, not shared references, so an
    # undo snapshot survives every in-place clip edit the panel can make.
    function Copy-TrimLaneObj {
        param($Lane)
        $clips = @(foreach ($c in @($Lane.Clips)) { Copy-TrimClipObj -Clip $c })
        return [PSCustomObject]@{
            Id     = $Lane.Id
            Kind   = $Lane.Kind
            Label  = $Lane.Label
            IsMain = [bool]$Lane.IsMain
            Clips  = @($clips)
        }
    }

    # Same null-filter pattern the track stack used, one level deeper: the lanes list AND
    # every lane's own Clips come out as ArrayLists so a clip can be added/removed in place
    # without rebuilding the lane object around it.
    function Set-TrimLanes {
        param([object[]]$Lanes = @())
        $list = New-Object System.Collections.ArrayList
        foreach ($l in @($Lanes)) {
            if ($null -eq $l) { continue }
            $clips = New-Object System.Collections.ArrayList
            foreach ($c in @($l.Clips)) { if ($null -ne $c) { [void]$clips.Add($c) } }
            $l.Clips = $clips
            [void]$list.Add($l)
        }
        $script:TrimLanes = $list
    }

    function Get-TrimLaneById {
        param([string]$Id)
        foreach ($l in $script:TrimLanes) { if ($l.Id -eq $Id) { return $l } }
        return $null
    }

    # @{Lane; Clip} for a clip id, or $null. Thin wrapper over the model's own lookup so
    # the app never walks the lanes array by hand.
    function Get-TrimClipRef {
        param([string]$Id)
        if ([string]::IsNullOrEmpty($Id)) { return $null }
        return (Get-TrimClipById2 -Lanes @($script:TrimLanes) -ClipId $Id)
    }

    function Get-TrimSelectedClipObj {
        if ($null -eq $script:TrimSelectedClip) { return $null }
        $ref = Get-TrimClipRef -Id $script:TrimSelectedClip
        if ($null -eq $ref) { return $null }
        return $ref.Clip
    }

    # One write-through for every mutable field a clip carries, mirroring Update-CaptionField:
    # only the parameters the caller actually bound are applied, via $PSBoundParameters --
    # everything else on the clip is left exactly as it was rather than stomped back to a
    # param default.
    function Set-TrimClipValues {
        param(
            [Parameter(Mandatory = $true)][string]$Id,
            [double]$GainDb,
            [bool]$Muted,
            [double]$Offset,
            [double]$InStart,
            [double]$InEnd,
            [double]$DurationOverride,
            [bool]$Enabled,
            [double]$PipX,
            [double]$PipY,
            [double]$PipW,
            [double]$PipH,
            [bool]$PipNull
        )
        $ref = Get-TrimClipRef -Id $Id
        if ($null -eq $ref) { return }
        $t = $ref.Clip
        if ($PSBoundParameters.ContainsKey("GainDb")) { $t.GainDb = [math]::Max(-30.0, [math]::Min(30.0, $GainDb)) }
        if ($PSBoundParameters.ContainsKey("Muted")) { $t.Muted = $Muted }
        if ($PSBoundParameters.ContainsKey("Offset")) { $t.Offset = [math]::Max(0.0, $Offset) }
        if ($PSBoundParameters.ContainsKey("InStart")) { $t.InStart = [math]::Max(0.0, $InStart) }
        if ($PSBoundParameters.ContainsKey("InEnd")) { $t.InEnd = [math]::Max(0.0, $InEnd) }
        # 0.2s floor, the same one New-TrimClip enforces for image clips (spec 4.3).
        if ($PSBoundParameters.ContainsKey("DurationOverride")) { $t.DurationOverride = [math]::Max(0.2, $DurationOverride) }
        if ($PSBoundParameters.ContainsKey("Enabled")) { $t.Enabled = $Enabled }
        # The full-frame toggle (spec 4.6): Pip $null IS full-frame, so this is a distinct
        # write from any X/Y/W/H and wins over them when both are bound.
        if ($PSBoundParameters.ContainsKey("PipNull") -and $PipNull) {
            $t.Pip = $null
        } elseif ($PSBoundParameters.ContainsKey("PipX") -or $PSBoundParameters.ContainsKey("PipY") -or
                  $PSBoundParameters.ContainsKey("PipW") -or $PSBoundParameters.ContainsKey("PipH")) {
            if ($null -eq $t.Pip) { $t.Pip = @{ X = 0.5; Y = 0.5; W = 0.3; H = 0.3 } }
            # W/H first, THEN X/Y clamped against whichever W/H is now in effect -- a
            # center clamp against the OLD size would let a box that just grew hang off
            # the frame edge for one write. 0.05..1.0 (doubles, never int literals: the
            # Max(0, double) truncation trap) matches the binding contract.
            if ($PSBoundParameters.ContainsKey("PipW")) { $t.Pip.W = [math]::Max(0.05, [math]::Min(1.0, $PipW)) }
            if ($PSBoundParameters.ContainsKey("PipH")) { $t.Pip.H = [math]::Max(0.05, [math]::Min(1.0, $PipH)) }
            $curW = [double]$t.Pip.W
            $curH = [double]$t.Pip.H
            if ($PSBoundParameters.ContainsKey("PipX")) {
                $t.Pip.X = [math]::Max($curW / 2.0, [math]::Min(1.0 - $curW / 2.0, $PipX))
            }
            if ($PSBoundParameters.ContainsKey("PipY")) {
                $t.Pip.Y = [math]::Max($curH / 2.0, [math]::Min(1.0 - $curH / 2.0, $PipY))
            }
        }
        Update-TrimLaneRows
        Request-TrimProjectSave
    }

    # The ROW fader/mute (spec 3.2): an audio lane's gain and mute belong to the row, not to
    # one clip on it, so the write goes through to EVERY clip on the lane. Per-clip values
    # are kept equal by construction this way, which is what lets the row badge read clip 0.
    function Set-TrimLaneAudioValues {
        param(
            [Parameter(Mandatory = $true)][string]$Id,
            [double]$GainDb,
            [bool]$Muted
        )
        $lane = Get-TrimLaneById -Id $Id
        if ($null -eq $lane) { return }
        foreach ($c in @($lane.Clips)) {
            if ($PSBoundParameters.ContainsKey("GainDb")) { $c.GainDb = [math]::Max(-30.0, [math]::Min(30.0, $GainDb)) }
            if ($PSBoundParameters.ContainsKey("Muted")) { $c.Muted = $Muted }
        }
        Update-TrimLaneRows
        Request-TrimProjectSave
    }

    # The eye (spec 3.2): a video lane is shown or hidden as a whole, so Enabled is written
    # to every clip on it -- the model carries Enabled per clip, the UI offers it per row.
    function Set-TrimLaneEnabled {
        param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][bool]$Enabled)
        $lane = Get-TrimLaneById -Id $Id
        if ($null -eq $lane) { return }
        foreach ($c in @($lane.Clips)) { $c.Enabled = $Enabled }
        Update-TrimLaneRows
        Request-TrimProjectSave
    }

    # Reads the row's headline gain/mute off clip 0 -- see Set-TrimLaneAudioValues for why
    # one clip can stand for the row.
    function Get-TrimLaneHeadClip {
        param($Lane)
        $clips = @($Lane.Clips)
        if ($clips.Count -eq 0) { return $null }
        return $clips[0]
    }

    # Spec 4.4: deleting a linked overlay clip takes its audio peer with it -- a video clip
    # and the audio that came out of the same file are one thing to the user. The MAIN
    # video clip is the exception: it shares its LinkId with every source audio row, and
    # deleting it means "audio-only export" (exactly what deleting v2's video-main did),
    # never "delete all the audio too".
    function Remove-TrimClipWithLinks {
        param([Parameter(Mandatory = $true)][string]$Id)
        $ref = Get-TrimClipRef -Id $Id
        if ($null -eq $ref) { return }
        $ids = if (Test-TrimClipIsMainVideo -Lane $ref.Lane -Clip $ref.Clip) {
            @([string]$Id)
        } else {
            # NOT wrapped in @(): Get-TrimLinkedClipIds returns `,@($ids)`, so @(...) around
            # the call nests the id list one level deeper and every $cid below binds to the
            # whole array -- Get-TrimClipRef then matched nothing and the delete silently
            # removed no clips at all (trap #2).
            Get-TrimLinkedClipIds -Lanes @($script:TrimLanes) -ClipId $Id
        }
        if (@($ids).Count -eq 0) { $ids = @([string]$Id) }
        foreach ($cid in @($ids)) {
            $r = Get-TrimClipRef -Id $cid
            if ($null -eq $r) { continue }
            [void]$r.Lane.Clips.Remove($r.Clip)
            if ($script:TrimSelectedClip -eq $cid) { $script:TrimSelectedClip = $null }
        }
        Update-TrimLaneRows
        # Same reasoning as Remove-TrimLaneRow's: deleting the main video clip is one of the
        # ways the stack becomes audio-only, and the selection text is where that shows.
        Update-TrimSelectionText
        Request-TrimProjectSave
    }

    # One row's trash: the lane and everything on it. Deleting the MAIN video lane is how a
    # user asks for an audio-only export, exactly as deleting v2's video-main track was.
    function Remove-TrimLaneRow {
        param([Parameter(Mandatory = $true)][string]$Id)
        $lane = Get-TrimLaneById -Id $Id
        if ($null -eq $lane) { return }
        foreach ($c in @($lane.Clips)) {
            if ($script:TrimSelectedClip -eq [string]$c.Id) { $script:TrimSelectedClip = $null }
        }
        [void]$script:TrimLanes.Remove($lane)
        if ($script:TrimSelectedLane -eq $Id) { $script:TrimSelectedLane = $null }
        Update-TrimLaneRows
        # Removing a row can flip the stack into (or out of) the audio-only state, which is
        # only ever announced through the selection text -- so it is refreshed here rather
        # than at each of the several call sites that can delete a row.
        Update-TrimSelectionText
        Request-TrimProjectSave
    }

    # The video lane header's trash: the lane AND every audio lane grouped under it, since
    # those rows are that video's own audio and would be left orphaned otherwise.
    function Remove-TrimLaneGroup {
        param([Parameter(Mandatory = $true)][string]$Id)
        $lane = Get-TrimLaneById -Id $Id
        if ($null -eq $lane) { return }
        $victims = @($lane)
        if ($lane.Kind -eq "video") {
            foreach ($g in @(Get-TrimLaneGroups)) {
                if ($null -ne $g.VideoLane -and [string]$g.VideoLane.Id -eq [string]$Id) {
                    foreach ($a in @($g.AudioLanes)) { $victims += ,$a }
                }
            }
        }
        foreach ($v in $victims) { Remove-TrimLaneRow -Id ([string]$v.Id) }
    }

    # V-numbering (spec 4.5) by POSITION: the main lane is V1 wherever it sits, and the other
    # video lanes count outward from the row nearest it. Its own function rather than an
    # inline block in Update-TrimLaneRows because the add flow labels a new grouped audio row
    # "{Vn} audio" and has to agree with what the header will print. Reads the lanes array
    # directly: Get-TrimLaneGroups walks the video lanes in that same order, so the two agree
    # without this needing the grouping pass.
    function Get-TrimVideoLaneNames {
        $videoLanes = @(@($script:TrimLanes) | Where-Object { $_.Kind -eq "video" })
        $names = @{}
        $mainIdx = -1
        for ($i = 0; $i -lt @($videoLanes).Count; $i++) {
            if ([bool]$videoLanes[$i].IsMain) { $mainIdx = $i; break }
        }
        if ($mainIdx -ge 0) {
            $names[[string]$videoLanes[$mainIdx].Id] = "V1"
            $n = 2
            for ($i = $mainIdx - 1; $i -ge 0; $i--) { $names[[string]$videoLanes[$i].Id] = "V$n"; $n++ }
            for ($i = $mainIdx + 1; $i -lt @($videoLanes).Count; $i++) { $names[[string]$videoLanes[$i].Id] = "V$n"; $n++ }
        } else {
            $n = 1
            for ($i = 0; $i -lt @($videoLanes).Count; $i++) { $names[[string]$videoLanes[$i].Id] = "V$n"; $n++ }
        }
        return $names
    }

    # Spec 4.3: a new video lane goes to the TOP of the list (the topmost video lane paints
    # last, so a new one is what the user expects to see over everything); a new audio lane
    # goes to the end. Returns the lane so the caller can select it.
    #
    # -AfterLaneId overrides both placements and drops the new row directly BELOW the named
    # lane. The add flow needs it for a video clip's own audio row: an appended row would sit
    # at the bottom of the stack until the next Get-TrimLaneGroups pass hoisted it, which
    # renders as the row visibly jumping, and a group whose video lane is not immediately
    # above its audio rows is not what spec 2's grouping draws.
    function Add-TrimLaneRow {
        param([Parameter(Mandatory = $true)][string]$Kind, [string]$Label = "", [string]$AfterLaneId = "")
        $text = if ([string]::IsNullOrWhiteSpace($Label)) {
            if ($Kind -eq "video") { "Video" } else { "Audio" }
        } else { $Label }
        $lane = New-TrimLane -Kind $Kind -Label $text
        # New-TrimLane hands back a plain array; the app's invariant is an ArrayList per
        # lane so clips can be added in place (see Set-TrimLanes).
        $lane.Clips = New-Object System.Collections.ArrayList
        $afterIdx = -1
        if (-not [string]::IsNullOrEmpty($AfterLaneId)) {
            for ($i = 0; $i -lt $script:TrimLanes.Count; $i++) {
                if ([string]$script:TrimLanes[$i].Id -eq [string]$AfterLaneId) { $afterIdx = $i; break }
            }
        }
        if ($afterIdx -ge 0) { $script:TrimLanes.Insert($afterIdx + 1, $lane) }
        elseif ($Kind -eq "video") { $script:TrimLanes.Insert(0, $lane) }
        else { [void]$script:TrimLanes.Add($lane) }
        Update-TrimLaneRows
        Request-TrimProjectSave
        return $lane
    }

    # Adds an already-built clip to a lane. Separate from Add-TrimLaneRow so the add flow
    # can drop a clip onto an EXISTING row without creating one.
    function Add-TrimClipToLane {
        param([Parameter(Mandatory = $true)][string]$LaneId, [Parameter(Mandatory = $true)]$Clip)
        $lane = Get-TrimLaneById -Id $LaneId
        if ($null -eq $lane) { return }
        [void]$lane.Clips.Add($Clip)
    }

    # The â‹®â‹® reorder. A video lane never travels alone: its grouped audio rows are that
    # video's own audio and move as one block, or the group would silently dissolve on the
    # next Get-TrimLaneGroups pass (which reads the lanes array IN ORDER).
    function Move-TrimLaneTo {
        param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][int]$NewIndex)
        $lane = Get-TrimLaneById -Id $Id
        if ($null -eq $lane) { return }
        $block = @($lane)
        if ($lane.Kind -eq "video") {
            foreach ($g in @(Get-TrimLaneGroups)) {
                if ($null -ne $g.VideoLane -and [string]$g.VideoLane.Id -eq [string]$Id) {
                    foreach ($a in @($g.AudioLanes)) { $block += ,$a }
                }
            }
        }
        $blockIds = @{}
        foreach ($b in $block) { $blockIds[[string]$b.Id] = $true }
        $rest = @()
        foreach ($l in @($script:TrimLanes)) { if (-not $blockIds.ContainsKey([string]$l.Id)) { $rest += ,$l } }
        $idx = [math]::Max(0, [math]::Min(@($rest).Count, $NewIndex))
        $out = @()
        for ($i = 0; $i -lt @($rest).Count; $i++) {
            if ($i -eq $idx) { foreach ($b in $block) { $out += ,$b } }
            $out += ,$rest[$i]
        }
        if ($idx -ge @($rest).Count) { foreach ($b in $block) { $out += ,$b } }
        Set-TrimLanes -Lanes @($out)
        Update-TrimLaneRows
        Request-TrimProjectSave
    }

    # Grouping (spec 2): an audio lane belongs under a video lane when it holds at least one
    # clip and EVERY one of its clips is linked to a clip on that video lane. Anything else
    # -- an empty row, a row with a free clip on it, a row linked to two different videos --
    # is a free row and lands in the trailing group. Evaluated in lanes-array order, so the
    # first video lane that can claim an audio row gets it.
    function Get-TrimLaneGroups {
        $lanes = @($script:TrimLanes)
        $videoLanes = @(@($lanes) | Where-Object { $_.Kind -eq "video" })
        $audioLanes = @(@($lanes) | Where-Object { $_.Kind -eq "audio" })
        $claimed = @{}
        $groups = @()
        foreach ($v in $videoLanes) {
            $vLinks = @{}
            foreach ($c in @($v.Clips)) {
                $lk = [string]$c.LinkId
                if (-not [string]::IsNullOrEmpty($lk)) { $vLinks[$lk] = $true }
            }
            $members = @()
            foreach ($a in $audioLanes) {
                if ($claimed.ContainsKey([string]$a.Id)) { continue }
                $clips = @($a.Clips)
                if ($clips.Count -eq 0) { continue }
                $all = $true
                foreach ($c in $clips) {
                    $lk = [string]$c.LinkId
                    if ([string]::IsNullOrEmpty($lk) -or -not $vLinks.ContainsKey($lk)) { $all = $false; break }
                }
                if ($all) {
                    $members += ,$a
                    $claimed[[string]$a.Id] = $true
                }
            }
            $groups += ,@{ VideoLane = $v; AudioLanes = @($members) }
        }
        $free = @()
        foreach ($a in $audioLanes) { if (-not $claimed.ContainsKey([string]$a.Id)) { $free += ,$a } }
        $groups += ,@{ VideoLane = $null; AudioLanes = @($free) }
        # PLAIN @(), never `,@()` -- every caller wraps this call in @(...) to get array
        # semantics, and a `,@()` return emits the whole list as ONE object, which @(...)
        # then wraps again (trap #2, the nesting Get-TrimAudioStreams's comment describes).
        # It looked right for as long as there was exactly one video lane: iterating the
        # 1-element outer array once, `$g.VideoLane` member-enumerated to that lane and
        # `$g.AudioLanes` to every audio row, which is the same answer. With a SECOND
        # video lane it collapsed the whole stack into one row whose Label was every video
        # lane's label concatenated. Same convention as Get-RecentFiles.
        return @($groups)
    }

    # U / the toolbar button. Pops the SELECTED clip out of its link group (spec 4.2's
    # pop-one-with-orphan-tidy, which Clear-TrimClipLinks owns) -- or, with a lane header
    # selected, pops every clip on that lane. A selection with no links at all is a no-op
    # rather than an undo step that changes nothing.
    function Invoke-TrimUnlink {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        $targets = @()
        if ($null -ne $script:TrimSelectedClip) {
            $ref = Get-TrimClipRef -Id $script:TrimSelectedClip
            if ($null -ne $ref -and -not [string]::IsNullOrEmpty([string]$ref.Clip.LinkId)) {
                $targets += ,([string]$ref.Clip.Id)
            }
        } elseif ($null -ne $script:TrimSelectedLane) {
            $lane = Get-TrimLaneById -Id $script:TrimSelectedLane
            if ($null -ne $lane) {
                foreach ($c in @($lane.Clips)) {
                    if (-not [string]::IsNullOrEmpty([string]$c.LinkId)) { $targets += ,([string]$c.Id) }
                }
            }
        }
        if (@($targets).Count -eq 0) { return }
        Push-TrimUndo
        foreach ($cid in @($targets)) {
            [void](Clear-TrimClipLinks -Lanes @($script:TrimLanes) -ClipId $cid)
        }
        Update-TrimLaneRows
        Request-TrimProjectSave
    }

    # Clip selection. A clip Id string (or $null), like the caption/zoom selections.
    # Selecting a clip drops the caption and zoom selections AND the lane selection -- four
    # selections sharing one Delete key and one gold highlight would otherwise be ambiguous
    # (spec 3.3's single gold selection). Redraw is the caller's job, exactly as it is for
    # Set-TrimSelectedCaption/Zoom.
    function Set-TrimSelectedClip {
        param($Id)
        $script:TrimSelectedClip = $Id
        if ($null -ne $Id) {
            $script:TrimSelectedLane = $null
            Clear-TrimCaptionSelection
            Clear-TrimZoomSelection
        }
    }

    function Set-TrimSelectedLane {
        param($Id)
        $script:TrimSelectedLane = $Id
        if ($null -ne $Id) {
            $script:TrimSelectedClip = $null
            Clear-TrimCaptionSelection
            Clear-TrimZoomSelection
        }
    }

    # Snap is a TOOL MODE, not a per-file setting: it lives in settings.json and survives
    # the session, the same convention $script:ZoomMagnet follows within one.
    # Reader, so a click handler never has to touch $script:TrimSnapEnabled bare (inside a
    # closure that read would land in the closure's own module and come back $null).
    function Get-TrimSnapEnabled {
        return [bool]$script:TrimSnapEnabled
    }

    function Set-TrimSnapEnabled {
        param([Parameter(Mandatory = $true)][bool]$Value)
        $script:TrimSnapEnabled = $Value
        $global:TrimSnapEnabled = $Value
        Save-Settings
        Update-TrimSnapButton
    }

    # The toolbar magnet's accent. The button itself arrives with Task 11's XAML, so this
    # is null-guarded exactly like every other optional control lookup in this file.
    function Update-TrimSnapButton {
        if ($null -eq $buttonTrimSnap) { return }
        if ($script:TrimSnapEnabled) {
            $accent = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#3E9B84")
            $buttonTrimSnap.BorderBrush = $accent
            if ($null -ne $textTrimSnapGlyph) { $textTrimSnapGlyph.Foreground = $accent }
        } else {
            $buttonTrimSnap.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
            if ($null -ne $textTrimSnapGlyph) {
                $textTrimSnapGlyph.ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty)
            }
        }
    }

    # A clip's own source duration for span math: the probed duration of ITS file from
    # $script:TrimClipDurations (populated at add-time and, for a restored project, once
    # per clip in $onTrimFile) -- NOT the main video's duration, which is only right for
    # the main lane's own clip. 0.0 on a cache miss rather than re-probing here: this runs
    # on every mouse-move of a live drag, and shelling out to ffprobe that often would
    # stall it.
    function Get-TrimClipSourceDuration {
        param($Lane, $Clip)
        if (Test-TrimClipIsMainVideo -Lane $Lane -Clip $Clip) { return [double]$script:TrimDuration }
        $p = [string]$Clip.Path
        if ($p -eq [string]$script:TrimInputFile) { return [double]$script:TrimDuration }
        if ($script:TrimClipDurations.ContainsKey($p)) { return [double]$script:TrimClipDurations[$p] }
        return 0.0
    }

    function Get-TrimClipBarBounds {
        param($Lane, $Clip)
        $span = Get-TrimClipSpan -Clip $Clip -SourceDuration (Get-TrimClipSourceDuration -Lane $Lane -Clip $Clip)
        $left = Convert-TrimTimeToX -Seconds ([double]$span.Start)
        $right = Convert-TrimTimeToX -Seconds ([double]$span.End)
        return @{ Left = $left; Width = [math]::Max(2.0, $right - $left) }
    }

    # The ONE cache read for a clip's own source duration, without needing its lane: the
    # link-aware transforms are group-wide and walk clips that live on OTHER rows, where
    # Get-TrimClipSourceDuration's -Lane argument is not to hand. 0.0 on a miss rather
    # than re-probing -- this runs on every mouse-move of a live drag.
    function Get-TrimClipCachedDuration {
        param($Clip)
        if ($null -eq $Clip) { return 0.0 }
        $p = [string]$Clip.Path
        if ($script:TrimClipDurations.ContainsKey($p)) { return [double]$script:TrimClipDurations[$p] }
        if ($p -eq [string]$script:TrimInputFile) { return [double]$script:TrimDuration }
        return 0.0
    }

    # clipId -> @{Border; Canvas}, filled by Update-TrimLaneRows as it renders and read
    # once at drag start. Write-throughs rather than bare $script: writes so the render
    # loop and any closure are looking at the same hashtable.
    function Clear-TrimClipElements {
        $script:TrimClipElements = @{}
    }

    function Register-TrimClipElement {
        param([Parameter(Mandatory = $true)][string]$ClipId, $Border, $Canvas)
        $script:TrimClipElements[$ClipId] = @{ Border = $Border; Canvas = $Canvas }
    }

    function Get-TrimClipElement {
        param([string]$ClipId)
        if ([string]::IsNullOrEmpty($ClipId)) { return $null }
        if ($script:TrimClipElements.ContainsKey($ClipId)) { return $script:TrimClipElements[$ClipId] }
        return $null
    }

    # Same drag lifecycle as the caption lane and the row fader, field for field: snapshot
    # taken at mouse-down (pushed on release only if something actually moved), the drag
    # applied against the ORIGINAL values every move (never accumulated deltas, which drift
    # and let a clamp "eat" motion), and direct references to the Border(s)/Canvas this drag
    # owns rather than a redraw -- Update-TrimLaneRows rebuilds every row's Border/Grid/
    # Canvas from scratch, which would tear down the very canvas this drag has captured
    # (which is why it bails on Test-TrimClipDrag).
    #
    # What is new here is the LINK GROUP. Every model write goes through the group-aware
    # transforms (Move-TrimClipLinked / Set-TrimClipInPointLinked / Set-TrimClipOutPointLinked),
    # which apply ONE shared clamped delta to every member -- so a linked video/audio pair
    # can never drift apart. The peers' own Borders live on their own row canvases and are
    # repositioned in the same gesture, so the pair visibly travels together.
    #
    # Snap (spec 4.8): the point set is built ONCE at drag start with the dragged clip's
    # whole link group excluded (a clip must not snap to itself) and the playhead included.
    # A linked pair snaps as ONE: the resolve runs on the dragged edge and the winning
    # position feeds the shared delta, never per member.
    function Start-TrimClipDrag {
        param(
            [Parameter(Mandatory = $true)][string]$ClipId,
            [string]$Mode = "move",
            [double]$StartX,
            $Canvas,
            $Border,
            $PeerElements = $null
        )
        $ref = Get-TrimClipRef -Id $ClipId
        if ($null -eq $ref) { return }
        $clip = $ref.Clip
        # The pre-drag span, in the same resolved form Get-TrimClipSpan hands the renderer:
        # the InEnd 0.0 "natural end" sentinel is resolved through the duration cache here
        # so the edge math below works on literal timestamps (the trap Task 8's ported drag
        # documented). Span.End on a cache miss is Offset + 0, which leaves the edge inert
        # rather than inventing a duration -- the backend clamps refuse it too.
        $span = Get-TrimClipSpan -Clip $clip -SourceDuration (Get-TrimClipCachedDuration -Clip $clip)
        # Assigned plainly, never `@(Get-TrimLinkedClipIds ...)`: the function returns
        # `,@($ids)`, so an @(...) around the CALL nests the list one level deeper (trap #2).
        # @($groupIds) below is safe -- a variable unrolls normally.
        $groupIds = Get-TrimLinkedClipIds -Lanes @($script:TrimLanes) -ClipId $ClipId
        # Originals for EVERY member: the release test is "did anything in the link group
        # actually move", and the group is what the transforms write to.
        $orig = @{}
        foreach ($gid in $groupIds) {
            $r = Get-TrimClipRef -Id ([string]$gid)
            if ($null -eq $r) { continue }
            $orig[[string]$gid] = @{
                Offset           = [double]$r.Clip.Offset
                InStart          = [double]$r.Clip.InStart
                InEnd            = [double]$r.Clip.InEnd
                DurationOverride = [double]$r.Clip.DurationOverride
            }
        }
        # Peer Borders, by clip id, from the map the render filled. A caller may pass its
        # own list; the default is to resolve the whole link group here. A peer with no
        # rendered single-body Border (a cut-list-space row, which is not draggable) is
        # simply left out -- its model still moves, and the rebuild on release redraws it.
        $peers = @()
        if ($null -ne $PeerElements) {
            $peers = @($PeerElements)
        } else {
            foreach ($gid in $groupIds) {
                if ([string]$gid -eq [string]$ClipId) { continue }
                $el = Get-TrimClipElement -ClipId ([string]$gid)
                if ($null -eq $el) { continue }
                $peers += ,@{ ClipId = [string]$gid; Border = $el.Border; Canvas = $el.Canvas }
            }
        }
        $state = Get-TrimTimelineState
        $fadeLengths = Get-TrimFadeLengths -Pieces @($state.Pieces)
        $tlPlayhead = Convert-TrimSourceToTimeline -SourceSeconds $script:TrimPlayhead -TimelinePieces $state.TimelinePieces
        # Same trap-#2 rule as $groupIds: Get-TrimSnapPoints returns `,@($points)`, so it is
        # assigned plainly here rather than wrapped at the call.
        $snapPoints = Get-TrimSnapPoints -Lanes @($script:TrimLanes) -Pieces @($state.Pieces) `
            -FadeLengths ([double[]]@($fadeLengths)) -ClipDurations $script:TrimClipDurations `
            -MainPath $script:TrimInputFile -PlayheadTimeline $tlPlayhead `
            -ExcludeClipIds ([string[]]@($groupIds))
        $script:TrimClipDrag = @{
            ClipId        = [string]$ClipId
            Mode          = $Mode
            StartX        = $StartX
            Canvas        = $Canvas
            Border        = $Border
            Peers         = @($peers)
            GroupIds      = @($groupIds)
            Orig          = $orig
            OrigOffset    = [double]$clip.Offset
            OrigSpanStart = [double]$span.Start
            OrigSpanEnd   = [double]$span.End
            # Restored when the drag comes off a snap lock and on release: the snapped
            # highlight must not outlive the lock that caused it.
            OrigBrush     = $(if ($null -ne $Border) { $Border.BorderBrush } else { $null })
            SnapPoints    = @($snapPoints)
            Snapshot      = New-TrimUndoSnapshot
        }
    }

    function Test-TrimClipDrag {
        return ($null -ne $script:TrimClipDrag)
    }

    # ~8px of pull, expressed in SECONDS through the live view scale -- Resolve-TrimSnap
    # knows nothing about pixels, and the threshold has to shrink as the user zooms in or
    # the pull would cover minutes at full-project zoom.
    function Get-TrimSnapThreshold {
        return 8.0 * $script:TrimViewSpan / [math]::Max(1.0, $canvasTrimTimeline.ActualWidth)
    }

    function Update-TrimClipDrag {
        param([double]$CurrentX)
        $drag = $script:TrimClipDrag
        if ($null -eq $drag) { return }
        $ref = Get-TrimClipRef -Id $drag.ClipId
        if ($null -eq $ref) { return }
        $dt = Convert-TrimPixelsToSeconds -Pixels ($CurrentX - $drag.StartX)
        $snapInfo = $null
        switch ($drag.Mode) {
            "instart" {
                $edge = $drag.OrigSpanStart + $dt
                if ($script:TrimSnapEnabled) {
                    $s = Resolve-TrimSnap -Position $edge -Points $drag.SnapPoints -Threshold (Get-TrimSnapThreshold)
                    if ($s.Snapped) { $edge = $s.Position; $snapInfo = $s }
                }
                # The transform is delta-based and clamps group-wide; feed it the delta
                # from the CURRENT clip state so repeated moves stay convergent.
                $curSpan = Get-TrimClipSpan -Clip $ref.Clip -SourceDuration (Get-TrimClipCachedDuration -Clip $ref.Clip)
                [void](Set-TrimClipInPointLinked -Lanes @($script:TrimLanes) -ClipId $drag.ClipId -Delta ($edge - [double]$curSpan.Start))
            }
            "inend" {
                $edge = $drag.OrigSpanEnd + $dt
                if ($script:TrimSnapEnabled) {
                    $s = Resolve-TrimSnap -Position $edge -Points $drag.SnapPoints -Threshold (Get-TrimSnapThreshold)
                    if ($s.Snapped) { $edge = $s.Position; $snapInfo = $s }
                }
                $curSpan = Get-TrimClipSpan -Clip $ref.Clip -SourceDuration (Get-TrimClipCachedDuration -Clip $ref.Clip)
                [void](Set-TrimClipOutPointLinked -Lanes @($script:TrimLanes) -ClipId $drag.ClipId -Delta ($edge - [double]$curSpan.End) -ClipDurations $script:TrimClipDurations)
            }
            default {
                $target = $drag.OrigOffset + $dt
                if ($script:TrimSnapEnabled) {
                    $threshold = Get-TrimSnapThreshold
                    # Both edges pull; the closer lock wins (start tested first on a tie).
                    $len = $drag.OrigSpanEnd - $drag.OrigSpanStart
                    $s1 = Resolve-TrimSnap -Position $target -Points $drag.SnapPoints -Threshold $threshold
                    $s2 = Resolve-TrimSnap -Position ($target + $len) -Points $drag.SnapPoints -Threshold $threshold
                    if ($s1.Snapped -and (-not $s2.Snapped -or [math]::Abs($s1.Position - $target) -le [math]::Abs($s2.Position - ($target + $len)))) {
                        $target = $s1.Position; $snapInfo = $s1
                    } elseif ($s2.Snapped) {
                        $target = $s2.Position - $len; $snapInfo = $s2
                    }
                }
                # Applied against ORIGINALS via the pure link-aware transform (never
                # accumulated deltas): rebuild the offset from the recorded origin.
                [void](Move-TrimClipLinked -Lanes @($script:TrimLanes) -ClipId $drag.ClipId -NewOffset $target)
            }
        }
        Update-TrimSnapFlash -SnapInfo $snapInfo
        Update-TrimClipDragGeometry
    }

    # The mockup's snap feedback: a 2px #3E9B84 line across the whole stack at the locked
    # point with a code-built glow (never a Theme storyboard -- see the frozen-storyboard
    # startup trap), plus the dragged Border's own .snapped border colour. Removed the
    # instant the drag comes off the lock. +250 for the same reason the playhead carries
    # it: the overlay spans the panel while Convert-TrimTimeToX is body-relative.
    function Update-TrimSnapFlash {
        param($SnapInfo)
        $snapped = ($null -ne $SnapInfo -and [bool]$SnapInfo.Snapped)
        $drag = $script:TrimClipDrag
        if ($null -ne $drag -and $null -ne $drag.Border) {
            if ($snapped) {
                $drag.Border.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#3E9B84")
            } elseif ($null -ne $drag.OrigBrush) {
                $drag.Border.BorderBrush = $drag.OrigBrush
            }
        }
        if ($null -eq $canvasTrimLaneOverlay) { return }
        $old = $script:TrimSnapFlashLine
        if ($null -ne $old -and $canvasTrimLaneOverlay.Children.Contains($old)) {
            $canvasTrimLaneOverlay.Children.Remove($old)
        }
        $script:TrimSnapFlashLine = $null
        if (-not $snapped) { return }
        $x = 250.0 + (Convert-TrimTimeToX -Seconds ([double]$SnapInfo.Point))
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $x; $line.X2 = $x
        $line.Y1 = 0
        # Same 4000 as the playhead: taller than any realistic stack, cropped by the
        # overlay canvas's own ClipToBounds.
        $line.Y2 = 4000
        $line.Stroke = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#3E9B84")
        $line.StrokeThickness = 2
        $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $glow.Color = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString("#3E9B84"))
        $glow.BlurRadius = 8
        $glow.ShadowDepth = 0
        $line.Effect = $glow
        [void]$canvasTrimLaneOverlay.Children.Add($line)
        $script:TrimSnapFlashLine = $line
    }

    # Repositions the dragged Border AND every peer Border in place from fresh
    # Get-TrimClipSpan values -- no Children.Clear(), no new elements -- so it can run on
    # every mouse-move without disturbing the mouse capture the drag is holding.
    function Update-TrimClipDragGeometry {
        $drag = $script:TrimClipDrag
        if ($null -eq $drag) { return }
        $targets = @()
        $targets += ,@{ ClipId = [string]$drag.ClipId; Border = $drag.Border }
        foreach ($p in @($drag.Peers)) { $targets += ,$p }
        foreach ($t in $targets) {
            if ($null -eq $t.Border) { continue }
            $r = Get-TrimClipRef -Id ([string]$t.ClipId)
            if ($null -eq $r) { continue }
            $bounds = Get-TrimClipBarBounds -Lane $r.Lane -Clip $r.Clip
            [System.Windows.Controls.Canvas]::SetLeft($t.Border, [double]$bounds.Left)
            $t.Border.Width = [double]$bounds.Width
        }
    }

    function Complete-TrimClipDrag {
        $drag = $script:TrimClipDrag
        if ($null -eq $drag) { return }
        # Before the state is dropped: the flash reads $script:TrimClipDrag to put the
        # dragged Border's own brush back.
        Update-TrimSnapFlash -SnapInfo $null
        $script:TrimClipDrag = $null
        # Sub-millisecond differences are the jitter of a plain click, not a move -- and
        # the whole link group is tested, because a clamp can leave the dragged member
        # where it was while its peers moved.
        $changed = $false
        foreach ($gid in @($drag.GroupIds)) {
            $o = $drag.Orig[[string]$gid]
            if ($null -eq $o) { continue }
            $r = Get-TrimClipRef -Id ([string]$gid)
            if ($null -eq $r) { continue }
            if (([math]::Abs([double]$r.Clip.Offset - [double]$o.Offset) -gt 0.001) -or
                ([math]::Abs([double]$r.Clip.InStart - [double]$o.InStart) -gt 0.001) -or
                ([math]::Abs([double]$r.Clip.InEnd - [double]$o.InEnd) -gt 0.001) -or
                ([math]::Abs([double]$r.Clip.DurationOverride - [double]$o.DurationOverride) -gt 0.001)) {
                $changed = $true
                break
            }
        }
        # The rebuild happens either way: it is what re-paints the gold selection a
        # drag-start set directly, and (through Task 9's trim-aware filmstrip/waveform
        # cache keys) what re-requests the row media for a clip whose in/out just moved.
        if ($changed) {
            Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
            Request-TrimProjectSave
        }
        Update-TrimLaneRows
    }

    # Grouped NLE rows (spec 3.1-3.3 and the approved mockup): one row per visible lane,
    # each a 250px header beside a body canvas, video lanes 44px with their own audio rows
    # indented 18px under a gold spine beneath them, free audio rows flat at the bottom.
    # Video clip bodies carry filmstrips, audio clip bodies carry waveforms.
    #
    # Rebuilt from scratch on every structural change, like the caption/zoom lanes -- with
    # one exception. While a drag is live, this returns immediately instead: a full
    # rebuild replaces every row's Canvas with a brand-new object, and WPF releases mouse
    # capture the instant the captured element leaves the visual tree, which would abort
    # the drag after its very first pixel of movement. The live drag repositions the one
    # element it owns directly instead, and this catches back up on mouse-up.
    function Update-TrimLaneRows {
        if ($null -eq $panelTrimLanes) { return }
        if (Test-TrimClipDrag) { return }
        if (Test-TrimLaneReorderDrag) { return }
        if (Test-TrimLaneGainDrag) { return }
        # Prunes the PiP/audio-clip preview pools down to the clips that still exist --
        # every structural change (add, delete, undo/redo, unlink, load) reaches here,
        # which is exactly when a clip can have vanished out from under its pooled
        # MediaElement.
        Sync-TrimClipMediaElementPools
        $panelTrimLanes.Children.Clear()
        # The clipId -> Border map is as disposable as the rows themselves: every element
        # in it is about to be replaced, and a stale entry would hand the next drag a
        # Border that is no longer in the visual tree.
        Clear-TrimClipElements
        if (-not $script:TrimInputFile -or @($script:TrimLanes).Count -eq 0) {
            $panelTrimLanes.Visibility = "Collapsed"
            # Null-guarded like every FindName control: a stale MainWindow.xaml from an
            # in-place update can predate the add-track row.
            if ($null -ne $panelTrimAddTracks) { $panelTrimAddTracks.Visibility = "Collapsed" }
            Update-TrimLaneOverlay
            return
        }
        # Always visible now: spec 4.1 makes the source audio rows part of the ordinary
        # single-file session (no U toggle needed to see them).
        $panelTrimLanes.Visibility = "Visible"
        if ($null -ne $panelTrimAddTracks) { $panelTrimAddTracks.Visibility = "Visible" }

        $bc = New-Object System.Windows.Media.BrushConverter
        $goldBrush        = $bc.ConvertFromString("#E0C48F")
        $lineBrush        = $bc.ConvertFromString("#2A3B52")
        $dimBrush         = $bc.ConvertFromString("#44506A")
        $iconBrush        = $bc.ConvertFromString("#8FA8C0")
        $iconBackBrush    = $bc.ConvertFromString("#101828")
        $redBrush         = $bc.ConvertFromString("#E64A3C")
        $redBackBrush     = $bc.ConvertFromString("#2A1210")
        $trashBrush       = $bc.ConvertFromString("#E68A7C")
        $trashBackBrush   = $bc.ConvertFromString("#1A0D0B")
        $trashBorderBrush = $bc.ConvertFromString("#B3382A")
        $clipBorderBrush  = $bc.ConvertFromString("#5A82B8")
        $imageBorderBrush = $bc.ConvertFromString("#8CC7FF")
        $placeholderBrush = $bc.ConvertFromString("#101828")
        $audioBodyBrush   = $bc.ConvertFromString("#16324E")
        $railBrush        = $bc.ConvertFromString("#1A2436")
        $fillBrush        = $bc.ConvertFromString("#5A7EA8")
        $plateBrush       = $bc.ConvertFromString("#88000000")
        $chipBackBrush    = $bc.ConvertFromString("#99070B14")
        $plateTextBrush   = $bc.ConvertFromString("#DDE7F2")

        $eyeGlyph   = [char]::ConvertFromUtf32(0x1F441)   # the eye is a surrogate PAIR
        $trashGlyph = [char]::ConvertFromUtf32(0x1F5D1)
        $liveGlyph  = [char]::ConvertFromUtf32(0x1F50A)
        $mutedGlyph = [char]::ConvertFromUtf32(0x1F507)

        # Display order: each video lane, then its own audio rows (skipped while the group
        # is collapsed), then the free rows flat at the bottom.
        $ordered = @()
        foreach ($g in @(Get-TrimLaneGroups)) {
            if ($null -ne $g.VideoLane) {
                $ordered += ,@{ Lane = $g.VideoLane; Grouped = $false; MainGroup = [bool]$g.VideoLane.IsMain }
                if (-not $script:TrimCollapsedLanes.ContainsKey([string]$g.VideoLane.Id)) {
                    # MainGroup marks the rows that live in CUT-LIST space rather than raw
                    # source space -- V1 and the source-audio rows still linked to it. An
                    # unlinked row leaves the group (spec 4.2) and with it this flag, which
                    # is exactly when its clips gain real Offset/InStart/InEnd freedom.
                    foreach ($a in @($g.AudioLanes)) {
                        $ordered += ,@{ Lane = $a; Grouped = $true; MainGroup = [bool]$g.VideoLane.IsMain }
                    }
                }
            } else {
                foreach ($a in @($g.AudioLanes)) { $ordered += ,@{ Lane = $a; Grouped = $false; MainGroup = $false } }
            }
        }

        # Numbering by POSITION (spec 4.5): the main lane is always V1 wherever it sits,
        # the other video lanes count upward from the row nearest it, and the free audio
        # lanes are A1.. top-down. Grouped audio rows show a note glyph, not a number.
        # The V-numbers come from Get-TrimVideoLaneNames so the add flow, which labels a new
        # grouped audio row "{Vn} audio", agrees with what this header prints.
        $names = Get-TrimVideoLaneNames
        $an = 1
        foreach ($e in $ordered) {
            if ($e.Lane.Kind -eq "audio" -and -not $e.Grouped) { $names[[string]$e.Lane.Id] = "A$an"; $an++ }
        }

        # Timeline geometry for the ghosts: V1's own end (the cut list) and the full
        # timeline including anything that runs past it (spec 4.7's montage).
        $state = Get-TrimTimelineState
        $v1End = [double]$state.TotalDuration
        # The structural refresh of the cache the transport/ruler read (the other one is in
        # Update-TrimTimeline, for piece edits): every add, delete, drag-drop, unlink,
        # undo/redo and load rebuilds these rows, which is exactly when a clip can have
        # started or stopped reaching past V1's end.
        $timelineLength = Update-TrimTimelineLengthCache
        $focusLane = Get-TrimFaderFocusLane

        foreach ($entry in $ordered) {
            $ln = $entry.Lane
            $thisId = [string]$ln.Id
            $isVideoLane = ($ln.Kind -eq "video")
            # Captured by the trash handler below: the main lane deletes ALONE (audio-only
            # export), never as a group.
            $isMainLane = [bool]$ln.IsMain
            $isGrouped = [bool]$entry.Grouped
            $isSelectedLane = ($thisId -eq [string]$script:TrimSelectedLane)
            $rowHeight = $(if ($isVideoLane) { 44.0 } else { 40.0 })
            $head = Get-TrimLaneHeadClip -Lane $ln
            # The row's headline state: an empty row reads as live and unmuted rather than
            # crashing on a clip that isn't there.
            $rowMuted = $(if ($null -ne $head) { [bool]$head.Muted } else { $false })
            $rowEnabled = $(if ($null -ne $head) { [bool]$head.Enabled } else { $true })
            $rowGain = $(if ($null -ne $head) { [double]$head.GainDb } else { 0.0 })
            $rowDim = $(if ($isVideoLane) { -not $rowEnabled } else { $rowMuted })
            $isCollapsed = $script:TrimCollapsedLanes.ContainsKey($thisId)

            $rowGrid = New-Object System.Windows.Controls.Grid
            $rowGrid.Height = $rowHeight
            $rowGrid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
            # A row is transparent to hit-testing where nothing painted; without a real
            # Background the drop events only fire over the header and clip bodies.
            $rowGrid.Background = [System.Windows.Media.Brushes]::Transparent

            # Files dropped straight onto a row land in THIS lane, at the drop position --
            # the identical Add-TrimMediaFromPath flow the header's "Add media..." dialog
            # uses, so kind refusals (audio file on a video lane, adds to V1) and the
            # on-demand audio rows behave exactly the same. GetNewClosure for $thisId,
            # like every other per-row handler.
            $rowGrid.AllowDrop = $true
            $rowGrid.Add_PreviewDragOver({
                param($eventSource, $e)
                if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
                    $e.Effects = [System.Windows.DragDropEffects]::Copy
                    $e.Handled = $true
                }
            })
            $rowGrid.Add_Drop({
                param($eventSource, $e)
                if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
                $files = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
                if ($files.Count -eq 0) { return }
                # The shared timeline canvas is the x-reference for every strip, so the
                # drop position converts with the same mapping the playhead uses.
                $t = Convert-TrimXToTime -X ($e.GetPosition($canvasTrimTimeline)).X
                foreach ($f in $files) {
                    Add-TrimMediaFromPath -Path ([string]$f) -TargetLaneId $thisId -AtTimeline ([math]::Max(0.0, $t))
                }
                $e.Handled = $true
            }.GetNewClosure())
            $c0 = New-Object System.Windows.Controls.ColumnDefinition
            $c0.Width = New-Object System.Windows.GridLength(250)
            $c1 = New-Object System.Windows.Controls.ColumnDefinition
            $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            [void]$rowGrid.ColumnDefinitions.Add($c0)
            [void]$rowGrid.ColumnDefinitions.Add($c1)

            # ---- Header (column 0) ----
            # A grouped audio row is inset 18px and carries a 2px gold spine on its left
            # edge. The spine is its own element rather than a BorderBrush: WPF gives a
            # Border ONE brush for all four sides, and the other three stay #2A3B52.
            $headHost = New-Object System.Windows.Controls.DockPanel
            $headHost.LastChildFill = $true
            if ($isGrouped) {
                $headHost.Margin = New-Object System.Windows.Thickness(18, 0, 0, 0)
                $spine = New-Object System.Windows.Controls.Border
                $spine.Width = 2
                $spine.Background = $goldBrush
                [System.Windows.Controls.DockPanel]::SetDock($spine, "Left")
                [void]$headHost.Children.Add($spine)
            }
            [System.Windows.Controls.Grid]::SetColumn($headHost, 0)

            $headerBorder = New-Object System.Windows.Controls.Border
            $headerBorder.Style = $ctx.Window.FindResource("LaneHeaderStyle")
            if ($isSelectedLane) { $headerBorder.BorderBrush = $goldBrush }
            Add-TrimLaneHeaderContextMenu -Header $headerBorder -LaneId $thisId `
                -IsVideoLane $isVideoLane -IsMainLane $isMainLane
            [void]$headHost.Children.Add($headerBorder)

            # Auto | * | Auto: left identity block, stretchy middle (the fader), right
            # button block -- the mockup's flex header, expressed as a Grid.
            $headGrid = New-Object System.Windows.Controls.Grid
            $headGrid.Margin = New-Object System.Windows.Thickness(7, 0, 7, 0)
            foreach ($w in @(0, 1, 2)) {
                $cd = New-Object System.Windows.Controls.ColumnDefinition
                $cd.Width = $(if ($w -eq 1) {
                    New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
                } else {
                    New-Object System.Windows.GridLength(0, [System.Windows.GridUnitType]::Auto)
                })
                [void]$headGrid.ColumnDefinitions.Add($cd)
            }
            $headerBorder.Child = $headGrid

            $leftPanel = New-Object System.Windows.Controls.StackPanel
            $leftPanel.Orientation = "Horizontal"
            $leftPanel.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($leftPanel, 0)
            [void]$headGrid.Children.Add($leftPanel)

            $rightPanel = New-Object System.Windows.Controls.StackPanel
            $rightPanel.Orientation = "Horizontal"
            $rightPanel.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($rightPanel, 2)
            [void]$headGrid.Children.Add($rightPanel)

            if ($isVideoLane) {
                $grip = New-Object System.Windows.Controls.TextBlock
                $grip.Text = [string][char]0x22EE + [string][char]0x22EE
                $grip.Foreground = $dimBrush
                $grip.FontSize = 12
                $grip.VerticalAlignment = "Center"
                $grip.Cursor = [System.Windows.Input.Cursors]::SizeNS
                $grip.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
                Add-TrimLaneReorderHandlers -Grip $grip -Header $headerBorder -LaneId $thisId
                [void]$leftPanel.Children.Add($grip)

                $caret = New-Object System.Windows.Controls.Button
                $caret.Style = $ctx.Window.FindResource("LaneCaretButtonStyle")
                $caret.Content = $(if ($isCollapsed) { [string][char]0x25B8 } else { [string][char]0x25BE })
                $caret.VerticalAlignment = "Center"
                # GetNewClosure over the per-row locals ONLY, and every write goes through a
                # top-level write-through -- a bare $script: read or write in here would land
                # in this closure's own private module and never see the real state.
                $caret.Add_Click({
                    Set-TrimLaneCollapsed -Id $thisId -Collapsed (-not $isCollapsed)
                }.GetNewClosure())
                [void]$leftPanel.Children.Add($caret)

                $nameBlock = New-Object System.Windows.Controls.TextBlock
                $nameBlock.Style = $ctx.Window.FindResource("LaneNameStyle")
                $nameBlock.Text = $(if ($names.ContainsKey($thisId)) { [string]$names[$thisId] } else { "V" })
                $nameBlock.VerticalAlignment = "Center"
                $nameBlock.Margin = New-Object System.Windows.Thickness(3, 0, 5, 0)
                [void]$leftPanel.Children.Add($nameBlock)
            } else {
                # A FREE audio row carries its own ⋮⋮ (the mockup draws one on A1/A2 but
                # not on a grouped ♪ row): a grouped row's position is decided by its
                # video lane's block, so a handle there would promise a move that
                # Get-TrimLaneGroups would immediately undo on the next rebuild.
                if (-not $isGrouped) {
                    $agrip = New-Object System.Windows.Controls.TextBlock
                    $agrip.Text = [string][char]0x22EE + [string][char]0x22EE
                    $agrip.Foreground = $dimBrush
                    $agrip.FontSize = 12
                    $agrip.VerticalAlignment = "Center"
                    $agrip.Cursor = [System.Windows.Input.Cursors]::SizeNS
                    $agrip.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
                    Add-TrimLaneReorderHandlers -Grip $agrip -Header $headerBorder -LaneId $thisId
                    [void]$leftPanel.Children.Add($agrip)
                }
                $note = New-Object System.Windows.Controls.TextBlock
                $note.Text = [string][char]0x266A
                $note.Foreground = $iconBrush
                $note.FontSize = 11
                $note.FontWeight = "Bold"
                $note.VerticalAlignment = "Center"
                $note.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
                [void]$leftPanel.Children.Add($note)
                if (-not $isGrouped) {
                    $nameBlock = New-Object System.Windows.Controls.TextBlock
                    $nameBlock.Style = $ctx.Window.FindResource("LaneNameStyle")
                    $nameBlock.Text = $(if ($names.ContainsKey($thisId)) { [string]$names[$thisId] } else { "A" })
                    $nameBlock.VerticalAlignment = "Center"
                    $nameBlock.Margin = New-Object System.Windows.Thickness(0, 0, 5, 0)
                    [void]$leftPanel.Children.Add($nameBlock)
                }
            }

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Style = $ctx.Window.FindResource("LaneLabelStyle")
            $label.VerticalAlignment = "Center"
            $labelText = [string]$ln.Label
            if ([string]::IsNullOrWhiteSpace($labelText)) {
                if (@($ln.Clips).Count -eq 0) {
                    $labelText = "empty"
                } elseif ($isVideoLane) {
                    $labelText = $(if ($isMainLane) { [System.IO.Path]::GetFileName([string]$script:TrimInputFile) } else { "Overlay" })
                } else {
                    $labelText = "audio"
                }
            }
            $label.Text = $labelText
            if (@($ln.Clips).Count -eq 0) { $label.Foreground = $dimBrush }
            $label.MaxWidth = $(if ($isVideoLane) { 108 } else { 62 })
            [void]$leftPanel.Children.Add($label)

            if ($isVideoLane) {
                # Eye: the lane's clips render (grey) or are excluded from render AND
                # preview (red, and the row's clip bodies dim to 40%).
                $eye = New-Object System.Windows.Controls.Button
                $eye.Style = $ctx.Window.FindResource("LaneIconButtonStyle")
                $eye.Content = $eyeGlyph
                $eye.Foreground = $(if ($rowEnabled) { $iconBrush } else { $redBrush })
                $eye.Background = $(if ($rowEnabled) { $iconBackBrush } else { $redBackBrush })
                $eye.BorderBrush = $(if ($rowEnabled) { $lineBrush } else { $redBrush })
                $eye.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
                $eye.Add_Click({
                    Push-TrimUndo
                    Set-TrimLaneEnabled -Id $thisId -Enabled (-not $rowEnabled)
                }.GetNewClosure())
                [void]$rightPanel.Children.Add($eye)
            } else {
                # Fader (the stretchy middle column) + dB badge, mute, trash on the right.
                $faderPanel = New-Object System.Windows.Controls.StackPanel
                $faderPanel.MinWidth = 70
                $faderPanel.VerticalAlignment = "Center"
                $faderPanel.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
                $faderPanel.Opacity = $(if ($rowMuted) { 0.4 } else { 1.0 })
                [System.Windows.Controls.Grid]::SetColumn($faderPanel, 1)
                [void]$headGrid.Children.Add($faderPanel)

                $railCanvas = New-Object System.Windows.Controls.Canvas
                # 13, not the rail's own 5: the rail is 5px of PAINT, but a 5px tall click
                # target is a dart throw. The canvas is as tall as the thumb and the rail
                # sits inset inside it, so the whole thumb-height band drags the fader.
                $railCanvas.Height = 13
                $railCanvas.Focusable = $true
                $railCanvas.Cursor = [System.Windows.Input.Cursors]::Hand
                # A Canvas paints nothing by default and an unpainted area is not hit
                # testable, so the transparent background IS what makes the rail clickable.
                $railCanvas.Background = [System.Windows.Media.Brushes]::Transparent
                [void]$faderPanel.Children.Add($railCanvas)

                $rail = New-Object System.Windows.Controls.Border
                $rail.Height = 5
                $rail.Background = $railBrush
                $rail.BorderBrush = $lineBrush
                $rail.BorderThickness = New-Object System.Windows.Thickness(1)
                $rail.CornerRadius = New-Object System.Windows.CornerRadius(2)
                [System.Windows.Controls.Canvas]::SetLeft($rail, 0)
                [System.Windows.Controls.Canvas]::SetTop($rail, 4)
                [void]$railCanvas.Children.Add($rail)

                $faderFill = New-Object System.Windows.Shapes.Rectangle
                $faderFill.Height = 5
                $faderFill.Fill = $fillBrush
                [System.Windows.Controls.Canvas]::SetLeft($faderFill, 0)
                [System.Windows.Controls.Canvas]::SetTop($faderFill, 4)
                [void]$railCanvas.Children.Add($faderFill)

                $thumb = New-Object System.Windows.Shapes.Rectangle
                $thumb.Width = 5
                $thumb.Height = 13
                $thumb.RadiusX = 1; $thumb.RadiusY = 1
                $thumb.Fill = $goldBrush
                [System.Windows.Controls.Canvas]::SetTop($thumb, 0)
                [void]$railCanvas.Children.Add($thumb)

                $ticks = New-Object System.Windows.Controls.Canvas
                $ticks.Height = 4
                $ticks.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
                [void]$faderPanel.Children.Add($ticks)

                $badge = New-Object System.Windows.Controls.TextBlock
                $badge.FontSize = 9
                $badge.Foreground = $goldBrush
                $badge.Width = 34
                $badge.TextAlignment = "Right"
                $badge.VerticalAlignment = "Center"
                $badge.Opacity = $(if ($rowMuted) { 0.4 } else { 1.0 })
                $badge.Text = "{0:+0.0;-0.0;0}" -f $rowGain
                $badge.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
                [void]$rightPanel.Children.Add($badge)

                # First paint and every resize: the rail's width is only known after
                # layout, so the fill/thumb/ticks are placed from the SizeChanged pass.
                $railCanvas.Add_SizeChanged({
                    param($eventSource, $e)
                    Update-TrimFaderVisual -Rail $rail -Fill $faderFill -Thumb $thumb -Ticks $ticks -Badge $badge `
                        -Gain (Get-TrimLaneGain -Id $thisId) -Width $eventSource.ActualWidth
                }.GetNewClosure())

                # The edit bracket: snapshot at mouse-down, live writes on move, one undo
                # entry on release if anything changed. Capture lives on the rail CANVAS,
                # never on the thumb -- the thumb moves out from under the pointer.
                $railCanvas.Add_MouseLeftButtonDown({
                    param($eventSource, $e)
                    $w = $eventSource.ActualWidth
                    if ($w -le 0) { return }
                    if ($e.ClickCount -ge 2) {
                        # Double-click resets to 0.0 dB as its OWN undo step; the bracket
                        # the first click opened is dropped rather than pushed.
                        Clear-LaneGainEdit
                        [void]$eventSource.ReleaseMouseCapture()
                        Push-TrimUndo
                        Set-TrimLaneAudioValues -Id $thisId -GainDb 0.0
                        $e.Handled = $true
                        return
                    }
                    Start-LaneGainEdit -LaneId $thisId
                    Set-LaneGainDragging -Value $true
                    Set-TrimFaderFocusLane -Id $thisId
                    [void]$eventSource.Focus()
                    [void]$eventSource.CaptureMouse()
                    Set-TrimLaneAudioValues -Id $thisId -GainDb (Convert-TrimFaderXToGain -X ($e.GetPosition($eventSource)).X -Width $w)
                    Update-TrimFaderVisual -Rail $rail -Fill $faderFill -Thumb $thumb -Ticks $ticks -Badge $badge `
                        -Gain (Get-TrimLaneGain -Id $thisId) -Width $w
                    $e.Handled = $true
                }.GetNewClosure())

                $railCanvas.Add_MouseMove({
                    param($eventSource, $e)
                    if (-not (Test-TrimLaneGainDrag)) { return }
                    $w = $eventSource.ActualWidth
                    if ($w -le 0) { return }
                    Set-TrimLaneAudioValues -Id $thisId -GainDb (Convert-TrimFaderXToGain -X ($e.GetPosition($eventSource)).X -Width $w)
                    Update-TrimFaderVisual -Rail $rail -Fill $faderFill -Thumb $thumb -Ticks $ticks -Badge $badge `
                        -Gain (Get-TrimLaneGain -Id $thisId) -Width $w
                }.GetNewClosure())

                $railCanvas.Add_MouseLeftButtonUp({
                    param($eventSource, $e)
                    if (-not (Test-TrimLaneGainDrag)) { return }
                    [void]$eventSource.ReleaseMouseCapture()
                    Set-LaneGainDragging -Value $false
                    Complete-LaneGainEdit
                    Update-TrimLaneRows
                })

                # Keyboard nudge, through the SAME bracket: Start- is a no-op while one is
                # already open for this lane, and the 600ms debounce closes it once the
                # presses stop -- so a burst of Up/Down is one undo entry (spec 8).
                $railCanvas.Add_PreviewKeyDown({
                    param($eventSource, $e)
                    $isUp = ($e.Key -eq [System.Windows.Input.Key]::Up)
                    $isDown = ($e.Key -eq [System.Windows.Input.Key]::Down)
                    if (-not $isUp -and -not $isDown) { return }
                    Start-LaneGainEdit -LaneId $thisId
                    Set-TrimFaderFocusLane -Id $thisId
                    Set-TrimLaneAudioValues -Id $thisId -GainDb ((Get-TrimLaneGain -Id $thisId) + $(if ($isUp) { 0.5 } else { -0.5 }))
                    Request-LaneGainCommit
                    $e.Handled = $true
                }.GetNewClosure())

                # The row rebuild a keyboard nudge triggers destroys the focused canvas;
                # without this the second Up press would go nowhere.
                if ($null -ne $focusLane -and [string]$focusLane -eq $thisId) {
                    $railCanvas.Add_Loaded({
                        param($eventSource, $e)
                        [void]$eventSource.Focus()
                    })
                }

                $mute = New-Object System.Windows.Controls.Button
                $mute.Style = $ctx.Window.FindResource("LaneIconButtonStyle")
                $mute.Content = $(if ($rowMuted) { $mutedGlyph } else { $liveGlyph })
                $mute.Foreground = $(if ($rowMuted) { $redBrush } else { $iconBrush })
                $mute.Background = $(if ($rowMuted) { $redBackBrush } else { $iconBackBrush })
                $mute.BorderBrush = $(if ($rowMuted) { $redBrush } else { $lineBrush })
                $mute.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
                $mute.Add_Click({
                    Push-TrimUndo
                    Set-TrimLaneAudioValues -Id $thisId -Muted (-not $rowMuted)
                }.GetNewClosure())
                [void]$rightPanel.Children.Add($mute)
            }

            # A video row's trash takes its grouped audio rows with it -- EXCEPT the main
            # lane's. Get-TrimLaneStack links V1 and every source audio row on one shared
            # LinkId, so the main lane's "group" is the whole stack; taking the group there
            # would delete everything and hit the "Every track was deleted" refusal instead
            # of producing the audio-only export that deleting the main video has always
            # meant (v2's video-main delete, and Remove-TrimLaneRow's own contract).
            $trash = New-Object System.Windows.Controls.Button
            $trash.Style = $ctx.Window.FindResource("LaneIconButtonStyle")
            $trash.Content = $trashGlyph
            $trash.Foreground = $trashBrush
            $trash.Background = $trashBackBrush
            $trash.BorderBrush = $trashBorderBrush
            $trash.Add_Click({
                Push-TrimUndo
                if ($isVideoLane -and -not $isMainLane) {
                    Remove-TrimLaneGroup -Id $thisId
                } else {
                    Remove-TrimLaneRow -Id $thisId
                }
            }.GetNewClosure())
            [void]$rightPanel.Children.Add($trash)

            [void]$rowGrid.Children.Add($headHost)

            # ---- Body (column 1) ----
            $bodyBorder = New-Object System.Windows.Controls.Border
            $bodyBorder.Style = $ctx.Window.FindResource("LaneRowStyle")
            $bodyBorder.CornerRadius = New-Object System.Windows.CornerRadius(0, 4, 4, 0)
            $bodyBorder.ClipToBounds = $true
            if ($isSelectedLane) { $bodyBorder.BorderBrush = $goldBrush }
            [System.Windows.Controls.Grid]::SetColumn($bodyBorder, 1)
            $bodyCanvas = New-Object System.Windows.Controls.Canvas
            $bodyCanvas.Background = [System.Windows.Media.Brushes]::Transparent
            $bodyCanvas.ClipToBounds = $true
            $bodyBorder.Child = $bodyCanvas
            [void]$rowGrid.Children.Add($bodyBorder)

            # Clip drags are driven from the row CANVAS, not from the clip bodies: the
            # canvas is what holds the mouse capture (a Border that a rebuild replaced
            # would lose it), and it keeps receiving the move/up even while the pointer
            # travels over other rows. No GetNewClosure on these three -- they read and
            # write $script: state through top-level functions and capture nothing but
            # $eventSource, which WPF supplies.
            $bodyCanvas.Add_MouseMove({
                param($eventSource, $e)
                if (-not (Test-TrimClipDrag)) { return }
                Update-TrimClipDrag -CurrentX ($e.GetPosition($eventSource)).X
            })

            $bodyCanvas.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (-not (Test-TrimClipDrag)) { return }
                [void]$eventSource.ReleaseMouseCapture()
                Complete-TrimClipDrag
            })

            # Losing the capture some other way (another window steals focus mid-drag)
            # would otherwise leave the drag live forever -- and Update-TrimLaneRows bails
            # while it is, so the whole stack would stop redrawing.
            $bodyCanvas.Add_LostMouseCapture({
                param($eventSource, $e)
                if (-not (Test-TrimClipDrag)) { return }
                Complete-TrimClipDrag
            })

            $bodyWidth = $bodyCanvas.ActualWidth
            # No -250 here: every timeline-space row now shares the 250px header inset
            # (MainWindow.xaml), so CanvasTrimTimeline IS body width.
            if ($bodyWidth -le 0) { $bodyWidth = [math]::Max(0.0, $canvasTrimTimeline.ActualWidth) }
            $clipHeight = $rowHeight - 6.0
            $isMainGroupRow = [bool]$entry.MainGroup

            foreach ($clip in @($ln.Clips)) {
                $thisClipId = [string]$clip.Id
                $isMainClip = Test-TrimClipIsMainVideo -Lane $ln -Clip $clip
                $isSelectedClip = ($thisClipId -eq [string]$script:TrimSelectedClip)
                $isImageClip = ([string]$clip.Kind -eq "image")
                $isAudioClip = ([string]$clip.Kind -eq "audio")
                $sourceDuration = Get-TrimClipSourceDuration -Lane $ln -Clip $clip

                # CUT-LIST SPACE vs SOURCE SPACE. V1's own clip and the source-audio rows
                # still linked to it are not free clips: what they show is the assembled
                # cut list, the same pieces the ruler and the filmstrip above are drawn
                # from. Laying them out from Get-TrimClipSpan (which knows only raw
                # in/out) would run them past V1's end the moment anything is cut, and
                # their media would cover deleted footage -- so the peaks would stop
                # sitting under the frames they belong to. These rows are therefore drawn
                # as ONE BODY PER TIMELINE PIECE, each piece placed at its timeline x and
                # filled from its own source range. Every other clip keeps the single
                # source-space body it always had.
                $cutSpace = $isMainClip -or ($isAudioClip -and $isMainGroupRow -and
                    [string]$clip.Path -eq [string]$script:TrimInputFile)

                $segments = @()
                if ($cutSpace) {
                    $tps = @($state.TimelinePieces)
                    $srcTotal = 0.0
                    foreach ($q in $tps) { $srcTotal += ([double]$q.SourceEnd - [double]$q.SourceStart) }
                    foreach ($q in $tps) {
                        $sx1 = Convert-TrimTimeToX -Seconds ([double]$q.TimelineStart)
                        $sx2 = Convert-TrimTimeToX -Seconds ([double]$q.TimelineEnd)
                        $segLen = [double]$q.SourceEnd - [double]$q.SourceStart
                        # The eight-frame budget is spread across the pieces by length
                        # rather than spent per piece: twenty cuts would otherwise mean
                        # 160 ffmpeg extractions for one row.
                        $frames = 8
                        if ($srcTotal -gt 0.0) {
                            $frames = [int][math]::Round(8.0 * $segLen / $srcTotal)
                        }
                        $frames = [math]::Max(1, [math]::Min(8, $frames))
                        $segments += ,@{
                            Left = $sx1; Width = [math]::Max(2.0, $sx2 - $sx1)
                            SrcStart = [double]$q.SourceStart; SrcEnd = [double]$q.SourceEnd; Frames = $frames
                        }
                    }
                } else {
                    $bounds = Get-TrimClipBarBounds -Lane $ln -Clip $clip
                    $segments += ,@{
                        Left = [double]$bounds.Left; Width = [double]$bounds.Width
                        SrcStart = [double]$clip.InStart
                        SrcEnd = $(if ([double]$clip.InEnd -gt 0.0) { [double]$clip.InEnd } else { $sourceDuration })
                        Frames = 8
                    }
                }

                $segIndex = 0
                $segCount = @($segments).Count
                foreach ($seg in $segments) {
                    $isFirstSeg = ($segIndex -eq 0)
                    $isLastSeg = ($segIndex -eq $segCount - 1)
                    $segIndex++

                    # V1's bodies ARE the cut pieces now that the SRC strip is hidden, so
                    # the piece selection ($script:TrimSelected, what Del removes) paints
                    # here: the selected piece's body gets the gold selected border.
                    $isSelectedPiece = ($cutSpace -and $isMainClip -and ($segIndex - 1) -eq $script:TrimSelected)
                    $clipBorder = New-Object System.Windows.Controls.Border
                    $clipBorder.Height = $clipHeight
                    $clipBorder.Width = [double]$seg.Width
                    $clipBorder.CornerRadius = New-Object System.Windows.CornerRadius(3)
                    $clipBorder.ClipToBounds = $true
                    $clipBorder.BorderThickness = New-Object System.Windows.Thickness($(if ($isSelectedClip -or $isSelectedPiece) { 2 } else { 1 }))
                    $clipBorder.BorderBrush = $(if ($isSelectedClip -or $isSelectedPiece) { $goldBrush }
                        elseif ($isImageClip) { $imageBorderBrush } else { $clipBorderBrush })
                    $clipBorder.Background = $(if ($isAudioClip) { $audioBodyBrush } else { $placeholderBrush })
                    $clipBorder.Opacity = $(if ($rowDim -or -not $clip.Enabled) { 0.4 } else { 1.0 })
                    $clipBorder.Cursor = [System.Windows.Input.Cursors]::Hand
                    [System.Windows.Controls.Canvas]::SetLeft($clipBorder, [double]$seg.Left)
                    [System.Windows.Controls.Canvas]::SetTop($clipBorder, 3)

                    $clipGrid = New-Object System.Windows.Controls.Grid
                    $clipBorder.Child = $clipGrid

                    if ($isAudioClip) {
                        $wave = Request-TrimRowWaveform -Path ([string]$clip.Path) -StreamIndex ([int]$clip.StreamIdx) `
                            -InStart ([double]$seg.SrcStart) -Length ([math]::Max(0.0, [double]$seg.SrcEnd - [double]$seg.SrcStart)) `
                            -Width 1600 -Height 34
                        if ($null -ne $wave) {
                            $waveImage = New-Object System.Windows.Controls.Image
                            $waveImage.Source = $wave
                            $waveImage.Stretch = "Fill"
                            $waveImage.Opacity = 0.85
                            [void]$clipGrid.Children.Add($waveImage)
                        }
                    } elseif ($isImageClip) {
                        # An image clip is its own filmstrip: one stretched frame, no ffmpeg.
                        $still = Get-TrimStripImage -FilePath ([string]$clip.Path)
                        if ($null -ne $still) {
                            $stillImage = New-Object System.Windows.Controls.Image
                            $stillImage.Source = $still
                            $stillImage.Stretch = "UniformToFill"
                            [void]$clipGrid.Children.Add($stillImage)
                        }
                    } else {
                        $strip = Request-TrimClipStrip -Path ([string]$clip.Path) -InStart ([double]$seg.SrcStart) `
                            -EffInEnd ([double]$seg.SrcEnd) -Frames ([int]$seg.Frames)
                        if ($null -ne $strip) {
                            $stripPanel = New-Object System.Windows.Controls.Primitives.UniformGrid
                            $stripPanel.Rows = 1
                            $stripPanel.Columns = @($strip).Count
                            foreach ($frame in @($strip)) {
                                $cell = New-Object System.Windows.Controls.Image
                                $cell.Source = $frame
                                $cell.Stretch = "UniformToFill"
                                [void]$stripPanel.Children.Add($cell)
                            }
                            [void]$clipGrid.Children.Add($stripPanel)
                        }
                    }

                    # Name plate and chip on the FIRST body only: a cut-space row is one
                    # clip drawn in several pieces, not several clips.
                    if ($isFirstSeg) {
                        $linked = -not [string]::IsNullOrEmpty([string]$clip.LinkId)
                        $plateText = [System.IO.Path]::GetFileName([string]$clip.Path)
                        if ($isMainClip) { $plateText = "{0} - cut to {1}" -f $plateText, (Format-TrimTime $v1End) }
                        if ($isImageClip) { $plateText = "{0} - {1:0.#}s" -f $plateText, [double]$clip.DurationOverride }
                        if ($linked) { $plateText = "{0} {1}" -f $plateText, ([char]::ConvertFromUtf32(0x1F517)) }
                        $plate = New-Object System.Windows.Controls.Border
                        $plate.Background = $plateBrush
                        $plate.HorizontalAlignment = "Left"
                        $plate.VerticalAlignment = "Bottom"
                        $plate.Padding = New-Object System.Windows.Thickness(3, 0, 3, 0)
                        $plateBlock = New-Object System.Windows.Controls.TextBlock
                        $plateBlock.Text = $plateText
                        $plateBlock.FontSize = 8.5
                        $plateBlock.Foreground = $plateTextBrush
                        $plate.Child = $plateBlock
                        [void]$clipGrid.Children.Add($plate)
                    }

                    # State chip on the LAST body, so it sits at the clip's right edge the
                    # way the mockup draws it -- on a cut-space row the first body's right
                    # edge is a cut, not the end of the clip.
                    if (-not $isAudioClip -and $isLastSeg) {
                        $chipText = $(if ($isImageClip) { "img" }
                            elseif ($null -eq $clip.Pip) { [string][char]0x26F6 + " full" }
                            else { "{0} {1:0}% pip" -f ([string][char]0x25F1), ([double]$clip.Pip.W * 100.0) })
                        $chip = New-Object System.Windows.Controls.Border
                        $chip.BorderThickness = New-Object System.Windows.Thickness(1)
                        $chip.BorderBrush = $(if ($isImageClip) { $imageBorderBrush } else { $goldBrush })
                        $chip.Background = $chipBackBrush
                        $chip.CornerRadius = New-Object System.Windows.CornerRadius(3)
                        $chip.Padding = New-Object System.Windows.Thickness(3, 0, 3, 0)
                        $chip.HorizontalAlignment = "Right"
                        $chip.VerticalAlignment = "Top"
                        $chip.Margin = New-Object System.Windows.Thickness(0, 2, 2, 0)
                        $chipBlock = New-Object System.Windows.Controls.TextBlock
                        $chipBlock.Text = $chipText
                        $chipBlock.FontSize = 8.5
                        $chipBlock.Foreground = $(if ($isImageClip) { $imageBorderBrush } else { $goldBrush })
                        $chip.Child = $chipBlock
                        # The chip is the second way into the full-frame/box toggle (the
                        # props strip's button is the first), through the SAME write-through.
                        # Marked Handled so the press never reaches the body's drag handler
                        # underneath. Only where there is something to toggle: an image chip
                        # and V1's own chip are labels, not controls.
                        if (Test-TrimClipCanBox -Lane $ln -Clip $clip) {
                            $chip.Cursor = [System.Windows.Input.Cursors]::Hand
                            $chip.Add_MouseLeftButtonDown({
                                param($eventSource, $e)
                                Set-TrimSelectedClip -Id $thisClipId
                                Invoke-TrimClipDisplayModeToggle -Id $thisClipId
                                $e.Handled = $true
                            }.GetNewClosure())
                        }
                        [void]$clipGrid.Children.Add($chip)
                    }

                    # DRAGGABLE vs FIXED. A cut-list-space row is one clip drawn in several
                    # pieces at positions the CUT LIST decides, not the clip's own
                    # Offset/InStart -- dragging one body would be a lie about what the
                    # model can express (V1 sequencing is out of scope), so those bodies
                    # keep the plain select-and-rebuild handler. Every other clip is a
                    # single source-space body and gets the full drag.
                    if ($cutSpace) {
                        if ($isMainClip) {
                            # Clicking a V1 body selects the PIECE (what Del removes and a
                            # fade sits beside), never the main clip -- deleting the whole
                            # V1 stays on the row's trash. Mirrors what the old SRC piece
                            # click did, including arming the Delete button. GetNewClosure
                            # over the piece ordinal, like every per-item handler.
                            $thisPieceIndex = $segIndex - 1
                            $clipBorder.Add_MouseLeftButtonDown({
                                param($eventSource, $e)
                                Set-TrimSelection -Index $thisPieceIndex
                                Set-TrimSelectedClip -Id $null
                                $buttonTrimDelete.IsEnabled = $true
                                Update-TrimSelectionText
                                Update-TrimTimeline
                                $e.Handled = $true
                            }.GetNewClosure())
                        } else {
                            # GetNewClosure over $thisClipId, exactly as the caption blocks
                            # do -- without it every body captures the loop's final clip and
                            # clicking any of them selects the last.
                            $clipBorder.Add_MouseLeftButtonDown({
                                param($eventSource, $e)
                                Set-TrimSelectedClip -Id $thisClipId
                                Update-TrimLaneRows
                                $e.Handled = $true
                            }.GetNewClosure())
                        }
                    } else {
                        Register-TrimClipElement -ClipId $thisClipId -Border $clipBorder -Canvas $bodyCanvas
                        # Selection is painted DIRECTLY here rather than through a rebuild:
                        # the rebuild would replace the very canvas this press is about to
                        # capture. Update-TrimLaneRows catches up on release.
                        $clipBorder.Add_MouseLeftButtonDown({
                            param($eventSource, $e)
                            Set-TrimSelectedClip -Id $thisClipId
                            $eventSource.BorderBrush = $goldBrush
                            $eventSource.BorderThickness = New-Object System.Windows.Thickness(2)
                            Start-TrimClipDrag -ClipId $thisClipId -Mode "move" `
                                -StartX ($e.GetPosition($bodyCanvas)).X -Canvas $bodyCanvas -Border $eventSource
                            [void]$bodyCanvas.CaptureMouse()
                            $e.Handled = $true
                            Update-TrimClipProps
                        }.GetNewClosure())

                        # Edge grips: 6px transparent strips INSIDE the body that trim the
                        # in/out point instead of moving the clip. Transparent rather than
                        # unset -- a Rectangle with no Fill is not hit-testable at all.
                        # Dropped on bodies too narrow to hold them, where they would leave
                        # no draggable middle. Being children of the body, their press is
                        # handled before it bubbles to the move handler above.
                        if ([double]$seg.Width -ge 20.0) {
                            foreach ($side in @("instart", "inend")) {
                                $edgeGrip = New-Object System.Windows.Shapes.Rectangle
                                $edgeGrip.Width = 6
                                $edgeGrip.Fill = [System.Windows.Media.Brushes]::Transparent
                                $edgeGrip.Cursor = [System.Windows.Input.Cursors]::SizeWE
                                $edgeGrip.HorizontalAlignment = $(if ($side -eq "instart") { "Left" } else { "Right" })
                                $edgeGrip.VerticalAlignment = "Stretch"
                                $thisMode = $side
                                $thisBody = $clipBorder
                                $edgeGrip.Add_MouseLeftButtonDown({
                                    param($eventSource, $e)
                                    Set-TrimSelectedClip -Id $thisClipId
                                    $thisBody.BorderBrush = $goldBrush
                                    $thisBody.BorderThickness = New-Object System.Windows.Thickness(2)
                                    Start-TrimClipDrag -ClipId $thisClipId -Mode $thisMode `
                                        -StartX ($e.GetPosition($bodyCanvas)).X -Canvas $bodyCanvas -Border $thisBody
                                    [void]$bodyCanvas.CaptureMouse()
                                    $e.Handled = $true
                                    Update-TrimClipProps
                                }.GetNewClosure())
                                [void]$clipGrid.Children.Add($edgeGrip)
                            }
                        }
                    }

                    [void]$bodyCanvas.Children.Add($clipBorder)
                }
            }

            # Ghosts (spec 3.3): the montage region past V1's end on the V1 row, and the
            # drop hint on a lane with nothing on it.
            $ghostText = $null
            $ghostLeft = 0.0
            $ghostWidth = 0.0
            if (@($ln.Clips).Count -eq 0) {
                $ghostText = $(if ($isVideoLane) { "drop a video or image here" } else { "drop audio here" })
                $ghostLeft = 0.0
                $ghostWidth = $bodyWidth
            } elseif ($isMainLane -and $isVideoLane -and $timelineLength -gt $v1End + 0.001) {
                $ghostText = "past V1's end -> black base"
                $ghostLeft = Convert-TrimTimeToX -Seconds $v1End
                $ghostWidth = (Convert-TrimTimeToX -Seconds $timelineLength) - $ghostLeft
            }
            if ($null -ne $ghostText -and $ghostWidth -gt 4.0) {
                $ghost = New-Object System.Windows.Controls.Grid
                $ghost.Width = $ghostWidth
                $ghost.Height = $clipHeight
                $ghostRect = New-Object System.Windows.Shapes.Rectangle
                $ghostRect.Stroke = $lineBrush
                $ghostRect.StrokeThickness = 1
                # Built and filled, NOT New-Object with an array: PowerShell splats an
                # array argument across the constructor's parameters, so
                # `New-Object DoubleCollection(@(3, 3))` looks for a 2-argument overload
                # and throws "Cannot find an overload ... argument count: 2" -- which
                # took the whole window down the first time a ghost was drawn.
                $dashes = New-Object System.Windows.Media.DoubleCollection
                [void]$dashes.Add(3.0)
                [void]$dashes.Add(3.0)
                $ghostRect.StrokeDashArray = $dashes
                $ghostRect.RadiusX = 3; $ghostRect.RadiusY = 3
                [void]$ghost.Children.Add($ghostRect)
                $ghostBlock = New-Object System.Windows.Controls.TextBlock
                $ghostBlock.Text = $ghostText
                $ghostBlock.FontSize = 9
                $ghostBlock.Foreground = $dimBrush
                $ghostBlock.HorizontalAlignment = "Center"
                $ghostBlock.VerticalAlignment = "Center"
                [void]$ghost.Children.Add($ghostBlock)
                [System.Windows.Controls.Canvas]::SetLeft($ghost, $ghostLeft)
                [System.Windows.Controls.Canvas]::SetTop($ghost, 3)
                [void]$bodyCanvas.Children.Add($ghost)
            }

            # Whole-row select. Fires for header clicks always, and for body clicks only
            # where no clip body sits -- a clip's own handler marks its clicks Handled.
            $rowGrid.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                Set-TrimSelectedLane -Id $thisId
                Update-TrimLaneRows
            }.GetNewClosure())

            [void]$panelTrimLanes.Children.Add($rowGrid)
        }

        Update-TrimLaneOverlay
        # Every structural change (mute, gain, delete, unlink, undo/redo, load) comes
        # through here, so refreshing the props strip at the end of a row rebuild is enough
        # to keep it in sync without a second call at each of those sites. The points that
        # select a clip WITHOUT rebuilding the rows (drag-start on a bar/grip, mid-drag)
        # call Update-TrimClipProps directly instead.
        Update-TrimClipProps
        # And the PiP box/preview follow the same rule: a row rebuild is what a clip
        # selection change (or add/delete) usually comes through, so this is the one place
        # that keeps both in sync without a second call at every site above.
        Update-PipBoxOverlay
        # Paint order first: a lane reorder changes which clip covers which without
        # touching a single element, so the stack has to be re-asserted before the pass
        # that makes those elements visible.
        Update-TrimPreviewStackOrder
        # NOT -Seek: a rebuild does not move the playhead, and an element that is already
        # inside its span is already showing the right frame. A clip that is genuinely new
        # here has InSpan $false and gets its Position seeded by that branch anyway. This
        # matters because a rebuild is NOT a rare event -- the lane panel's own
        # SizeChanged re-enters it, and seeding on every one of those would re-seek every
        # visible clip several times a second.
        Update-PipPreview -SourceSeconds $script:TrimPlayhead
        Update-TrimBlackBase
    }

    # The caret. Collapsed groups hide their audio rows; the state is UI-only (it never
    # reaches the project file), which is why it lives in a plain hashtable.
    function Set-TrimLaneCollapsed {
        param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][bool]$Collapsed)
        if ($Collapsed) { $script:TrimCollapsedLanes[$Id] = $true }
        else { [void]$script:TrimCollapsedLanes.Remove($Id) }
        Update-TrimLaneRows
    }

    # The stack-spanning playhead, drawn on the overlay canvas that sits above every lane
    # row (Task 10 adds the green snap flash to the same canvas). +250 because the overlay
    # spans the whole panel while Convert-TrimTimeToX is body-relative, and the body starts
    # after the 250px header column.
    function Update-TrimLaneOverlay {
        if ($null -eq $canvasTrimLaneOverlay) { return }
        $canvasTrimLaneOverlay.Children.Clear()
        if (-not $script:TrimInputFile) { return }
        if ($null -eq $panelTrimLanes -or $panelTrimLanes.Visibility -ne "Visible") { return }
        # Get-TrimTimelinePlayhead, not the plain source->timeline convert: out in the
        # montage region the source has run out and only the extension offset knows where
        # the playhead is.
        $tl = Get-TrimTimelinePlayhead
        $x = 250.0 + (Convert-TrimTimeToX -Seconds $tl)
        if ($x -lt 250.0) { return }
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $x; $line.X2 = $x
        $line.Y1 = 0
        # Taller than any realistic stack; the overlay canvas has ClipToBounds="True" so
        # WPF crops the overhang rather than this having to know the panel's height (which
        # is 0 during the very layout pass that adds the rows).
        $line.Y2 = 4000
        $line.Stroke = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#E64A3C")
        $line.StrokeThickness = 2
        [void]$canvasTrimLaneOverlay.Children.Add($line)
    }

    # Spec 4.6: only a NON-MAIN video clip has a display mode to offer. The main lane's clip
    # IS the frame (there is nothing to box it against) and audio has no picture at all; an
    # image clip is drawn by the same PiP path but is out of the toggle's scope here, so it
    # keeps whatever geometry it was given.
    function Test-TrimClipCanBox {
        param($Lane, $Clip)
        if ($null -eq $Lane -or $null -eq $Clip) { return $false }
        if ([string]$Clip.Kind -ne "video") { return $false }
        if (Test-TrimClipIsMainVideo -Lane $Lane -Clip $Clip) { return $false }
        return $true
    }

    # The one place the box's starting geometry is written down, shared by the props-strip
    # button and the clip chip. 35% of the frame WIDE, and as TALL as that width needs to be
    # for the clip's OWN aspect to survive the box (the same frameAspect/clipAspect
    # correction Update-PipBoxDrag's magnet applies), read from the cache the add flow filled
    # so this never shells out to ffprobe.
    function Invoke-TrimClipDisplayModeToggle {
        param([Parameter(Mandatory = $true)][string]$Id)
        $ref = Get-TrimClipRef -Id $Id
        if ($null -eq $ref) { return }
        if (-not (Test-TrimClipCanBox -Lane $ref.Lane -Clip $ref.Clip)) { return }
        Push-TrimUndo
        if ($null -eq $ref.Clip.Pip) {
            $frameAspect = 16.0 / 9.0
            $p = [string]$ref.Clip.Path
            $clipAspect = if ($script:TrimClipAspect.ContainsKey($p)) { [double]$script:TrimClipAspect[$p] } else { $frameAspect }
            if ($clipAspect -le 0.0) { $clipAspect = $frameAspect }
            Set-TrimClipValues -Id $Id -PipX 0.5 -PipY 0.5 -PipW 0.35 -PipH (0.35 * ($frameAspect / $clipAspect))
        } else {
            # $null Pip IS full-frame (spec 4.6) -- a distinct write, not W/H of 1.0.
            Set-TrimClipValues -Id $Id -PipNull $true
        }
        # Set-TrimClipValues rebuilds the rows (which refills this strip) and saves; the box
        # overlay follows from that same rebuild.
    }

    # Fills the CLIP strip from the selection, or hides it. Called after every row rebuild
    # (see Update-TrimLaneRows) and directly from the selection points that intentionally
    # skip a rebuild while a drag is starting. A LANE selection no longer shows the strip:
    # the row's gain/mute/eye/trash live in its header now (spec 3.2).
    function Update-TrimClipProps {
        # "Selection ticks": every row rebuild (load, undo/redo, mute/gain/delete, unlink)
        # ends up here, so this is also the one place that keeps the preview volume caught
        # up with the model without a second call at each of those sites.
        Update-TrimPreviewVolume
        if ($null -eq $panelTrimTrackProps) { return }
        $ref = $null
        if ($null -ne $script:TrimSelectedClip) { $ref = Get-TrimClipRef -Id $script:TrimSelectedClip }
        if ($null -eq $ref) {
            $panelTrimTrackProps.Visibility = "Collapsed"
            return
        }
        $panelTrimTrackProps.Visibility = "Visible"
        $clip = $ref.Clip
        if ($null -ne $textTrackPropsName) {
            $name = [System.IO.Path]::GetFileName([string]$clip.Path)
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$clip.Kind }
            $textTrackPropsName.Text = "{0} ({1})" -f $name, [string]$clip.Kind
        }
        $canBox = Test-TrimClipCanBox -Lane $ref.Lane -Clip $clip
        $boxed = ($null -ne $clip.Pip)
        if ($null -ne $buttonClipDisplayMode) {
            $buttonClipDisplayMode.Visibility = $(if ($canBox) { "Visible" } else { "Collapsed" })
            # The button names what the click DOES, not what the clip currently is.
            $buttonClipDisplayMode.Content = $(if ($boxed) { [string][char]0x26F6 + " Full-frame" } else { [string][char]0x25F1 + " Box" })
        }
        if ($null -ne $textClipDisplayHint) {
            $textClipDisplayHint.Text = $(if ($canBox -and $boxed) { "the box drags in the preview" } else { "" })
        }
    }

    # Approximates the export's per-row gain in the single preview decoder: one MediaElement
    # cannot play separate streams at separate volumes, so this collapses the whole stack to
    # one number -- silence if every source audio clip is muted, otherwise the gain of the
    # first unmuted one. The EXPORT (Tracks.psm1's mix graph) is authoritative; this is only
    # ever what plays back while editing.
    function Update-TrimPreviewVolume {
        if ($null -eq $mediaTrimPreview) { return }
        # SOURCE audio only: the main file's own streams are what this element is decoding.
        # An external audio clip has its own off-tree element (Update-TrimAudioClipPreview).
        $sources = @()
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                if ($c.Kind -ne "audio") { continue }
                if ([string]$c.Path -ne [string]$script:TrimInputFile) { continue }
                if (-not $c.Enabled) { continue }
                $sources += ,$c
            }
        }
        if (@($sources).Count -eq 0) { return }
        $unmuted = @(@($sources) | Where-Object { -not $_.Muted })
        if (@($unmuted).Count -eq 0) {
            $mediaTrimPreview.Volume = 0
            return
        }
        $firstUnmutedSourceGain = [double]$unmuted[0].GainDb
        $mediaTrimPreview.Volume = [math]::Min(1.0, [math]::Pow(10.0, $firstUnmutedSourceGain / 20.0))
    }

    # ---- Row fader edit bracket (spec 3.2) ---------------------------------------
    # The same Start/Complete pair as the zoom sliders, but scoped to a LANE (the props
    # strip's own gain slider is gone -- gain belongs to the row header now) and shared by
    # all three ways a fader moves: a rail drag, a
    # double-click reset, and Up/Down on a focused rail. One undo entry per gesture --
    # for the keyboard that means one entry per BURST of presses, which is what the
    # spec 8 backlog item ("keyboard gain joins the undo bracket") asks for.
    function Start-LaneGainEdit {
        param([Parameter(Mandatory = $true)][string]$LaneId)
        if ($null -ne $script:TrimLaneGainEdit) {
            if ([string]$script:TrimLaneGainEdit.LaneId -eq [string]$LaneId) { return }
            Complete-LaneGainEdit
        }
        $lane = Get-TrimLaneById -Id $LaneId
        if ($null -eq $lane) { return }
        $head = Get-TrimLaneHeadClip -Lane $lane
        $script:TrimLaneGainEdit = @{
            LaneId   = [string]$LaneId
            GainDb   = $(if ($null -ne $head) { [double]$head.GainDb } else { 0.0 })
            Snapshot = New-TrimUndoSnapshot
            Dragging = $false
        }
    }

    function Complete-LaneGainEdit {
        $edit = $script:TrimLaneGainEdit
        $script:TrimLaneGainEdit = $null
        if ($null -eq $edit) { return }
        $lane = Get-TrimLaneById -Id $edit.LaneId
        if ($null -eq $lane) { return }
        $head = Get-TrimLaneHeadClip -Lane $lane
        if ($null -eq $head) { return }
        if ([math]::Abs([double]$head.GainDb - [double]$edit.GainDb) -lt 1e-9) { return }
        Push-TrimUndoSnapshot -Snapshot $edit.Snapshot
    }

    # Drops the bracket WITHOUT pushing it -- the double-click reset takes its own
    # Push-TrimUndo, and the click that opened the bracket changed nothing worth a
    # second entry.
    function Clear-LaneGainEdit {
        $script:TrimLaneGainEdit = $null
    }

    function Set-LaneGainDragging {
        param([bool]$Value)
        if ($null -ne $script:TrimLaneGainEdit) { $script:TrimLaneGainEdit.Dragging = $Value }
    }

    function Test-TrimLaneGainDrag {
        return ($null -ne $script:TrimLaneGainEdit -and [bool]$script:TrimLaneGainEdit.Dragging)
    }

    # The ⋮⋮ reorder drag; the row rebuild has to stand out of its way for the same reason
    # it stands out of a clip drag's, so the test lands here with the state variable it
    # reads.
    function Test-TrimLaneReorderDrag {
        return ($null -ne $script:TrimLaneReorderDrag)
    }

    # A mouse position in PanelTrimTracks coordinates. A top-level function rather than a
    # bare $panelTrimLanes read inside a GetNewClosure'd handler: a closure's variable
    # lookups land in its own private module, where the panel would come back $null and
    # GetPosition would silently measure against the window root instead.
    function Get-TrimLanePanelY {
        param($MouseArgs)
        if ($null -eq $panelTrimLanes -or $null -eq $MouseArgs) { return 0.0 }
        return [double]($MouseArgs.GetPosition($panelTrimLanes)).Y
    }

    # The rows Update-TrimLaneRows paints, in display order, with the heights it gives
    # them (44/40 plus the 4px row margin) -- the one place that geometry is written down
    # for the reorder drag to walk. Grouped rows are marked, because a video lane's block
    # is itself plus the grouped rows under it.
    function Get-TrimLaneDisplayRows {
        $rows = @()
        foreach ($g in @(Get-TrimLaneGroups)) {
            if ($null -ne $g.VideoLane) {
                $rows += ,@{ Lane = $g.VideoLane; Height = 48.0; Grouped = $false }
                if (-not $script:TrimCollapsedLanes.ContainsKey([string]$g.VideoLane.Id)) {
                    foreach ($a in @($g.AudioLanes)) { $rows += ,@{ Lane = $a; Height = 44.0; Grouped = $true } }
                }
            } else {
                foreach ($a in @($g.AudioLanes)) { $rows += ,@{ Lane = $a; Height = 44.0; Grouped = $false } }
            }
        }
        # Plain @(), for the same reason Get-TrimLaneGroups uses one: both call sites wrap
        # this in @(...), and a `,@()` return would nest the list (trap #2).
        return @($rows)
    }

    # Same bracket as every other drag in this panel: snapshot at mouse-down, pushed on
    # release only if the order actually changed. A video lane never travels alone -- its
    # grouped audio rows are that video's own audio and move as one block (Move-TrimLaneTo
    # owns the array surgery; this only decides WHERE).
    function Start-TrimLaneReorderDrag {
        param([Parameter(Mandatory = $true)][string]$LaneId, [double]$StartY)
        $lane = Get-TrimLaneById -Id $LaneId
        if ($null -eq $lane) { return }
        $blockIds = @{}
        $blockIds[[string]$LaneId] = $true
        if ($lane.Kind -eq "video") {
            foreach ($g in @(Get-TrimLaneGroups)) {
                if ($null -ne $g.VideoLane -and [string]$g.VideoLane.Id -eq [string]$LaneId) {
                    foreach ($a in @($g.AudioLanes)) { $blockIds[[string]$a.Id] = $true }
                }
            }
        }
        $script:TrimLaneReorderDrag = @{
            LaneId      = [string]$LaneId
            Kind        = [string]$lane.Kind
            StartY      = $StartY
            BlockIds    = $blockIds
            TargetIndex = -1
            Snapshot    = New-TrimUndoSnapshot
        }
    }

    function Update-TrimLaneReorderDrag {
        param([double]$CurrentY)
        $drag = $script:TrimLaneReorderDrag
        if ($null -eq $drag) { return }
        $rows = @(Get-TrimLaneDisplayRows)
        # Boundary k sits above display row k; boundary N is the bottom of the stack.
        $bounds = @()
        $y = 0.0
        foreach ($r in $rows) { $bounds += ,$y; $y += [double]$r.Height }
        $bounds += ,$y
        # Legal drop points. A video block may only land where a GROUP starts (never
        # between a video lane and its own ♪ rows, which the very next Get-TrimLaneGroups
        # pass would pull back together); a free audio lane reorders within its own
        # section (spec 4.5: audio order is cosmetic, video order is render stacking).
        $allowed = @()
        for ($k = 0; $k -le @($rows).Count; $k++) {
            if ($drag.Kind -eq "video") {
                if ($k -eq @($rows).Count -or -not [bool]$rows[$k].Grouped) { $allowed += ,$k }
            } else {
                $lastIsFree = (@($rows).Count -gt 0 -and $rows[-1].Lane.Kind -eq "audio" -and -not [bool]$rows[-1].Grouped)
                if ($k -eq @($rows).Count) {
                    if ($lastIsFree) { $allowed += ,$k }
                } elseif ($rows[$k].Lane.Kind -eq "audio" -and -not [bool]$rows[$k].Grouped) {
                    $allowed += ,$k
                }
            }
        }
        $best = -1
        $bestDist = [double]::MaxValue
        foreach ($k in $allowed) {
            $d = [math]::Abs($CurrentY - [double]$bounds[$k])
            if ($d -lt $bestDist) { $bestDist = $d; $best = $k }
        }
        $script:TrimLaneReorderDrag.TargetIndex = $best
        Update-TrimLaneReorderIndicator -Y $(if ($best -ge 0) { [double]$bounds[$best] } else { -1.0 })
    }

    # The live feedback: a 2px gold line drawn between rows on the overlay canvas the
    # playhead already lives on. Code-drawn and removed by reference rather than by
    # clearing the canvas, which would take the playhead with it.
    function Update-TrimLaneReorderIndicator {
        param([double]$Y)
        if ($null -eq $canvasTrimLaneOverlay) { return }
        $old = $script:TrimLaneReorderLine
        if ($null -ne $old -and $canvasTrimLaneOverlay.Children.Contains($old)) {
            $canvasTrimLaneOverlay.Children.Remove($old)
        }
        $script:TrimLaneReorderLine = $null
        if ($Y -lt 0.0) { return }
        $w = 4000.0
        if ($null -ne $panelTrimLanes -and $panelTrimLanes.ActualWidth -gt 0) { $w = [double]$panelTrimLanes.ActualWidth }
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = 0; $line.X2 = $w
        $line.Y1 = $Y; $line.Y2 = $Y
        $line.Stroke = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#E0C48F")
        $line.StrokeThickness = 2
        [void]$canvasTrimLaneOverlay.Children.Add($line)
        $script:TrimLaneReorderLine = $line
    }

    function Complete-TrimLaneReorderDrag {
        $drag = $script:TrimLaneReorderDrag
        $script:TrimLaneReorderDrag = $null
        Update-TrimLaneReorderIndicator -Y -1.0
        if ($null -eq $drag) { return }
        $k = [int]$drag.TargetIndex
        if ($k -lt 0) { Update-TrimLaneRows; return }
        # Move-TrimLaneTo's index is measured against the lanes array with the dragged
        # BLOCK already taken out, so walk forward from the drop boundary to the first
        # display row that is not part of the block and look that lane up in the remainder.
        $rows = @(Get-TrimLaneDisplayRows)
        $rest = @()
        $block = @()
        foreach ($l in @($script:TrimLanes)) {
            if ($drag.BlockIds.ContainsKey([string]$l.Id)) { $block += ,$l } else { $rest += ,$l }
        }
        $anchor = $null
        for ($i = $k; $i -lt @($rows).Count; $i++) {
            if (-not $drag.BlockIds.ContainsKey([string]$rows[$i].Lane.Id)) { $anchor = $rows[$i].Lane; break }
        }
        $newIndex = @($rest).Count
        if ($null -ne $anchor) {
            for ($i = 0; $i -lt @($rest).Count; $i++) {
                if ([string]$rest[$i].Id -eq [string]$anchor.Id) { $newIndex = $i; break }
            }
        }
        # A drop that lands the block back where it started is not an undo step. Compare
        # the order Move-TrimLaneTo WOULD produce against the one already there rather
        # than comparing indexes, which differ harmlessly for the same arrangement.
        $idx = [math]::Max(0, [math]::Min(@($rest).Count, $newIndex))
        $wouldBe = @()
        for ($i = 0; $i -lt @($rest).Count; $i++) {
            if ($i -eq $idx) { foreach ($b in $block) { $wouldBe += ,[string]$b.Id } }
            $wouldBe += ,[string]$rest[$i].Id
        }
        if ($idx -ge @($rest).Count) { foreach ($b in $block) { $wouldBe += ,[string]$b.Id } }
        $now = @(foreach ($l in @($script:TrimLanes)) { [string]$l.Id })
        if (($wouldBe -join "|") -eq ($now -join "|")) { Update-TrimLaneRows; return }
        Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
        # Rebuild + save are Move-TrimLaneTo's own; the V-numbers renumber by position on
        # that rebuild (spec 4.5), and IsMain keeps "V1" wherever it lands.
        Move-TrimLaneTo -Id $drag.LaneId -NewIndex $newIndex
    }

    # Empty non-main lanes: the rows "Delete empty tracks" clears. The MAIN lane is excluded
    # even when it has no clips -- deleting it is the audio-only-export gesture, never
    # housekeeping.
    function Get-TrimEmptyLaneIds {
        $ids = @()
        foreach ($l in @($script:TrimLanes)) {
            if ([bool]$l.IsMain) { continue }
            if (@($l.Clips).Count -eq 0) { $ids += ,([string]$l.Id) }
        }
        return @($ids)
    }

    # ONE undo step for the whole sweep (the menu item reads as a single action), which is
    # why the Push is here and not inside the loop.
    function Invoke-TrimDeleteEmptyLanes {
        $ids = @(Get-TrimEmptyLaneIds)
        if (@($ids).Count -eq 0) { return }
        Push-TrimUndo
        foreach ($id in $ids) { Remove-TrimLaneRow -Id $id }
    }

    # The row header's right-click menu. Built per row in code (there is no XAML row), and a
    # separate function so every MenuItem closure captures this function's OWN parameters
    # rather than the render loop's live locals -- the same reason
    # Add-TrimLaneReorderHandlers exists. "Delete empty tracks" is enabled from the state at
    # BUILD time, which is current because every structural change rebuilds the rows.
    function Add-TrimLaneHeaderContextMenu {
        param($Header, [Parameter(Mandatory = $true)][string]$LaneId,
              [bool]$IsVideoLane, [bool]$IsMainLane)
        if ($null -eq $Header) { return }
        $thisId = [string]$LaneId
        $thisIsVideo = [bool]$IsVideoLane
        $thisIsMain = [bool]$IsMainLane
        $menu = New-Object System.Windows.Controls.ContextMenu

        $miAddVideo = New-Object System.Windows.Controls.MenuItem
        $miAddVideo.Header = "Add video track"
        $miAddVideo.Add_Click({ Invoke-TrimAddVideoTrack })
        [void]$menu.Items.Add($miAddVideo)

        $miAddAudio = New-Object System.Windows.Controls.MenuItem
        $miAddAudio.Header = "Add audio track"
        $miAddAudio.Add_Click({ Invoke-TrimAddAudioTrack })
        [void]$menu.Items.Add($miAddAudio)

        $miAddMedia = New-Object System.Windows.Controls.MenuItem
        $miAddMedia.Header = "Add media to this track..."
        # V1 is never a media target (its clip IS the cut list), so the item is greyed rather
        # than offered and then refused.
        $miAddMedia.IsEnabled = (-not $thisIsMain)
        $miAddMedia.Add_Click({ Invoke-TrimAddClip -TargetLaneId $thisId }.GetNewClosure())
        [void]$menu.Items.Add($miAddMedia)

        [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

        $miDelete = New-Object System.Windows.Controls.MenuItem
        $miDelete.Header = "Delete track"
        # Same IsMain gate as the row's own trash: a non-main VIDEO lane takes its grouped
        # audio rows with it; the main lane deletes alone, which is how an audio-only export
        # is asked for.
        $miDelete.Add_Click({
            Push-TrimUndo
            if ($thisIsVideo -and -not $thisIsMain) {
                Remove-TrimLaneGroup -Id $thisId
            } else {
                Remove-TrimLaneRow -Id $thisId
            }
        }.GetNewClosure())
        [void]$menu.Items.Add($miDelete)

        $miDeleteEmpty = New-Object System.Windows.Controls.MenuItem
        $miDeleteEmpty.Header = "Delete empty tracks"
        $miDeleteEmpty.IsEnabled = (@(Get-TrimEmptyLaneIds).Count -gt 0)
        $miDeleteEmpty.Add_Click({ Invoke-TrimDeleteEmptyLanes })
        [void]$menu.Items.Add($miDeleteEmpty)

        $Header.ContextMenu = $menu
    }

    # Wires one ⋮⋮ grip. The capture goes on the row's HEADER Border rather than the grip
    # itself: the grip is a small TextBlock the pointer leaves immediately, and the header
    # survives the drag because Update-TrimLaneRows bails on Test-TrimLaneReorderDrag.
    # A separate function so the two call sites (video row, free audio row) share one
    # closure shape and the handlers capture $LaneId/$Header rather than the render
    # loop's live locals.
    function Add-TrimLaneReorderHandlers {
        param($Grip, $Header, [Parameter(Mandatory = $true)][string]$LaneId)
        if ($null -eq $Grip -or $null -eq $Header) { return }
        $thisLaneId = [string]$LaneId
        $thisHeader = $Header
        $Grip.Add_MouseLeftButtonDown({
            param($eventSource, $e)
            Start-TrimLaneReorderDrag -LaneId $thisLaneId -StartY (Get-TrimLanePanelY -MouseArgs $e)
            [void]$thisHeader.CaptureMouse()
            $e.Handled = $true
        }.GetNewClosure())
        $Header.Add_MouseMove({
            param($eventSource, $e)
            if (-not (Test-TrimLaneReorderDrag)) { return }
            Update-TrimLaneReorderDrag -CurrentY (Get-TrimLanePanelY -MouseArgs $e)
        })
        $Header.Add_MouseLeftButtonUp({
            param($eventSource, $e)
            if (-not (Test-TrimLaneReorderDrag)) { return }
            [void]$eventSource.ReleaseMouseCapture()
            Complete-TrimLaneReorderDrag
        })
        # Same insurance the clip drag carries: a capture lost some other way would leave
        # the reorder live forever, and the row rebuild bails while it is.
        $Header.Add_LostMouseCapture({
            param($eventSource, $e)
            if (-not (Test-TrimLaneReorderDrag)) { return }
            Complete-TrimLaneReorderDrag
        })
    }

    # The row's headline gain, read fresh from the model. Every fader handler goes
    # through this rather than capturing a value: a captured gain is stale the moment
    # the first mouse-move writes a new one.
    function Get-TrimLaneGain {
        param([string]$Id)
        $lane = Get-TrimLaneById -Id $Id
        if ($null -eq $lane) { return 0.0 }
        $head = Get-TrimLaneHeadClip -Lane $lane
        if ($null -eq $head) { return 0.0 }
        return [double]$head.GainDb
    }

    function Set-TrimFaderFocusLane {
        param($Id)
        $script:TrimFaderFocusLane = $Id
    }

    function Get-TrimFaderFocusLane {
        return $script:TrimFaderFocusLane
    }

    # Keyboard gain closes its bracket 600ms after the last press. A DispatcherTimer
    # rather than a per-press push: holding Up would otherwise fill the undo stack with
    # one entry per 0.5 dB and bury whatever came before it.
    function Request-LaneGainCommit {
        if ($null -eq $script:TrimLaneGainTimer) {
            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [timespan]::FromMilliseconds(600)
            # No GetNewClosure: both statements are top-level functions, so their
            # $script: access is the real script scope.
            $timer.Add_Tick({ Stop-LaneGainCommitTimer; Complete-LaneGainEdit })
            $script:TrimLaneGainTimer = $timer
        }
        $script:TrimLaneGainTimer.Stop()
        $script:TrimLaneGainTimer.Start()
    }

    function Stop-LaneGainCommitTimer {
        if ($null -ne $script:TrimLaneGainTimer) { $script:TrimLaneGainTimer.Stop() }
    }

    # -30..+30 dB across the rail, 0 dB dead centre. Shared by the rail's mouse-down and
    # its mouse-move so a click and a drag land on exactly the same number.
    function Convert-TrimFaderXToGain {
        param([double]$X, [double]$Width)
        if ($Width -le 0) { return 0.0 }
        $frac = [math]::Max(0.0, [math]::Min(1.0, $X / $Width))
        return ($frac * 60.0) - 30.0
    }

    # Repositions an already-built fader in place -- no rebuild, so it can run on every
    # mouse-move without disturbing the capture the rail canvas is holding (the same
    # rule Update-TrimClipDragGeometry follows for clip bars).
    function Update-TrimFaderVisual {
        param($Rail, $Fill, $Thumb, $Ticks, $Badge, [double]$Gain, [double]$Width)
        $g = [math]::Max(-30.0, [math]::Min(30.0, $Gain))
        if ($null -ne $Badge) { $Badge.Text = "{0:+0.0;-0.0;0}" -f $g }
        if ($Width -le 0) { return }
        $frac = ($g + 30.0) / 60.0
        if ($null -ne $Rail) { $Rail.Width = $Width }
        if ($null -ne $Fill) { $Fill.Width = [math]::Max(0.0, $frac * $Width) }
        if ($null -ne $Thumb) { [System.Windows.Controls.Canvas]::SetLeft($Thumb, ($frac * $Width) - 2.0) }
        if ($null -ne $Ticks) {
            $Ticks.Children.Clear()
            $major = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#5A7EA8")
            $minor = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#2A3B52")
            # Majors at -30/-15/0/+15/+30 dB, minors halfway between each pair.
            foreach ($t in @(
                @{ F = 0.0;   M = $true }, @{ F = 0.125; M = $false }, @{ F = 0.25;  M = $true },
                @{ F = 0.375; M = $false }, @{ F = 0.5;  M = $true }, @{ F = 0.625; M = $false },
                @{ F = 0.75;  M = $true }, @{ F = 0.875; M = $false }, @{ F = 1.0;   M = $true })) {
                $tick = New-Object System.Windows.Shapes.Rectangle
                $tick.Width = 1
                $tick.Height = $(if ($t.M) { 4.0 } else { 3.0 })
                $tick.Fill = $(if ($t.M) { $major } else { $minor })
                [System.Windows.Controls.Canvas]::SetTop($tick, 0)
                [System.Windows.Controls.Canvas]::SetLeft($tick, [math]::Min($Width - 1.0, [double]$t.F * $Width))
                [void]$Ticks.Children.Add($tick)
            }
        }
    }

    # Two keyframes at the same instant are a zero-length glide, which Get-TrimZoomStateAt
    # resolves arbitrarily and New-ZoomCropFilter would divide by. Keyframes are kept this
    # far apart instead of merged, so a drag can never destroy one by dropping it on another.
    $script:TrimZoomMinGap = 0.05

    # Retime one keyframe. Clamped to the clip AND to its immediate neighbours, so a drag
    # cannot reorder the list: the keyframe stays in its own slot and the lane, the glide and
    # the exported filtergraph all keep reading the same sequence.
    function Move-TrimZoomKeyframe {
        param([string]$Id, [double]$Time)
        $kf = Get-TrimZoomById -Id $Id
        if ($null -eq $kf) { return }
        # 0.0/doubles in every clamp: [math]::Max(0, <double>) binds the INT overload and
        # truncates, which is what quantised the caption drags to whole seconds.
        $lo = 0.0
        $hi = [math]::Max(0.0, [double]$script:TrimDuration)
        foreach ($other in @($script:TrimZooms)) {
            if ($other.Id -eq $Id) { continue }
            $t = [double]$other.Time
            if ($t -le [double]$kf.Time) { $lo = [math]::Max($lo, $t + $script:TrimZoomMinGap) }
            else { $hi = [math]::Min($hi, $t - $script:TrimZoomMinGap) }
        }
        # Keyframes packed tighter than the gap allows leave no legal position at all;
        # refusing beats snapping onto a neighbour and silently merging the two.
        if ($hi -lt $lo) { return }
        $kf.Time = [math]::Max($lo, [math]::Min($hi, $Time))
        Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
    }

    # Absolute write for the framing values, clamped exactly as New-ZoomKeyframe clamps them
    # so a keyframe edited here can never hold a value the constructor would have rejected.
    # Each is optional: Task 7's spotlight drag moves the centre without touching the level.
    function Set-TrimZoomValues {
        param([string]$Id, $CX = $null, $CY = $null, $W = $null, $H = $null)
        $kf = Get-TrimZoomById -Id $Id
        if ($null -eq $kf) { return }
        if ($null -ne $CX) { $kf.CX = [math]::Max(0.0, [math]::Min(1.0, [double]$CX)) }
        if ($null -ne $CY) { $kf.CY = [math]::Max(0.0, [math]::Min(1.0, [double]$CY)) }
        if ($null -ne $W) { $kf.W = [math]::Max(1.0 / 6.0, [math]::Min(3.0, [double]$W)) }
        if ($null -ne $H) { $kf.H = [math]::Max(1.0 / 6.0, [math]::Min(3.0, [double]$H)) }
        # A zoomed-OUT axis has no legal off-centre position: the export pad has room
        # for a centred frame only, so the preview must agree with it.
        $box = Get-ZoomKeyframeBox -Keyframe $kf
        if ($box.W -gt 1.0001) { $kf.CX = 0.5 }
        if ($box.H -gt 1.0001) { $kf.CY = 0.5 }
        Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
        # The spotlight box IS these three numbers drawn, so it is stale the instant one of
        # them moves. Self-contained rather than left to the caller: every write path here
        # (box drag commit, pill slider) would otherwise need its own redraw.
        Update-ZoomBoxOverlay
    }

    # Same drag lifecycle as the caption lane: snapshot at mouse-down, pushed on release only
    # if the keyframe actually ended up somewhere else, so a click that merely selects a
    # diamond costs no undo step.
    function Start-TrimZoomDrag {
        param([string]$Id, [double]$StartX)
        $kf = Get-TrimZoomById -Id $Id
        if ($null -eq $kf) { return }
        $script:TrimZoomDrag = @{
            Id       = $Id
            StartX   = $StartX
            OrigTime = [double]$kf.Time
            Snapshot = New-TrimUndoSnapshot
        }
    }

    function Test-TrimZoomDrag {
        return ($null -ne $script:TrimZoomDrag)
    }

    # Applied against the drag's ORIGINAL time, never accumulated: per-move deltas drift, and
    # a clamped neighbour would otherwise "eat" motion so dragging back never returns.
    function Update-TrimZoomDrag {
        param([double]$CurrentX)
        $drag = $script:TrimZoomDrag
        if ($null -eq $drag) { return }
        $dt = Convert-TrimPixelsToSeconds -Pixels ($CurrentX - $drag.StartX)
        Move-TrimZoomKeyframe -Id $drag.Id -Time ($drag.OrigTime + $dt)
    }

    function Complete-TrimZoomDrag {
        $drag = $script:TrimZoomDrag
        $script:TrimZoomDrag = $null
        if ($null -eq $drag) { return }
        $kf = Get-TrimZoomById -Id $drag.Id
        if ($null -eq $kf) { return }
        # Sub-millisecond movement is the jitter of a plain click, not a drag.
        if ([math]::Abs([double]$kf.Time - $drag.OrigTime) -lt 0.001) { return }
        Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
        # On release rather than per mouse move: one save per drag, and the early return
        # above means a click that moved nothing does not rewrite the project file either.
        Request-TrimProjectSave
    }

    # Rebuilt from scratch like the caption lane, and guarded on the canvas being non-null
    # for the same stale-XAML reason. Called at the END of Update-TrimTimeline.
    function Update-TrimZoomLane {
        # Unconditional and first, exactly like Update-TrimCaptionLane's overlay call: this is
        # the cheapest correct hook for "the zoom model or the zoom selection changed" (every
        # mutation, both Clear- paths and undo pass through here), and the lane's own early
        # returns below must not suppress the spotlight box, which carries its own guards.
        Update-ZoomBoxOverlay
        if ($null -eq $canvasTrimZooms) { return }
        $canvasTrimZooms.Children.Clear()
        if (-not $script:TrimInputFile) { return }

        $laneWidth = $canvasTrimZooms.ActualWidth
        if ($laneWidth -le 0) { $laneWidth = $canvasTrimTimeline.ActualWidth }
        $laneHeight = $canvasTrimZooms.ActualHeight
        if ($laneHeight -le 0) { $laneHeight = 26 }

        $timelinePieces = (Get-TrimTimelineState).TimelinePieces

        # Keyframe times are SOURCE seconds, like caption times, so an x is the same two-step
        # conversion the playhead uses: source -> timeline (compacted) -> pixels.
        $sorted = @(@($script:TrimZooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
        $xs = @()
        foreach ($z in $sorted) {
            $xs += [double](Convert-TrimTimeToX -Seconds (
                Convert-TrimSourceToTimeline -SourceSeconds ([double]$z.Time) -TimelinePieces $timelinePieces))
        }

        # Ramps first so the diamonds paint over their ends. One per consecutive pair: flat
        # while the level is held above 1x, a gradient in the direction the zoom is moving,
        # and nothing at all across a stretch that is 1x at both ends -- there is no zoom
        # there to show.
        $rampHeight = 6.0
        $rampTop = [math]::Max(0.0, ($laneHeight - $rampHeight) / 2.0)
        for ($i = 0; $i -lt $sorted.Count - 1; $i++) {
            # Magnitude for ramp direction: how much the picture is blown up, as the
            # geometric mean of the two axes so a pure stretch still counts as motion.
            # 1.0 = identity, above = zoomed in, below = zoomed out.
            $box0 = Get-ZoomKeyframeBox -Keyframe $sorted[$i]
            $box1 = Get-ZoomKeyframeBox -Keyframe $sorted[$i + 1]
            $l0 = 1.0 / [math]::Sqrt([math]::Max(1e-6, $box0.W * $box0.H))
            $l1 = 1.0 / [math]::Sqrt([math]::Max(1e-6, $box1.W * $box1.H))
            $styleName = $null
            if ([math]::Abs($l1 - $l0) -lt 0.001) {
                if (-not (Test-ZoomIdentity -W $box0.W -H $box0.H)) { $styleName = "ZoomRampHoldStyle" }
            } elseif ($l1 -gt $l0) { $styleName = "ZoomRampStyle" }
            else { $styleName = "ZoomRampDownStyle" }
            if ($null -eq $styleName) { continue }

            $x1 = $xs[$i]
            $x2 = $xs[$i + 1]
            # Fully off-view: nothing to draw, and a rectangle hundreds of thousands of
            # pixels wide at a deep zoom is worth not building at all.
            if ($x2 -le 0 -or $x1 -ge $laneWidth) { continue }
            $left = [math]::Max(0.0, $x1)
            $right = [math]::Min([double]$laneWidth, $x2)
            if ($right - $left -le 0.5) { continue }

            $ramp = New-Object System.Windows.Shapes.Rectangle
            $ramp.Style = $ctx.Window.FindResource($styleName)
            $ramp.Width = $right - $left
            $ramp.Height = $rampHeight
            # Not hit-testable: a ramp lies between two diamonds and a hit-testable strip
            # would swallow the empty-lane click that deselects.
            $ramp.IsHitTestVisible = $false
            [System.Windows.Controls.Canvas]::SetLeft($ramp, $left)
            [System.Windows.Controls.Canvas]::SetTop($ramp, $rampTop)
            $canvasTrimZooms.Children.Add($ramp) | Out-Null
        }

        # Diamonds: 13x13 squares the style rotates 45 degrees about their own centre, so the
        # layout rect is still 13x13 and only the painted footprint grows to ~18px diagonal.
        # Centring the LAYOUT rect therefore centres the diamond, and 18.4 < 26 means the
        # points stay inside the lane.
        $diamondSize = 13.0
        $diamondTop = [math]::Max(0.0, ($laneHeight - $diamondSize) / 2.0)
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $x = $xs[$i]
            if ($x -lt -$diamondSize -or $x -gt $laneWidth + $diamondSize) { continue }

            $isSelected = ($sorted[$i].Id -eq $script:TrimSelectedZoom)
            $diamond = New-Object System.Windows.Shapes.Rectangle
            $diamond.Style = $ctx.Window.FindResource(
                $(if ($isSelected) { "ZoomDiamondSelectedStyle" } else { "ZoomDiamondStyle" }))
            $diamond.Width = $diamondSize
            $diamond.Height = $diamondSize
            [System.Windows.Controls.Canvas]::SetLeft($diamond, $x - ($diamondSize / 2.0))
            [System.Windows.Controls.Canvas]::SetTop($diamond, $diamondTop)

            $thisId = $sorted[$i].Id

            # GetNewClosure is required, exactly as on the caption blocks: without it every
            # diamond captures the loop variable's final value and dragging any of them moves
            # the last keyframe. Mouse capture goes on the CANVAS, not on the diamond: the
            # lane is rebuilt on every MouseMove, which destroys the element mid-drag, and a
            # capture held by a destroyed element is lost.
            $diamond.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                $x = ($e.GetPosition($canvasTrimZooms)).X
                Set-TrimSelectedZoom -Id $thisId
                Start-TrimZoomDrag -Id $thisId -StartX $x
                $canvasTrimZooms.CaptureMouse() | Out-Null
                $e.Handled = $true
                Update-TrimZoomLane
            }.GetNewClosure())

            $canvasTrimZooms.Children.Add($diamond) | Out-Null
        }
    }

    # The live zoom. Applied to PreviewZoomHost, which wraps only the two video surfaces, so
    # the caption overlay beside it stays pinned to the frame instead of zooming with it.
    #
    # LAYOUT-based, not RenderTransform-based, and that is a hard-won decision: a
    # ScaleTransform+TranslateTransform on this host was verifiably attached (property
    # readback, TransformToAncestor, HasAnimatedProperties all agreed) and still never
    # reached the pixels -- not on screen, not in PrintWindow, not even in a
    # RenderTargetBitmap -- while the identical transform in an isolated WPF repro with
    # the same video rendered fine. Root cause unfound (2026-08-11); sizing the host
    # and offsetting it with a margin is pixel-equivalent, provably renders in this
    # app, and PreviewCell's Clip crops the overflow to the video box.
    #
    # The geometry sums: the box region (W,H fractions at centre CX,CY) must land on
    # the video box PreviewBox describes. The host becomes the box's inverse scale of
    # the video box and is shifted so the region's top-left sits at the box's origin.
    function Update-PreviewZoom {
        param([double]$SourceSeconds)
        if ($null -eq $previewZoomHost -or $null -eq $script:PreviewBox) { return }
        $state = Get-TrimZoomStateAt -Zooms @($script:TrimZooms) -Seconds $SourceSeconds
        $box = $script:PreviewBox
        $w = [double]$box.W
        $h = [double]$box.H
        if ($w -le 0 -or $h -le 0) { return }
        # Identity fast-path. This runs 20x a second during playback; the reset also
        # keeps the preview bit-identical to no-zoom rather than resampled.
        if (Test-ZoomIdentity -W ([double]$state.W) -H ([double]$state.H)) {
            $previewZoomHost.HorizontalAlignment = "Center"
            $previewZoomHost.VerticalAlignment = "Center"
            $previewZoomHost.Margin = New-Object System.Windows.Thickness(0)
            $previewZoomHost.Width = $w
            $previewZoomHost.Height = $h
            return
        }
        # Per-axis scale: the box (W, H fractions of the frame) fills the whole video
        # box, so a non-frame-shaped box stretches the picture -- that is the
        # magnet-off effect, not a bug. W/H above 1 gives a scale below 1: the frame
        # shrinks and the black cell background shows around it inside the clip,
        # matching the export's pad.
        $sx = 1.0 / [double]$state.W
        $sy = 1.0 / [double]$state.H
        $tx = ($w / 2.0) - ($sx * [double]$state.CX * $w)
        $ty = ($h / 2.0) - ($sy * [double]$state.CY * $h)
        $previewZoomHost.HorizontalAlignment = "Left"
        $previewZoomHost.VerticalAlignment = "Top"
        $previewZoomHost.Width = $w * $sx
        $previewZoomHost.Height = $h * $sy
        $previewZoomHost.Margin = New-Object System.Windows.Thickness(([double]$box.X + $tx), ([double]$box.Y + $ty), 0, 0)
    }

    function Invoke-TrimAddZoom {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        # A second keyframe on top of an existing one has no legal position to be dragged to
        # (Move-TrimZoomKeyframe would refuse every request) and would be a zero-length glide
        # on export. Selecting the one already there is what the user was reaching for anyway.
        foreach ($z in @($script:TrimZooms)) {
            if ([math]::Abs([double]$z.Time - $script:TrimPlayhead) -lt $script:TrimZoomMinGap) {
                Set-TrimSelectedZoom -Id $z.Id
                Update-TrimTimeline
                return
            }
        }
        Push-TrimUndo
        # Seeded from the glide as it stands at the playhead, not from 1x: adding a keyframe
        # in the middle of an existing move must not yank the picture back to unzoomed. The
        # new keyframe changes nothing until it is edited, which is the only honest default.
        $state = Get-TrimZoomStateAt -Zooms @($script:TrimZooms) -Seconds $script:TrimPlayhead
        $kf = New-ZoomKeyframe -Time $script:TrimPlayhead -CX $state.CX -CY $state.CY -W $state.W -H $state.H
        [void]$script:TrimZooms.Add($kf)
        Set-TrimSelectedZoom -Id $kf.Id
        Update-TrimTimeline
        Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
        Request-TrimProjectSave
    }

    function Invoke-TrimDeleteZoom {
        $kf = Get-TrimSelectedZoom
        if ($null -eq $kf) { return }
        Push-TrimUndo
        $script:TrimZooms.Remove($kf)
        $script:TrimSelectedZoom = $null
        Update-TrimTimeline
        # Removing a keyframe changes the glide everywhere its neighbours reached, so the
        # picture under the playhead is stale until this runs.
        Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
        Request-TrimProjectSave
    }

    # ---- External clip tracks: add, PiP/audio-clip preview pools, PiP drag ----
    #
    # Extensions this app already treats as audio-only in the ffprobe/export code paths;
    # anything else in the Filter goes to "video-clip".
    $script:TrimAudioClipExtensions = @(".mp3", ".m4a", ".wav", ".flac")
    # Stills (spec 4.3): they live on a VIDEO lane, carry no audio and get their span from
    # DurationOverride (5.0s by default) rather than from a probed source duration.
    $script:TrimImageClipExtensions = @(".png", ".jpg", ".jpeg", ".bmp", ".webp")

    # Removes and disposes one clip's pooled preview MediaElement(s) -- both a PiP element
    # (in the visual tree) and an audio-clip element (deliberately never in it) are torn
    # down the same way, so a single track Id passed here cleans up whichever pool it was
    # actually in.
    function Remove-TrimClipMediaElement {
        param([string]$Id)
        if ($script:PipMediaElements.ContainsKey($Id)) {
            $el = $script:PipMediaElements[$Id].Element
            try { $el.Stop() } catch {}
            try { $el.Close() } catch {}
            if ($null -ne $previewCell -and $previewCell.Children.Contains($el)) { $previewCell.Children.Remove($el) | Out-Null }
            $script:PipMediaElements.Remove($Id)
        }
        # A still has no media to stop -- pulling the Image out of the visual tree and
        # dropping the entry is the whole teardown (the BitmapImage it points at is freed
        # with it).
        if ($script:ImageElements.ContainsKey($Id)) {
            $img = $script:ImageElements[$Id].Element
            if ($null -ne $previewCell -and $previewCell.Children.Contains($img)) { $previewCell.Children.Remove($img) | Out-Null }
            $script:ImageElements.Remove($Id)
        }
        if ($script:AudioClipMediaElements.ContainsKey($Id)) {
            $entry = $script:AudioClipMediaElements[$Id]
            try { $entry.Element.Stop() } catch {}
            try { $entry.Element.Close() } catch {}
            $script:AudioClipMediaElements.Remove($Id)
        }
    }

    # Prunes both pools down to the clips that still exist. Called from Update-TrimLaneRows
    # (every structural change -- add, delete, undo/redo, unlink, load) so an undone add or
    # a deleted clip never leaves an orphaned MediaElement sitting in the visual tree (or,
    # for an audio clip, silently still playing off-tree). Keyed by CLIP id.
    function Sync-TrimClipMediaElementPools {
        $liveIds = @{}
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
                $liveIds[[string]$c.Id] = $true
            }
        }
        foreach ($id in @($script:PipMediaElements.Keys)) { if (-not $liveIds.ContainsKey($id)) { Remove-TrimClipMediaElement -Id $id } }
        foreach ($id in @($script:ImageElements.Keys)) { if (-not $liveIds.ContainsKey($id)) { Remove-TrimClipMediaElement -Id $id } }
        foreach ($id in @($script:AudioClipMediaElements.Keys)) { if (-not $liveIds.ContainsKey($id)) { Remove-TrimClipMediaElement -Id $id } }
    }

    # Clears both pools entirely -- used only when the whole session's file changes, since a
    # fresh file's tracks are unrelated to whatever clips the previous one had loaded.
    function Clear-TrimClipMediaElementPools {
        foreach ($id in @($script:PipMediaElements.Keys)) { Remove-TrimClipMediaElement -Id $id }
        foreach ($id in @($script:ImageElements.Keys)) { Remove-TrimClipMediaElement -Id $id }
        foreach ($id in @($script:AudioClipMediaElements.Keys)) { Remove-TrimClipMediaElement -Id $id }
    }

    # Both preview-element factories put their element in the SAME slot: PreviewCell's
    # visual tree AFTER PreviewZoomHost (and after the black montage base) and BEFORE
    # CanvasCaptionOverlay, so the picture sits over the main preview but under the
    # caption/PiP-box overlay. Insert order among themselves is paint order, which
    # Update-TrimPreviewStackOrder re-asserts on every structural rebuild.
    function Add-TrimPreviewElement {
        param($Element)
        if ($null -eq $previewCell -or $null -eq $canvasCaptionOverlay) { return }
        $idx = $previewCell.Children.IndexOf($canvasCaptionOverlay)
        if ($idx -ge 0) { $previewCell.Children.Insert($idx, $Element) } else { $previewCell.Children.Add($Element) | Out-Null }
    }

    # One MediaElement per overlay video CLIP, built once and reused. The entry is
    # @{ Element; InSpan } exactly like the audio pool's: InSpan is "this element was
    # already showing its own footage last time we looked", which is what lets
    # Update-PipPreview skip the Position write on the 19 ticks out of 20 that only move
    # the playhead a few frames inside a span the element is already playing.
    function Get-PipMediaElement {
        param($Clip)
        $Track = $Clip
        $id = [string]$Track.Id
        if (-not $script:PipMediaElements.ContainsKey($id)) {
            $el = New-Object System.Windows.Controls.MediaElement
            $el.LoadedBehavior = "Manual"
            $el.UnloadedBehavior = "Manual"
            # Stretch is per-update now (Uniform full-frame, Fill boxed), not fixed here.
            $el.Stretch = "Fill"
            $el.IsHitTestVisible = $false
            $el.Volume = 0
            $el.Visibility = "Collapsed"
            try { $el.Source = New-Object System.Uri([string]$Track.Path) } catch {}
            Add-TrimPreviewElement -Element $el
            $script:PipMediaElements[$id] = @{ Element = $el; InSpan = $false }
        }
        return $script:PipMediaElements[$id]
    }

    # One Image per still CLIP, same pool shape and same slot. The BitmapImage is decoded
    # ONCE (CacheOption OnLoad, so the file handle is released immediately and the decode
    # never repeats on a later layout pass) and then cached with the element -- a still
    # costs nothing per tick beyond a Visibility/geometry write.
    function Get-PipImageElement {
        param($Clip)
        $id = [string]$Clip.Id
        if (-not $script:ImageElements.ContainsKey($id)) {
            $el = New-Object System.Windows.Controls.Image
            $el.IsHitTestVisible = $false
            $el.Visibility = "Collapsed"
            $el.HorizontalAlignment = "Left"
            $el.VerticalAlignment = "Top"
            $el.Stretch = "Uniform"
            try {
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.UriSource = New-Object System.Uri([string]$Clip.Path)
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.EndInit()
                $el.Source = $bmp
            } catch {}
            Add-TrimPreviewElement -Element $el
            $script:ImageElements[$id] = @{ Element = $el; InSpan = $false }
        }
        return $script:ImageElements[$id]
    }

    # Paint order. WPF paints a Panel's children in index order, so "later in Children" is
    # "on top". The lane stack is drawn top row first, and the TOPMOST video row is the one
    # that covers the others (spec 3.1) -- so walking the lanes BOTTOM-UP and re-inserting
    # each element at the caption overlay's index leaves the topmost lane's element last,
    # i.e. on top. Re-asserted on every structural rebuild because a lane reorder changes
    # who covers whom without creating or destroying a single element.
    function Update-TrimPreviewStackOrder {
        if ($null -eq $previewCell -or $null -eq $canvasCaptionOverlay) { return }
        $lanes = @($script:TrimLanes)
        for ($i = $lanes.Count - 1; $i -ge 0; $i--) {
            $lane = $lanes[$i]
            if ($lane.Kind -ne "video") { continue }
            foreach ($c in @($lane.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
                $id = [string]$c.Id
                $el = $null
                if ($script:PipMediaElements.ContainsKey($id)) { $el = $script:PipMediaElements[$id].Element }
                elseif ($script:ImageElements.ContainsKey($id)) { $el = $script:ImageElements[$id].Element }
                if ($null -eq $el) { continue }
                if ($previewCell.Children.Contains($el)) { $previewCell.Children.Remove($el) }
                Add-TrimPreviewElement -Element $el
            }
        }
    }

    # The black montage base (spec 4.7). Past V1's own last frame the main MediaElement has
    # no frame to give and simply keeps showing the last one it decoded -- which would sit
    # under the montage clips as a frozen still instead of the black the export produces.
    # One Rectangle the size of the preview box, inserted directly ABOVE PreviewZoomHost
    # (so it covers that stale frame) and BELOW every clip element (so it never covers a
    # clip), shown only while the playhead is out past V1's end.
    function Update-TrimBlackBase {
        if ($null -eq $previewCell -or $null -eq $previewZoomHost -or $null -eq $script:PreviewBox) { return }
        if ($null -eq $script:TrimBlackBase) {
            $rect = New-Object System.Windows.Shapes.Rectangle
            $rect.Fill = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#FF000000")
            $rect.IsHitTestVisible = $false
            $rect.HorizontalAlignment = "Left"
            $rect.VerticalAlignment = "Top"
            $rect.Visibility = "Collapsed"
            $script:TrimBlackBase = $rect
        }
        $base = $script:TrimBlackBase
        if (-not $previewCell.Children.Contains($base)) {
            # +1: directly after the host, which is below every clip element (those are
            # inserted at the caption overlay's index, further down the list).
            $hostIdx = $previewCell.Children.IndexOf($previewZoomHost)
            if ($hostIdx -ge 0) { $previewCell.Children.Insert($hostIdx + 1, $base) }
            else { $previewCell.Children.Add($base) | Out-Null }
        }
        $box = $script:PreviewBox
        $base.Width = [double]$box.W
        $base.Height = [double]$box.H
        $base.Margin = New-Object System.Windows.Thickness([double]$box.X, [double]$box.Y, 0, 0)
        $state = Get-TrimTimelineState
        $show = ((Get-TrimTimelinePlayhead) -gt ([double]$state.TotalDuration + 0.01))
        $base.Visibility = $(if ($show) { "Visible" } else { "Collapsed" })
    }

    # One MediaElement per audio-clip track, built once and reused -- but NEVER added to
    # any Panel's Children. WPF's MediaElement plays audio through the same MediaPlayer
    # regardless of whether it is in the visual tree; being off-tree just means it never
    # tries to render a frame nobody would see. InSpan tracks whether THIS element was
    # playing the last time it was checked, so Update-TrimAudioClipPreview can tell "just
    # entered the span" (seed Position once) from "still inside it" (let it run) without
    # re-seeking on every single tick.
    function Get-AudioClipMediaElement {
        param($Clip)
        $Track = $Clip
        $id = [string]$Track.Id
        if (-not $script:AudioClipMediaElements.ContainsKey($id)) {
            $el = New-Object System.Windows.Controls.MediaElement
            $el.LoadedBehavior = "Manual"
            $el.UnloadedBehavior = "Manual"
            try { $el.Source = New-Object System.Uri([string]$Track.Path) } catch {}
            $script:AudioClipMediaElements[$id] = @{ Element = $el; InSpan = $false }
        }
        return $script:AudioClipMediaElements[$id]
    }

    # Positions/plays every overlay clip's preview element against the TIMELINE playhead
    # (never source seconds -- a clip's Offset is a timeline position, exactly like a clip
    # bar drag writes). Called from the same places Update-PreviewZoom is: the transport
    # tick, every scrub, and the preview frame resize.
    #
    # Two geometries, decided by Pip (spec 4.6):
    #   full-frame (Pip $null) -- the element fills the WHOLE preview box with Stretch
    #     Uniform, so a clip whose aspect differs from the frame's is aspect-fit and the
    #     black bars come free: the black montage base (or the main picture) is what shows
    #     through beside it, which is exactly what the export's own scale+pad produces.
    #   boxed -- the Pip rectangle, Stretch Fill, unchanged from Task 8.
    #
    # -Seek is the difference between "the user jumped the playhead" and "50ms passed".
    # A scrub passes -Seek $true and every element re-seeks; the 20x/sec tick does not, so
    # an element that is already inside its own span is left alone to play (writing
    # Position on a playing MediaElement restarts its decode and stutters the picture).
    function Update-PipPreview {
        param([double]$SourceSeconds, [bool]$Seek = $false)
        if ($null -eq $previewCell -or $null -eq $script:PreviewBox) { return }
        $box = $script:PreviewBox
        $bw = [double]$box.W
        $bh = [double]$box.H
        # -SourceSeconds still decides the position while the playhead is inside the cut
        # list (every caller passes $script:TrimPlayhead, but the parameter is the contract).
        # Out in the montage region there is no source second to convert and the extension
        # offset is the only thing that knows where the playhead is.
        $timelinePlayhead = $(if (Test-TrimInExtension) { Get-TrimTimelinePlayhead } else {
            $state = Get-TrimTimelineState
            Convert-TrimSourceToTimeline -SourceSeconds $SourceSeconds -TimelinePieces $state.TimelinePieces
        })
        $playing =($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
        # BOTTOM-UP, the same order Update-TrimPreviewStackOrder inserts in: a newly built
        # element is added to the tree here, on the pass that first needs it, and doing it
        # in paint order means it lands on top of the lanes below it straight away rather
        # than waiting for the next structural rebuild to sort the stack out.
        #
        # Overlay clips only: the main lane's own video clip IS the main preview element.
        $overlays = @()
        $lanes = @($script:TrimLanes)
        for ($i = $lanes.Count - 1; $i -ge 0; $i--) {
            $lane = $lanes[$i]
            if ($lane.Kind -ne "video") { continue }
            foreach ($c in @($lane.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
                if ($c.Kind -ne "video" -and $c.Kind -ne "image") { continue }
                $overlays += ,@{ Lane = $lane; Clip = $c }
            }
        }
        foreach ($o in $overlays) {
            $t = $o.Clip
            $isImage = ([string]$t.Kind -eq "image")
            $entry = $(if ($isImage) { Get-PipImageElement -Clip $t } else { Get-PipMediaElement -Clip $t })
            $el = $entry.Element
            $span = Get-TrimClipSpan -Clip $t -SourceDuration (Get-TrimClipSourceDuration -Lane $o.Lane -Clip $t)
            $inSpan = ($timelinePlayhead -ge [double]$span.Start -and $timelinePlayhead -lt [double]$span.End)
            # A row with the eye off (spec 3.2) renders nothing at all -- the same flag the
            # export reads to leave the clip out of the overlay chain.
            if (-not $inSpan -or -not $t.Enabled -or $bw -le 0 -or $bh -le 0) {
                $el.Visibility = "Collapsed"
                if (-not $isImage) { try { $el.Pause() } catch {} }
                $entry.InSpan = $false
                continue
            }
            $el.Visibility = "Visible"
            $el.HorizontalAlignment = "Left"
            $el.VerticalAlignment = "Top"
            if ($null -eq $t.Pip) {
                $el.Width = $bw
                $el.Height = $bh
                $el.Stretch = "Uniform"
                $el.Margin = New-Object System.Windows.Thickness([double]$box.X, [double]$box.Y, 0, 0)
            } else {
                $pip = $t.Pip
                $el.Width = [double]$pip.W * $bw
                $el.Height = [double]$pip.H * $bh
                $el.Stretch = "Fill"
                $marginX = [double]$box.X + (([double]$pip.X - ([double]$pip.W / 2.0)) * $bw)
                $marginY = [double]$box.Y + (([double]$pip.Y - ([double]$pip.H / 2.0)) * $bh)
                $el.Margin = New-Object System.Windows.Thickness($marginX, $marginY, 0, 0)
            }
            # A still has no clock: geometry and visibility are all it has, so the whole
            # transport half below is skipped for it (and its InSpan only tracks state).
            if ($isImage) { $entry.InSpan = $true; continue }
            # PiP audio comes through only if the clip has a linked audio row --
            # this MediaElement is picture only.
            $el.Volume = 0
            if ($Seek -or -not $entry.InSpan) {
                $pos = [math]::Max(0.0, ($timelinePlayhead - [double]$t.Offset + [double]$t.InStart))
                try { $el.Position = [timespan]::FromSeconds($pos) } catch {}
            }
            $entry.InSpan = $true
            if ($playing) { try { $el.Play() } catch {} } else { try { $el.Pause() } catch {} }
        }
    }

    # Plays every EXTERNAL audio clip's off-tree MediaElement while the timeline playhead is
    # inside its span AND the main transport is playing -- scrubbing deliberately never
    # seeks these (the comment on Get-AudioClipMediaElement explains why: the export's own
    # mix is authoritative, this is only ever an approximation while editing). The loaded
    # file's OWN audio streams are excluded: the main preview element is already decoding
    # them, and playing them twice would double the source audio.
    function Update-TrimAudioClipPreview {
        param([double]$SourceSeconds, [bool]$Playing)
        # Same extension-aware playhead as Update-PipPreview's: the span math here was
        # already timeline-based, but a source->timeline convert caps out at V1's end, so
        # without this an audio clip that plays over the montage region would go silent the
        # moment the transport left the cut list.
        $timelinePlayhead = $(if (Test-TrimInExtension) { Get-TrimTimelinePlayhead } else {
            $state = Get-TrimTimelineState
            Convert-TrimSourceToTimeline -SourceSeconds $SourceSeconds -TimelinePieces $state.TimelinePieces
        })
        $clips = @()
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                if ($c.Kind -ne "audio") { continue }
                if ([string]$c.Path -eq [string]$script:TrimInputFile) { continue }
                $clips += ,@{ Lane = $lane; Clip = $c }
            }
        }
        foreach ($entryRef in $clips) {
            $t = $entryRef.Clip
            $entry = Get-AudioClipMediaElement -Clip $t
            $el = $entry.Element
            $span = Get-TrimClipSpan -Clip $t -SourceDuration (Get-TrimClipSourceDuration -Lane $entryRef.Lane -Clip $t)
            $inSpan = ($timelinePlayhead -ge [double]$span.Start -and $timelinePlayhead -lt [double]$span.End -and [bool]$t.Enabled)
            $vol = if ($t.Muted) { 0.0 } else { [math]::Min(1.0, [math]::Pow(10.0, [double]$t.GainDb / 20.0)) }
            $el.Volume = $vol
            if ($Playing -and $inSpan) {
                if (-not $entry.InSpan) {
                    $pos = [math]::Max(0.0, ($timelinePlayhead - [double]$t.Offset + [double]$t.InStart))
                    try { $el.Position = [timespan]::FromSeconds($pos) } catch {}
                    try { $el.Play() } catch {}
                    $entry.InSpan = $true
                }
            } else {
                if ($entry.InSpan) { try { $el.Pause() } catch {} }
                $entry.InSpan = $false
            }
        }
    }

    # ---- Add flows (spec 4.3) ------------------------------------------------------
    #
    # Two gestures where v2 had one. "+ Video track" / "+ Audio track" create an EMPTY lane
    # and nothing else -- an empty row is a first-class thing to want (it persists in the
    # project file and shows a "drop ... here" ghost), and it is where the header's own
    # context menu then puts media. "Add media to this track..." is the file-dialog half.
    function Invoke-TrimAddVideoTrack {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        Push-TrimUndo
        [void](Add-TrimLaneRow -Kind "video")
        Update-TrimLaneRows
        Request-TrimProjectSave
    }

    function Invoke-TrimAddAudioTrack {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        Push-TrimUndo
        [void](Add-TrimLaneRow -Kind "audio")
        Update-TrimLaneRows
        Request-TrimProjectSave
    }

    # Why a named target can be refused, or "" when it is fine. PURE -- it creates nothing,
    # so the refusal can be shown before any undo step is pushed.
    function Test-TrimAddTargetLane {
        param([Parameter(Mandatory = $true)][string]$Kind, [string]$TargetLaneId = "")
        if ([string]::IsNullOrEmpty($TargetLaneId)) { return "" }
        $lane = Get-TrimLaneById -Id $TargetLaneId
        if ($null -eq $lane) { return "That track is gone." }
        if ([string]$lane.Kind -ne $Kind) {
            return ("That lane holds {0} clips." -f [string]$lane.Kind)
        }
        # The MAIN lane is never a target: its clip IS the cut list, and laying a second clip
        # end-to-end on V1 (sequencing) is out of scope.
        if ([bool]$lane.IsMain) { return "V1 carries the source video itself." }
        return ""
    }

    # The row a media add lands on, CREATING one when there is nowhere to put it. Called
    # after Push-TrimUndo (it mutates the lane list), and only once Test-TrimAddTargetLane
    # has cleared the request.
    function Get-TrimAddTargetLane {
        param([Parameter(Mandatory = $true)][string]$Kind, [string]$TargetLaneId = "")
        if (-not [string]::IsNullOrEmpty($TargetLaneId)) { return (Get-TrimLaneById -Id $TargetLaneId) }
        if ($Kind -eq "video") {
            # The TOPMOST non-main video lane: the topmost video row paints last, so that is
            # the one the user is looking at.
            foreach ($l in @($script:TrimLanes)) {
                if ([string]$l.Kind -eq "video" -and -not [bool]$l.IsMain) { return $l }
            }
            return (Add-TrimLaneRow -Kind "video")
        }
        # The last FREE audio lane. A grouped row is some video clip's own audio (spec 2), so
        # dropping an unrelated file on it would dissolve the group on the next rebuild.
        # Get-TrimLaneGroups is the file's ONE inverse-convention function -- wrapped in @().
        $free = @()
        foreach ($g in @(Get-TrimLaneGroups)) {
            if ($null -eq $g.VideoLane) { $free = @($g.AudioLanes) }
        }
        if (@($free).Count -gt 0) { return $free[@($free).Count - 1] }
        return (Add-TrimLaneRow -Kind "audio")
    }

    # The media add. The OpenFileDialog cannot be exercised by the UIA harness (it hangs on
    # the native Open dialog), so this is verified by code-path review plus scripted checks
    # that craft a project file directly -- see the Task 10 report.
    # The dialog half of adding media; the work lives in Add-TrimMediaFromPath so a file
    # DROPPED onto a lane row takes the identical path (kind routing, refusals, caches,
    # undo, on-demand audio rows) without ever opening the dialog.
    function Invoke-TrimAddClip {
        param([string]$TargetLaneId = "")
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = "Media|*.mp4;*.mkv;*.mov;*.mp3;*.m4a;*.wav;*.flac;*.png;*.jpg;*.jpeg;*.bmp;*.webp|All files|*.*"
        if ($dlg.ShowDialog() -ne $true) { return }
        Add-TrimMediaFromPath -Path $dlg.FileName -TargetLaneId $TargetLaneId
    }

    function Add-TrimMediaFromPath {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [string]$TargetLaneId = "",
            # Timeline seconds to place the clip's START at; negative means "at the
            # playhead" (the dialog flow). A drop passes the drop position instead.
            [double]$AtTimeline = -1.0
        )
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $path = $Path
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        # Routing by extension: anything that is not a known still or a known audio-only
        # container is treated as video, exactly as the "All files" half of the filter implies.
        $kind = if ($script:TrimAudioClipExtensions -contains $ext) { "audio" }
                elseif ($script:TrimImageClipExtensions -contains $ext) { "image" }
                else { "video" }
        # A still lives on a VIDEO lane; only real audio wants an audio row.
        $laneKind = $(if ($kind -eq "audio") { "audio" } else { "video" })

        $refusal = Test-TrimAddTargetLane -Kind $laneKind -TargetLaneId $TargetLaneId
        if (-not [string]::IsNullOrEmpty($refusal)) {
            Show-PanelMessage -Block $textTrimMeta -IsWarning -Text $refusal
            return
        }

        # Probed once, up front, and cached by path -- the export call site and every span
        # calculation from here on read the caches rather than re-shelling to ffprobe.
        # An IMAGE gets no duration entry: its span comes from DurationOverride (5.0s by
        # default, New-TrimClip's own floor), so the duration cache would never be read for
        # it -- only the aspect, which the PiP resize magnet needs.
        $frameAspect = 16.0 / 9.0
        if ($kind -ne "image") {
            $script:TrimClipDurations[[string]$path] = Get-TrimClipDuration -Path $path
        }
        if ($kind -ne "audio") {
            $sourceProfile = Get-TrimSourceProfile -InputFile $path
            $script:TrimClipAspect[[string]$path] = $(if ([double]$sourceProfile.Height -gt 0) {
                [double]$sourceProfile.Width / [double]$sourceProfile.Height
            } else { $frameAspect })
        }

        $state = Get-TrimTimelineState
        $timelineOffset = if ($AtTimeline -ge 0.0) {
            # 0.0 floor only -- a drop past V1's end is a legitimate montage add.
            [math]::Max(0.0, $AtTimeline)
        } else {
            Convert-TrimSourceToTimeline -SourceSeconds $script:TrimPlayhead -TimelinePieces $state.TimelinePieces
        }

        Push-TrimUndo
        $lane = Get-TrimAddTargetLane -Kind $laneKind -TargetLaneId $TargetLaneId
        if ($null -eq $lane) { return }
        $laneId = [string]$lane.Id

        if ($kind -eq "audio") {
            # A free audio clip: no link, its own offset.
            $clip = New-TrimClip -Kind "audio" -Path $path -Offset $timelineOffset
            Add-TrimClipToLane -LaneId $laneId -Clip $clip
            Set-TrimSelectedClip -Id ([string]$clip.Id)
        } elseif ($kind -eq "image") {
            # DurationOverride is left at New-TrimClip's 5.0s default (spec 4.3); the edge
            # grips trim it from there.
            $clip = New-TrimClip -Kind "image" -Path $path -Offset $timelineOffset
            Add-TrimClipToLane -LaneId $laneId -Clip $clip
            Set-TrimSelectedClip -Id ([string]$clip.Id)
        } else {
            # Spec 4.6: an added video lands FULL-FRAME (Pip $null), not boxed -- the box is
            # something the user opts into afterwards, through the props strip or the chip.
            $linkId = [guid]::NewGuid().ToString("N")
            $vclip = New-TrimClip -Kind "video" -Path $path -Offset $timelineOffset -LinkId $linkId
            Add-TrimClipToLane -LaneId $laneId -Clip $vclip
            # Its own audio rides along on a grouped row created ON DEMAND, directly below the
            # video lane, sharing one fresh LinkId so moving or deleting either takes the
            # other with it. A file with no audio streams gets no row at all (spec 4.3).
            # NOT @(...) around the call: Get-TrimAudioStreams passes ConvertFrom-AudioStreamProbe's
            # `,@($result)` straight through, so wrapping it here nests it and $s binds to the
            # whole array -- `[int]$s.StreamIdx` then throws on any 2-stream file (trap #2, the
            # exact crash Get-TrimAudioStreams's own comment describes). The load path at
            # $onTrimFile assigns it plainly for the same reason.
            $addedStreams = Get-TrimAudioStreams -InputFile $path
            $streamCount = @($addedStreams).Count
            if ($streamCount -gt 0) {
                $laneNames = Get-TrimVideoLaneNames
                $vName = $(if ($laneNames.ContainsKey($laneId)) { [string]$laneNames[$laneId] } else { "V" })
                # One row per stream, each below the last: two streams sharing one row would
                # be two clips stacked at the same offset, which no row can draw.
                $afterId = $laneId
                $streamNo = 1
                foreach ($s in @($addedStreams)) {
                    $rowLabel = $(if ($streamCount -eq 1) { "{0} audio" -f $vName } else { "{0} audio {1}" -f $vName, $streamNo })
                    $aLane = Add-TrimLaneRow -Kind "audio" -Label $rowLabel -AfterLaneId $afterId
                    $afterId = [string]$aLane.Id
                    $streamNo++
                    $aclip = New-TrimClip -Kind "audio" -Path $path -StreamIdx ([int]$s.StreamIdx) `
                        -Offset $timelineOffset -LinkId $linkId
                    Add-TrimClipToLane -LaneId ([string]$aLane.Id) -Clip $aclip
                }
            }
            Set-TrimSelectedClip -Id ([string]$vclip.Id)
        }
        Update-TrimLaneRows
        Update-PipPreview -SourceSeconds $script:TrimPlayhead
        Update-TrimBlackBase
        Request-TrimProjectSave
    }

    # ---- PiP spotlight box (drag/resize on the caption overlay canvas) ----
    #
    # Drawn only while the selected clip is a BOXED overlay video clip, the same "one thing
    # owns the overlay's furniture at a time" rule the zoom box and captions already share
    # (see Set-TrimSelectedClip/-Zoom/-Caption clearing each other). Cloned from the zoom
    # box's element pattern (gold frame + body mover + bottom-right handle) per the
    # Task 10 brief, with its own PipBoxElements tracking list so it can be torn down
    # and rebuilt without disturbing the zoom box's or the captions' own elements.
    function Remove-PipBoxElements {
        if ($null -eq $canvasCaptionOverlay) { return }
        foreach ($el in @($script:PipBoxElements)) {
            if ($canvasCaptionOverlay.Children.Contains($el)) { $canvasCaptionOverlay.Children.Remove($el) }
        }
        $script:PipBoxElements.Clear()
    }

    function Add-PipBoxElement {
        param($Element, [double]$Left, [double]$Top)
        [System.Windows.Controls.Canvas]::SetLeft($Element, $Left)
        [System.Windows.Controls.Canvas]::SetTop($Element, $Top)
        $Element.IsHitTestVisible = $false
        $canvasCaptionOverlay.Children.Add($Element) | Out-Null
        [void]$script:PipBoxElements.Add($Element)
    }

    # Redrawn from the model, called right after Update-ZoomBoxOverlay at every point the
    # caption/zoom overlay redraws (tick, scrub, selection change) -- see the call sites
    # added alongside Update-ZoomBoxOverlay's own.
    # The selected clip when -- and only when -- it is a BOXED overlay video clip: the box
    # is what drags a PiP around, and a full-frame clip (Pip $null) has nothing to drag
    # until Task 12's full-frame handling lands.
    function Get-TrimSelectedPipClip {
        if ($null -eq $script:TrimSelectedClip) { return $null }
        $ref = Get-TrimClipRef -Id $script:TrimSelectedClip
        if ($null -eq $ref) { return $null }
        if (Test-TrimClipIsMainVideo -Lane $ref.Lane -Clip $ref.Clip) { return $null }
        if ($ref.Clip.Kind -ne "video" -and $ref.Clip.Kind -ne "image") { return $null }
        if ($null -eq $ref.Clip.Pip) { return $null }
        return $ref.Clip
    }

    function Update-PipBoxOverlay {
        if ($null -eq $canvasCaptionOverlay) { return }
        Remove-PipBoxElements
        $t = Get-TrimSelectedPipClip
        if ($null -eq $t) { return }

        $w = [double]$canvasCaptionOverlay.ActualWidth
        $h = [double]$canvasCaptionOverlay.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }

        # Mid-drag the box on screen is the one being dragged, not the one stored: the
        # values already landed live (Update-PipBoxDrag writes through Set-TrimClipValues
        # every move), but reading them back off the drag state avoids a redundant
        # clip lookup mid-gesture, mirroring the zoom box's $forming path.
        $drag = $script:PipBoxDrag
        $pip = if ($null -ne $drag -and $drag.Moved) {
            @{ X = $drag.X; Y = $drag.Y; W = $drag.W; H = $drag.H }
        } elseif ($null -ne $t.Pip) {
            $t.Pip
        } else {
            @{ X = 0.5; Y = 0.5; W = 0.35; H = 0.35 }
        }

        $bw = $w * [math]::Max(0.01, [double]$pip.W)
        $bh = $h * [math]::Max(0.01, [double]$pip.H)
        $left = [math]::Max(0.0, [math]::Min($w - $bw, ([double]$pip.X * $w) - ($bw / 2.0)))
        $top = [math]::Max(0.0, [math]::Min($h - $bh, ([double]$pip.Y * $h) - ($bh / 2.0)))

        $frame = New-Object System.Windows.Controls.Border
        $frame.BorderBrush = Get-CaptionBrush -Hex $script:ZoomBoxStrokeBrush -Fallback "#E0C48F"
        $frame.BorderThickness = New-Object System.Windows.Thickness(2)
        $frame.Width = [math]::Max(1.0, $bw)
        $frame.Height = [math]::Max(1.0, $bh)
        Add-PipBoxElement -Element $frame -Left $left -Top $top

        $mover = New-Object System.Windows.Shapes.Rectangle
        $mover.Width = [math]::Max(1.0, $bw)
        $mover.Height = [math]::Max(1.0, $bh)
        $mover.Fill = [System.Windows.Media.Brushes]::Transparent
        $mover.Cursor = [System.Windows.Input.Cursors]::SizeAll
        Add-PipBoxElement -Element $mover -Left $left -Top $top
        $mover.IsHitTestVisible = $true
        # No GetNewClosure: exactly one PiP box can exist at a time (the selected track),
        # so there is no per-item loop variable to capture -- same reasoning as the zoom
        # box's mover/sizer.
        $mover.Add_MouseLeftButtonDown({
            param($eventSource, $e)
            $p = $e.GetPosition($canvasCaptionOverlay)
            Start-PipBoxDrag -StartX $p.X -StartY $p.Y -Mode "pipmove"
            $canvasCaptionOverlay.CaptureMouse() | Out-Null
            $e.Handled = $true
        })

        $sizer = New-Object System.Windows.Shapes.Ellipse
        $sizer.Width = 13
        $sizer.Height = 13
        $sizer.Fill = Get-CaptionBrush -Hex $script:ZoomBoxStrokeBrush -Fallback "#E0C48F"
        $sizer.Stroke = Get-CaptionBrush -Hex "#12161C" -Fallback "#000000"
        $sizer.StrokeThickness = 1.5
        $sizer.Cursor = [System.Windows.Input.Cursors]::SizeNWSE
        Add-PipBoxElement -Element $sizer `
            -Left ([math]::Max(0.0, [math]::Min($w - 13.0, $left + $bw - 6.5))) `
            -Top ([math]::Max(0.0, [math]::Min($h - 13.0, $top + $bh - 6.5)))
        $sizer.IsHitTestVisible = $true
        $sizer.Add_MouseLeftButtonDown({
            param($eventSource, $e)
            $p = $e.GetPosition($canvasCaptionOverlay)
            Start-PipBoxDrag -StartX $p.X -StartY $p.Y -Mode "pipresize"
            $canvasCaptionOverlay.CaptureMouse() | Out-Null
            $e.Handled = $true
        })
    }

    # Same lifecycle shape as Start-/Update-/Complete-ZoomBoxDrag: snapshot at mouse-down,
    # applied live against the ORIGINAL values every move, pushed on release only if the
    # box actually moved.
    function Start-PipBoxDrag {
        param([double]$StartX, [double]$StartY, [string]$Mode)
        $t = Get-TrimSelectedPipClip
        if ($null -eq $t) { return }
        $pip = if ($null -ne $t.Pip) { $t.Pip } else { @{ X = 0.5; Y = 0.5; W = 0.35; H = 0.35 } }
        $script:PipBoxDrag = @{
            Mode   = $Mode
            StartX = $StartX
            StartY = $StartY
            Moved  = $false
            OrigX  = [double]$pip.X
            OrigY  = [double]$pip.Y
            OrigW  = [double]$pip.W
            OrigH  = [double]$pip.H
            X      = [double]$pip.X
            Y      = [double]$pip.Y
            W      = [double]$pip.W
            H      = [double]$pip.H
            ClipId   = [string]$t.Id
            Snapshot = New-TrimUndoSnapshot
        }
    }

    function Test-PipBoxDrag {
        return ($null -ne $script:PipBoxDrag)
    }

    # Magnet ON locks the CLIP's OWN aspect (Task 10 ruling #6 -- NOT the frame's, unlike
    # the zoom box's magnet), read from the cache Invoke-TrimAddClip populated so a
    # mouse-move handler never has to shell out to ffprobe mid-drag.
    function Update-PipBoxDrag {
        param([double]$CurrentX, [double]$CurrentY)
        $drag = $script:PipBoxDrag
        if ($null -eq $drag) { return }
        if ($null -eq $canvasCaptionOverlay) { return }
        $w = [double]$canvasCaptionOverlay.ActualWidth
        $h = [double]$canvasCaptionOverlay.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }

        $dx = $CurrentX - [double]$drag.StartX
        $dy = $CurrentY - [double]$drag.StartY
        if (-not $drag.Moved -and ([math]::Abs($dx) -gt 4.0 -or [math]::Abs($dy) -gt 4.0)) { $drag.Moved = $true }
        if (-not $drag.Moved) { return }

        $ref = Get-TrimClipRef -Id $drag.ClipId
        if ($null -eq $ref) { return }
        $t = $ref.Clip

        if ($drag.Mode -eq "pipmove") {
            $cx = [math]::Max($drag.OrigW / 2.0, [math]::Min(1.0 - $drag.OrigW / 2.0, $drag.OrigX + ($dx / $w)))
            $cy = [math]::Max($drag.OrigH / 2.0, [math]::Min(1.0 - $drag.OrigH / 2.0, $drag.OrigY + ($dy / $h)))
            $drag.X = $cx
            $drag.Y = $cy
            Set-TrimClipValues -Id $drag.ClipId -PipX $cx -PipY $cy
            return
        }

        if ($drag.Mode -eq "pipresize") {
            $newW = [math]::Max(0.05, [math]::Min(1.0, $drag.OrigW + (2.0 * $dx / $w)))
            $newH = [math]::Max(0.05, [math]::Min(1.0, $drag.OrigH + (2.0 * $dy / $h)))
            if ($script:PipMagnet) {
                $clipAspect = if ($script:TrimClipAspect.ContainsKey([string]$t.Path)) { [double]$script:TrimClipAspect[[string]$t.Path] } else { 16.0 / 9.0 }
                $frameAspect = 16.0 / 9.0
                $wDelta = [math]::Abs($newW - $drag.OrigW)
                $hDelta = [math]::Abs($newH - $drag.OrigH)
                if ($wDelta -ge $hDelta) {
                    $newH = [math]::Max(0.05, [math]::Min(1.0, $newW * ($frameAspect / $clipAspect)))
                } else {
                    $newW = [math]::Max(0.05, [math]::Min(1.0, $newH * ($clipAspect / $frameAspect)))
                }
            }
            $cx = [math]::Max($newW / 2.0, [math]::Min(1.0 - $newW / 2.0, $drag.OrigX))
            $cy = [math]::Max($newH / 2.0, [math]::Min(1.0 - $newH / 2.0, $drag.OrigY))
            $drag.W = $newW
            $drag.H = $newH
            $drag.X = $cx
            $drag.Y = $cy
            Set-TrimClipValues -Id $drag.ClipId -PipW $newW -PipH $newH -PipX $cx -PipY $cy
            return
        }
    }

    function Complete-PipBoxDrag {
        $drag = $script:PipBoxDrag
        $script:PipBoxDrag = $null
        if ($null -eq $drag) { return }
        if ($drag.Moved) {
            Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
            Request-TrimProjectSave
        }
        Update-TrimClipProps
    }

    # ---- Caption preview overlay ----
    #
    # Captions drawn over the video, in the same normalised space the export uses: X/Y are
    # fractions of the preview box and FontSizeFrac is a fraction of its height, so what is
    # positioned here lands in the same place at 2560x1440 as it does in a 900px preview.
    #
    # The outline is approximated with a DropShadowEffect at zero depth -- WPF has no text
    # stroke on TextBlock, and the real outline is drawn by libass at export time. The
    # preview is deliberately an approximation; the export is authoritative.
    $script:CaptionOverlaySelectBrush = "#6FD8FF"

    function Set-CaptionPosition {
        param([string]$Id, [double]$X, [double]$Y)
        $cap = Get-TrimCaptionById -Id $Id
        if ($null -eq $cap) { return }
        # Doubles in both slots of every clamp: [math]::Max(0, <double>) binds the INT
        # overload and truncates (Task 9's quantised-drag bug).
        $cap.X = [math]::Max(0.02, [math]::Min(0.98, $X))
        $cap.Y = [math]::Max(0.06, [math]::Min(0.94, $Y))
    }

    function Set-CaptionSize {
        param([string]$Id, [double]$FontSizeFrac)
        $cap = Get-TrimCaptionById -Id $Id
        if ($null -eq $cap) { return }
        $cap.FontSizeFrac = [math]::Max(0.02, [math]::Min(0.2, $FontSizeFrac))
    }

    # Bad colour text can only reach here through a validated path, but a project file edited
    # by hand could still carry one, and an unparsable colour would take the whole redraw
    # down on every tick. Fall back rather than throw.
    function Get-CaptionBrush {
        param([string]$Hex, [string]$Fallback)
        try { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }
        catch { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Fallback) }
    }

    function Get-CaptionColor {
        param([string]$Hex, [string]$Fallback)
        try { return [System.Windows.Media.ColorConverter]::ConvertFromString($Hex) }
        catch { return [System.Windows.Media.ColorConverter]::ConvertFromString($Fallback) }
    }

    # Everything the caption redraw owns, and the transient zoom-box shapes with it (they are
    # rebuilt from the model by Update-ZoomBoxOverlay, which runs right after every call to
    # Update-CaptionOverlay). The zoom PILL is deliberately left in place: it is a live
    # control, and pulling it out of the visual tree while its slider holds the mouse capture
    # -- which the 20x/sec playback tick would do mid-drag -- kills the capture and the drag
    # dies halfway across the range.
    function Clear-CaptionOverlayChildren {
        if ($null -eq $canvasCaptionOverlay) { return }
        for ($i = $canvasCaptionOverlay.Children.Count - 1; $i -ge 0; $i--) {
            $child = $canvasCaptionOverlay.Children[$i]
            if ($null -ne $script:ZoomPillBorder -and [object]::ReferenceEquals($child, $script:ZoomPillBorder)) { continue }
            $canvasCaptionOverlay.Children.RemoveAt($i)
        }
        $script:ZoomBoxElements.Clear()
    }

    function Update-CaptionOverlay {
        param([double]$SourceSeconds)
        if ($null -eq $canvasCaptionOverlay) { return }
        Clear-CaptionOverlayChildren
        if (-not $script:TrimInputFile) { return }
        # A rendered crossfade is playing on top of the live preview; the captions belong
        # under it, not floating over a frame from a different position. Leave the overlay
        # cleared until the fade ends (Update-TrimFadeOverlay calls back in on the way out).
        if ($null -ne $script:TrimFadeOverlayKey) { return }

        $w = $canvasCaptionOverlay.ActualWidth
        $h = $canvasCaptionOverlay.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }

        foreach ($c in @($script:TrimCaptions)) {
            $isSelected = ($c.Id -eq $script:TrimSelectedCaption)
            # The selected caption is drawn even when the playhead is outside its window --
            # otherwise selecting one and scrubbing away leaves nothing to drag or resize.
            $inWindow = ($SourceSeconds -ge [double]$c.Start -and $SourceSeconds -lt [double]$c.End)
            if (-not $inWindow -and -not $isSelected) { continue }
            # An empty caption has no glyphs, so it would measure to nothing and be
            # impossible to grab. Selected, it gets a placeholder so it can still be placed;
            # unselected, there is nothing worth putting over the video.
            $isEmpty = [string]::IsNullOrEmpty($c.Text)
            if ($isEmpty -and -not $isSelected) { continue }

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = if ($isEmpty) { "(empty)" } else { [string]$c.Text }
            $label.FontFamily = New-Object System.Windows.Media.FontFamily([string]$c.FontFamily)
            $label.FontWeight = if ($c.Bold) {
                [System.Windows.FontWeights]::Bold
            } else {
                [System.Windows.FontWeights]::Normal
            }
            $label.FontSize = [math]::Max(1.0, [double]$c.FontSizeFrac * $h)
            $label.Foreground = Get-CaptionBrush -Hex ([string]$c.FillColor) -Fallback "#FFFFFF"
            $label.TextAlignment = "Center"
            $label.TextWrapping = "NoWrap"

            $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $glow.ShadowDepth = 0
            $glow.BlurRadius = [double]$c.OutlineWidth * 2
            $glow.Color = Get-CaptionColor -Hex ([string]$c.OutlineColor) -Fallback "#000000"
            $glow.Opacity = 1
            $label.Effect = $glow

            $element = $label
            if ($isSelected) {
                # Solid 1.5px cyan, not dashed: Border has no dash support and overlaying a
                # dashed Rectangle would add a second element to keep in sync through every
                # drag for a purely cosmetic difference. Background must be Transparent
                # rather than unset -- an unset Background is not hit-testable, so the box
                # around the glyphs would not be draggable.
                $box = New-Object System.Windows.Controls.Border
                $box.BorderBrush = Get-CaptionBrush -Hex $script:CaptionOverlaySelectBrush -Fallback "#6FD8FF"
                $box.BorderThickness = New-Object System.Windows.Thickness(1.5)
                $box.Background = [System.Windows.Media.Brushes]::Transparent
                $box.Padding = New-Object System.Windows.Thickness(3)
                $box.Cursor = [System.Windows.Input.Cursors]::SizeAll
                $box.Child = $label
                $element = $box
            }

            $element.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
            $ew = $element.DesiredSize.Width
            $eh = $element.DesiredSize.Height
            $left = ([double]$c.X * $w) - ($ew / 2)
            $top = ([double]$c.Y * $h) - ($eh / 2)
            [System.Windows.Controls.Canvas]::SetLeft($element, $left)
            [System.Windows.Controls.Canvas]::SetTop($element, $top)
            $canvasCaptionOverlay.Children.Add($element) | Out-Null

            if (-not $isSelected) { continue }

            $thisId = $c.Id
            # GetNewClosure, exactly as on the lane blocks: without it every element captures
            # the loop variable's final value. Capture goes on the CANVAS, not on these
            # elements -- the overlay is rebuilt on every MouseMove, and a capture held by a
            # destroyed element is lost after one move.
            $element.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                $p = $e.GetPosition($canvasCaptionOverlay)
                Start-CaptionOverlayDrag -Id $thisId -Mode "move" -StartX $p.X -StartY $p.Y
                $canvasCaptionOverlay.CaptureMouse() | Out-Null
                $e.Handled = $true
            }.GetNewClosure())

            $handle = New-Object System.Windows.Shapes.Ellipse
            $handle.Width = 13
            $handle.Height = 13
            $handle.Fill = Get-CaptionBrush -Hex $script:CaptionOverlaySelectBrush -Fallback "#6FD8FF"
            $handle.Stroke = Get-CaptionBrush -Hex "#12161C" -Fallback "#000000"
            $handle.StrokeThickness = 1.5
            $handle.Cursor = [System.Windows.Input.Cursors]::SizeNWSE
            [System.Windows.Controls.Canvas]::SetLeft($handle, $left + $ew - 6.5)
            [System.Windows.Controls.Canvas]::SetTop($handle, $top + $eh - 6.5)
            $handle.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                $p = $e.GetPosition($canvasCaptionOverlay)
                Start-CaptionOverlayDrag -Id $thisId -Mode "size" -StartX $p.X -StartY $p.Y
                $canvasCaptionOverlay.CaptureMouse() | Out-Null
                # Handled, so the box's own move-drag underneath does not also start and
                # turn a resize into a reposition.
                $e.Handled = $true
            }.GetNewClosure())
            $canvasCaptionOverlay.Children.Add($handle) | Out-Null
        }
    }

    # Same shape as the lane's drag lifecycle, and for the same reasons: the snapshot is
    # taken when the drag BEGINS and pushed only on release, and only if something actually
    # moved -- one undo step per drag, none for a click that just selects.
    function Start-CaptionOverlayDrag {
        param([string]$Id, [string]$Mode, [double]$StartX, [double]$StartY)
        $cap = Get-TrimCaptionById -Id $Id
        if ($null -eq $cap) { return }
        $script:CaptionOverlayDrag = @{
            Id       = $Id
            Mode     = $Mode
            StartX   = $StartX
            StartY   = $StartY
            OrigX    = [double]$cap.X
            OrigY    = [double]$cap.Y
            OrigSize = [double]$cap.FontSizeFrac
            Snapshot = New-TrimUndoSnapshot
        }
    }

    function Test-CaptionOverlayDrag {
        return ($null -ne $script:CaptionOverlayDrag)
    }

    # Deltas are applied against the drag's ORIGINAL values, never accumulated, so a clamped
    # edge cannot eat motion and dragging back out returns to where it started.
    function Update-CaptionOverlayDrag {
        param([double]$CurrentX, [double]$CurrentY)
        $drag = $script:CaptionOverlayDrag
        if ($null -eq $drag) { return }
        if ($null -eq $canvasCaptionOverlay) { return }
        $w = $canvasCaptionOverlay.ActualWidth
        $h = $canvasCaptionOverlay.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }
        if ($drag.Mode -eq "size") {
            # Dragging the handle down grows the caption: the vertical delta is read as a
            # fraction of the preview height, the same unit FontSizeFrac is stored in.
            Set-CaptionSize -Id $drag.Id -FontSizeFrac ($drag.OrigSize + (($CurrentY - $drag.StartY) / $h))
        } else {
            Set-CaptionPosition -Id $drag.Id `
                -X ($drag.OrigX + (($CurrentX - $drag.StartX) / $w)) `
                -Y ($drag.OrigY + (($CurrentY - $drag.StartY) / $h))
        }
    }

    function Complete-CaptionOverlayDrag {
        $drag = $script:CaptionOverlayDrag
        $script:CaptionOverlayDrag = $null
        if ($null -eq $drag) { return }
        $cap = Get-TrimCaptionById -Id $drag.Id
        if ($null -eq $cap) { return }
        if ([math]::Abs([double]$cap.X - $drag.OrigX) -lt 1e-4 -and
            [math]::Abs([double]$cap.Y - $drag.OrigY) -lt 1e-4 -and
            [math]::Abs([double]$cap.FontSizeFrac - $drag.OrigSize) -lt 1e-4) { return }
        Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
        # Same release-only hook as the lane drag, for the same reason.
        Request-TrimProjectSave
        # No sidebar refresh: position and size have no field in the properties column, so
        # nothing there can have gone stale.
    }

    # ---- Zoom spotlight box + floating pill ----
    #
    # Drawn on CanvasCaptionOverlay, the UNZOOMED layer, on purpose: the box has to show
    # where the zoom is being aimed within the whole frame, and a box drawn inside the zoomed
    # picture would be a box drawn inside its own result.
    #
    # Element ownership on that shared canvas: the box shapes are transient and tracked in
    # $script:ZoomBoxElements so they can be removed one by one (a Children.Clear() here
    # would take the captions with them); the pill is persistent and exempt from the caption
    # redraw's clear (see Clear-CaptionOverlayChildren).
    $script:ZoomBoxDimBrush = "#8C04070E"
    $script:ZoomBoxStrokeBrush = "#E0C48F"

    function Remove-ZoomBoxElements {
        if ($null -eq $canvasCaptionOverlay) { return }
        foreach ($el in @($script:ZoomBoxElements)) {
            if ($canvasCaptionOverlay.Children.Contains($el)) { $canvasCaptionOverlay.Children.Remove($el) }
        }
        $script:ZoomBoxElements.Clear()
    }

    function Add-ZoomBoxElement {
        param($Element, [double]$Left, [double]$Top)
        [System.Windows.Controls.Canvas]::SetLeft($Element, $Left)
        [System.Windows.Controls.Canvas]::SetTop($Element, $Top)
        # None of the box furniture is hit-testable: a press anywhere inside the preview has
        # to reach the canvas itself, because that is what starts a new box (and what the
        # existing deselect handler tests OriginalSource for).
        $Element.IsHitTestVisible = $false
        $canvasCaptionOverlay.Children.Add($Element) | Out-Null
        [void]$script:ZoomBoxElements.Add($Element)
    }

    function Add-ZoomBoxDimRect {
        param([double]$Left, [double]$Top, [double]$Width, [double]$Height)
        # Degenerate strips happen constantly -- a box pinned to the top edge has no top
        # dim -- and a Rectangle with a negative Width throws.
        if ($Width -le 0.5 -or $Height -le 0.5) { return }
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = $Width
        $r.Height = $Height
        $r.Fill = Get-CaptionBrush -Hex $script:ZoomBoxDimBrush -Fallback "#8C000000"
        Add-ZoomBoxElement -Element $r -Left $Left -Top $Top
    }

    # The frame a keyframe describes, in overlay pixels. A Canvas has no box-shadow, so the
    # "everything outside is dimmed" look is composed from four rectangles around this rect.
    function Get-ZoomBoxRect {
        param([double]$BoxW, [double]$BoxH, [double]$CX, [double]$CY, [double]$Width, [double]$Height)
        $bw = $Width * [math]::Max(0.01, [double]$BoxW)
        $bh = $Height * [math]::Max(0.01, [double]$BoxH)
        # Clamped inside the frame when the box fits: a zoom-in box hanging off the edge
        # would be asking for footage that is not there. A zoomed-OUT axis (box bigger
        # than the frame) stays centred instead -- there is no legal clamp range -- and
        # the preview cell's Clip crops the overhang visually.
        if ($bw -le $Width) {
            $left = [math]::Max(0.0, [math]::Min($Width - $bw, ([double]$CX * $Width) - ($bw / 2.0)))
        } else {
            $left = ($Width - $bw) / 2.0
        }
        if ($bh -le $Height) {
            $top = [math]::Max(0.0, [math]::Min($Height - $bh, ([double]$CY * $Height) - ($bh / 2.0)))
        } else {
            $top = ($Height - $bh) / 2.0
        }
        return @{ Left = $left; Top = $top; Width = $bw; Height = $bh }
    }

    # Redrawn from the model, exactly like the lane and the caption overlay, and called right
    # after every Update-CaptionOverlay (which clears the canvas underneath it) plus at the
    # end of Update-TrimZoomLane (which is what a selection change redraws).
    function Update-ZoomBoxOverlay {
        if ($null -eq $canvasCaptionOverlay) { return }
        Remove-ZoomBoxElements

        $kf = Get-TrimSelectedZoom
        $drag = $script:ZoomBoxDrag
        $forming = ($null -ne $drag -and $drag.Moved -and $null -ne $drag.Rect)
        if ($null -eq $kf -or -not $script:TrimInputFile) {
            Hide-ZoomPill
            return
        }

        $w = [double]$canvasCaptionOverlay.ActualWidth
        $h = [double]$canvasCaptionOverlay.ActualHeight
        if ($w -le 0 -or $h -le 0) { Hide-ZoomPill; return }

        # Mid-drag the box on screen is the one being drawn, not the one stored: the commit
        # only happens on release, so until then the model still holds the old framing.
        if ($forming) {
            $rect = $drag.Rect
            $boxW = [math]::Max(0.01, [double]$rect.Width / $w)
            $boxH = [math]::Max(0.01, [double]$rect.Height / $h)
        } else {
            $box = Get-ZoomKeyframeBox -Keyframe $kf
            $boxW = [double]$box.W
            $boxH = [double]$box.H
            $rect = Get-ZoomBoxRect -BoxW $boxW -BoxH $boxH -CX ([double]$kf.CX) -CY ([double]$kf.CY) -Width $w -Height $h
        }
        $nonIdentity = -not (Test-ZoomIdentity -W $boxW -H $boxH)

        # At identity the box IS the whole frame, so there is nothing outside it to dim --
        # four zero-width strips. The frame and the badge are still drawn, because a fresh
        # identity keyframe with nothing on screen would look like the selection had not
        # taken. (Zoom-out boxes overflow the frame; the dim helper drops the negative
        # strips itself.)
        if ($nonIdentity) {
            Add-ZoomBoxDimRect -Left 0.0 -Top 0.0 -Width $w -Height $rect.Top
            Add-ZoomBoxDimRect -Left 0.0 -Top ($rect.Top + $rect.Height) -Width $w -Height ($h - $rect.Top - $rect.Height)
            Add-ZoomBoxDimRect -Left 0.0 -Top $rect.Top -Width $rect.Left -Height $rect.Height
            Add-ZoomBoxDimRect -Left ($rect.Left + $rect.Width) -Top $rect.Top `
                -Width ($w - $rect.Left - $rect.Width) -Height $rect.Height
        }

        $frame = New-Object System.Windows.Controls.Border
        $frame.BorderBrush = Get-CaptionBrush -Hex $script:ZoomBoxStrokeBrush -Fallback "#E0C48F"
        $frame.BorderThickness = New-Object System.Windows.Thickness(2)
        $frame.Width = [math]::Max(1.0, $rect.Width)
        $frame.Height = [math]::Max(1.0, $rect.Height)
        Add-ZoomBoxElement -Element $frame -Left $rect.Left -Top $rect.Top

        # The grab surface: an invisible, HIT-TESTABLE rect over the committed box so it
        # can be dragged to a new position like a caption. Only when a real box exists
        # and not mid-draw -- the forming box has nothing to grab yet. Added AFTER
        # Add-ZoomBoxElement's blanket IsHitTestVisible=$false, deliberately undone
        # here: this one element is the exception that rule exists to protect.
        if (-not $forming -and $nonIdentity) {
            $mover = New-Object System.Windows.Shapes.Rectangle
            $mover.Width = [math]::Max(1.0, $rect.Width)
            $mover.Height = [math]::Max(1.0, $rect.Height)
            $mover.Fill = [System.Windows.Media.Brushes]::Transparent
            $mover.Cursor = [System.Windows.Input.Cursors]::SizeAll
            Add-ZoomBoxElement -Element $mover -Left $rect.Left -Top $rect.Top
            $mover.IsHitTestVisible = $true
            # No GetNewClosure: it reads no per-item loop variable (there is exactly one
            # box), and all state flows through top-level functions.
            $mover.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                $p = $e.GetPosition($canvasCaptionOverlay)
                Start-ZoomBoxDrag -StartX $p.X -StartY $p.Y -Mode "move"
                $canvasCaptionOverlay.CaptureMouse() | Out-Null
                # Stop the bubble: the canvas press handler would read this same press as
                # the corner of a NEW box.
                $e.Handled = $true
            })

            # Bottom-right resize handle, the caption box's grammar exactly: same 13px
            # dot, same diagonal cursor. Free resize by default; the magnet toggle on
            # the pill locks it back to the frame's shape. Drawn after the mover so it
            # wins the hit test over it.
            $sizer = New-Object System.Windows.Shapes.Ellipse
            $sizer.Width = 13
            $sizer.Height = 13
            $sizer.Fill = Get-CaptionBrush -Hex $script:ZoomBoxStrokeBrush -Fallback "#E0C48F"
            $sizer.Stroke = Get-CaptionBrush -Hex "#12161C" -Fallback "#000000"
            $sizer.StrokeThickness = 1.5
            $sizer.Cursor = [System.Windows.Input.Cursors]::SizeNWSE
            Add-ZoomBoxElement -Element $sizer `
                -Left ([math]::Max(0.0, [math]::Min($w - 13.0, $rect.Left + $rect.Width - 6.5))) `
                -Top ([math]::Max(0.0, [math]::Min($h - 13.0, $rect.Top + $rect.Height - 6.5)))
            $sizer.IsHitTestVisible = $true
            $sizer.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                $p = $e.GetPosition($canvasCaptionOverlay)
                Start-ZoomBoxDrag -StartX $p.X -StartY $p.Y -Mode "resize"
                $canvasCaptionOverlay.CaptureMouse() | Out-Null
                $e.Handled = $true
            })
        }

        # Zoom badge, top-right INSIDE the box: outside it would fall off the frame for a
        # box pinned to the top edge, which is where most zooms end up. A stretched box
        # shows both axes; a uniform one keeps the familiar single figure.
        $badge = New-Object System.Windows.Controls.Border
        $badge.Background = Get-CaptionBrush -Hex "#D9090D1A" -Fallback "#000000"
        $badge.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $badge.Padding = New-Object System.Windows.Thickness(5, 1, 5, 1)
        $badgeText = New-Object System.Windows.Controls.TextBlock
        $badgeText.Text = Get-ZoomBadgeText -BoxW $boxW -BoxH $boxH
        $badgeText.FontSize = 11
        $badgeText.Foreground = Get-CaptionBrush -Hex $script:ZoomBoxStrokeBrush -Fallback "#E0C48F"
        $badge.Child = $badgeText
        $badge.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
        $bw = $badge.DesiredSize.Width
        $bh = $badge.DesiredSize.Height
        Add-ZoomBoxElement -Element $badge `
            -Left ([math]::Max(0.0, [math]::Min($w - $bw, $rect.Left + $rect.Width - $bw - 4.0))) `
            -Top ([math]::Max(0.0, [math]::Min($h - $bh, $rect.Top + 4.0)))

        Show-ZoomPill -BoxW $boxW -BoxH $boxH -Rect $rect -Width $w -Height $h
    }

    function Get-ZoomBadgeText {
        param([double]$BoxW, [double]$BoxH)
        $zx = 1.0 / [math]::Max(0.01, $BoxW)
        $zy = 1.0 / [math]::Max(0.01, $BoxH)
        if ([math]::Abs($BoxW - $BoxH) -lt 0.005) { return ("{0:N1}x" -f $zx) }
        return ("{0:N1}x / {1:N1}x" -f $zx, $zy)
    }

    function Hide-ZoomPill {
        if ($null -eq $script:ZoomPillBorder) { return }
        $script:ZoomPillBorder.Visibility = "Collapsed"
    }

    # Position and sync only -- the pill itself is built once by Initialize-ZoomPill.
    function Show-ZoomPill {
        param([double]$BoxW, [double]$BoxH, $Rect, [double]$Width, [double]$Height)
        if ($null -eq $script:ZoomPillBorder) { return }
        $script:ZoomPillBorder.Visibility = "Visible"
        # The slider is a UNIFORM control: it reads the box's overall magnitude (geometric
        # mean of the axes so a stretch still registers) and writes a frame-shaped box
        # back. Fine detail per axis lives on the corner handle, not here.
        $sliderLevel = [math]::Max(1.0, [math]::Min(6.0, 1.0 / [math]::Sqrt([math]::Max(1e-6, $BoxW * $BoxH))))
        # The whole point of the loading flag: this assignment raises ValueChanged exactly as
        # a user drag does, and the handler behind it would write the value straight back
        # (snapped to the nearest tick) over the box the drag just committed.
        Set-ZoomUiLoading -Value $true
        try {
            if ($null -ne $script:ZoomPillSlider) { $script:ZoomPillSlider.Value = $sliderLevel }
            if ($null -ne $script:ZoomPillValueText) { $script:ZoomPillValueText.Text = Get-ZoomBadgeText -BoxW $BoxW -BoxH $BoxH }
            Update-ZoomMagnetVisual
        } finally {
            # finally, not a trailing assignment: a throw in the fill would otherwise leave
            # the flag set and deaden the pill for the rest of the session.
            Set-ZoomUiLoading -Value $false
        }

        # Frozen in place while the slider is being dragged: the box shrinks as the level
        # rises, so re-anchoring the pill to it per tick would walk the thumb out from under
        # the pointer that is dragging it.
        if ($null -ne $script:ZoomPillSlider -and $script:ZoomPillSlider.IsMouseCaptureWithin) { return }

        $script:ZoomPillBorder.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
        $pw = $script:ZoomPillBorder.DesiredSize.Width
        $ph = $script:ZoomPillBorder.DesiredSize.Height
        $left = ([double]$Rect.Left + ([double]$Rect.Width / 2.0)) - ($pw / 2.0)
        $top = [double]$Rect.Top + [double]$Rect.Height + 8.0
        # Under the box normally; above it when the box runs to the bottom of the frame, so
        # the pill is never half off the picture.
        if ($top + $ph -gt $Height) { $top = [double]$Rect.Top - $ph - 8.0 }
        [System.Windows.Controls.Canvas]::SetLeft($script:ZoomPillBorder, [math]::Max(0.0, [math]::Min($Width - $pw, $left)))
        [System.Windows.Controls.Canvas]::SetTop($script:ZoomPillBorder, [math]::Max(0.0, [math]::Min($Height - $ph, $top)))
    }

    function Test-ZoomUiLoading {
        return $script:ZoomUiLoading
    }

    function Set-ZoomUiLoading {
        param([bool]$Value)
        $script:ZoomUiLoading = $Value
    }

    # ---- Drag-to-draw / drag-to-move ----
    #
    # A press on the bare overlay while a zoom is selected is ambiguous: it is either the
    # start of a new box or the click that deselects. It is treated as a box until the
    # release proves otherwise, which is why nothing is committed on the way down.
    #
    # A press INSIDE the committed box is a different gesture entirely: it grabs the box
    # and MOVES it (Mode "move"), keeping the level -- the same way a caption is dragged.
    # Move applies live through Set-TrimZoomValues so the zoomed preview pans under the
    # pointer; draw commits only on release.
    function Start-ZoomBoxDrag {
        param([double]$StartX, [double]$StartY, [string]$Mode = "draw")
        $orig = Get-TrimSelectedZoom
        $origBox = if ($orig) { Get-ZoomKeyframeBox -Keyframe $orig } else { @{ W = 1.0; H = 1.0 } }
        $script:ZoomBoxDrag = @{
            Mode     = $Mode
            StartX   = $StartX
            StartY   = $StartY
            Moved    = $false
            Rect     = $null
            OrigCX   = if ($orig) { [double]$orig.CX } else { 0.5 }
            OrigCY   = if ($orig) { [double]$orig.CY } else { 0.5 }
            OrigW    = [double]$origBox.W
            OrigH    = [double]$origBox.H
            Snapshot = New-TrimUndoSnapshot
        }
    }

    function Test-ZoomBoxDrag {
        return ($null -ne $script:ZoomBoxDrag)
    }

    # 16:9-locked from the larger of the two deltas, in whatever direction the pointer went.
    # The overlay canvas is itself exactly 16:9 (it is pinned to the video box), so clamping
    # the WIDTH to the canvas is enough -- the height that follows can never overflow.
    function Update-ZoomBoxDrag {
        param([double]$CurrentX, [double]$CurrentY)
        $drag = $script:ZoomBoxDrag
        if ($null -eq $drag) { return }
        if ($null -eq $canvasCaptionOverlay) { return }
        $w = [double]$canvasCaptionOverlay.ActualWidth
        $h = [double]$canvasCaptionOverlay.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }

        $dx = $CurrentX - [double]$drag.StartX
        $dy = $CurrentY - [double]$drag.StartY
        if (-not $drag.Moved -and
            ([math]::Abs($dx) -gt $script:ZoomBoxDragThreshold -or [math]::Abs($dy) -gt $script:ZoomBoxDragThreshold)) {
            $drag.Moved = $true
        }

        if ($drag.Mode -eq "move") {
            if (-not $drag.Moved) { return }
            $kf = Get-TrimSelectedZoom
            if ($null -eq $kf) { return }
            $box = Get-ZoomKeyframeBox -Keyframe $kf
            # Nothing to move at identity -- the box IS the frame.
            if (Test-ZoomIdentity -W $box.W -H $box.H) { return }
            # Clamped per axis so the box never leaves the frame: a box W wide has its
            # centre in [W/2, 1 - W/2]. A zoomed-OUT axis has no legal off-centre
            # position at all (the export pad is centred), so it pins to 0.5. Applied
            # LIVE (unlike draw, which commits on release) so the zoomed preview pans
            # with the pointer, exactly like dragging a caption.
            $cx = if ($box.W -lt 1.0) {
                [math]::Max($box.W / 2.0, [math]::Min(1.0 - $box.W / 2.0, [double]$drag.OrigCX + ($dx / $w)))
            } else { 0.5 }
            $cy = if ($box.H -lt 1.0) {
                [math]::Max($box.H / 2.0, [math]::Min(1.0 - $box.H / 2.0, [double]$drag.OrigCY + ($dy / $h)))
            } else { 0.5 }
            Set-TrimZoomValues -Id ([string]$kf.Id) -CX $cx -CY $cy
            return
        }

        if ($drag.Mode -eq "resize") {
            if (-not $drag.Moved) { return }
            $kf = Get-TrimSelectedZoom
            if ($null -eq $kf) { return }
            # The corner handle grows the box around its CENTRE, the same way the caption
            # handle grows the caption around its anchor: half the pointer delta lands on
            # each side, so a corner drag of d pixels widens the box by 2d/frame.
            $newW = [double]$drag.OrigW + (2.0 * $dx / $w)
            $newH = [double]$drag.OrigH + (2.0 * $dy / $h)
            if ($script:ZoomMagnet) {
                # Magnet: frame-shaped means W == H in normalised units. Follow whichever
                # axis the pointer moved further on, so the gesture feels direct.
                $uniform = if ([math]::Abs($newW - [double]$drag.OrigW) -ge [math]::Abs($newH - [double]$drag.OrigH)) { $newW } else { $newH }
                $newW = $uniform
                $newH = $uniform
            }
            # Applied LIVE so the preview stretches under the pointer; Set-TrimZoomValues
            # clamps to the model's limits and re-centres any zoomed-out axis itself.
            Set-TrimZoomValues -Id ([string]$kf.Id) -W $newW -H $newH
            return
        }

        # Draw mode. Magnet ON keeps the forming box frame-shaped from the larger of the
        # two deltas, in whatever direction the pointer went -- the overlay canvas is
        # itself exactly frame-shaped, so clamping the WIDTH to the canvas is enough.
        # Magnet OFF tracks both axes independently: the box is exactly what was dragged.
        # 0.0 in every clamp, never 0: [math]::Max(0, <double>) binds the int overload and
        # truncates, which is exactly what quantised the caption drags to whole seconds.
        if ($script:ZoomMagnet) {
            $bw = [math]::Min($w, [math]::Max([math]::Abs($dx), [math]::Abs($dy) * 16.0 / 9.0))
            $bh = $bw * 9.0 / 16.0
        } else {
            $bw = [math]::Min($w, [math]::Abs($dx))
            $bh = [math]::Min($h, [math]::Abs($dy))
        }
        $left = if ($dx -lt 0) { [double]$drag.StartX - $bw } else { [double]$drag.StartX }
        $top = if ($dy -lt 0) { [double]$drag.StartY - $bh } else { [double]$drag.StartY }
        $drag.Rect = @{
            Left   = [math]::Max(0.0, [math]::Min($w - $bw, $left))
            Top    = [math]::Max(0.0, [math]::Min($h - $bh, $top))
            Width  = $bw
            Height = $bh
        }
    }

    # Release. Anything smaller than the minimum -- including a drag that never really
    # started -- is read as the click it looks like and falls through to the deselect the
    # overlay did before zooms existed.
    function Complete-ZoomBoxDrag {
        $drag = $script:ZoomBoxDrag
        $script:ZoomBoxDrag = $null
        if ($null -eq $drag) { return }
        $kf = Get-TrimSelectedZoom
        if ($null -eq $kf) { return }
        if ($null -eq $canvasCaptionOverlay) { return }

        if ($drag.Mode -eq "move" -or $drag.Mode -eq "resize") {
            # The values already landed live; this settles the bookkeeping. A no-move
            # click on the box (or its handle) keeps the selection -- clicking the thing
            # you selected must never deselect it.
            if ($drag.Moved) {
                Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
                Request-TrimProjectSave
            }
            return
        }

        $w = [double]$canvasCaptionOverlay.ActualWidth
        $h = [double]$canvasCaptionOverlay.ActualHeight
        if (-not $drag.Moved -or $null -eq $drag.Rect -or
            [double]$drag.Rect.Width -lt $script:ZoomBoxMinWidth -or $w -le 0 -or $h -le 0) {
            Clear-TrimZoomSelection
            return
        }
        $rect = $drag.Rect
        Push-TrimUndoSnapshot -Snapshot $drag.Snapshot
        # The drawn rectangle IS the box: W/H are its size as fractions of the frame.
        # With the magnet on the draw already kept it frame-shaped; with it off this is
        # exactly the free rectangle the user made.
        Set-TrimZoomValues -Id ([string]$kf.Id) `
            -CX (([double]$rect.Left + ([double]$rect.Width / 2.0)) / $w) `
            -CY (([double]$rect.Top + ([double]$rect.Height / 2.0)) / $h) `
            -W ([double]$rect.Width / $w) `
            -H ([double]$rect.Height / $h)
        # One save per completed drag, like every other drag here.
        Request-TrimProjectSave
    }

    # ---- The floating pill ----
    #
    # Built once, in code rather than XAML, because it lives inside a Canvas whose contents
    # are otherwise entirely data-driven, and because its position is recomputed from the box
    # on every redraw.
    function Initialize-ZoomPill {
        if ($null -eq $canvasCaptionOverlay) { return }
        if ($null -ne $script:ZoomPillBorder) { return }

        $border = New-Object System.Windows.Controls.Border
        $border.Style = $ctx.Window.FindResource("ZoomPillStyle")
        $border.Visibility = "Collapsed"
        # Above the caption elements, which are re-added on every redraw while this one just
        # sits there: without an explicit z-index the pill would sink under a caption drawn
        # over the same part of the picture.
        [System.Windows.Controls.Panel]::SetZIndex($border, 50)

        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = "Horizontal"

        $minLabel = New-Object System.Windows.Controls.TextBlock
        $minLabel.Style = $ctx.Window.FindResource("ZoomPillTextStyle")
        $minLabel.Text = "1x"
        $row.Children.Add($minLabel) | Out-Null

        $slider = New-Object System.Windows.Controls.Slider
        $slider.Minimum = 1.0
        $slider.Maximum = 6.0
        $slider.TickFrequency = 0.1
        $slider.IsSnapToTickEnabled = $true
        $slider.Width = 130
        $slider.VerticalAlignment = "Center"
        $slider.Margin = New-Object System.Windows.Thickness(8, 0, 8, 0)
        $row.Children.Add($slider) | Out-Null

        $valueText = New-Object System.Windows.Controls.TextBlock
        $valueText.Style = $ctx.Window.FindResource("ZoomPillTextStyle")
        $valueText.Text = "1.0x"
        $valueText.MinWidth = 34
        $row.Children.Add($valueText) | Out-Null

        # The magnet: ON locks the box to the frame's shape (uniform zoom, like the
        # caption box's proportional resize); OFF frees both axes so the corner handle
        # can stretch the picture. A Button restyled by hand rather than a ToggleButton:
        # the pressed-state visuals of the stock ToggleButton fight the pill's dark
        # chrome, and the on/off state lives in script scope anyway.
        $magnetButton = New-Object System.Windows.Controls.Button
        $magnetButton.Style = $ctx.Window.FindResource("PresetButtonStyle")
        $magnetButton.Content = [char]::ConvertFromUtf32(0x1F9F2)   # magnet emoji
        $magnetButton.Padding = New-Object System.Windows.Thickness(7, 3, 7, 3)
        $magnetButton.FontSize = 12
        $magnetButton.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
        $magnetButton.VerticalAlignment = "Center"
        $magnetButton.ToolTip = "Magnet: keep the box video-shaped while resizing. Off = free resize (stretches the picture)."
        $row.Children.Add($magnetButton) | Out-Null

        # Confirms the zoom and puts the box away. Clicking empty preview does the same,
        # but a deep zoom's box can cover essentially the whole frame, leaving nothing
        # safe to click -- this button always exists and never moves the box.
        $okButton = New-Object System.Windows.Controls.Button
        $okButton.Style = $ctx.Window.FindResource("PresetButtonStyle")
        $okButton.Content = "OK"
        $okButton.Padding = New-Object System.Windows.Thickness(11, 3, 11, 3)
        $okButton.FontSize = 11
        $okButton.FontWeight = "Bold"
        $okButton.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
        $okButton.VerticalAlignment = "Center"
        $row.Children.Add($okButton) | Out-Null

        $deleteButton = New-Object System.Windows.Controls.Button
        $deleteButton.Style = $ctx.Window.FindResource("PresetButtonStyle")
        $deleteButton.Content = "Delete"
        $deleteButton.Padding = New-Object System.Windows.Thickness(9, 3, 9, 3)
        $deleteButton.FontSize = 11
        $deleteButton.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
        $deleteButton.VerticalAlignment = "Center"
        $row.Children.Add($deleteButton) | Out-Null

        $border.Child = $row
        $canvasCaptionOverlay.Children.Add($border) | Out-Null

        # Assigned through the script scope BEFORE the handlers below are attached: the
        # handlers reach the controls through these fields, and a handler that ran against a
        # still-null field would silently do nothing.
        $script:ZoomPillBorder = $border
        $script:ZoomPillSlider = $slider
        $script:ZoomPillValueText = $valueText
        $script:ZoomPillMagnetButton = $magnetButton
        Update-ZoomMagnetVisual

        # No GetNewClosure on any of these: they reach $script: state through the top-level
        # functions only, and a closure would rebind those writes into its own private module.
        $slider.Add_ValueChanged({
            if (Test-ZoomUiLoading) { return }
            Set-ZoomLevelFromPill
        })
        # Undo brackets the whole drag, exactly as it does on the caption outline slider:
        # ValueChanged fires on every tick of one.
        $slider.Add_GotMouseCapture({ Start-ZoomSliderEdit })
        $slider.Add_LostMouseCapture({ Complete-ZoomSliderEdit })
        $magnetButton.Add_Click({
            Set-ZoomMagnet -Value (-not $script:ZoomMagnet)
        })
        # Keeps the keyframe exactly as edited; only the selection (and with it the
        # box and this pill) goes away. The values were already saved live.
        $okButton.Add_Click({ Clear-TrimZoomSelection })
        $deleteButton.Add_Click({ Invoke-TrimDeleteZoom })
    }

    # Write-throughs for the magnet flag: read/toggled from plain (non-closured)
    # handlers, but kept as functions anyway so every path agrees on the visual.
    function Set-ZoomMagnet {
        param([bool]$Value)
        $script:ZoomMagnet = $Value
        Update-ZoomMagnetVisual
    }

    function Update-ZoomMagnetVisual {
        if ($null -eq $script:ZoomPillMagnetButton) { return }
        # Dim when off: the state has to be readable at a glance, and the button is the
        # only place it shows.
        $script:ZoomPillMagnetButton.Opacity = if ($script:ZoomMagnet) { 1.0 } else { 0.35 }
    }

    function Set-ZoomLevelFromPill {
        $kf = Get-TrimSelectedZoom
        if ($null -eq $kf) { return }
        if ($null -eq $script:ZoomPillSlider) { return }
        # The slider writes a UNIFORM, frame-shaped box: it tightens or loosens the
        # framing the box drag chose, it does not move it. A stretched box snaps back
        # to the frame's shape here -- per-axis freedom belongs to the corner handle.
        $lvl = [math]::Max(1.0, [double]$script:ZoomPillSlider.Value)
        Set-TrimZoomValues -Id ([string]$kf.Id) -W (1.0 / $lvl) -H (1.0 / $lvl)
        if ($null -ne $script:ZoomPillValueText) {
            $box = Get-ZoomKeyframeBox -Keyframe $kf
            $script:ZoomPillValueText.Text = Get-ZoomBadgeText -BoxW $box.W -BoxH $box.H
        }
        # The lane's ramps are drawn from the levels, so they are stale the moment one
        # changes -- and this redraws the box and the preview with them.
        Update-TrimZoomLane
        # Debounced, which is what makes it safe on a per-tick handler.
        Request-TrimProjectSave
    }

    function Start-ZoomSliderEdit {
        $kf = Get-TrimSelectedZoom
        if ($null -eq $kf) { $script:ZoomSliderEdit = $null; return }
        $box = Get-ZoomKeyframeBox -Keyframe $kf
        $script:ZoomSliderEdit = @{ Id = [string]$kf.Id; W = [double]$box.W; H = [double]$box.H; Snapshot = New-TrimUndoSnapshot }
    }

    function Complete-ZoomSliderEdit {
        $edit = $script:ZoomSliderEdit
        $script:ZoomSliderEdit = $null
        if ($null -eq $edit) { return }
        $kf = Get-TrimZoomById -Id $edit.Id
        if ($null -eq $kf) { return }
        $box = Get-ZoomKeyframeBox -Keyframe $kf
        if ([math]::Abs([double]$box.W - [double]$edit.W) -lt 1e-9 -and
            [math]::Abs([double]$box.H - [double]$edit.H) -lt 1e-9) { return }
        Push-TrimUndoSnapshot -Snapshot $edit.Snapshot
    }

    # ---- Fade preview proxies ----
    #
    # Keyed on everything that changes what the render looks like: both sides of the cut
    # and the fade length. Changing the length, or moving the cut, therefore asks for a
    # different file rather than silently playing the old render.
    function Get-TrimFadeProxyKey {
        param([double]$OutgoingEnd, [double]$IncomingStart, [double]$FadeSeconds)
        return ("{0:N3}_{1:N3}_{2:N2}" -f $OutgoingEnd, $IncomingStart, $FadeSeconds)
    }

    # Write-throughs, same reason as Set-TrimThumbnail: called from closured timer ticks.
    # The Remove- variants exist for the watchers' FAILURE path -- a bare
    # $script:...Pending.Remove() inside a GetNewClosure'd tick reads the closure's own
    # never-initialized copy (trap #7), so the "render failed" branch crashed with
    # "cannot call a method on a null-valued expression" whenever a reload deleted the
    # scratch dir under an in-flight render. Flaky for months; root-caused 2026-08-11.
    function Remove-TrimFadeProxyPending { param([string]$Key) $script:TrimFadeProxyPending.Remove($Key) }
    function Remove-TrimThumbPending { param([string]$Key) $script:TrimThumbPending.Remove($Key) }

    function Set-TrimFadeProxy {
        param([string]$Key, [string]$FilePath)
        $script:TrimFadeProxies[$Key] = $FilePath
        $script:TrimFadeProxyPending.Remove($Key)
        # A render started while the playhead was already parked inside that fade -- the
        # common case, since turning a fade on is usually done right where you are looking.
        # Nothing else would put the overlay up until playback moved.
        Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
    }

    function Request-TrimFadeProxy {
        param([double]$OutgoingEnd, [double]$IncomingStart, [double]$FadeSeconds)
        if (-not $script:TrimInputFile -or -not $script:TrimFadeProxyDir) { return }
        $key = Get-TrimFadeProxyKey -OutgoingEnd $OutgoingEnd -IncomingStart $IncomingStart -FadeSeconds $FadeSeconds
        if ($script:TrimFadeProxies.ContainsKey($key) -or $script:TrimFadeProxyPending.ContainsKey($key)) { return }
        # One at a time. Unlike thumbnails these are real encodes, and toggling a few
        # fades in a row would otherwise start several 1440p reads at once and stall the
        # very playback they exist to improve. Whatever is skipped gets asked for again
        # on the next redraw.
        if ($script:TrimFadeProxyPending.Count -ge 1) { return }
        $script:TrimFadeProxyPending[$key] = $true

        $outFile = Join-Path $script:TrimFadeProxyDir ("fade{0}.mp4" -f ($key -replace '[^\d]', ''))
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file, $outgoing, $incoming, $fade, $outFile)
            Import-Module $modulePath -Force
            Export-TrimFadeProxy -InputFile $file -OutgoingEnd $outgoing -IncomingStart $incoming `
                -FadeSeconds $fade -OutputFile $outFile
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($script:TrimInputFile).
           AddArgument($OutgoingEnd).AddArgument($IncomingStart).AddArgument($FadeSeconds).AddArgument($outFile) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(150)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()
            if (Test-Path $outFile) { Set-TrimFadeProxy -Key $key -FilePath $outFile }
            else { Remove-TrimFadeProxyPending -Key $key }
        }.GetNewClosure())
        $watcher.Start()
    }

    # The fade the playhead is currently inside, or $null. A fade is rendered from the
    # outgoing piece's last N seconds, so that window in SOURCE space is exactly where the
    # export would be showing the blend. Named for the playhead, not "active", to keep it
    # distinct from $script:TrimActiveFade, which is the unrelated question of which fade
    # the length picker edits.
    function Get-TrimFadeAtPlayhead {
        param([double]$SourceSeconds)
        if (-not $script:TrimEditorReady) { return $null }
        $list = @($script:TrimCutList)
        for ($i = 0; $i -lt $list.Count - 1; $i++) {
            $end = [double]$list[$i].End
            $length = Get-TrimFadeLength -SourceSeconds $end
            if ($length -le 0) { continue }
            $start = $end - $length
            if ($SourceSeconds -ge $start -and $SourceSeconds -lt $end) {
                $key = Get-TrimFadeProxyKey -OutgoingEnd $end -IncomingStart ([double]$list[$i + 1].Start) -FadeSeconds $length
                return @{
                    Key    = $key
                    Path   = $script:TrimFadeProxies[$key]
                    Offset = $SourceSeconds - $start
                }
            }
        }
        return $null
    }

    # Swaps the rendered fade over the live preview while the playhead is inside a fade,
    # and takes it away again on the way out. Called from the playback tick and from
    # scrubbing, so a paused scrub into a fade shows the blended frame too.
    function Update-TrimFadeOverlay {
        param([double]$SourceSeconds)
        if ($null -eq $mediaTrimFadePreview) { return }
        $active = Get-TrimFadeAtPlayhead -SourceSeconds $SourceSeconds

        if (-not $active -or -not $active.Path) {
            # Only touch the element when something actually changes: this runs 20x a
            # second, and reassigning Source or calling Stop() every tick restarts the
            # decoder continuously.
            if ($script:TrimFadeOverlayKey) {
                $mediaTrimFadePreview.Pause()
                $mediaTrimFadePreview.Visibility = "Collapsed"
                $script:TrimFadeOverlayKey = $null
                # Captions are suppressed while a fade proxy is up; the fade has just ended,
                # so bring them back rather than waiting for the next thing that redraws.
                Update-CaptionOverlay -SourceSeconds $SourceSeconds
                Update-ZoomBoxOverlay
                Update-PipBoxOverlay
            }
            return
        }

        if ($script:TrimFadeOverlayKey -ne $active.Key) {
            $mediaTrimFadePreview.Source = New-Object System.Uri($active.Path)
            $mediaTrimFadePreview.Visibility = "Visible"
            $script:TrimFadeOverlayKey = $active.Key
        }
        $mediaTrimFadePreview.Position = [timespan]::FromSeconds($active.Offset)
        # Follows the main element rather than free-running: the two have to stay lined up,
        # and the proxy is short enough that re-seeking it every tick is cheap.
        if ($buttonTrimPlay.Content -eq "Pause") { $mediaTrimFadePreview.Play() }
        else { $mediaTrimFadePreview.Pause() }
    }

    function Update-TrimSelectionText {
        if (-not $script:TrimEditorReady) { return }
        # Deleting the main video lane is how this build lets an audio-only export happen,
        # which nothing else about the selection text would otherwise reveal -- so it is
        # appended regardless of which branch below sets the base text.
        $hasVideo = $false
        $clipTotal = 0
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                $clipTotal++
                if (($c.Kind -eq "video" -or $c.Kind -eq "image") -and $c.Enabled) { $hasVideo = $true }
            }
        }
        $audioOnlySuffix = if (-not $hasVideo -and $clipTotal -gt 0) { " -- audio-only export" } else { "" }
        $state = Get-TrimTimelineState
        if ($script:TrimSelected -lt 0 -or $script:TrimSelected -ge $state.Pieces.Count) {
            $textTrimSelection.Text = "nothing selected" + $audioOnlySuffix
            return
        }
        # Timeline-space bounds, matching the ruler and the drawn timeline (which are also
        # timeline-space now) -- not the piece's real position in the source file.
        $tp = $state.TimelinePieces[$script:TrimSelected]
        $textTrimSelection.Text = ("selected {0} to {1} ({2:N2}s)" -f (Format-TrimTime $tp.TimelineStart), (Format-TrimTime $tp.TimelineEnd), ($tp.TimelineEnd - $tp.TimelineStart)) + $audioOnlySuffix
    }

    # Snapshot before every change. Cloning matters: the pieces are objects and a shallow
    # copy of the array would let undo hand back a list whose contents were mutated. The
    # captions need the same treatment for a stronger reason -- a lane drag and the Task 10
    # sidebar both edit caption objects IN PLACE, so an uncloned snapshot would hand undo
    # the very objects the edit is about to change.
    function New-TrimUndoSnapshot {
        return @{
            List            = @(@($script:TrimCutList) | ForEach-Object { [PSCustomObject]@{ Start = $_.Start; End = $_.End } })
            Selected        = $script:TrimSelected
            Captions        = @(foreach ($c in $script:TrimCaptions) { Copy-TrimCaption -Caption $c })
            SelectedCaption = $script:TrimSelectedCaption
            # Cloned for exactly the reason the captions are: a diamond drag and the Task 7
            # spotlight both edit keyframe objects IN PLACE, so an uncloned snapshot would
            # hand undo the very objects the edit is about to change.
            Zooms           = @(foreach ($z in $script:TrimZooms) { Copy-TrimZoom -Zoom $z })
            SelectedZoom    = $script:TrimSelectedZoom
            # Cloned for the same reason as the zooms: a clip drag, the fader and the PiP box
            # all edit clip objects IN PLACE, so an uncloned snapshot would hand undo the
            # very objects the edit is about to change. Copy-TrimLaneObj is deep (lane AND
            # its clips), so nothing in the snapshot shares a reference with the live model.
            Lanes           = @(foreach ($l in $script:TrimLanes) { Copy-TrimLaneObj -Lane $l })
            SelectedClip    = $script:TrimSelectedClip
            SelectedLane    = $script:TrimSelectedLane
        }
    }

    # Split out from Push-TrimUndo so a drag can take its snapshot when it BEGINS and push
    # that same snapshot on release -- one undo step per completed drag rather than one per
    # mouse move.
    function Push-TrimUndoSnapshot {
        param($Snapshot)
        [void]$script:TrimUndoStack.Add($Snapshot)
        # A new edit forks history: whatever was undone can no longer be redone.
        # Undo/redo themselves bypass this function for exactly that reason.
        if ($null -ne $script:TrimRedoStack) { $script:TrimRedoStack.Clear() }
        $buttonTrimUndo.IsEnabled = $true
        Update-TrimRedoButton
    }

    function Update-TrimRedoButton {
        if ($null -ne $buttonTrimRedo) {
            $buttonTrimRedo.IsEnabled = ($null -ne $script:TrimRedoStack -and $script:TrimRedoStack.Count -gt 0)
        }
    }

    function Push-TrimUndo {
        Push-TrimUndoSnapshot -Snapshot (New-TrimUndoSnapshot)
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
        Request-TrimProjectSave
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
        Request-TrimProjectSave
    }

    # Shared by undo and redo: puts a snapshot's state back and refreshes every view.
    # The callers own the stack bookkeeping (what gets popped, what the current state
    # gets pushed onto) -- this only restores.
    function Restore-TrimSnapshot {
        param($last)
        $script:TrimCutList = @($last.List)
        $script:TrimSelected = $last.Selected
        # Entries pushed before captions existed have no Captions key; treating a missing
        # one as "no captions" would wipe the lane, so only restore what was recorded.
        if ($last.ContainsKey("Captions")) {
            Set-TrimCaptions -Captions $last.Captions
            Set-TrimSelectedCaption -Id $last.SelectedCaption
        }
        # Same "only restore what was recorded" rule for zooms: entries pushed before zoom
        # keyframes existed carry no Zooms key, and treating that as "no zooms" would wipe
        # the lane.
        if ($last.ContainsKey("Zooms")) {
            Set-TrimZooms -Zooms $last.Zooms
            # NOT Set-TrimSelectedZoom: that one clears the caption selection, which the
            # line above has just restored. A snapshot already records a consistent pair, so
            # the restore writes both straight through.
            $script:TrimSelectedZoom = $last.SelectedZoom
        }
        # Same "only restore what was recorded" rule for lanes: entries pushed before the
        # lane stack existed carry no Lanes key, and treating that as "no lanes" would
        # wipe the stack down to nothing.
        if ($last.ContainsKey("Lanes")) {
            Set-TrimLanes -Lanes $last.Lanes
            # NOT Set-TrimSelectedClip/Lane: those clear the caption/zoom selections, which
            # the lines above have just restored. A snapshot already records a consistent
            # set, so the restore writes all of them straight through.
            $script:TrimSelectedClip = $last.SelectedClip
            $script:TrimSelectedLane = $last.SelectedLane
            Update-TrimLaneRows
        }
        $buttonTrimDelete.IsEnabled = ($script:TrimSelected -ge 0)
        $buttonTrimUndo.IsEnabled = ($script:TrimUndoStack.Count -gt 0)
        Update-TrimSelectionText
        Update-TrimTimeline
        # The sidebar edits whatever is selected, so an undo that changed the selection --
        # including one that undid an add and left nothing selected -- has to move it.
        if ($null -eq (Get-TrimSelectedCaption)) { Hide-CaptionSidebar } else { Show-CaptionSidebar }
        # The glide is part of what an undo puts back, so the picture has to follow it.
        Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
        # Undo changes the model as much as any edit does, so the saved project has to
        # follow it back -- otherwise closing the app restores the state that was undone.
        Request-TrimProjectSave
    }

    function Invoke-TrimUndo {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        if ($script:TrimUndoStack.Count -eq 0) { return }
        $last = $script:TrimUndoStack[$script:TrimUndoStack.Count - 1]
        $script:TrimUndoStack.RemoveAt($script:TrimUndoStack.Count - 1)
        # The state being left becomes the redo target. Added directly, not through
        # Push-TrimUndoSnapshot: that one clears the redo stack (any NEW edit makes
        # the redone future unreachable), which is exactly wrong mid undo/redo.
        [void]$script:TrimRedoStack.Add((New-TrimUndoSnapshot))
        Restore-TrimSnapshot -last $last
        Update-TrimRedoButton
    }

    function Invoke-TrimRedo {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        if ($null -eq $script:TrimRedoStack -or $script:TrimRedoStack.Count -eq 0) { return }
        $next = $script:TrimRedoStack[$script:TrimRedoStack.Count - 1]
        $script:TrimRedoStack.RemoveAt($script:TrimRedoStack.Count - 1)
        [void]$script:TrimUndoStack.Add((New-TrimUndoSnapshot))
        Restore-TrimSnapshot -last $next
        Update-TrimRedoButton
    }

    # ---- Caption properties sidebar ----
    #
    # The column edits whatever caption is selected. Every field writes straight through to
    # the caption object and refreshes the lane and the preview overlay, so the three views
    # of a caption never disagree.

    # Not Format-TrimTime: that one is built on $ts.Minutes and truncates to whole seconds
    # (a pre-existing int-overload bug, deliberately not touched here), which would make the
    # time boxes lose the milliseconds of every caption they round-trip. TotalMinutes also
    # keeps working past the hour mark, where $ts.Minutes silently wraps.
    function Format-CaptionTime {
        param([double]$Seconds)
        $ts = [timespan]::FromSeconds([math]::Max(0.0, $Seconds))
        return ("{0:D2}:{1:D2}.{2:D3}" -f [int][math]::Floor($ts.TotalMinutes), $ts.Seconds, $ts.Milliseconds)
    }

    # MM:SS.mmm -> seconds, or $null if the text is not exactly that. Returning $null rather
    # than a best guess is the point: the caller reverts the box from the model instead of
    # applying something the user did not type.
    function ConvertFrom-CaptionTime {
        param([string]$Text)
        if ($Text -notmatch '^(\d+):([0-5]\d)\.(\d{3})$') { return $null }
        return ([double]$matches[1] * 60) + [double]$matches[2] + ([double]$matches[3] / 1000)
    }

    function Test-CaptionSidebarLoading {
        return $script:CaptionSidebarLoading
    }

    function Set-CaptionSidebarLoading {
        param([bool]$Value)
        $script:CaptionSidebarLoading = $Value
    }

    # Single write path for every sidebar field. Refreshing the lane also refreshes the
    # preview overlay (Update-TrimCaptionLane calls it first thing), so one call keeps both
    # views in step without drawing the overlay twice per keystroke.
    function Update-CaptionField {
        param([string]$Id, [string]$Field, $Value)
        $cap = Get-TrimCaptionById -Id $Id
        if ($null -eq $cap) { return }
        $cap.$Field = $Value
        Update-TrimCaptionLane
        # Every sidebar field writes through here, so this one call covers text, font,
        # bold, colours, outline width and bounce. Debounced, which is what makes it safe
        # to hang off a per-keystroke handler.
        Request-TrimProjectSave
    }

    function Show-CaptionSidebar {
        $cap = Get-TrimSelectedCaption
        # Selection change, not a blur: lane blocks are non-Focusable Borders, so clicking
        # another caption's block repopulates the text box while the caret stays in it and no
        # LostFocus ever fires. Settle the in-flight edit against the caption it was opened
        # for before the box is refilled, or its undo step is lost outright.
        Complete-CaptionTextEditOnSelectionChange -Id $(if ($null -eq $cap) { "" } else { [string]$cap.Id })
        if ($null -eq $panelCaptionSidebar) { return }
        # Asked to show the properties of nothing: collapse rather than leave the previous
        # caption's values on screen attached to no caption at all.
        if ($null -eq $cap) { Hide-CaptionSidebar; return }
        Set-CaptionSidebarLoading -Value $true
        try {
            if ($null -ne $textCaptionText) { $textCaptionText.Text = [string]$cap.Text }
            if ($null -ne $comboCaptionFont) { $comboCaptionFont.SelectedItem = [string]$cap.FontFamily }
            if ($null -ne $checkCaptionBold) { $checkCaptionBold.IsChecked = [bool]$cap.Bold }
            if ($null -ne $textCaptionFill) { $textCaptionFill.Text = [string]$cap.FillColor }
            if ($null -ne $textCaptionOutline) { $textCaptionOutline.Text = [string]$cap.OutlineColor }
            if ($null -ne $sliderCaptionOutlineW) { $sliderCaptionOutlineW.Value = [double]$cap.OutlineWidth }
            if ($null -ne $checkCaptionBounce) { $checkCaptionBounce.IsChecked = [bool]$cap.BounceIn }
            if ($null -ne $textCaptionStart) { $textCaptionStart.Text = Format-CaptionTime ([double]$cap.Start) }
            if ($null -ne $textCaptionEnd) { $textCaptionEnd.Text = Format-CaptionTime ([double]$cap.End) }
        } finally {
            # finally, not a trailing assignment: a throw anywhere in the fill would
            # otherwise leave the flag set and silently deaden every handler for the rest
            # of the session.
            Set-CaptionSidebarLoading -Value $false
        }
        $panelCaptionSidebar.Visibility = "Visible"
        # The caret never left the box, so no GotFocus will fire to open the next bracket.
        # Re-arm it here against the caption now on screen; typing straight after clicking a
        # different lane block otherwise gets no undo checkpoint at all.
        if ($null -ne $textCaptionText -and $textCaptionText.IsKeyboardFocusWithin) { Start-CaptionTextEdit }
    }

    function Hide-CaptionSidebar {
        # Hiding is a selection change too (delete, deselect, file load): settle any in-flight
        # text edit before the box goes away, since its LostFocus is not guaranteed either.
        Complete-CaptionTextEdit
        Set-CaptionSidebarLoading -Value $false
        if ($null -eq $panelCaptionSidebar) { return }
        $panelCaptionSidebar.Visibility = "Collapsed"
    }

    # Deselect. Without it nothing but delete, undo or a file load ever drops the selection,
    # so the cyan box and its handle sit over the picture through playback for the rest of the
    # session. Deliberately NOT bound to Escape: this app has no panel-level keyboard
    # shortcuts, and Escape is already the dismiss key for its dialogs.
    function Clear-TrimCaptionSelection {
        if ($null -eq $script:TrimSelectedCaption) { return }
        Set-TrimSelectedCaption -Id $null
        Hide-CaptionSidebar
        Update-TrimCaptionLane
        Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
        Update-ZoomBoxOverlay
        Update-PipBoxOverlay
    }

    # Re-fills one box from the model without the write-back a plain assignment would
    # trigger. Used by every reject path: bad input leaves the model alone and the box shows
    # what the caption actually holds.
    function Reset-CaptionSidebarField {
        param($Box, [string]$Text)
        if ($null -eq $Box) { return }
        Set-CaptionSidebarLoading -Value $true
        try { $Box.Text = $Text } finally { Set-CaptionSidebarLoading -Value $false }
    }

    # A text edit is one undo step per focus session, not per keystroke: the snapshot is
    # taken on GotFocus and pushed on LostFocus only if the text ended up different.
    function Start-CaptionTextEdit {
        $cap = Get-TrimSelectedCaption
        if ($null -eq $cap) { $script:CaptionTextEdit = $null; return }
        $script:CaptionTextEdit = @{ Id = $cap.Id; Text = [string]$cap.Text; Snapshot = New-TrimUndoSnapshot }
    }

    function Complete-CaptionTextEdit {
        $edit = $script:CaptionTextEdit
        $script:CaptionTextEdit = $null
        if ($null -eq $edit) { return }
        $cap = Get-TrimCaptionById -Id $edit.Id
        if ($null -eq $cap) { return }
        if ([string]$cap.Text -eq $edit.Text) { return }
        Push-TrimUndoSnapshot -Snapshot $edit.Snapshot
        # Update-CaptionField already asked for a save per keystroke; this one covers the
        # case where the debounce timer is still pending as the box loses focus, and costs
        # nothing when it is not.
        Request-TrimProjectSave
    }

    # Same completion, but only when the selection actually moved to a different caption:
    # re-showing the sidebar for the caption already being typed into must leave the open
    # bracket alone, or every redraw would chop the edit into a separate undo step.
    function Complete-CaptionTextEditOnSelectionChange {
        param([string]$Id)
        $edit = $script:CaptionTextEdit
        if ($null -eq $edit) { return }
        if ([string]$edit.Id -eq [string]$Id) { return }
        Complete-CaptionTextEdit
    }

    # The slider raises ValueChanged on every tick of a drag; the snapshot is taken when it
    # grabs the mouse and pushed when it lets go, so a drag across the range is one step.
    function Start-CaptionSliderEdit {
        $cap = Get-TrimSelectedCaption
        if ($null -eq $cap) { $script:CaptionSliderEdit = $null; return }
        $script:CaptionSliderEdit = @{ Id = $cap.Id; Value = [double]$cap.OutlineWidth; Snapshot = New-TrimUndoSnapshot }
    }

    function Complete-CaptionSliderEdit {
        $edit = $script:CaptionSliderEdit
        $script:CaptionSliderEdit = $null
        if ($null -eq $edit) { return }
        $cap = Get-TrimCaptionById -Id $edit.Id
        if ($null -eq $cap) { return }
        if ([math]::Abs([double]$cap.OutlineWidth - $edit.Value) -lt 1e-9) { return }
        Push-TrimUndoSnapshot -Snapshot $edit.Snapshot
    }

    # #RRGGBB only, stored uppercase (ConvertTo-AssColor uppercases on export anyway, and a
    # consistent case makes the "did it change" test a plain string compare). Anything else
    # is rejected outright and the box goes back to the model's value.
    function Set-CaptionColorFromBox {
        param($Box, [string]$Field)
        if ($null -eq $Box) { return }
        $cap = Get-TrimSelectedCaption
        if ($null -eq $cap) { return }
        $current = [string]$cap.$Field
        $typed = ([string]$Box.Text).Trim()
        if ($typed -notmatch '^#[0-9A-Fa-f]{6}$') { Reset-CaptionSidebarField -Box $Box -Text $current; return }
        $value = $typed.ToUpper()
        if ($value -eq $current) { Reset-CaptionSidebarField -Box $Box -Text $current; return }
        Push-TrimUndo
        Update-CaptionField -Id $cap.Id -Field $Field -Value $value
        Reset-CaptionSidebarField -Box $Box -Text $value
    }

    # The palette route into the same write path as a valid hex entry: apply uppercased,
    # sync the box so the two views never disagree, one undo step per click. A top-level
    # function because the swatch click handlers are .GetNewClosure()'d (they each capture
    # their own colour) and a bare $script: write from inside one lands in the closure's
    # own module.
    function Set-CaptionColorFromSwatch {
        param([string]$Color, [string]$Field)
        # The palette is populated once at startup, but Show-CaptionSidebar's fill can
        # still be running if a click lands mid-refresh; same guard every other field uses.
        if (Test-CaptionSidebarLoading) { return }
        $cap = Get-TrimSelectedCaption
        if ($null -eq $cap) { return }
        $box = if ($Field -eq "FillColor") { $textCaptionFill } else { $textCaptionOutline }
        $value = ([string]$Color).ToUpper()
        $current = [string]$cap.$Field
        if ($value -eq $current) { return }
        Push-TrimUndo
        Update-CaptionField -Id $cap.Id -Field $Field -Value $value
        Reset-CaptionSidebarField -Box $box -Text $value
        Request-TrimProjectSave
    }

    # Spec palette: twelve common caption colours, with the hex box left in place for
    # anything else.
    $script:CaptionPalette = @(
        "#FFFFFF", "#000000", "#FFD65A", "#FF4D4D", "#4DFF6E", "#4DA6FF",
        "#FF8A00", "#FF4DDB", "#00E5FF", "#A64DFF", "#1A1A1A", "#E0C48F"
    )

    function Add-CaptionSwatches {
        param($Panel, [string]$Field)
        if ($null -eq $Panel) { return }
        $Panel.Children.Clear()
        foreach ($color in $script:CaptionPalette) {
            $btn = New-Object System.Windows.Controls.Button
            # The keyed style carries the 16x16 / 2px margin / thin #33FFFFFF border and,
            # crucially, a template that actually paints the button's own Background --
            # the stock WPF chrome ignores it and every swatch would come out grey.
            $swatchStyle = $ctx.Window.TryFindResource("CaptionSwatchButtonStyle")
            if ($null -ne $swatchStyle) { $btn.Style = $swatchStyle }
            $btn.Width = 16
            $btn.Height = 16
            $btn.Margin = New-Object System.Windows.Thickness(2)
            $btn.Background = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString($color))
            $btn.ToolTip = $color
            $btn.Cursor = "Hand"
            # GetNewClosure is required, exactly as on the lane blocks: without it every
            # swatch would capture the loop variable's final value and all twelve would
            # paint the last colour in the list.
            $thisColor = $color
            $thisField = $Field
            $btn.Add_Click({ Set-CaptionColorFromSwatch -Color $thisColor -Field $thisField }.GetNewClosure())
            [void]$Panel.Children.Add($btn)
        }
    }

    # One box retimes one end; the other end comes from the model. Validated BEFORE any undo
    # is pushed, because Set-TrimCaptionTimes rejects a pair under the minimum length and a
    # pre-emptive push would leave an undo step for a change that never happened.
    function Set-CaptionTimeFromBox {
        param($Box, [string]$Edge)
        if ($null -eq $Box) { return }
        $cap = Get-TrimSelectedCaption
        if ($null -eq $cap) { return }
        $start = [double]$cap.Start
        $end = [double]$cap.End
        $parsed = ConvertFrom-CaptionTime -Text ([string]$Box.Text).Trim()
        $ok = $null -ne $parsed
        if ($ok) {
            if ($Edge -eq "start") { $start = $parsed } else { $end = $parsed }
            $ok = ($start -ge 0) -and ($end -le $script:TrimDuration) -and
                  (($end - $start) -ge ($script:TrimCaptionMinLength - 1e-6))
        }
        if (-not $ok) {
            $revert = if ($Edge -eq "start") { [double]$cap.Start } else { [double]$cap.End }
            Reset-CaptionSidebarField -Box $Box -Text (Format-CaptionTime $revert)
            return
        }
        if ([math]::Abs($start - [double]$cap.Start) -lt 1e-9 -and
            [math]::Abs($end - [double]$cap.End) -lt 1e-9) { return }
        Push-TrimUndo
        Set-TrimCaptionTimes -Id $cap.Id -Start $start -End $end
        Update-TrimCaptionLane
        # Straight back from the model: Set-TrimCaptionTimes clamps, so what landed is not
        # necessarily what was typed and the box must not claim otherwise.
        $applied = if ($Edge -eq "start") { [double]$cap.Start } else { [double]$cap.End }
        Reset-CaptionSidebarField -Box $Box -Text (Format-CaptionTime $applied)
        # Retiming from the boxes goes through Set-TrimCaptionTimes, not Update-CaptionField,
        # so it needs its own save hook.
        Request-TrimProjectSave
    }

    function Invoke-TrimAddCaption {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        Push-TrimUndo
        # Pulled back off the very end of the clip, so a caption added with the playhead
        # parked at the end is still a caption and not a zero-length sliver.
        $start = [math]::Max(0.0, [math]::Min($script:TrimPlayhead, $script:TrimDuration - $script:TrimCaptionMinLength))
        # Two seconds is a readable default; a playhead parked near the end of the clip
        # gets whatever is left rather than a caption running off the end.
        $cap = New-Caption -Start $start -End ([math]::Min($script:TrimDuration, $start + 2.0)) -Text ""
        [void]$script:TrimCaptions.Add($cap)
        Set-TrimSelectedCaption -Id $cap.Id
        Clear-TrimZoomSelection
        Update-TrimTimeline
        Show-CaptionSidebar
        # A new caption is empty, so the only useful next action is typing into it --
        # the spec asks for the text box to take focus rather than making the user click it.
        # Posted at Input priority rather than called inline: Show-CaptionSidebar has only
        # just flipped the column to Visible, and Focus() on an element whose container has
        # not been laid out yet silently does nothing.
        if ($null -ne $textCaptionText) {
            $textCaptionText.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Input,
                # GetNewClosure: the block runs after this call has returned, so a plain
                # scriptblock would resolve $textCaptionText against a call stack that is
                # gone. Read-only capture, so no $script: write lands in the wrong module.
                [action]({ $textCaptionText.Focus() | Out-Null }.GetNewClosure())) | Out-Null
        }
        Request-TrimProjectSave
    }

    function Invoke-TrimDeleteCaption {
        $cap = Get-TrimSelectedCaption
        if ($null -eq $cap) { return }
        Push-TrimUndo
        $script:TrimCaptions.Remove($cap)
        Set-TrimSelectedCaption -Id $null
        Update-TrimTimeline
        Hide-CaptionSidebar
        Request-TrimProjectSave
    }

    function Update-TrimPosition {
        # Timeline-space, matching the ruler and the drawn track: how far into the
        # assembled EXPORT the playhead is, not how far into the raw source file.
        # Denominator is the WHOLE timeline (spec 4.7), not just the cut list: with a clip
        # running past V1's end the export is longer than V1 is, and a readout that stopped
        # counting at V1's end would freeze at "1:00 / 1:00" for the whole montage.
        $tl = Get-TrimTimelinePlayhead
        $textTrimPosition.Text = "$(Format-TrimTime $tl) / $(Format-TrimTime (Get-TrimTimelineLengthCached))"
        # The lane stack's own playhead. Drawn here beside the readout rather than from a
        # row rebuild: the playhead moves on every timer tick while playing, and rebuilding
        # every row at 30fps is not a thing to do.
        Update-TrimLaneOverlay
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

    # Filmstrip thumbnails for the timeline pieces. Keyed by source-file second (rounded,
    # since a piece's thumbnail times are fixed once drawn and only change on split/delete,
    # not on zoom/pan) so the same frame is never extracted twice. $script:TrimThumbPending
    # tracks in-flight requests so a redraw mid-extraction doesn't queue duplicates.
    function Set-TrimThumbnail {
        param([string]$Key, [string]$FilePath)
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.UriSource = New-Object System.Uri($FilePath)
        $img.EndInit()
        $img.Freeze()
        $script:TrimThumbCache[$Key] = $img
        $script:TrimThumbPending.Remove($Key)
        Update-TrimTimeline
    }

    # One background job per missing frame, same shape as Start-TrimKeyframeRead below.
    # Extraction is cheap (a keyframe-index seek, not a decode of everything before it),
    # and a trim session only ever needs a few dozen thumbnails at once, so there is
    # nothing to gain from a shared worker queue here.
    function Request-TrimThumbnail {
        param([string]$File, [double]$Seconds)
        $key = "{0:N2}" -f $Seconds
        if ($script:TrimThumbCache.ContainsKey($key) -or $script:TrimThumbPending.ContainsKey($key)) { return }
        # Ceiling on concurrent extractions. Now that thumbnail times follow the viewport,
        # spinning the wheel through a dozen zoom levels asks for a fresh set at each one,
        # and every request is its own runspace plus ffmpeg process. The dropped requests
        # are not lost: the next redraw re-asks for whatever is still missing, and by then
        # the view has settled, so what actually gets extracted is the level the user
        # stopped on rather than every level they passed through.
        if ($script:TrimThumbPending.Count -ge 12) { return }
        $script:TrimThumbPending[$key] = $true

        $outFile = Join-Path $script:TrimThumbDir ("t{0}.jpg" -f ($key -replace '[^\d]', ''))
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file, $seconds, $outFile)
            Import-Module $modulePath -Force
            Export-TrimThumbnail -InputFile $file -Seconds $seconds -OutputFile $outFile
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($File).AddArgument($Seconds).AddArgument($outFile) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(120)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()
            if (Test-Path $outFile) {
                Set-TrimThumbnail -Key $key -FilePath $outFile
            } else {
                Remove-TrimThumbPending -Key $key
            }
        }.GetNewClosure())
        $watcher.Start()
    }

    # ---- Row media: filmstrip frames and per row waveforms -----------------------
    # Audio rows carry their own waveforms now and video clips carry filmstrips, so a
    # freshly loaded stack asks for a dozen renders on its first paint. Both kinds go
    # through ONE queue driven by ONE pump timer that keeps exactly one ffmpeg job in
    # flight (the "skip if a job is running" guard) -- same DispatcherTimer shape as
    # Request-TrimThumbnail's watcher, but shared, because a runspace-per-request here
    # would put ten ffmpeg processes on the box at once.
    function Get-TrimMediaHash {
        param([string]$Text)
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try {
            $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
        } finally { $md5.Dispose() }
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    }

    # A file's identity for cache-key purposes: size + last write time. A re-encode that
    # keeps the same name still gets a fresh key.
    function Get-TrimMediaStamp {
        param([string]$Path)
        try {
            $fi = New-Object System.IO.FileInfo([string]$Path)
            if (-not $fi.Exists) { return "0|0" }
            return ("{0}|{1}" -f $fi.Length, $fi.LastWriteTimeUtc.Ticks)
        } catch { return "0|0" }
    }

    # One directory per (file, in-point, out-point): the trimmed range IS part of the
    # key, so a completed edge-trim asks for a different eight frames and an undo lands
    # straight back on the cached set.
    function Get-TrimStripCacheDir {
        param([string]$Path, [double]$InStart, [double]$EffInEnd, [int]$Frames = 8)
        # Frames is part of the key: a cut-space piece asks for fewer than eight frames,
        # and a 3-frame set sharing a directory with an 8-frame set would read as a
        # half-rendered strip forever.
        $key = "{0}|{1}|{2:N1}|{3:N1}|f{4}" -f $Path, (Get-TrimMediaStamp -Path $Path), $InStart, $EffInEnd, $Frames
        return (Join-Path $env:LOCALAPPDATA ("FFmpegGUI\stripcache\" + (Get-TrimMediaHash -Text $key)))
    }

    function Add-TrimRowMediaJob {
        param([hashtable]$Job)
        $key = [string]$Job.Key
        if ($script:TrimRowMediaClaimed.ContainsKey($key)) { return }
        $script:TrimRowMediaClaimed[$key] = $true
        [void]$script:TrimStripPending.Add($Job)
        Start-TrimRowMediaPump
    }

    function Start-TrimRowMediaPump {
        if ($null -eq $script:TrimRowMediaTimer) {
            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [timespan]::FromMilliseconds(120)
            # No GetNewClosure: the tick body is a real top-level function, so its
            # $script: reads and writes hit the real script scope.
            $timer.Add_Tick({ Invoke-TrimRowMediaTick })
            $script:TrimRowMediaTimer = $timer
        }
        if (-not $script:TrimRowMediaTimer.IsEnabled) { $script:TrimRowMediaTimer.Start() }
    }

    function Invoke-TrimRowMediaTick {
        $job = $script:TrimRowMediaJob
        if ($null -ne $job) {
            # Skip-if-running guard, exactly as the thumbnail watcher's first line.
            if (-not $job.Handle.IsCompleted) { return }
            try { $job.PS.EndInvoke($job.Handle) | Out-Null } catch { }
            $job.PS.Dispose()
            $script:TrimRowMediaJob = $null
            if (Test-Path -LiteralPath ([string]$job.OutFile)) {
                if ([string]$job.Kind -eq "wave") { Set-TrimRowWaveform -Key ([string]$job.Key) -FilePath ([string]$job.OutFile) }
                $script:TrimRowMediaDirty = $true
            }
            # A render that produced nothing (unreadable file, no such stream) keeps its
            # claimed key, so the next redraw does not re-queue the same doomed job.
        }
        if (@($script:TrimStripPending).Count -eq 0) {
            $script:TrimRowMediaTimer.Stop()
            if ($script:TrimRowMediaDirty -and -not (Test-TrimClipDrag) -and -not (Test-TrimLaneGainDrag)) {
                $script:TrimRowMediaDirty = $false
                Update-TrimLaneRows
            }
            return
        }
        $next = $script:TrimStripPending[0]
        $script:TrimStripPending.RemoveAt(0)
        $script:TrimRowMediaJob = Start-TrimRowMediaJob -Job $next
    }

    function Start-TrimRowMediaJob {
        param([hashtable]$Job)
        $modulePath = Join-Path $scriptRoot "backend\VideoTrimmer.psm1"
        $ps = [powershell]::Create()
        if ([string]$Job.Kind -eq "wave") {
            $ps.AddScript({
                param($modulePath, $file, $streamIndex, $start, $duration, $width, $height, $outFile)
                Import-Module $modulePath -Force
                Export-TrimWaveform -InputFile $file -StreamIndex $streamIndex -StartSeconds $start `
                    -DurationSeconds $duration -Width $width -Height $height -OutputFile $outFile
            }).AddArgument($modulePath).AddArgument([string]$Job.Path).AddArgument([int]$Job.StreamIndex).
              AddArgument([double]$Job.Start).AddArgument([double]$Job.Duration).AddArgument([int]$Job.Width).
              AddArgument([int]$Job.Height).AddArgument([string]$Job.OutFile) | Out-Null
        } else {
            $ps.AddScript({
                param($modulePath, $file, $seconds, $outFile)
                Import-Module $modulePath -Force
                Export-TrimThumbnail -InputFile $file -Seconds $seconds -OutputFile $outFile -Height 80
            }).AddArgument($modulePath).AddArgument([string]$Job.Path).AddArgument([double]$Job.Seconds).
              AddArgument([string]$Job.OutFile) | Out-Null
        }
        return @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = [string]$Job.Kind; Key = [string]$Job.Key; OutFile = [string]$Job.OutFile }
    }

    # Write-through for the pump tick (which runs inside a DispatcherTimer handler).
    # Deliberately does NOT redraw: the tick decides when a redraw is due, so a render
    # landing mid-draw can never re-enter Update-TrimLaneRows.
    function Set-TrimRowWaveform {
        param([string]$Key, [string]$FilePath)
        try {
            $img = New-Object System.Windows.Media.Imaging.BitmapImage
            $img.BeginInit()
            $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $img.UriSource = New-Object System.Uri($FilePath)
            $img.EndInit()
            $img.Freeze()
            $script:TrimWaveCache[$Key] = $img
        } catch { }
    }

    # Decoded once per file path: a row rebuild happens on every selection change, and
    # re-decoding eight JPEGs per clip each time is what would make that feel slow.
    function Get-TrimStripImage {
        param([string]$FilePath)
        if ($script:TrimStripImages.ContainsKey($FilePath)) { return $script:TrimStripImages[$FilePath] }
        try {
            $img = New-Object System.Windows.Media.Imaging.BitmapImage
            $img.BeginInit()
            $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $img.UriSource = New-Object System.Uri($FilePath)
            $img.EndInit()
            $img.Freeze()
            $script:TrimStripImages[$FilePath] = $img
            return $img
        } catch { return $null }
    }

    # Eight frames across the clip's VISIBLE range, at the middle of each eighth so the
    # first and last cells are frames of the clip rather than its boundaries. Returns the
    # eight bitmaps once they all exist, $null (having queued the missing ones) until then.
    function Request-TrimClipStrip {
        param([string]$Path, [double]$InStart, [double]$EffInEnd, [int]$Frames = 8)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        $n = [math]::Max(1, [math]::Min(8, $Frames))
        $dir = Get-TrimStripCacheDir -Path $Path -InStart $InStart -EffInEnd $EffInEnd -Frames $n
        $files = @()
        $missing = @()
        for ($k = 0; $k -lt $n; $k++) {
            $f = Join-Path $dir ("strip{0}.jpg" -f $k)
            $files += ,$f
            if (-not (Test-Path -LiteralPath $f)) { $missing += ,$k }
        }
        if (@($missing).Count -eq 0) {
            $images = @()
            foreach ($f in $files) {
                $img = Get-TrimStripImage -FilePath $f
                if ($null -eq $img) { return $null }
                $images += ,$img
            }
            return ,@($images)
        }
        # 0.05 rather than 0: a degenerate span would ask ffmpeg for n copies of the
        # same frame, which is harmless but pointless -- this keeps the times distinct.
        $effLen = [math]::Max(0.05, $EffInEnd - $InStart)
        try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { return $null }
        foreach ($k in $missing) {
            $t = $InStart + (([double]$k + 0.5) / [double]$n) * $effLen
            Add-TrimRowMediaJob -Job @{
                Kind = "strip"; Key = ("strip|{0}|{1}" -f $dir, $k); OutFile = $files[$k]
                Path = $Path; Seconds = $t
            }
        }
        return $null
    }

    # One waveform per audio ROW, keyed by file + absolute stream + file stamp + pixel
    # size + the clip's own in/out. The in/out belong in the key: the render is of
    # exactly that window, so a trimmed clip that reused the untrimmed key would show a
    # waveform of the wrong audio.
    function Request-TrimRowWaveform {
        param([string]$Path, [int]$StreamIndex, [double]$InStart, [double]$Length, [int]$Width, [int]$Height)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if ($Length -le 0.01) { return $null }
        $key = "{0}|{1}|{2}|{3}x{4}|{5:N1}|{6:N1}" -f $Path, $StreamIndex, (Get-TrimMediaStamp -Path $Path), $Width, $Height, $InStart, $Length
        if ($script:TrimWaveCache.ContainsKey($key)) { return $script:TrimWaveCache[$key] }
        $outFile = Join-Path (Get-TrimWaveDir) ("row_{0}.png" -f (Get-TrimMediaHash -Text $key))
        # Hydrate from the disk cache before deciding this row is missing: any earlier
        # open of this file already paid the ffmpeg render.
        if (Test-Path -LiteralPath $outFile) {
            Set-TrimRowWaveform -Key $key -FilePath $outFile
            if ($script:TrimWaveCache.ContainsKey($key)) { return $script:TrimWaveCache[$key] }
        }
        Add-TrimRowMediaJob -Job @{
            Kind = "wave"; Key = $key; OutFile = $outFile; Path = $Path; StreamIndex = $StreamIndex
            Start = $InStart; Duration = $Length; Width = $Width; Height = $Height
        }
        return $null
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
        # Sizes the zoom host and the caption overlay to the largest exact-16:9 box
        # that fits BOTH the card width and the window height. Width-only sizing (the
        # old behavior) made a preview so tall on wide windows that the timeline fell
        # below the fold and needed scrolling. The 660 is the vertical budget
        # everything except the preview needs: transport + track + lanes + ruler +
        # fades + status + buttons + card padding + window chrome.
        #
        # The host and the overlay are sized INDIVIDUALLY and the cell gets a Clip
        # geometry over the box -- there is deliberately no sized wrapper grid doing
        # this job. One was tried (2026-08-11) and the zoom's RenderTransform, while
        # verifiably attached and even reported by TransformToAncestor, simply never
        # reached the screen with the wrapper in the tree; the same transform on the
        # same host renders fine without it.
        $script:UpdatePreviewFrameSize = {
            if ($null -eq $previewCell) { return }
            $cellW = [double]$previewCell.ActualWidth
            if ($cellW -le 0) { return }
            # A PROPORTION of the window, not "window minus a fixed budget": with the old
            # `height - 660` a taller screen gave every extra pixel to the preview and the
            # timeline stayed cramped against the bottom edge. 38% keeps the preview
            # comfortably readable while the track area -- where the actual editing
            # happens -- gets the larger share of a maximized window.
            $availH = [double]$ctx.Window.ActualHeight * 0.38
            if ($availH -lt 320.0) { $availH = 320.0 }
            $w = [math]::Min($cellW, $availH * 16.0 / 9.0)
            $h = $w * 9.0 / 16.0
            foreach ($el in @($previewZoomHost, $canvasCaptionOverlay)) {
                if ($null -eq $el) { continue }
                $el.HorizontalAlignment = "Center"
                $el.VerticalAlignment = "Center"
                $el.Width = $w
                $el.Height = $h
            }
            # The cell's height is PINNED to the box: a zoomed host is laid out larger
            # than the box, and without the pin its size would grow this cell, shove
            # the whole timeline below the fold, and re-trigger SizeChanged in a loop.
            # With the pin, the oversized host simply overflows and the clip below
            # crops that overflow to exactly the video box.
            $previewCell.Height = $h
            $boxX = ($cellW - $w) / 2.0
            $boxY = 0.0
            $previewCell.Clip = New-Object System.Windows.Media.RectangleGeometry (
                New-Object System.Windows.Rect ($boxX, $boxY, $w, $h))
            # Everything the layout-based zoom needs to place the host: the box's
            # position and size within the cell. Re-asserted here because a resize
            # just re-centred the host at identity, which is wrong mid-zoom.
            $script:PreviewBox = @{ X = $boxX; Y = $boxY; W = $w; H = $h }
            Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
            # The PiP element(s) and the spotlight box are both positioned from this same
            # box, so a resize leaves them stale in exactly the way it leaves the zoom
            # transform stale.
            Update-PipPreview -SourceSeconds $script:TrimPlayhead
            # The base is sized from the same box the resize just recomputed.
            Update-TrimBlackBase
            Update-PipBoxOverlay
        }
        if ($null -ne $previewCell) {
            $previewCell.Add_SizeChanged({ & $script:UpdatePreviewFrameSize })
            $ctx.Window.Add_SizeChanged({ & $script:UpdatePreviewFrameSize })
        } else {
            # Old XAML without PreviewCell: keep the previous width-driven sizing.
            $mediaTrimPreview.Add_SizeChanged({
                param($eventSource, $e)
                if ($e.NewSize.Width -gt 0) {
                    $mediaTrimPreview.Height = $e.NewSize.Width * 9 / 16
                    if ($null -ne $canvasCaptionOverlay) {
                        $canvasCaptionOverlay.HorizontalAlignment = "Center"
                        $canvasCaptionOverlay.VerticalAlignment = "Center"
                        $canvasCaptionOverlay.Width = $e.NewSize.Width
                        $canvasCaptionOverlay.Height = $e.NewSize.Width * 9 / 16
                    }
                }
            })
        }

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

        # ---- Transport stop / the montage extension clock (spec 4.7) ------------------
        #
        # Three ways the main MediaElement can run out of picture: it reaches the end of
        # the file (MediaEnded), it runs off the end of the last surviving piece (the tick
        # below), or the user scrubs past V1's end. In all three, if a clip on some lane
        # still has footage out there, the transport must KEEP RUNNING -- there is simply
        # nothing left for the main element to contribute, so it pauses (it is never asked
        # to seek past its own duration) and the DispatcherTimer's wall clock drives the
        # playhead the rest of the way.
        function Stop-TrimTransport {
            try { $mediaTrimPreview.Pause() } catch {}
            if ($null -ne $buttonTrimPlay) { $buttonTrimPlay.Content = "Play" }
            if ($null -ne $script:TrimTimer) { $script:TrimTimer.Stop() }
            Set-TrimExtensionClockIdle
            # Whatever the pools were playing has to stop with it.
            Update-PipPreview -SourceSeconds $script:TrimPlayhead
            Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $false
            Update-TrimBlackBase
        }

        # The clock keeps its stamp only while it is actually advancing something.
        function Set-TrimExtensionClockIdle { $script:TrimExtensionClock = $null }

        function Stop-TrimAtV1End {
            $state = Get-TrimTimelineState
            $len = Get-TrimTimelineLengthCached
            $playing = ($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
            if ($playing -and $len -gt ([double]$state.TotalDuration + 0.01)) {
                try { $mediaTrimPreview.Pause() } catch {}
                # A hair past V1's end rather than exactly on it: the extension offset IS
                # the "am I out there" flag, and 0.0 means "inside the cut list".
                Set-TrimExtensionPosition -Seconds 0.001
                return
            }
            Stop-TrimTransport
        }

        # One tick's worth of wall time, added to the playhead's position past V1's end.
        function Step-TrimExtensionClock {
            if (-not (Test-TrimInExtension)) { return }
            $playing = ($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
            if (-not $playing) { Set-TrimExtensionClockIdle; return }
            $now = [datetime]::UtcNow
            $prev = $script:TrimExtensionClock
            Reset-TrimExtensionClock
            # First tick after entering the extension has nothing to measure from.
            if ($null -eq $prev) { return }
            $state = Get-TrimTimelineState
            $len = Get-TrimTimelineLengthCached
            $next = [double]$script:TrimExtensionOffset + ($now - $prev).TotalSeconds
            $max = [math]::Max(0.0, $len - [double]$state.TotalDuration)
            if ($next -ge $max) {
                Set-TrimExtensionPosition -Seconds $max
                Stop-TrimTransport
                return
            }
            Set-TrimExtensionPosition -Seconds $next
        }

        $script:TrimTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:TrimTimer.Interval = [timespan]::FromMilliseconds(50)
        $script:TrimTimer.Add_Tick({
            if (Test-TrimInExtension) {
                # Out past V1's end: MediaElement.Position is frozen on the last frame it
                # decoded and says nothing about where the timeline is, so wall time does.
                Step-TrimExtensionClock
            } else {
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
                        # Past the last surviving piece: either the montage carries on out
                        # there, or this is the end of the timeline and the transport stops.
                        Stop-TrimAtV1End
                    }
                }
            }

            Update-TrimPosition
            Update-TrimTimeline -TickOnly
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            # After the fade overlay, not before: the fade owns the picture while it is up
            # and Update-CaptionOverlay reads the key it just set.
            Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
            # The caption redraw just cleared the overlay canvas the spotlight box (and the
            # PiP box) live on.
            Update-ZoomBoxOverlay
            Update-PipBoxOverlay
            # After the captions: the zoom transform is what makes the glide visible during
            # playback, and it has its own identity fast-path so a clip with no keyframes
            # pays almost nothing for being asked 20x a second.
            Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
            # And the PiP/audio-clip pools follow the same tick: video-clip elements seek
            # and play/pause with the main transport, audio-clip elements play only while
            # actually playing (see Update-TrimAudioClipPreview's own comment on why
            # scrubbing never reaches them).
            Update-PipPreview -SourceSeconds $script:TrimPlayhead
            Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $true
            Update-TrimBlackBase
        })

        $buttonTrimPlay.Add_Click({
            if ($buttonTrimPlay.Content -eq "Play") {
                # Play from inside the montage region does NOT start the main element: it
                # has no frame out there, and playing it would run the source on under a
                # timeline position it no longer matches. The extension clock takes over
                # from the moment the timer starts (Test-/Reset- rather than a bare
                # $script: read/write: this block IS a GetNewClosure'd one).
                if (Test-TrimInExtension) { Reset-TrimExtensionClock } else { $mediaTrimPreview.Play() }
                $buttonTrimPlay.Content = "Pause"
                $script:TrimTimer.Start()
            } else {
                $mediaTrimPreview.Pause()
                $buttonTrimPlay.Content = "Play"
                $script:TrimTimer.Stop()
                # Pausing the main transport has to pause every PiP/audio-clip element too --
                # otherwise a video-clip PiP or an audio-clip keeps running silently past the
                # point the visible transport stopped.
                Update-PipPreview -SourceSeconds $script:TrimPlayhead
                Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $false
                Update-TrimBlackBase
            }
        }.GetNewClosure())

        # The source file itself ran out. Same fork as the tick's: the montage carries on
        # if there is anything out past V1's end, otherwise the transport stops.
        $mediaTrimPreview.Add_MediaEnded({
            Stop-TrimAtV1End
        }.GetNewClosure())

        # Scrubbing: one shared seek used by the click AND by the playhead drag. -Light is
        # the per-mouse-move variant: it takes the tick's cheap timeline path (no lane-row
        # rebuild) and skips the PiP -Seek, whose per-move MediaElement.Position writes
        # would stutter the drag -- the full pass on release catches the pools up.
        # A top-level function so its bare $script: writes land in the real script scope.
        function Set-TrimScrubFromX {
            param([double]$X, [switch]$Light)
            if (-not $script:TrimInputFile) { return }
            $state = Get-TrimTimelineState
            # The position lands in timeline (compacted) space; convert to a real source
            # second before seeking, so a scrub can never target deleted footage.
            $t = Convert-TrimXToTime -X $X
            # 0.0, not 0 (trap #8): the int overload truncated every scrub click to a
            # whole second, so the playhead could never land between seconds.
            #
            # Clamped to the WHOLE timeline, not the cut list: past V1's end the position
            # is in the montage region, which is a real part of the export.
            $wasInExtension = Test-TrimInExtension
            $playing = ($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
            $tClamped = [math]::Max(0.0, [math]::Min((Get-TrimTimelineLengthCached), $t))
            $extra = $tClamped - [double]$state.TotalDuration
            # The source position is clamped to the end of the last surviving piece either
            # way -- the main element is never asked to seek past its own footage. Out in
            # the extension it is also PAUSED and the black base covers the stale frame.
            $script:TrimPlayhead = Convert-TrimTimelineToSource `
                -TimelineSeconds ([math]::Min($tClamped, [double]$state.TotalDuration)) `
                -TimelinePieces $state.TimelinePieces
            $mediaTrimPreview.Position = [timespan]::FromSeconds($script:TrimPlayhead)
            if ($extra -gt 0) {
                Set-TrimExtensionPosition -Seconds $extra
                try { $mediaTrimPreview.Pause() } catch {}
            } else {
                Set-TrimExtensionPosition -Seconds 0.0
                # Coming BACK from the extension while the transport is still running: the
                # main element was paused out there and has to be handed the picture again.
                if ($wasInExtension -and $playing) { try { $mediaTrimPreview.Play() } catch {} }
            }
            Update-TrimPosition
            if ($Light) { Update-TrimTimeline -TickOnly } else { Update-TrimTimeline }
            # Scrubbing into a fade shows the blended frame too, not just playback.
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            # Scrubbing across a caption's window shows it appear and disappear on time.
            Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
            Update-ZoomBoxOverlay
            Update-PipBoxOverlay
            # And scrubbing across a glide shows the picture move with it, paused.
            Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
            if (-not $Light) {
                # Scrubbing repositions a PiP's video, but deliberately never seeks an
                # audio-clip (Update-TrimAudioClipPreview's own comment explains why).
                Update-PipPreview -SourceSeconds $script:TrimPlayhead -Seek $true
                Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $false
            }
            Update-TrimBlackBase
        }

        # Scrub press-and-drag, shared across surfaces: the RULER is the visible scrub
        # strip now that the SRC filmstrip row is hidden (the hidden timeline canvas
        # keeps the handlers too -- harmless, unreachable). Mouse capture goes on the
        # surface that took the press ($eventSource); the x always converts through the
        # hidden canvas, the x-axis authority every strip shares.
        #
        # No GetNewClosure() on these, same reason as the timer tick above: they write
        # $script: state, which a closure would rebind into its own private module.
        $script:TrimScrubDownHandler = {
            param($eventSource, $e)
            if (-not $script:TrimInputFile) { return }
            Set-TrimScrubFromX -X ($e.GetPosition($canvasTrimTimeline)).X
            $script:TrimScrubDrag = $true
            [void]$eventSource.CaptureMouse()
        }
        $script:TrimScrubMoveHandler = {
            param($eventSource, $e)
            if (-not $script:TrimScrubDrag) { return }
            Set-TrimScrubFromX -X ($e.GetPosition($canvasTrimTimeline)).X -Light
        }
        $script:TrimScrubUpHandler = {
            param($eventSource, $e)
            if (-not $script:TrimScrubDrag) { return }
            $script:TrimScrubDrag = $false
            $eventSource.ReleaseMouseCapture()
            # The full pass: lane rows recatch the final position and the PiP pools seek.
            Set-TrimScrubFromX -X ($e.GetPosition($canvasTrimTimeline)).X
        }
        foreach ($scrubSurface in @($canvasTrimTimeline, $canvasTrimRuler)) {
            if ($null -eq $scrubSurface) { continue }
            $scrubSurface.Add_MouseLeftButtonDown($script:TrimScrubDownHandler)
            $scrubSurface.Add_MouseMove($script:TrimScrubMoveHandler)
            $scrubSurface.Add_MouseLeftButtonUp($script:TrimScrubUpHandler)
        }

        # Ctrl + wheel zooms around the pointer, Shift + wheel PANS; a bare wheel is left
        # alone so the panel still scrolls the way every other screen does. Attached to
        # every timeline surface (ruler, lanes, caption/zoom/fade strips) because the strip
        # that used to take this wheel -- the SRC filmstrip -- is hidden now.
        $script:TrimWheelHandler = {
            param($eventSource, $e)
            if (-not $script:TrimInputFile) { return }
            $wheelCtrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
            $wheelShift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
            if (-not $wheelCtrl -and -not $wheelShift) { return }
            $state = Get-TrimTimelineState
            if ($state.TotalDuration -le 0) { return }
            $e.Handled = $true
            $viewMax = Get-TrimViewMax -TimelineLength (Get-TrimTimelineLengthCached)

            if ($wheelShift -and -not $wheelCtrl) {
                # PAN: a notch slides the view 10% of its span; wheel-down scrolls right,
                # the usual horizontal-scroll convention.
                $step = $script:TrimViewSpan * 0.1 * $(if ($e.Delta -gt 0) { -1.0 } else { 1.0 })
                $newStart = [math]::Max(0.0, [math]::Min($viewMax - $script:TrimViewSpan, $script:TrimViewStart + $step))
                Set-TrimView -Start $newStart -Span $script:TrimViewSpan
                Update-TrimTimeline -TickOnly
                Request-TrimZoomRefine
                return
            }

            # Anchor and span are both timeline (compacted) seconds -- zoom operates on
            # the same space the ruler and track are drawn in. Floor of 0.5s: below that
            # the pieces are narrower than their own borders. Ceiling of viewMax, not the
            # content length: the breathing room past the last clip is part of the view.
            $anchor = Convert-TrimXToTime -X ($e.GetPosition($canvasTrimTimeline)).X
            $factor = if ($e.Delta -gt 0) { 0.8 } else { 1.25 }
            $newSpan = [math]::Max(0.5, [math]::Min($viewMax, $script:TrimViewSpan * $factor))
            $ratio = if ($script:TrimViewSpan -gt 0) { ($anchor - $script:TrimViewStart) / $script:TrimViewSpan } else { 0.5 }
            $newStart = [math]::Max(0.0, [math]::Min($viewMax - $newSpan, $anchor - ($ratio * $newSpan)))
            Set-TrimView -Start $newStart -Span $newSpan
            # Cheap path per notch, full rebuild once the wheel goes quiet -- see the
            # comment on $script:ZoomRefineTimer.
            Update-TrimTimeline -TickOnly
            Request-TrimZoomRefine
        }
        foreach ($wheelSurface in @($canvasTrimTimeline, $canvasTrimRuler, $canvasTrimFades,
                                    $canvasTrimCaptions, $canvasTrimZooms, $panelTrimLanes)) {
            if ($null -eq $wheelSurface) { continue }
            $wheelSurface.Add_PreviewMouseWheel($script:TrimWheelHandler)
        }

        # The canvas has no width until it is laid out, so the first paint must wait for it,
        # and a resize invalidates every x already computed.
        $canvasTrimTimeline.Add_SizeChanged({ Update-TrimTimeline })

        # Lane drags are driven from the CANVAS, not from the blocks: the lane is rebuilt on
        # every move, so a handler living on a block would be destroyed mid-drag. The canvas
        # holds the mouse capture and survives the redraw.
        #
        # No GetNewClosure() on these two, deliberately -- same reason as the timeline
        # canvas handlers above: they read and write $script: state, which a closure would
        # rebind into its own private module, and neither needs to capture anything.
        if ($null -ne $canvasTrimCaptions) {
            $canvasTrimCaptions.Add_MouseMove({
                param($eventSource, $e)
                if (-not (Test-TrimCaptionDrag)) { return }
                Update-TrimCaptionDrag -CurrentX ($e.GetPosition($canvasTrimCaptions)).X
                # Lane only: a handful of borders, cheap enough to redraw per mouse move,
                # where a full Update-TrimTimeline would re-request thumbnails.
                Update-TrimCaptionLane
            })

            $canvasTrimCaptions.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (-not (Test-TrimCaptionDrag)) { return }
                $canvasTrimCaptions.ReleaseMouseCapture()
                Complete-TrimCaptionDrag
                Update-TrimTimeline
            })

            # Empty lane space deselects. The blocks and their grips mark their own clicks
            # Handled and are children of this canvas, so OriginalSource being the canvas
            # itself means the click landed on bare background -- a drag start can never
            # reach here.
            $canvasTrimCaptions.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                if ($e.OriginalSource -ne $canvasTrimCaptions) { return }
                Clear-TrimCaptionSelection
            })

            $canvasTrimCaptions.Add_SizeChanged({ Update-TrimCaptionLane })
        }

        # Zoom lane drags, same three handlers and the same reasoning as the caption lane
        # above: capture lives on the canvas because the lane is rebuilt on every move, and
        # none of these take a GetNewClosure() -- they read and write $script: state through
        # top-level functions and capture nothing.
        if ($null -ne $canvasTrimZooms) {
            $canvasTrimZooms.Add_MouseMove({
                param($eventSource, $e)
                if (-not (Test-TrimZoomDrag)) { return }
                Update-TrimZoomDrag -CurrentX ($e.GetPosition($canvasTrimZooms)).X
                # Lane only: a handful of shapes, cheap per mouse move, where a full
                # Update-TrimTimeline would re-request thumbnails.
                Update-TrimZoomLane
            })

            $canvasTrimZooms.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (-not (Test-TrimZoomDrag)) { return }
                $canvasTrimZooms.ReleaseMouseCapture()
                Complete-TrimZoomDrag
                Update-TrimTimeline
            })

            # Empty lane space deselects. The diamonds mark their own clicks Handled and are
            # children of this canvas, and the ramps are not hit-testable at all, so an
            # OriginalSource of the canvas itself is bare background and never a drag start.
            $canvasTrimZooms.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                if ($e.OriginalSource -ne $canvasTrimZooms) { return }
                Clear-TrimZoomSelection
            })

            $canvasTrimZooms.Add_SizeChanged({ Update-TrimZoomLane })
        }

        # Track lanes: the panel itself is the stable element (its per-lane children are
        # rebuilt on every structural change), so a resize just needs the one redraw --
        # there is no per-lane capture to protect here since a resize cannot happen mid-drag.
        if ($null -ne $panelTrimLanes) {
            $panelTrimLanes.Add_SizeChanged({ Update-TrimLaneRows })
        }

        # The zoom translate is computed from the host's own width and height, so every
        # pixel of it is wrong until the next redraw once the box changes size -- opening the
        # caption sidebar takes 240px off it, exactly as it does off the caption overlay.
        if ($null -ne $previewZoomHost) {
            $previewZoomHost.Add_SizeChanged({ Update-PreviewZoom -SourceSeconds $script:TrimPlayhead })
        }
        # Preview-overlay drags. Capture lives on the overlay canvas for the same reason it
        # lives on the lane canvas: the overlay is rebuilt on every move, so a capture held
        # by the caption element itself would die after the first one. No GetNewClosure()
        # here either -- these read and write $script: state through top-level functions and
        # capture nothing.
        if ($null -ne $canvasCaptionOverlay) {
            # Empty video space deselects, same test as the lane: the caption box and its
            # resize handle are children that mark their own clicks Handled, so an
            # OriginalSource of the canvas itself is background and never a drag start.
            $canvasCaptionOverlay.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                if ($e.OriginalSource -ne $canvasCaptionOverlay) { return }
                # With a zoom keyframe selected the same press means something else: it is
                # the corner of a new spotlight box. Nothing is decided here -- a press that
                # never travels far enough is settled as a plain click on release and falls
                # through to the deselect below.
                if ($null -ne (Get-TrimSelectedZoom)) {
                    $p = $e.GetPosition($canvasCaptionOverlay)
                    Start-ZoomBoxDrag -StartX $p.X -StartY $p.Y
                    $canvasCaptionOverlay.CaptureMouse() | Out-Null
                    return
                }
                Clear-TrimCaptionSelection
            })

            $canvasCaptionOverlay.Add_MouseMove({
                param($eventSource, $e)
                # PiP box first: it and the zoom box can never both be live (selecting a
                # track clears the zoom selection, selecting a zoom clears the track
                # selection -- Set-TrimSelectedClip/-Zoom's mutual-exclusion), so testing
                # order between the two never matters, only that both are checked before
                # falling through to the caption drag.
                if (Test-PipBoxDrag) {
                    $p = $e.GetPosition($canvasCaptionOverlay)
                    Update-PipBoxDrag -CurrentX $p.X -CurrentY $p.Y
                    Update-PipBoxOverlay
                    return
                }
                # The zoom box next: the cheaper test of the two remaining drags.
                if (Test-ZoomBoxDrag) {
                    $p = $e.GetPosition($canvasCaptionOverlay)
                    Update-ZoomBoxDrag -CurrentX $p.X -CurrentY $p.Y
                    # Box only: the forming rectangle is drawn straight from the drag, and
                    # nothing is written to the model until the button comes up.
                    Update-ZoomBoxOverlay
                    return
                }
                if (-not (Test-CaptionOverlayDrag)) { return }
                $p = $e.GetPosition($canvasCaptionOverlay)
                Update-CaptionOverlayDrag -CurrentX $p.X -CurrentY $p.Y
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
                Update-ZoomBoxOverlay
                Update-PipBoxOverlay
            })

            $canvasCaptionOverlay.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (Test-PipBoxDrag) {
                    $canvasCaptionOverlay.ReleaseMouseCapture()
                    Complete-PipBoxDrag
                    Update-TrimLaneRows
                    Update-PipBoxOverlay
                    return
                }
                if (Test-ZoomBoxDrag) {
                    $canvasCaptionOverlay.ReleaseMouseCapture()
                    Complete-ZoomBoxDrag
                    # Full redraw: the level changed, so the lane's ramps did too -- and this
                    # is what puts the committed box back on screen in place of the forming
                    # one, through Update-TrimZoomLane.
                    Update-TrimTimeline
                    return
                }
                if (-not (Test-CaptionOverlayDrag)) { return }
                $canvasCaptionOverlay.ReleaseMouseCapture()
                Complete-CaptionOverlayDrag
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
                Update-ZoomBoxOverlay
                Update-PipBoxOverlay
            })

            # Opening or closing the sidebar takes 240px off the preview, so every X/Y
            # already converted to pixels is wrong until the next redraw -- and the box and
            # its pill are positioned in those same pixels.
            $canvasCaptionOverlay.Add_SizeChanged({
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
                Update-ZoomBoxOverlay
                Update-PipBoxOverlay
            })

            # Once, at startup: the pill is a live control, not a redrawn shape, and lives in
            # the canvas for the whole session with only its visibility and position changing.
            Initialize-ZoomPill
        }

        if ($null -ne $buttonTrimAddCaption) { $buttonTrimAddCaption.Add_Click({ Invoke-TrimAddCaption }) }
        if ($null -ne $buttonCaptionDelete) { $buttonCaptionDelete.Add_Click({ Invoke-TrimDeleteCaption }) }
        if ($null -ne $buttonTrimAddZoom) { $buttonTrimAddZoom.Add_Click({ Invoke-TrimAddZoom }) }
        if ($null -ne $buttonTrimAddVideoTrack) { $buttonTrimAddVideoTrack.Add_Click({ Invoke-TrimAddVideoTrack }) }
        if ($null -ne $buttonTrimAddAudioTrack) { $buttonTrimAddAudioTrack.Add_Click({ Invoke-TrimAddAudioTrack }) }
        if ($null -ne $buttonTrimUnlink) { $buttonTrimUnlink.Add_Click({ Invoke-TrimUnlink }) }
        if ($null -ne $buttonTrimSnap) { $buttonTrimSnap.Add_Click({ Set-TrimSnapEnabled -Value (-not (Get-TrimSnapEnabled)) }) }
        # Once at startup, after Import-Config seeded the flag: the magnet has to show its
        # restored state before the user touches anything.
        Update-TrimSnapButton

        # ---- Clip properties strip handlers ----
        #
        # No GetNewClosure on either of these: like the zoom pill's slider, they reach the
        # selection through top-level state only, never through a captured loop variable.
        # The gain slider and mute box that used to live here are gone -- gain and mute
        # belong to the ROW now, and the row header owns them (spec 3.2).
        if ($null -ne $buttonClipDisplayMode) {
            $buttonClipDisplayMode.Add_Click({
                if ($null -eq $script:TrimSelectedClip) { return }
                Invoke-TrimClipDisplayModeToggle -Id ([string]$script:TrimSelectedClip)
            })
        }
        if ($null -ne $buttonTrackDelete) {
            $buttonTrackDelete.Add_Click({
                # The strip is clip-scoped: this deletes the SELECTED CLIP and its linked
                # peers (spec 4.4). Deleting a ROW is the header's own trash / context menu.
                if ($null -eq $script:TrimSelectedClip) { return }
                Push-TrimUndo
                Remove-TrimClipWithLinks -Id ([string]$script:TrimSelectedClip)
                Update-TrimSelectionText
            })
        }

        # ---- Caption sidebar handlers ----
        #
        # Every one of these bails on the loading flag first: WPF raises the same events for
        # a programmatic fill as for a user edit, so without that first line selecting a
        # caption would write all nine fields back and push undo steps for edits nobody made.
        if ($null -ne $comboCaptionFont) {
            # Once, at startup: enumerating installed fonts is not free and the list cannot
            # change while the window is open. Strings rather than FontFamily objects so the
            # combo's SelectedItem compares equal to the caption's stored name.
            $comboCaptionFont.ItemsSource = @(
                [System.Windows.Media.Fonts]::SystemFontFamilies | Sort-Object Source | ForEach-Object { $_.Source }
            )
            $comboCaptionFont.Add_SelectionChanged({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                $font = [string]$comboCaptionFont.SelectedItem
                if ([string]::IsNullOrEmpty($font) -or $font -eq [string]$cap.FontFamily) { return }
                Push-TrimUndo
                Update-CaptionField -Id $cap.Id -Field "FontFamily" -Value $font
            })
        }

        if ($null -ne $textCaptionText) {
            $textCaptionText.Add_TextChanged({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Update-CaptionField -Id $cap.Id -Field "Text" -Value ([string]$textCaptionText.Text)
            })
            # One undo step per visit to the box, not one per keystroke.
            $textCaptionText.Add_GotFocus({ Start-CaptionTextEdit })
            $textCaptionText.Add_LostFocus({ Complete-CaptionTextEdit })
        }

        if ($null -ne $checkCaptionBold) {
            $checkCaptionBold.Add_Click({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Push-TrimUndo
                Update-CaptionField -Id $cap.Id -Field "Bold" -Value ([bool]$checkCaptionBold.IsChecked)
            })
        }

        if ($null -ne $checkCaptionBounce) {
            $checkCaptionBounce.Add_Click({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Push-TrimUndo
                Update-CaptionField -Id $cap.Id -Field "BounceIn" -Value ([bool]$checkCaptionBounce.IsChecked)
            })
        }

        if ($null -ne $sliderCaptionOutlineW) {
            $sliderCaptionOutlineW.Add_ValueChanged({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Update-CaptionField -Id $cap.Id -Field "OutlineWidth" -Value ([double]$sliderCaptionOutlineW.Value)
            })
            # Undo brackets the whole drag: ValueChanged fires on every tick of one.
            $sliderCaptionOutlineW.Add_GotMouseCapture({ Start-CaptionSliderEdit })
            $sliderCaptionOutlineW.Add_LostMouseCapture({ Complete-CaptionSliderEdit })
        }

        # Colours and times are validated on the way OUT of the box, not per keystroke:
        # "#00FF0" is a legitimate intermediate state of typing "#00FF00".
        # Built once at startup, not per selection: the palette is fixed, and rebuilding it
        # on every Show-CaptionSidebar would throw away twelve buttons and their handlers
        # on each click of a lane block.
        Add-CaptionSwatches -Panel $panelCaptionFillSwatches -Field "FillColor"
        Add-CaptionSwatches -Panel $panelCaptionOutlineSwatches -Field "OutlineColor"

        if ($null -ne $textCaptionFill) {
            $textCaptionFill.Add_LostFocus({ Set-CaptionColorFromBox -Box $textCaptionFill -Field "FillColor" })
        }
        if ($null -ne $textCaptionOutline) {
            $textCaptionOutline.Add_LostFocus({ Set-CaptionColorFromBox -Box $textCaptionOutline -Field "OutlineColor" })
        }
        if ($null -ne $textCaptionStart) {
            $textCaptionStart.Add_LostFocus({ Set-CaptionTimeFromBox -Box $textCaptionStart -Edge "start" })
        }
        if ($null -ne $textCaptionEnd) {
            $textCaptionEnd.Add_LostFocus({ Set-CaptionTimeFromBox -Box $textCaptionEnd -Edge "end" })
        }

        $buttonTrimSplit.Add_Click({ Invoke-TrimSplit })
        $buttonTrimDelete.Add_Click({ Invoke-TrimDelete })
        $buttonTrimUndo.Add_Click({ Invoke-TrimUndo })
        if ($null -ne $buttonTrimRedo) { $buttonTrimRedo.Add_Click({ Invoke-TrimRedo }) }
        if ($null -ne $buttonTrimOpenAnother) {
            # Funnels into the dropzone's own Click so the file-dialog flow (and any
            # future changes to it) stays in exactly one place. A collapsed button
            # still handles a programmatic RaiseEvent.
            $buttonTrimOpenAnother.Add_Click({
                $buttonTrimBrowse.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            })
        }

        # Handled at the window, then filtered to the Trim panel: the Canvas cannot hold
        # focus reliably and a panel-level handler would miss keys pressed over the preview.
        # Guarded on TextBox focus so typing a URL on another screen never triggers a split.
        $ctx.Window.Add_PreviewKeyDown({
            param($eventSource, $e)
            if ($ctx.Panels.Trim.Visibility -ne "Visible") { return }
            if (-not $script:TrimInputFile) { return }
            if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
            # The whole caption sidebar is an input surface: typing S into the font
            # dropdown must type-ahead to Sitka, not split the video. IsKeyboardFocusWithin
            # covers the combo (and its popup items), the sliders and the checkboxes in
            # one test instead of enumerating control types.
            if ($null -ne $panelCaptionSidebar -and $panelCaptionSidebar.IsKeyboardFocusWithin) { return }
            # The floating zoom pill's buttons keep keyboard focus after a click, and a
            # focused button activates on Space -- so Space alone is swallowed here, or
            # play/pause would also re-click the magnet or Delete. Everything else
            # (Ctrl+Z/Y, C, Z, S, DEL) must keep working right after tapping a pill
            # control: a blanket return here was exactly what deadened every shortcut
            # until the user happened to click elsewhere.
            if ($null -ne $script:ZoomPillBorder -and $script:ZoomPillBorder.IsKeyboardFocusWithin -and
                $e.Key -eq [System.Windows.Input.Key]::Space) { return }

            $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0

            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::Z) { Invoke-TrimUndo; $e.Handled = $true; return }
            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::Y) { Invoke-TrimRedo; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::S -and -not $ctrl) { Invoke-TrimSplit; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::C -and -not $ctrl) { Invoke-TrimAddCaption; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::Z -and -not $ctrl) { Invoke-TrimAddZoom; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::U -and -not $ctrl) { Invoke-TrimUnlink; $e.Handled = $true; return }
            # N toggles snapping (the magnet), a tool mode that outlives the session --
            # read back through Get-TrimSnapEnabled rather than the bare $script: variable.
            if ($e.Key -eq [System.Windows.Input.Key]::N -and -not $ctrl) {
                Set-TrimSnapEnabled -Value (-not (Get-TrimSnapEnabled))
                $e.Handled = $true
                return
            }
            if ($e.Key -eq [System.Windows.Input.Key]::Delete) {
                # A selected zoom keyframe wins. Selecting one clears the caption selection
                # and vice versa, so at most one of these is ever armed -- but a piece can be
                # selected at the same time as a keyframe, and deleting footage is the far
                # more destructive of the two to do by accident.
                if ($null -ne (Get-TrimSelectedZoom)) { Invoke-TrimDeleteZoom }
                # A selected CLIP comes next, for the same reason: selecting one clears the
                # caption/zoom selections (Set-TrimSelectedClip), but a cut-list PIECE can
                # still be selected alongside it, and removing one clip is far less
                # destructive than removing a stretch of the source footage.
                elseif ($null -ne $script:TrimSelectedClip) {
                    Push-TrimUndo
                    Remove-TrimClipWithLinks -Id ([string]$script:TrimSelectedClip)
                    Update-TrimSelectionText
                }
                else { Invoke-TrimDelete }
                $e.Handled = $true
                return
            }
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

        # Flush the pending debounced save for the OUTGOING file before anything below
        # touches state -- same unconditional, timer-bypassed flush the window's Closed
        # handler does, and for the same reason. Without it, switching videos within a
        # second of an edit loses that edit, and worse, the still-armed timer would fire
        # later and write the NEW video's fresh state over the old file's project.
        if ($script:ProjectSaveTimer) { $script:ProjectSaveTimer.Stop() }
        if ($script:TrimInputFile) {
            Save-TrimProject -VideoPath $script:TrimInputFile -CutList @($script:TrimCutList) `
                -Fades $script:TrimFades -Captions @($script:TrimCaptions) -Zooms @($script:TrimZooms) `
                -Lanes @($script:TrimLanes) | Out-Null
        }

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
        $script:TrimRedoStack = New-Object System.Collections.ArrayList
        Update-TrimRedoButton
        # Fades belong to the file that was being edited: keys are source times, so
        # keeping them across a file swap would drop fades onto unrelated timestamps.
        $script:TrimFades = @{}
        $script:TrimActiveFade = $null
        # Captions belong to the file they were written over -- their times are source
        # seconds, so carrying them across a file swap would strand them on unrelated
        # footage. A drag in progress across a file pick is dropped for the same reason.
        $script:TrimCaptions = New-Object System.Collections.ArrayList
        $script:TrimSelectedCaption = $null
        $script:TrimCaptionDrag = $null
        # Zoom keyframes belong to the file they were written against for exactly the same
        # reason captions do -- their times are source seconds. A drag in progress across a
        # file pick is dropped with them.
        $script:TrimZooms = New-Object System.Collections.ArrayList
        $script:TrimSelectedZoom = $null
        $script:TrimZoomDrag = $null
        # Lanes belong to the file they were probed against for exactly the same reason --
        # never left $null (the Export-CutListAsync audio-only trap), always reset to an
        # empty ArrayList here and filled in below once the project/default stack is known.
        $script:TrimLanes = New-Object System.Collections.ArrayList
        $script:TrimSelectedClip = $null
        $script:TrimSelectedLane = $null
        $script:TrimCollapsedLanes = @{}
        $script:TrimClipDrag = $null
        $script:TrimLaneReorderDrag = $null
        $script:TrimClipElements = @{}
        $script:TrimSnapFlashLine = $null
        $script:TrimLaneReorderLine = $null
        # Reset to the legacy/unknown sentinel here; set to the real probed count a few
        # lines below once Get-TrimAudioStreams has run against the new file.
        $script:TrimSourceAudioStreamCount = -1
        # The previous file's external clips are unrelated to whatever the new file's
        # project restores below -- every pooled PiP/audio-clip MediaElement is torn down
        # rather than left playing (or sitting in the visual tree) against a file that is
        # no longer open, and the duration/aspect caches are keyed by path so they carry
        # no meaning across files either.
        Clear-TrimClipMediaElementPools
        $script:TrimClipDurations = @{}
        $script:TrimClipAspect = @{}
        $script:PipBoxDrag = $null
        # Whatever the previous file's glide left on the preview would otherwise sit over the
        # new file's first frame until something happens to redraw it.
        Update-PreviewZoom -SourceSeconds 0.0
        $script:TrimSelected = -1
        $script:TrimPlayhead = 0.0
        # A new file has no montage region until its own project restores one; leaving the
        # previous file's extension offset set would put the playhead past an end that no
        # longer exists.
        Set-TrimExtensionPosition -Seconds 0.0
        $script:TrimTimelineLengthCache = 0.0
        $script:TrimViewStart = 0.0
        # The first Update-TrimTimeline clamps this to Get-TrimViewMax (content plus
        # breathing room), so the default view always shows empty track after the content
        # -- the room the user drags new clips into.
        $script:TrimViewSpan = $script:TrimDuration
        # Empty until the async read lands; Find-NearestKeyframe treats that as "no
        # snapping" rather than "cannot cut".
        $script:TrimKeyframes = @()
        # The save warning is per file: a new pick deserves its own chance to report a
        # folder it cannot write to.
        $script:ProjectSaveWarned = $false

        # Restore whatever was last saved for this video, over the fresh state above and
        # before the first Update-TrimTimeline so the panel draws the restored edit once
        # rather than drawing the empty cut list first and flickering to it.
        # @() around the array members: Read-TrimProject hands back a hashtable whose
        # CutList/Captions values are arrays, and a one-element array unrolls to a bare
        # object on assignment without it.
        $project = Read-TrimProject -VideoPath $path
        # A file is there but unreadable (hand-edited, truncated, written by a newer
        # version). Reported rather than silently discarded -- but only further down,
        # after the unconditional message clear, which would otherwise wipe it.
        $projectUnreadable = $false
        # Keyframes the reader could not make sense of. Reported below rather than silently
        # dropped: a project that comes back with fewer zooms than it was saved with is
        # something the user needs to know about before they export.
        $droppedZooms = 0
        if ($project) {
            $script:TrimCutList = @($project.CutList)
            $script:TrimFades = $project.Fades
            $script:TrimCaptions = New-Object System.Collections.ArrayList
            foreach ($c in @($project.Captions)) { [void]$script:TrimCaptions.Add($c) }
            $script:TrimZooms = New-Object System.Collections.ArrayList
            foreach ($z in @($project.Zooms)) { [void]$script:TrimZooms.Add($z) }
            if ($project.DroppedZooms -gt 0) { $droppedZooms = [int]$project.DroppedZooms }
        } elseif (Test-Path -LiteralPath (Get-TrimProjectPath -VideoPath $path)) {
            $projectUnreadable = $true
        }

        # Lane stack: probe the file's own audio streams so the default stack (and every
        # source audio clip's StreamIdx) reflects THIS file, not whatever the previous one
        # had. Synchronous, same as the ffprobe call Get-VideoProperties already made above --
        # both are quick metadata reads, not the frame decode the keyframe scan needs async.
        $streams = Get-TrimAudioStreams -InputFile $path
        # @($streams).Count, not $streams.Count: Get-TrimAudioStreams always returns a real
        # array (ConvertFrom-AudioStreamProbe's `return ,@($result)`), so this is
        # belt-and-suspenders against the @($null).Count -eq 1 trap, not a fix for a real
        # null -- same defensive habit as the -Lanes wrapping at the export call site below.
        $script:TrimSourceAudioStreamCount = @($streams).Count
        if ($project -and $null -ne $project.Lanes -and @($project.Lanes).Count -gt 0) {
            # Restored lanes carry whatever Path was on disk at save time. The MAIN lane's
            # video clip is BY DEFINITION the loaded file -- not a movable reference to it --
            # so if the file has since moved (renamed, relocated), its recorded Path is
            # stale and must be rewritten to $path (the file we just resolved to load). Its
            # linked source audio clips travel with it, as does any clip that still points
            # at the OLD main path. Genuinely external clips are left untouched.
            $restored = @($project.Lanes)
            $mainLink = ""
            $oldMainPath = ""
            foreach ($ln in $restored) {
                foreach ($c in @($ln.Clips)) {
                    if (Test-TrimClipIsMainVideo -Lane $ln -Clip $c) {
                        $mainLink = [string]$c.LinkId
                        $oldMainPath = [string]$c.Path
                        $c.Path = $path
                    }
                }
            }
            foreach ($ln in $restored) {
                foreach ($c in @($ln.Clips)) {
                    if ($c.Kind -ne "audio") { continue }
                    $matchesLink = (-not [string]::IsNullOrEmpty($mainLink) -and [string]$c.LinkId -eq $mainLink)
                    $matchesPath = (-not [string]::IsNullOrEmpty($oldMainPath) -and [string]$c.Path -eq $oldMainPath)
                    if ($matchesLink -or $matchesPath) { $c.Path = $path }
                }
            }
            Set-TrimLanes -Lanes $restored
        } else {
            # No lanes to restore (a v1 project, no project file at all, or one that saved
            # an empty stack) -- the app builds the default lane stack: the recording's own
            # V1 lane plus one always-visible audio row per stream this file actually has.
            # No @() wrapper here: Get-TrimLaneStack already does `return ,@($lanes)`, and
            # wrapping an already-real array in another @() nests it one level deeper
            # (trap #2), which delivered a "list" of Count 1 holding the whole array.
            Set-TrimLanes -Lanes (Get-TrimLaneStack -Path $path -AudioStreams $streams)
        }
        # A restored project's external clips were probed against a PREVIOUS session's cache
        # (TrimClipDurations/TrimClipAspect were just cleared above) -- without re-probing
        # here, every one of them would read InEnd 0 as "SourceDuration 0.0" and land as a
        # zero-length span, invisible on both the row and the PiP preview.
        foreach ($ln in @($script:TrimLanes)) {
            foreach ($c in @($ln.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $ln -Clip $c) { continue }
                $tp = [string]$c.Path
                if ($tp -eq [string]$path) { continue }
                if (-not $script:TrimClipDurations.ContainsKey($tp)) {
                    $script:TrimClipDurations[$tp] = Get-TrimClipDuration -Path $tp
                }
                # Images get an aspect too: ffprobe reads their dimensions fine, and the
                # magnet-locked PiP resize needs one for every visual clip.
                if (($c.Kind -eq "video" -or $c.Kind -eq "image") -and -not $script:TrimClipAspect.ContainsKey($tp)) {
                    $clipProfile = Get-TrimSourceProfile -InputFile $tp
                    $script:TrimClipAspect[$tp] = if ([double]$clipProfile.Height -gt 0) {
                        [double]$clipProfile.Width / [double]$clipProfile.Height
                    } else { 16.0 / 9.0 }
                }
            }
        }

        # A second file's thumbnails are for a different source and must not be served
        # from the first file's cache -- keyed only by second, not by file.
        if ($script:TrimThumbDir -and (Test-Path $script:TrimThumbDir)) {
            Remove-Item -LiteralPath $script:TrimThumbDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:TrimThumbDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-thumbs-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TrimThumbDir -Force | Out-Null
        $script:TrimThumbCache = @{}
        $script:TrimThumbPending = @{}
        # Waveform strips get a PERSISTENT on-disk cache, unlike the thumbnails: they
        # took a visible couple of seconds to re-render on every single file open, and
        # a waveform never changes for a given source file. Keyed by path + size +
        # mtime so a re-recorded file with the same name renders fresh. The in-memory
        # caches still reset per file open like everything else.
        $script:TrimWaveCache = @{}
        $script:TrimWavePending = @{}
        # Row media (filmstrips + per row waveforms): the QUEUE is dropped on a new file
        # open -- those jobs were for the previous stack -- but the claimed-key set is
        # dropped with it so the new stack can ask again. Any job already in flight is
        # left to finish and land in the (now unused) cache rather than being aborted
        # mid-ffmpeg.
        $script:TrimStripPending = New-Object System.Collections.ArrayList
        $script:TrimRowMediaClaimed = @{}
        $script:TrimStripImages = @{}
        $script:TrimRowMediaDirty = $false
        try {
            $srcInfo = Get-Item -LiteralPath $path
            $waveKeySource = "{0}|{1}|{2:o}" -f $srcInfo.FullName.ToLowerInvariant(), $srcInfo.Length, $srcInfo.LastWriteTimeUtc
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $hash = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($waveKeySource)) |
                ForEach-Object { $_.ToString("x2") }) -join ""
            $md5.Dispose()
            $script:TrimWaveCacheDir = Join-Path $env:LOCALAPPDATA ("FFmpegGUI\wavecache\" + $hash.Substring(0, 20))
            New-Item -ItemType Directory -Path $script:TrimWaveCacheDir -Force | Out-Null
        } catch {
            # Cache dir is an optimization only; on any failure fall back to the
            # per-launch temp dir and behave exactly as before.
            $script:TrimWaveCacheDir = $script:TrimThumbDir
        }

        # Same reasoning for the rendered fades, and the overlay has to be taken down as
        # well: it is keyed by source time, so leaving it up would show the previous
        # file's blend over the new file's footage.
        if ($script:TrimFadeProxyDir -and (Test-Path $script:TrimFadeProxyDir)) {
            Remove-Item -LiteralPath $script:TrimFadeProxyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:TrimFadeProxyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-fades-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TrimFadeProxyDir -Force | Out-Null
        $script:TrimFadeProxies = @{}
        $script:TrimFadeProxyPending = @{}
        $script:TrimFadeOverlayKey = $null
        if ($null -ne $mediaTrimFadePreview) {
            $mediaTrimFadePreview.Visibility = "Collapsed"
            $mediaTrimFadePreview.Source = $null
        }

        if ($projectUnreadable) {
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text "Couldn't read the saved project for this video. Starting fresh."
        } elseif ($droppedZooms -gt 0) {
            # A warning, not an error: everything else in the project loaded fine and the
            # editor is perfectly usable -- there are simply fewer keyframes than there were.
            $noun = if ($droppedZooms -eq 1) { "zoom keyframe" } else { "zoom keyframes" }
            $verb = if ($droppedZooms -eq 1) { "couldn't be read and was skipped" }
                    else { "couldn't be read and were skipped" }
            Show-PanelMessage -Block $textTrimMeta -IsWarning `
                -Text ("{0} {1} {2}" -f $droppedZooms, $noun, $verb)
        } else {
            Show-PanelMessage -Block $textTrimMeta -Text ""
        }
        $cardTrimEditor.Visibility = "Visible"
        $mediaTrimPreview.Source = New-Object System.Uri($path)
        $mediaTrimPreview.Pause()
        $buttonTrimExport.IsEnabled = $true
        # Picking a second file must not leave the previous file's selection on screen,
        # nor its Delete button live against an index into a cut list that is now gone.
        $buttonTrimDelete.IsEnabled = $false
        # Nothing is selected in the new file, so the properties column must not be left
        # open over the previous file's caption.
        Hide-CaptionSidebar
        Update-TrimSelectionText
        Update-TrimTimeline
        # AFTER Update-TrimTimeline, not before: the readout's denominator is the cached
        # timeline length, and the load-path refresh of that cache is inside
        # Update-TrimTimeline -- painted first, a montage project shows V1's length until
        # the next repaint.
        Update-TrimPosition
        # After the load, not just the reset above: a project whose first keyframe sits AT
        # 0:00 zoomed is zoomed from the very first frame, so leaving the preview at
        # identity until the first scrub would show a picture the model does not agree
        # with. Posted at Loaded priority because PreviewZoomHost has no
        # ActualWidth yet on the pass that makes the card visible, and the translate is
        # computed from it -- called inline it would centre on a zero-sized box.
        # GetNewClosure: the block runs after this handler has returned. Read-only capture,
        # so no $script: write can land in the closure's private module.
        if ($null -ne $previewZoomHost) {
            $previewZoomHost.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Loaded,
                [action]({
                    Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
                    # Same reasoning as the zoom: PreviewBox has no size yet on the pass
                    # that makes the card visible, so a restored project's PiP tracks would
                    # otherwise sit invisible/mispositioned until the next tick or scrub.
                    Update-TrimPreviewStackOrder
                    Update-PipPreview -SourceSeconds $script:TrimPlayhead -Seek $true
                    Update-TrimBlackBase
                }.GetNewClosure())) | Out-Null
        }
        Start-TrimKeyframeRead -Path $path

        # With a file open, the huge dropzone and the recent list are just 400 vertical
        # pixels standing between the user and the timeline -- the whole reason the
        # editor used to need scrolling on a 1440p screen. They collapse here and the
        # small "Open another video" button in the transport row takes over their job
        # (it raises the dropzone's own Click, so the file dialog flow stays identical).
        if ($null -ne $buttonTrimBrowse) { $buttonTrimBrowse.Visibility = "Collapsed" }
        if ($null -ne $cardRecentTrim) { $cardRecentTrim.Visibility = "Collapsed" }
        if ($null -ne $buttonTrimOpenAnother) { $buttonTrimOpenAnother.Visibility = "Visible" }
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
        # Fade length picker. Selection is carried on Tag, which the button template's
        # trigger styles -- the same "set state from code, let the template react" shape
        # the rest of this panel uses.
        #
        # It edits the ACTIVE fade (the pill last clicked), falling back to setting the
        # default for the next one when no fade is selected. Applying to every fade at
        # once, which is what this used to do, makes a per-cut decision impossible.
        function Sync-TrimFadeLengthButtons {
            $current = if ($null -ne $script:TrimActiveFade) {
                Get-TrimFadeLength -SourceSeconds $script:TrimActiveFade
            } else {
                $script:TrimFadeSeconds
            }
            foreach ($entry in $fadeLengthButtons.GetEnumerator()) {
                if ($null -eq $entry.Value) { continue }
                $entry.Value.Tag = if ([math]::Abs($entry.Key - $current) -lt 0.001) { "selected" } else { "" }
            }
        }

        function Set-TrimFadeSeconds {
            param([double]$Seconds)
            # Always update the default too, so the next fade added matches the last
            # length chosen rather than snapping back to 0.5s.
            $script:TrimFadeSeconds = $Seconds
            if ($null -ne $script:TrimActiveFade) {
                Set-TrimFade -SourceSeconds $script:TrimActiveFade -Enabled $true -Seconds $Seconds
            }
            Sync-TrimFadeLengthButtons
            Update-TrimTimeline
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            Request-TrimProjectSave
        }

        foreach ($entry in $fadeLengthButtons.GetEnumerator()) {
            if ($null -eq $entry.Value) { continue }
            $seconds = [double]$entry.Key
            $entry.Value.Add_Click({ Set-TrimFadeSeconds -Seconds $seconds }.GetNewClosure())
        }
        Sync-TrimFadeLengthButtons

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

            # Assigned directly, never wrapped in @(): Get-TrimFadeFlags returns a
            # [bool[]] via ",(...)", and @() around that produces a one-element array
            # holding the bool[] -- which then fails to bind to Export-CutListAsync's
            # [bool[]] parameter with "cannot convert Boolean[] to Boolean" and takes
            # the whole window down, since this runs inside the message loop.
            $fadeLengths = Get-TrimFadeLengths -Pieces $pieces
            $anyFade = @($fadeLengths | Where-Object { $_ -gt 0 }).Count -gt 0

            # [object[]] cast for the same reason Get-TrimFadeLengths casts: an empty
            # bare @() binds to a typed array parameter as $null, and an empty caption
            # list is the normal case for a plain trim.
            $captions = [object[]]@($script:TrimCaptions)
            $anyCaption = @($captions | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Text) }).Count -gt 0

            # [object[]] cast for the same reason the captions get one: an empty bare @()
            # binds to a typed array parameter as $null, and no keyframes at all is the
            # normal case for a plain trim.
            $zooms = [object[]]@($script:TrimZooms)
            $zoomSpans = Get-TrimZoomSpans -Zooms $zooms -Pieces $pieces
            $anyZoom = $zoomSpans.Count -gt 0

            if ($anyFade -or $anyCaption -or $anyZoom) {
                # Both crossfades and burned captions re-encode the segments they touch,
                # and only h264/hevc have an encoder mapped. Anything else would splice a
                # differently-coded segment between copied ones and produce a file that
                # changes codec halfway through.
                $sourceProfile = Get-TrimSourceProfile -InputFile $script:TrimInputFile
                if (-not $sourceProfile.VideoEncoder) {
                    $reason = if ($anyFade) { "Fades need to re-encode across each cut" }
                        elseif ($anyCaption) { "Burning captions needs to re-encode the parts they cover" }
                        else { "Zooming needs to re-encode the parts it covers" }
                    Show-PanelMessage -Block $textTrimMeta -IsError -Text (
                        "{0}, and this file's video codec ({1}) is not one this app can re-encode. Remove them to export with plain cuts." -f $reason, $sourceProfile.VideoCodec)
                    return
                }
            }
            if ($anyFade) {
                $problem = Get-TrimFadeProblem -Pieces $pieces
                if ($problem) {
                    Show-PanelMessage -Block $textTrimMeta -IsError -Text $problem
                    return
                }
            }

            # A crossfade eats the outgoing piece's last fade-length of footage and blends
            # it with the next piece's head in one xfade pass. There is nowhere in that
            # pass to also apply a per-side crop, so a zoom overlapping a fade would have
            # to be silently dropped -- refuse instead. The windows match exactly the
            # footage the transition segment consumes, which is what
            # Split-TrimSegmentsForZooms throws on if one ever slips through.
            #
            # BOTH halves have to be tested. The transition eats the outgoing piece's last
            # $len seconds AND the incoming piece's first $len seconds, and a zoom sitting
            # only over the incoming head is just as impossible to render: the preview
            # glides through it while the export hard-cuts to the zoom level the following
            # segment starts at.
            if ($anyZoom -and $anyFade) {
                $clash = $false
                for ($b = 0; $b -lt $pieces.Count - 1 -and -not $clash; $b++) {
                    if ($b -ge $fadeLengths.Count) { break }
                    $len = [double]$fadeLengths[$b]
                    if ($len -le 0) { continue }
                    $windows = @(
                        @{ Start = ([double]$pieces[$b].End - $len); End = [double]$pieces[$b].End },
                        @{ Start = [double]$pieces[$b + 1].Start; End = ([double]$pieces[$b + 1].Start + $len) }
                    )
                    foreach ($w in $windows) {
                        foreach ($span in $zoomSpans) {
                            if ([double]$span.Start -lt [double]$w.End -and [double]$span.End -gt [double]$w.Start) {
                                $clash = $true
                                break
                            }
                        }
                        if ($clash) { break }
                    }
                }
                if ($clash) {
                    Show-PanelMessage -Block $textTrimMeta -IsError `
                        -Text "Move the zoom or the fade -- a zoomed crossfade isn't supported yet."
                    return
                }
            }

            # ---- Lane pre-flight refusals ----
            #
            # An empty stack (every lane, or every clip, deleted) has nothing left to
            # export -- checked before the missing-file scan below, which would otherwise
            # just report nothing at all with no explanation.
            $laneCount = @($script:TrimLanes).Count
            $clipTotal = 0
            foreach ($l in @($script:TrimLanes)) { $clipTotal += @($l.Clips).Count }
            if ($laneCount -eq 0 -or $clipTotal -eq 0) {
                Show-PanelMessage -Block $textTrimMeta -IsError -Text "Every track was deleted -- nothing to export."
                return
            }
            # Missing external files (main-path clips are the loaded file, always present).
            # A clip's file can vanish between being added and export time (moved, renamed,
            # deleted, or a removable drive unplugged) -- caught here rather than letting
            # ffmpeg fail deep inside the rebuild pipeline with an opaque error.
            $missing = $null
            foreach ($l in @($script:TrimLanes)) {
                foreach ($c in @($l.Clips)) {
                    if ($c.Path -ne $script:TrimInputFile -and -not (Test-Path -LiteralPath $c.Path)) { $missing = $c; break }
                }
                if ($null -ne $missing) { break }
            }
            if ($null -ne $missing) {
                Show-PanelMessage -Block $textTrimMeta -IsError `
                    -Text ("Can't find {0} -- it moved or was deleted." -f [System.IO.Path]::GetFileName($missing.Path))
                return
            }
            # Overlay spans, TIMELINE (compacted) time -- built once here and reused both for
            # the transition-clash refusal and the export call site itself.
            $overlaySpans = Get-TrimOverlaySpans -Lanes @($script:TrimLanes) -MainPath $script:TrimInputFile -ClipDurations $script:TrimClipDurations
            # Same reasoning as the zoomed-crossfade refusal above: an overlay has nowhere to
            # composite onto during a crossfade's own xfade pass. Test-PipTransitionClash
            # (Tracks.psm1) already carries the Task 4-adjudicated [T, T+d] window semantics
            # -- called here rather than reimplemented, and the overlay spans carry the same
            # Start/End keys the v2 pip spans did.
            if (Test-PipTransitionClash -PipSpans @($overlaySpans) -Pieces $pieces -FadeLengths $fadeLengths) {
                Show-PanelMessage -Block $textTrimMeta -IsError `
                    -Text "Move the clip or the fade -- a clip over a crossfade isn't supported yet."
                return
            }
            # The full timeline, including any lane content that runs past the last piece --
            # the export extends the video with black rather than truncating it.
            $timelineLength = Get-TrimTimelineLength -Lanes @($script:TrimLanes) -Pieces $pieces -FadeLengths $fadeLengths `
                -ClipDurations $script:TrimClipDurations -MainPath $script:TrimInputFile

            # Fonts are resolved by libass at burn time, from the fonts installed on THIS
            # machine. A name that is not installed still exports -- libass substitutes --
            # so this warns and carries on rather than refusing: a blocked export helps
            # nobody when the only consequence is a different typeface.
            $missingFonts = @(@($captions |
                Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Text) } |
                ForEach-Object { [string]$_.FontFamily } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique) |
                Where-Object { $name = $_
                    -not (@([System.Windows.Media.Fonts]::SystemFontFamilies) |
                        Where-Object { $_.Source -eq $name }).Count })
            if ($missingFonts.Count -gt 0) {
                Show-PanelMessage -Block $textTrimMeta -IsWarning -Text (
                    "This PC has no font called {0}, so those captions will burn in a substitute typeface." -f ($missingFonts -join ", "))
            } else {
                Show-PanelMessage -Block $textTrimMeta -Text ""
            }
            # -Lanes @($script:TrimLanes), never a bare $script:TrimLanes: the PS 5.1
            # @($null).Count -eq 1 trap means a null reaching the binder here would silently
            # take a different export branch instead of erroring -- but TrimLanes is never
            # actually $null (same invariant Set-TrimLanes/the file-load reset both keep),
            # so this is belt-and-suspenders, not a fix for a real null. $overlaySpans is
            # already a real array built above; @() around it is the same defensive habit.
            Register-Job (Export-CutListAsync -Context $ctx -InputFile $script:TrimInputFile -Pieces $pieces `
                -FadeLengths $fadeLengths -Captions $captions -Zooms $zooms `
                -Lanes @($script:TrimLanes) -ClipDurations $script:TrimClipDurations -OverlaySpans @($overlaySpans) `
                -TimelineLength $timelineLength `
                -SourceAudioStreamCount $script:TrimSourceAudioStreamCount `
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

    # The trim editor's scratch directories live for the session. Thumbnails are a few
    # hundred KB, but the rendered fades are real mp4s, so leaving a set behind per run
    # accumulates in %TEMP% with nothing to ever clear it.
    $ctx.Window.Add_Closed({
        # Unconditional, timer bypassed: closing within a second of the last edit would
        # otherwise take the debounced save down with the window. Save-TrimProject
        # swallows its own failures, and there is no panel left to report one to anyway.
        if ($script:TrimInputFile) {
            Save-TrimProject -VideoPath $script:TrimInputFile -CutList @($script:TrimCutList) `
                -Fades $script:TrimFades -Captions @($script:TrimCaptions) -Zooms @($script:TrimZooms) `
                -Lanes @($script:TrimLanes) | Out-Null
        }
        foreach ($dir in @($script:TrimThumbDir, $script:TrimFadeProxyDir)) {
            if ($dir -and (Test-Path $dir)) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    })

    Show-Panel -Context $ctx -Name "Compress"
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
