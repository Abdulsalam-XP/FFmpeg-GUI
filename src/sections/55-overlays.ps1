# 55-overlays.ps1 -- caption overlay, zoom box + pill, fade proxies/overlay.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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
        try { return ((New-LookBrushConverter)).ConvertFromString($Hex) }
        catch { return ((New-LookBrushConverter)).ConvertFromString($Fallback) }
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
        # InvariantCulture: "{0:N1}" follows the OS locale, and on comma-decimal systems
        # the badge read "2,5x". The badge is a ratio, not prose; it renders the same
        # everywhere.
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        if ([math]::Abs($BoxW - $BoxH) -lt 0.005) { return ($zx.ToString("0.0", $inv) + "x") }
        return ($zx.ToString("0.0", $inv) + "x / " + $zy.ToString("0.0", $inv) + "x")
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
