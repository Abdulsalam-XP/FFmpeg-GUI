# 25-timeline-strip.ps1 -- Update-TrimTimeline, ruler, fade toggles, caption lane.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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

        # The horizontal scrollbar mirrors the view window. Sync-guarded: writing Value
        # here fires ValueChanged, whose handler would otherwise re-enter this repaint.
        if ($null -ne $scrollTrimView) {
            $script:TrimViewScrollSync = $true
            $sbMax = $(if ($timelineLength -gt 0) { [math]::Max(0.0, (Get-TrimViewMax -TimelineLength $timelineLength) - $script:TrimViewSpan) } else { 0.0 })
            $scrollTrimView.Minimum = 0.0
            $scrollTrimView.Maximum = $sbMax
            $scrollTrimView.ViewportSize = $script:TrimViewSpan
            $scrollTrimView.SmallChange = $script:TrimViewSpan * 0.1
            $scrollTrimView.LargeChange = $script:TrimViewSpan * 0.9
            $scrollTrimView.Value = [math]::Min($sbMax, [math]::Max(0.0, $script:TrimViewStart))
            $scrollTrimView.Visibility = $(if ($script:TrimInputFile) { "Visible" } else { "Collapsed" })
            $script:TrimViewScrollSync = $false
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
            $points.Add((New-Object System.Windows.Point(16, 0)))
            $points.Add((New-Object System.Windows.Point(8, 10)))
            $grip.Points = $points
            [System.Windows.Controls.Canvas]::SetLeft($grip, $playX - 8)
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
                    $rulerGripPoints.Add((New-Object System.Windows.Point(16, 0)))
                    $rulerGripPoints.Add((New-Object System.Windows.Point(8, 10)))
                    $rulerGrip.Points = $rulerGripPoints
                    [System.Windows.Controls.Canvas]::SetLeft($rulerGrip, $playX - 8)
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
