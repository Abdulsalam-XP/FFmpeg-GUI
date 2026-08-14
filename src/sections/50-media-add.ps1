# 50-media-add.ps1 -- add track/clip flows, Add-TrimMediaFromPath, pip box drag.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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
            [double]$AtTimeline = -1.0,
            # Drop ergonomics (user ask, 2026-08-14): a file dropped on an unsuitable row
            # (a video on V1, audio on a video lane) lands on a FRESH lane instead of
            # bouncing off with a warning...
            [switch]$NewLaneOnRefusal,
            # ...and a file dropped on the open lane area below the rows always gets its
            # own new track -- "drag a video in" must not require "+ Video track" first.
            [switch]$ForceNewLane
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
            if ($NewLaneOnRefusal) {
                $ForceNewLane = $true
            } else {
                Show-PanelMessage -Block $textTrimMeta -IsWarning -Text $refusal
                return
            }
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
        $lane = if ($ForceNewLane) {
            Add-TrimLaneRow -Kind $laneKind
        } else {
            Get-TrimAddTargetLane -Kind $laneKind -TargetLaneId $TargetLaneId
        }
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
