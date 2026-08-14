# 20-timeline-math.ps1 -- time/x conversions, timeline pieces, fades/captions/zooms accessors.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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
        # Every mutating action still funnels here; it only MARKS now, never writes.
        $script:TrimProjectDirty = $true
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
