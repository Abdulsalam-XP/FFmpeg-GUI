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
    "backend\ProjectFile.psm1",
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
        param($Block, [string]$Text, [switch]$IsError, [switch]$IsSuccess)
        $Block.Text = $Text
        # Error wins over success if both are somehow passed -- a wrong "done" is worse
        # than a redundant red.
        $Block.Foreground = if ($IsError) { $errorBrush } elseif ($IsSuccess) { $successBrush } else { $mutedBrush }
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
    $canvasTrimWave      = $panelTrim.FindName("CanvasTrimWave")
    $canvasTrimFades     = $panelTrim.FindName("CanvasTrimFades")
    $canvasTrimCaptions  = $panelTrim.FindName("CanvasTrimCaptions")
    $panelTrimFadeLength = $panelTrim.FindName("PanelTrimFadeLength")
    $textTrimFadeNote    = $panelTrim.FindName("TextTrimFadeNote")
    $textTrimFadeScope   = $panelTrim.FindName("TextTrimFadeScope")
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
    $buttonTrimExport    = $panelTrim.FindName("ButtonTrimExport")
    $buttonTrimAddCaption = $panelTrim.FindName("ButtonTrimAddCaption")
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
            -CutList @($script:TrimCutList) -Fades $script:TrimFades -Captions @($script:TrimCaptions)
        if (-not $ok -and -not $script:ProjectSaveWarned) {
            $script:ProjectSaveWarned = $true
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text "Couldn't save the project file next to the video. Edits won't survive closing the app."
        }
    })

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
            # +20, the waveform row's fixed height: the playhead is meant to read as one
            # line across the whole track, and stopping it at the filmstrip's bottom edge
            # left the waveform with no position marker at all. The enclosing Border clips
            # it, so it can never spill past the track.
            $head.Height = $h + 20
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
                    $badgeLeft = [math]::Max(0, [math]::Min($rulerWidth - $badgeWidth, $playX - $badgeWidth / 2))
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
            }
        }

        Update-TrimFadeToggles -Pieces $pieces -TimelinePieces $timelinePieces

        $textTrimPieces.Text = if ($pieces.Count -eq 1) { "1 piece" } else { "$($pieces.Count) pieces" }
        # The input-file test is not redundant with the count: it keeps Export disabled
        # during the first layout pass, before anything has been picked.
        $buttonTrimExport.IsEnabled = ($pieces.Count -gt 0 -and $null -ne $script:TrimInputFile)

        Update-TrimWaveform
        Update-TrimCaptionLane
    }

    # Waveform strip under the filmstrip, one image per piece that is at least partly on
    # screen -- one slot per piece instead of several like the filmstrip loop above, since
    # a whole piece's waveform is cheap to stretch across its own width. Guarded on
    # $canvasTrimWave being non-null: it is $null on XAML that predates this task, same
    # stale-XAML rule as the rest of the trim editor.
    # No -TimelinePieces param, deliberately: Set-TrimWaveform calls this after a render
    # lands, from inside a closured timer tick, and has no timeline state of its own to
    # hand in. Computing it here via Get-TrimTimelineState makes every caller -- the end
    # of Update-TrimTimeline and the render callback alike -- agree on current pieces
    # instead of the redraw silently running against stale or missing ones.
    function Update-TrimWaveform {
        if ($null -eq $canvasTrimWave) { return }
        $canvasTrimWave.Children.Clear()
        if (-not $script:TrimInputFile) { return }

        $timelinePieces = (Get-TrimTimelineState).TimelinePieces

        $waveWidth = $canvasTrimWave.ActualWidth
        if ($waveWidth -le 0) { $waveWidth = $canvasTrimTimeline.ActualWidth }
        $waveHeight = $canvasTrimWave.ActualHeight
        if ($waveHeight -le 0) { $waveHeight = 20 }

        foreach ($tp in @($timelinePieces)) {
            $x1 = Convert-TrimTimeToX -Seconds $tp.TimelineStart
            $x2 = Convert-TrimTimeToX -Seconds $tp.TimelineEnd
            # NOT clamped to the viewport, deliberately -- the cached bitmap covers this
            # piece's FULL source range, so squeezing it into a clipped visible sub-range
            # (the way the clamped version used to) stretches the whole waveform into
            # whatever sliver is on screen, misaligning it in time at any zoom/pan where
            # a piece runs off either edge. Full unclipped left/width keeps the bitmap
            # time-aligned; CanvasTrimWave's parent Border has ClipToBounds="True", the
            # same mechanism the filmstrip's piece containers rely on, so WPF crops the
            # overhang visually without any math here.
            if ($x2 -lt 0 -or $x1 -gt $waveWidth) { continue }
            $pieceWidth = $x2 - $x1
            if ($pieceWidth -le 0) { continue }

            $key = "{0:N2}_{1:N2}" -f $tp.SourceStart, $tp.SourceEnd
            if ($script:TrimWaveCache.ContainsKey($key)) {
                $img = New-Object System.Windows.Controls.Image
                $img.Stretch = "Fill"
                $img.Width = $pieceWidth
                $img.Height = $waveHeight
                $img.Source = $script:TrimWaveCache[$key]
                [System.Windows.Controls.Canvas]::SetLeft($img, $x1)
                [System.Windows.Controls.Canvas]::SetTop($img, 0)
                $canvasTrimWave.Children.Add($img) | Out-Null
            } else {
                Request-TrimWaveform -File $script:TrimInputFile -SourceStart $tp.SourceStart -SourceEnd $tp.SourceEnd
            }
        }
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
            $block.Width = $bounds.Width
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

    function Update-CaptionOverlay {
        param([double]$SourceSeconds)
        if ($null -eq $canvasCaptionOverlay) { return }
        $canvasCaptionOverlay.Children.Clear()
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

    # ---- Fade preview proxies ----
    #
    # Keyed on everything that changes what the render looks like: both sides of the cut
    # and the fade length. Changing the length, or moving the cut, therefore asks for a
    # different file rather than silently playing the old render.
    function Get-TrimFadeProxyKey {
        param([double]$OutgoingEnd, [double]$IncomingStart, [double]$FadeSeconds)
        return ("{0:N3}_{1:N3}_{2:N2}" -f $OutgoingEnd, $IncomingStart, $FadeSeconds)
    }

    # Write-through, same reason as Set-TrimThumbnail: called from a closured timer tick.
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
            else { $script:TrimFadeProxyPending.Remove($key) }
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
        }
    }

    # Split out from Push-TrimUndo so a drag can take its snapshot when it BEGINS and push
    # that same snapshot on release -- one undo step per completed drag rather than one per
    # mouse move.
    function Push-TrimUndoSnapshot {
        param($Snapshot)
        [void]$script:TrimUndoStack.Add($Snapshot)
        $buttonTrimUndo.IsEnabled = $true
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

    function Invoke-TrimUndo {
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return }
        if ($script:TrimUndoStack.Count -eq 0) { return }
        $last = $script:TrimUndoStack[$script:TrimUndoStack.Count - 1]
        $script:TrimUndoStack.RemoveAt($script:TrimUndoStack.Count - 1)
        $script:TrimCutList = @($last.List)
        $script:TrimSelected = $last.Selected
        # Entries pushed before captions existed have no Captions key; treating a missing
        # one as "no captions" would wipe the lane, so only restore what was recorded.
        if ($last.ContainsKey("Captions")) {
            Set-TrimCaptions -Captions $last.Captions
            Set-TrimSelectedCaption -Id $last.SelectedCaption
        }
        $buttonTrimDelete.IsEnabled = ($script:TrimSelected -ge 0)
        $buttonTrimUndo.IsEnabled = ($script:TrimUndoStack.Count -gt 0)
        Update-TrimSelectionText
        Update-TrimTimeline
        # The sidebar edits whatever is selected, so an undo that changed the selection --
        # including one that undid an add and left nothing selected -- has to move it.
        if ($null -eq (Get-TrimSelectedCaption)) { Hide-CaptionSidebar } else { Show-CaptionSidebar }
        # Undo changes the model as much as any edit does, so the saved project has to
        # follow it back -- otherwise closing the app restores the state that was undone.
        Request-TrimProjectSave
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
                $script:TrimThumbPending.Remove($key)
            }
        }.GetNewClosure())
        $watcher.Start()
    }

    # Waveform strips, one per timeline piece rather than per pixel slot -- a piece's
    # audio range is fixed once drawn (only split/delete changes it), so there is no
    # zoom-driven churn to guard against the way the filmstrip slots need. Same
    # write-through reasoning as Set-TrimThumbnail: called from a closured timer tick.
    function Set-TrimWaveform {
        param([string]$Key, [string]$FilePath)
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.UriSource = New-Object System.Uri($FilePath)
        $img.EndInit()
        $img.Freeze()
        $script:TrimWaveCache[$Key] = $img
        $script:TrimWavePending.Remove($Key)
        Update-TrimWaveform
    }

    # One background job per missing waveform strip, same shape as Request-TrimThumbnail.
    function Request-TrimWaveform {
        param([string]$File, [double]$SourceStart, [double]$SourceEnd)
        $key = "{0:N2}_{1:N2}" -f $SourceStart, $SourceEnd
        if ($script:TrimWaveCache.ContainsKey($key) -or $script:TrimWavePending.ContainsKey($key)) { return }
        # Same concurrency ceiling idea as the thumbnail cap, just lower: there are far
        # fewer pieces than filmstrip slots at once, so 4 in flight is already generous.
        if ($script:TrimWavePending.Count -ge 4) { return }
        $script:TrimWavePending[$key] = $true

        $outFile = Join-Path $script:TrimThumbDir ("w{0}.png" -f ($key -replace '[^\d]', ''))
        $duration = [math]::Max(0.01, $SourceEnd - $SourceStart)
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file, $start, $duration, $outFile)
            Import-Module $modulePath -Force
            Export-TrimWaveform -InputFile $file -StartSeconds $start -DurationSeconds $duration -OutputFile $outFile
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($File).AddArgument($SourceStart).AddArgument($duration).AddArgument($outFile) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(120)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()
            if (Test-Path $outFile) {
                Set-TrimWaveform -Key $key -FilePath $outFile
            } else {
                $script:TrimWavePending.Remove($key)
            }
        }.GetNewClosure())
        $watcher.Start()
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
                # The caption overlay has to be the VIDEO box, not the cell it shares with
                # the preview. Left to stretch, it takes the height of the tallest thing in
                # that Grid -- which is the 500px properties sidebar the moment a caption is
                # selected -- and every caption is then drawn against a box 170px taller
                # than the picture, landing well below where the export puts it. Pinned to
                # the same 16:9 box as the preview and centred on it, a caption at Y=0.78
                # sits at 78% of the frame here and at 78% of the frame in the export.
                if ($null -ne $canvasCaptionOverlay) {
                    $canvasCaptionOverlay.HorizontalAlignment = "Center"
                    $canvasCaptionOverlay.VerticalAlignment = "Center"
                    $canvasCaptionOverlay.Width = $e.NewSize.Width
                    $canvasCaptionOverlay.Height = $e.NewSize.Width * 9 / 16
                }
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
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            # After the fade overlay, not before: the fade owns the picture while it is up
            # and Update-CaptionOverlay reads the key it just set.
            Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
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
            # Scrubbing into a fade shows the blended frame too, not just playback.
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            # Scrubbing across a caption's window shows it appear and disappear on time.
            Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
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
                Clear-TrimCaptionSelection
            })

            $canvasCaptionOverlay.Add_MouseMove({
                param($eventSource, $e)
                if (-not (Test-CaptionOverlayDrag)) { return }
                $p = $e.GetPosition($canvasCaptionOverlay)
                Update-CaptionOverlayDrag -CurrentX $p.X -CurrentY $p.Y
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
            })

            $canvasCaptionOverlay.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (-not (Test-CaptionOverlayDrag)) { return }
                $canvasCaptionOverlay.ReleaseMouseCapture()
                Complete-CaptionOverlayDrag
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
            })

            # Opening or closing the sidebar takes 240px off the preview, so every X/Y
            # already converted to pixels is wrong until the next redraw.
            $canvasCaptionOverlay.Add_SizeChanged({ Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead })
        }

        if ($null -ne $buttonTrimAddCaption) { $buttonTrimAddCaption.Add_Click({ Invoke-TrimAddCaption }) }
        if ($null -ne $buttonCaptionDelete) { $buttonCaptionDelete.Add_Click({ Invoke-TrimDeleteCaption }) }

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

        # Flush the pending debounced save for the OUTGOING file before anything below
        # touches state -- same unconditional, timer-bypassed flush the window's Closed
        # handler does, and for the same reason. Without it, switching videos within a
        # second of an edit loses that edit, and worse, the still-armed timer would fire
        # later and write the NEW video's fresh state over the old file's project.
        if ($script:ProjectSaveTimer) { $script:ProjectSaveTimer.Stop() }
        if ($script:TrimInputFile) {
            Save-TrimProject -VideoPath $script:TrimInputFile -CutList @($script:TrimCutList) `
                -Fades $script:TrimFades -Captions @($script:TrimCaptions) | Out-Null
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
        $script:TrimSelected = -1
        $script:TrimPlayhead = 0.0
        $script:TrimViewStart = 0.0
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
        if ($project) {
            $script:TrimCutList = @($project.CutList)
            $script:TrimFades = $project.Fades
            $script:TrimCaptions = New-Object System.Collections.ArrayList
            foreach ($c in @($project.Captions)) { [void]$script:TrimCaptions.Add($c) }
        } elseif (Test-Path -LiteralPath (Get-TrimProjectPath -VideoPath $path)) {
            $projectUnreadable = $true
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
        # Waveform strips share the thumbnail temp dir (created just above) -- keyed by
        # source range instead of a single second, since a waveform covers a whole piece.
        $script:TrimWaveCache = @{}
        $script:TrimWavePending = @{}

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

            if ($anyFade -or $anyCaption) {
                # Both crossfades and burned captions re-encode the segments they touch,
                # and only h264/hevc have an encoder mapped. Anything else would splice a
                # differently-coded segment between copied ones and produce a file that
                # changes codec halfway through.
                $sourceProfile = Get-TrimSourceProfile -InputFile $script:TrimInputFile
                if (-not $sourceProfile.VideoEncoder) {
                    $reason = if ($anyFade) { "Fades need to re-encode across each cut" } else { "Burning captions needs to re-encode the parts they cover" }
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
                Show-PanelMessage -Block $textTrimMeta -IsError -Text (
                    "This PC has no font called {0}, so those captions will burn in a substitute typeface." -f ($missingFonts -join ", "))
            } else {
                Show-PanelMessage -Block $textTrimMeta -Text ""
            }
            Register-Job (Export-CutListAsync -Context $ctx -InputFile $script:TrimInputFile -Pieces $pieces `
                -FadeLengths $fadeLengths -Captions $captions `
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
                -Fades $script:TrimFades -Captions @($script:TrimCaptions) | Out-Null
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
    # startup failure would otherwise look like the app simply never opening.
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "FFmpeg GUI could not start.`n`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)",
        "FFmpeg GUI", "OK", "Error") | Out-Null
}
