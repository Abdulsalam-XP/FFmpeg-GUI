# 40-zoom-preview.ps1 -- zoom keyframes, zoom lane, preview zoom.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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
