# 60-undo-captions.ps1 -- undo/redo, split/delete, caption sidebar, position readout.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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
