# 35-lane-rows.ps1 -- Update-TrimLaneRows, overlay, clip props, faders, reorder.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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

        $bc = (New-LookBrushConverter)
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
                # -NewLaneOnRefusal: a video dropped on V1 (or on a mismatched-kind row)
                # lands on a freshly created lane instead of bouncing off with a warning.
                $t = Convert-TrimXToTime -X ($e.GetPosition($canvasTrimTimeline)).X
                foreach ($f in $files) {
                    Add-TrimMediaFromPath -Path ([string]$f) -TargetLaneId $thisId -AtTimeline ([math]::Max(0.0, $t)) -NewLaneOnRefusal
                }
                $e.Handled = $true
            }.GetNewClosure())

            # Clicking EMPTY strip space jumps the playhead there -- and holding keeps
            # scrubbing -- like every NLE. Clip bodies mark their presses Handled, so this
            # bubbling handler only ever fires on bare row background; header-column
            # clicks (left of the strip, negative canvas x) keep selecting the lane.
            $rowGrid.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                if ($e.Handled) { return }
                $bgX = ($e.GetPosition($canvasTrimTimeline)).X
                if ($bgX -lt 0) { return }
                Set-TrimScrubFromX -X $bgX
                $script:TrimScrubDrag = $true
                # Capture on the PANEL, never this row: the jump's full repaint rebuilds
                # every row, so this grid is already detached by the time the capture
                # would matter. The panel persists and carries the shared move/up handlers.
                if ($null -ne $panelTrimLanes) { [void]$panelTrimLanes.CaptureMouse() }
                $e.Handled = $true
            })
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
            } elseif ($isMainLane) {
                # User pick (2026-08-15): the MAIN lane wears the gold accent so V1 reads
                # as "the" track at a glance -- the same spine language its grouped audio
                # rows already speak, one notch bolder.
                $mainSpine = New-Object System.Windows.Controls.Border
                $mainSpine.Width = 3
                $mainSpine.Background = $goldBrush
                [System.Windows.Controls.DockPanel]::SetDock($mainSpine, "Left")
                [void]$headHost.Children.Add($mainSpine)
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
                # A source row whose stream is still EXTRACTING (the one-time headroom
                # decode after load) shows an ellipsis: without it the fader looks done
                # while the stream is still seconds from being audible.
                if ($null -ne $head -and [string]$head.Path -eq [string]$script:TrimInputFile -and
                    $script:TrimSourceStreamPending.ContainsKey([string]([int]$head.StreamIdx))) {
                    $badge.Text = $badge.Text + [string][char]0x2026
                }
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
        $line.Stroke = ((New-LookBrushConverter)).ConvertFromString("#E64A3C")
        $line.StrokeThickness = 2
        [void]$canvasTrimLaneOverlay.Children.Add($line)
        # A grab wedge at the top of the line, matching the ruler's: the line is
        # draggable (the near-line press handler on the lane panel starts a scrub), and
        # a bare 2px line does not look like something you can hold.
        $wedge = New-Object System.Windows.Shapes.Polygon
        $wedgePoints = New-Object System.Windows.Media.PointCollection
        $wedgePoints.Add((New-Object System.Windows.Point(0, 0)))
        $wedgePoints.Add((New-Object System.Windows.Point(16, 0)))
        $wedgePoints.Add((New-Object System.Windows.Point(8, 10)))
        $wedge.Points = $wedgePoints
        $wedge.Fill = ((New-LookBrushConverter)).ConvertFromString("#E64A3C")
        [System.Windows.Controls.Canvas]::SetLeft($wedge, $x - 8)
        [System.Windows.Controls.Canvas]::SetTop($wedge, 0)
        [void]$canvasTrimLaneOverlay.Children.Add($wedge)
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
        # up with the model without a second call at each of those sites. Gain changes are
        # pure element-volume math now (headroom extraction), so volume IS the whole sync.
        Update-TrimPreviewVolume
        # New EXTERNAL audio clips (a drop, an undo, a restored project) start their
        # one-time headroom extraction here.
        Sync-TrimExtAudioWavs
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

    # Superseded shim: the per-stream preview (Update-TrimSourceAudioPreview) replaced the
    # old "first unmuted row's gain on the single decoder" collapse -- every source stream
    # has its own playback element now, each following its own row's fader and mute. Kept
    # under the old name so every existing refresh point keeps working.
    function Update-TrimPreviewVolume {
        Update-TrimSourceAudioPreview -Playing ($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
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
        $line.Stroke = ((New-LookBrushConverter)).ConvertFromString("#E0C48F")
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
            $major = ((New-LookBrushConverter)).ConvertFromString("#5A7EA8")
            $minor = ((New-LookBrushConverter)).ConvertFromString("#2A3B52")
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
