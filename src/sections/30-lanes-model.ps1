# 30-lanes-model.ps1 -- lane/clip model ops, selection, snap, clip drag.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

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
    function Test-TrimStackHasAnyClip {
        foreach ($lane in @($script:TrimLanes)) {
            if (@($lane.Clips).Count -gt 0) { return $true }
        }
        return $false
    }

    # Deleting the LAST content closes the file: an editor showing (and playing!) a video
    # whose every track was deleted is a lie, and the dropzone is what "nothing loaded"
    # looks like (user ask, 2026-08-14). The lanes are wiped to a truly empty list before the
    # flush-save so the sidecar records "no lanes" -- the reader then rebuilds the DEFAULT
    # stack on the next load instead of restoring emptiness.
    function Reset-TrimEditorToDropzone {
        if (-not $script:TrimInputFile) { return }
        Set-TrimLanes -Lanes @()
        Save-TrimProject -VideoPath $script:TrimInputFile `
            -CutList @($script:TrimCutList) -Fades $script:TrimFades -Captions @($script:TrimCaptions) `
            -Zooms @($script:TrimZooms) -Lanes @() | Out-Null
        $script:TrimProjectDirty = $false
        if ($null -ne $script:TrimTimer) { $script:TrimTimer.Stop() }
        try { $mediaTrimPreview.Stop() } catch {}
        try { $mediaTrimPreview.Source = $null } catch {}
        if ($null -ne $buttonTrimPlay) { $buttonTrimPlay.Content = "Play" }
        Clear-TrimClipMediaElementPools
        Clear-TrimSourceStreamAudio
        # A cleared editor has no history to walk back into -- undo would restore lanes
        # against a file that is no longer open.
        if ($null -ne $script:TrimUndoStack) { $script:TrimUndoStack.Clear() }
        if ($null -ne $script:TrimRedoStack) { $script:TrimRedoStack.Clear() }
        if ($null -ne $buttonTrimUndo) { $buttonTrimUndo.IsEnabled = $false }
        if ($null -ne $buttonTrimRedo) { $buttonTrimRedo.IsEnabled = $false }
        $script:TrimInputFile = $null
        if ($null -ne $cardTrimEditor) { $cardTrimEditor.Visibility = "Collapsed" }
        if ($null -ne $buttonTrimBrowse) { $buttonTrimBrowse.Visibility = "Visible" }
        if ($null -ne $cardRecentTrim) { $cardRecentTrim.Visibility = "Visible" }
        if ($null -ne $buttonTrimOpenAnother) { $buttonTrimOpenAnother.Visibility = "Collapsed" }
    }

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
        if (-not (Test-TrimStackHasAnyClip)) { Reset-TrimEditorToDropzone }
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
        if (-not (Test-TrimStackHasAnyClip)) { Reset-TrimEditorToDropzone }
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
            $accent = ((New-LookBrushConverter)).ConvertFromString("#3E9B84")
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
                $drag.Border.BorderBrush = ((New-LookBrushConverter)).ConvertFromString("#3E9B84")
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
        $line.Stroke = ((New-LookBrushConverter)).ConvertFromString("#3E9B84")
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
