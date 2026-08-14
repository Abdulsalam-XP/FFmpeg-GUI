# 10-shell-panels.ps1 -- compress/merge panels, jobs, recents renderer, dropzones.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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
            $recentLeaf = [System.IO.Path]::GetFileName($entry.Path)
            $name.Text = $recentLeaf
            $name.Foreground = $ctx.Window.FindResource("BrushTextPrimary")
            $name.FontFamily = $ctx.Window.FindResource("FontChrome")
            $name.FontSize = 12.5
            $name.FontWeight = "SemiBold"
            # A long filename must not push the MOST RECENT pill off the card.
            $name.TextTrimming = "CharacterEllipsis"
            if ([string]$entry.Job -eq "Saved") {
                # A "Saved" row is a restorable edit, not just a recently touched file --
                # the label is gold and GLOWS so it reads at a glance (user ask
                # 2026-08-14: "more apparent, glowy"). DockPanel, not StackPanel: the
                # filename keeps a finite width so its ellipsis still works.
                $nameLine = New-Object System.Windows.Controls.DockPanel
                $nameLine.LastChildFill = $true
                $savedTag = New-Object System.Windows.Controls.TextBlock
                $savedTag.Text = "Saved file:"
                $savedTag.FontFamily = $ctx.Window.FindResource("FontChrome")
                $savedTag.FontSize = 12.5
                $savedTag.FontWeight = "Bold"
                $savedTag.Foreground = $ctx.Window.FindResource("BrushGoldValue")
                $savedTag.Margin = New-Object System.Windows.Thickness(0, 0, 5, 0)
                $tagGlow = New-Object System.Windows.Media.Effects.DropShadowEffect
                $tagGlow.ShadowDepth = 0
                $tagGlow.BlurRadius = 9
                $tagGlow.Opacity = 0.95
                $goldBrushSaved = $ctx.Window.FindResource("BrushGoldValue")
                if ($goldBrushSaved -is [System.Windows.Media.SolidColorBrush]) { $tagGlow.Color = $goldBrushSaved.Color }
                $savedTag.Effect = $tagGlow
                [System.Windows.Controls.DockPanel]::SetDock($savedTag, [System.Windows.Controls.Dock]::Left)
                [void]$nameLine.Children.Add($savedTag)
                [void]$nameLine.Children.Add($name)
                $stack.Children.Add($nameLine) | Out-Null
            } else {
                $stack.Children.Add($name) | Out-Null
            }

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
