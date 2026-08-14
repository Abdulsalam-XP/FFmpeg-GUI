# 45-preview-pools.ps1 -- media element pools, pip/audio preview, source-stream + ext audio.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

    function Remove-TrimClipMediaElement {
        param([string]$Id)
        if ($script:PipMediaElements.ContainsKey($Id)) {
            $el = $script:PipMediaElements[$Id].Element
            try { $el.Stop() } catch {}
            try { $el.Close() } catch {}
            if ($null -ne $previewCell -and $previewCell.Children.Contains($el)) { $previewCell.Children.Remove($el) | Out-Null }
            $script:PipMediaElements.Remove($Id)
        }
        # A still has no media to stop -- pulling the Image out of the visual tree and
        # dropping the entry is the whole teardown (the BitmapImage it points at is freed
        # with it).
        if ($script:ImageElements.ContainsKey($Id)) {
            $img = $script:ImageElements[$Id].Element
            if ($null -ne $previewCell -and $previewCell.Children.Contains($img)) { $previewCell.Children.Remove($img) | Out-Null }
            $script:ImageElements.Remove($Id)
        }
        if ($script:AudioClipMediaElements.ContainsKey($Id)) {
            $entry = $script:AudioClipMediaElements[$Id]
            try { $entry.Element.Stop() } catch {}
            try { $entry.Element.Close() } catch {}
            $script:AudioClipMediaElements.Remove($Id)
        }
    }

    # Prunes both pools down to the clips that still exist. Called from Update-TrimLaneRows
    # (every structural change -- add, delete, undo/redo, unlink, load) so an undone add or
    # a deleted clip never leaves an orphaned MediaElement sitting in the visual tree (or,
    # for an audio clip, silently still playing off-tree). Keyed by CLIP id.
    function Sync-TrimClipMediaElementPools {
        $liveIds = @{}
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
                $liveIds[[string]$c.Id] = $true
            }
        }
        foreach ($id in @($script:PipMediaElements.Keys)) { if (-not $liveIds.ContainsKey($id)) { Remove-TrimClipMediaElement -Id $id } }
        foreach ($id in @($script:ImageElements.Keys)) { if (-not $liveIds.ContainsKey($id)) { Remove-TrimClipMediaElement -Id $id } }
        foreach ($id in @($script:AudioClipMediaElements.Keys)) { if (-not $liveIds.ContainsKey($id)) { Remove-TrimClipMediaElement -Id $id } }
    }

    # Clears both pools entirely -- used only when the whole session's file changes, since a
    # fresh file's tracks are unrelated to whatever clips the previous one had loaded.
    function Clear-TrimClipMediaElementPools {
        foreach ($id in @($script:PipMediaElements.Keys)) { Remove-TrimClipMediaElement -Id $id }
        foreach ($id in @($script:ImageElements.Keys)) { Remove-TrimClipMediaElement -Id $id }
        foreach ($id in @($script:AudioClipMediaElements.Keys)) { Remove-TrimClipMediaElement -Id $id }
    }

    # Both preview-element factories put their element in the SAME slot: PreviewCell's
    # visual tree AFTER PreviewZoomHost (and after the black montage base) and BEFORE
    # CanvasCaptionOverlay, so the picture sits over the main preview but under the
    # caption/PiP-box overlay. Insert order among themselves is paint order, which
    # Update-TrimPreviewStackOrder re-asserts on every structural rebuild.
    function Add-TrimPreviewElement {
        param($Element)
        if ($null -eq $previewCell -or $null -eq $canvasCaptionOverlay) { return }
        $idx = $previewCell.Children.IndexOf($canvasCaptionOverlay)
        if ($idx -ge 0) { $previewCell.Children.Insert($idx, $Element) } else { $previewCell.Children.Add($Element) | Out-Null }
    }

    # One MediaElement per overlay video CLIP, built once and reused. The entry is
    # @{ Element; InSpan } exactly like the audio pool's: InSpan is "this element was
    # already showing its own footage last time we looked", which is what lets
    # Update-PipPreview skip the Position write on the 19 ticks out of 20 that only move
    # the playhead a few frames inside a span the element is already playing.
    function Get-PipMediaElement {
        param($Clip)
        $Track = $Clip
        $id = [string]$Track.Id
        if (-not $script:PipMediaElements.ContainsKey($id)) {
            $el = New-Object System.Windows.Controls.MediaElement
            $el.LoadedBehavior = "Manual"
            $el.UnloadedBehavior = "Manual"
            # Stretch is per-update now (Uniform full-frame, Fill boxed), not fixed here.
            $el.Stretch = "Fill"
            $el.IsHitTestVisible = $false
            $el.Volume = 0
            $el.Visibility = "Collapsed"
            try { $el.Source = New-Object System.Uri([string]$Track.Path) } catch {}
            Add-TrimPreviewElement -Element $el
            $script:PipMediaElements[$id] = @{ Element = $el; InSpan = $false }
        }
        return $script:PipMediaElements[$id]
    }

    # One Image per still CLIP, same pool shape and same slot. The BitmapImage is decoded
    # ONCE (CacheOption OnLoad, so the file handle is released immediately and the decode
    # never repeats on a later layout pass) and then cached with the element -- a still
    # costs nothing per tick beyond a Visibility/geometry write.
    function Get-PipImageElement {
        param($Clip)
        $id = [string]$Clip.Id
        if (-not $script:ImageElements.ContainsKey($id)) {
            $el = New-Object System.Windows.Controls.Image
            $el.IsHitTestVisible = $false
            $el.Visibility = "Collapsed"
            $el.HorizontalAlignment = "Left"
            $el.VerticalAlignment = "Top"
            $el.Stretch = "Uniform"
            try {
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.UriSource = New-Object System.Uri([string]$Clip.Path)
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.EndInit()
                $el.Source = $bmp
            } catch {}
            Add-TrimPreviewElement -Element $el
            $script:ImageElements[$id] = @{ Element = $el; InSpan = $false }
        }
        return $script:ImageElements[$id]
    }

    # Paint order. WPF paints a Panel's children in index order, so "later in Children" is
    # "on top". The lane stack is drawn top row first, and the TOPMOST video row is the one
    # that covers the others (spec 3.1) -- so walking the lanes BOTTOM-UP and re-inserting
    # each element at the caption overlay's index leaves the topmost lane's element last,
    # i.e. on top. Re-asserted on every structural rebuild because a lane reorder changes
    # who covers whom without creating or destroying a single element.
    function Update-TrimPreviewStackOrder {
        if ($null -eq $previewCell -or $null -eq $canvasCaptionOverlay) { return }
        $lanes = @($script:TrimLanes)
        for ($i = $lanes.Count - 1; $i -ge 0; $i--) {
            $lane = $lanes[$i]
            if ($lane.Kind -ne "video") { continue }
            foreach ($c in @($lane.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
                $id = [string]$c.Id
                $el = $null
                if ($script:PipMediaElements.ContainsKey($id)) { $el = $script:PipMediaElements[$id].Element }
                elseif ($script:ImageElements.ContainsKey($id)) { $el = $script:ImageElements[$id].Element }
                if ($null -eq $el) { continue }
                if ($previewCell.Children.Contains($el)) { $previewCell.Children.Remove($el) }
                Add-TrimPreviewElement -Element $el
            }
        }
    }

    # The black montage base (spec 4.7). Past V1's own last frame the main MediaElement has
    # no frame to give and simply keeps showing the last one it decoded -- which would sit
    # under the montage clips as a frozen still instead of the black the export produces.
    # One Rectangle the size of the preview box, inserted directly ABOVE PreviewZoomHost
    # (so it covers that stale frame) and BELOW every clip element (so it never covers a
    # clip), shown only while the playhead is out past V1's end.
    function Update-TrimBlackBase {
        if ($null -eq $previewCell -or $null -eq $previewZoomHost -or $null -eq $script:PreviewBox) { return }
        if ($null -eq $script:TrimBlackBase) {
            $rect = New-Object System.Windows.Shapes.Rectangle
            $rect.Fill = ((New-LookBrushConverter)).ConvertFromString("#FF000000")
            $rect.IsHitTestVisible = $false
            $rect.HorizontalAlignment = "Left"
            $rect.VerticalAlignment = "Top"
            $rect.Visibility = "Collapsed"
            $script:TrimBlackBase = $rect
        }
        $base = $script:TrimBlackBase
        if (-not $previewCell.Children.Contains($base)) {
            # +1: directly after the host, which is below every clip element (those are
            # inserted at the caption overlay's index, further down the list).
            $hostIdx = $previewCell.Children.IndexOf($previewZoomHost)
            if ($hostIdx -ge 0) { $previewCell.Children.Insert($hostIdx + 1, $base) }
            else { $previewCell.Children.Add($base) | Out-Null }
        }
        $box = $script:PreviewBox
        $base.Width = [double]$box.W
        $base.Height = [double]$box.H
        $base.Margin = New-Object System.Windows.Thickness([double]$box.X, [double]$box.Y, 0, 0)
        $state = Get-TrimTimelineState
        $show = ((Get-TrimTimelinePlayhead) -gt ([double]$state.TotalDuration + 0.01))
        $base.Visibility = $(if ($show) { "Visible" } else { "Collapsed" })
    }

    # One MediaElement per audio-clip track, built once and reused -- but NEVER added to
    # any Panel's Children. WPF's MediaElement plays audio through the same MediaPlayer
    # regardless of whether it is in the visual tree; being off-tree just means it never
    # tries to render a frame nobody would see. InSpan tracks whether THIS element was
    # playing the last time it was checked, so Update-TrimAudioClipPreview can tell "just
    # entered the span" (seed Position once) from "still inside it" (let it run) without
    # re-seeking on every single tick.
    function Get-AudioClipMediaElement {
        param($Clip)
        $Track = $Clip
        $id = [string]$Track.Id
        if (-not $script:AudioClipMediaElements.ContainsKey($id)) {
            $el = New-Object System.Windows.Controls.MediaElement
            $el.LoadedBehavior = "Manual"
            $el.UnloadedBehavior = "Manual"
            try { $el.Source = New-Object System.Uri([string]$Track.Path) } catch {}
            $script:AudioClipMediaElements[$id] = @{ Element = $el; InSpan = $false; Path = [string]$Track.Path }
        }
        return $script:AudioClipMediaElements[$id]
    }

    # ---- Instant gain for EXTERNAL audio clips --------------------------------------
    # Same trick as the source streams (see Request-TrimSourceStreamAudio): decode once
    # to float PCM with the fader's whole +30dB range pre-applied, then every gain the
    # fader can ask for is pure element-volume attenuation. Keyed by PATH, so two clips
    # of the same song share one extraction.
    function Get-TrimExtAudioKey {
        param([string]$Path)
        return $Path.ToLowerInvariant()
    }

    function Request-TrimExtAudioWav {
        param([string]$Path)
        if (-not $script:TrimThumbDir) { return }
        $key = Get-TrimExtAudioKey -Path $Path
        if ($script:TrimExtAudioWav.ContainsKey($key) -or $script:TrimExtAudioPending.ContainsKey($key)) { return }
        $script:TrimExtAudioPending[$key] = $true
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hash = -join ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key)) | ForEach-Object { $_.ToString("x2") })
        $outFile = Join-Path $script:TrimThumbDir ("extaudio-" + $hash.Substring(0, 8) + ".wav")
        $srcFile = [string]$script:TrimInputFile
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file, $outFile)
            Import-Module $modulePath -Force
            Export-TrimAudioStream -InputFile $file -StreamIndex -1 -OutputFile $outFile -HeadroomDb 30.0
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($Path).AddArgument($outFile) | Out-Null
        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(500)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()
            Set-TrimExtAudioWav -Key $key -Path $outFile -ForFile $srcFile
        }.GetNewClosure())
        $watcher.Start()
    }

    function Set-TrimExtAudioWav {
        param([string]$Key, [string]$Path, [string]$ForFile)
        $script:TrimExtAudioPending.Remove($Key)
        # A different file may have switched in while ffmpeg ran; its load already wiped
        # the thumb dir this wav lived in.
        if ([string]$script:TrimInputFile -ne $ForFile) { return }
        if (Test-Path -LiteralPath $Path) { $script:TrimExtAudioWav[$Key] = $Path }
    }

    # Queues an extraction for every external audio clip on the timeline. Called from
    # Update-TrimClipProps (every row rebuild ends there: load, drop, undo, restore) --
    # cheap when nothing is new thanks to the ContainsKey guards.
    function Sync-TrimExtAudioWavs {
        if (-not $script:TrimInputFile -or -not $script:TrimThumbDir) { return }
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                if ($c.Kind -ne "audio") { continue }
                if ([string]$c.Path -eq [string]$script:TrimInputFile) { continue }
                Request-TrimExtAudioWav -Path ([string]$c.Path)
            }
        }
    }

    # Positions/plays every overlay clip's preview element against the TIMELINE playhead
    # (never source seconds -- a clip's Offset is a timeline position, exactly like a clip
    # bar drag writes). Called from the same places Update-PreviewZoom is: the transport
    # tick, every scrub, and the preview frame resize.
    #
    # Two geometries, decided by Pip (spec 4.6):
    #   full-frame (Pip $null) -- the element fills the WHOLE preview box with Stretch
    #     Uniform, so a clip whose aspect differs from the frame's is aspect-fit and the
    #     black bars come free: the black montage base (or the main picture) is what shows
    #     through beside it, which is exactly what the export's own scale+pad produces.
    #   boxed -- the Pip rectangle, Stretch Fill, unchanged from Task 8.
    #
    # -Seek is the difference between "the user jumped the playhead" and "50ms passed".
    # A scrub passes -Seek $true and every element re-seeks; the 20x/sec tick does not, so
    # an element that is already inside its own span is left alone to play (writing
    # Position on a playing MediaElement restarts its decode and stutters the picture).
    function Update-PipPreview {
        param([double]$SourceSeconds, [bool]$Seek = $false)
        if ($null -eq $previewCell -or $null -eq $script:PreviewBox) { return }
        $box = $script:PreviewBox
        $bw = [double]$box.W
        $bh = [double]$box.H
        # -SourceSeconds still decides the position while the playhead is inside the cut
        # list (every caller passes $script:TrimPlayhead, but the parameter is the contract).
        # Out in the montage region there is no source second to convert and the extension
        # offset is the only thing that knows where the playhead is.
        $timelinePlayhead = $(if (Test-TrimInExtension) { Get-TrimTimelinePlayhead } else {
            $state = Get-TrimTimelineState
            Convert-TrimSourceToTimeline -SourceSeconds $SourceSeconds -TimelinePieces $state.TimelinePieces
        })
        $playing =($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
        # BOTTOM-UP, the same order Update-TrimPreviewStackOrder inserts in: a newly built
        # element is added to the tree here, on the pass that first needs it, and doing it
        # in paint order means it lands on top of the lanes below it straight away rather
        # than waiting for the next structural rebuild to sort the stack out.
        #
        # Overlay clips only: the main lane's own video clip IS the main preview element.
        $overlays = @()
        $lanes = @($script:TrimLanes)
        for ($i = $lanes.Count - 1; $i -ge 0; $i--) {
            $lane = $lanes[$i]
            if ($lane.Kind -ne "video") { continue }
            foreach ($c in @($lane.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
                if ($c.Kind -ne "video" -and $c.Kind -ne "image") { continue }
                $overlays += ,@{ Lane = $lane; Clip = $c }
            }
        }
        foreach ($o in $overlays) {
            $t = $o.Clip
            $isImage = ([string]$t.Kind -eq "image")
            $entry = $(if ($isImage) { Get-PipImageElement -Clip $t } else { Get-PipMediaElement -Clip $t })
            $el = $entry.Element
            $span = Get-TrimClipSpan -Clip $t -SourceDuration (Get-TrimClipSourceDuration -Lane $o.Lane -Clip $t)
            $inSpan = ($timelinePlayhead -ge [double]$span.Start -and $timelinePlayhead -lt [double]$span.End)
            # A row with the eye off (spec 3.2) renders nothing at all -- the same flag the
            # export reads to leave the clip out of the overlay chain.
            if (-not $inSpan -or -not $t.Enabled -or $bw -le 0 -or $bh -le 0) {
                $el.Visibility = "Collapsed"
                if (-not $isImage) { try { $el.Pause() } catch {} }
                $entry.InSpan = $false
                continue
            }
            $el.Visibility = "Visible"
            $el.HorizontalAlignment = "Left"
            $el.VerticalAlignment = "Top"
            if ($null -eq $t.Pip) {
                $el.Width = $bw
                $el.Height = $bh
                $el.Stretch = "Uniform"
                $el.Margin = New-Object System.Windows.Thickness([double]$box.X, [double]$box.Y, 0, 0)
            } else {
                $pip = $t.Pip
                $el.Width = [double]$pip.W * $bw
                $el.Height = [double]$pip.H * $bh
                $el.Stretch = "Fill"
                $marginX = [double]$box.X + (([double]$pip.X - ([double]$pip.W / 2.0)) * $bw)
                $marginY = [double]$box.Y + (([double]$pip.Y - ([double]$pip.H / 2.0)) * $bh)
                $el.Margin = New-Object System.Windows.Thickness($marginX, $marginY, 0, 0)
            }
            # A still has no clock: geometry and visibility are all it has, so the whole
            # transport half below is skipped for it (and its InSpan only tracks state).
            if ($isImage) { $entry.InSpan = $true; continue }
            # PiP audio comes through only if the clip has a linked audio row --
            # this MediaElement is picture only.
            $el.Volume = 0
            if ($Seek -or -not $entry.InSpan) {
                $pos = [math]::Max(0.0, ($timelinePlayhead - [double]$t.Offset + [double]$t.InStart))
                try { $el.Position = [timespan]::FromSeconds($pos) } catch {}
            }
            $entry.InSpan = $true
            if ($playing) { try { $el.Play() } catch {} } else { try { $el.Pause() } catch {} }
        }
    }

    # Plays every EXTERNAL audio clip's off-tree MediaElement while the timeline playhead is
    # inside its span AND the main transport is playing -- scrubbing deliberately never
    # seeks these (the comment on Get-AudioClipMediaElement explains why: the export's own
    # mix is authoritative, this is only ever an approximation while editing). The loaded
    # file's OWN audio streams are excluded: the main preview element is already decoding
    # them, and playing them twice would double the source audio.
    function Update-TrimAudioClipPreview {
        param([double]$SourceSeconds, [bool]$Playing)
        # Same extension-aware playhead as Update-PipPreview's: the span math here was
        # already timeline-based, but a source->timeline convert caps out at V1's end, so
        # without this an audio clip that plays over the montage region would go silent the
        # moment the transport left the cut list.
        $timelinePlayhead = $(if (Test-TrimInExtension) { Get-TrimTimelinePlayhead } else {
            $state = Get-TrimTimelineState
            Convert-TrimSourceToTimeline -SourceSeconds $SourceSeconds -TimelinePieces $state.TimelinePieces
        })
        $clips = @()
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                if ($c.Kind -ne "audio") { continue }
                if ([string]$c.Path -eq [string]$script:TrimInputFile) { continue }
                $clips += ,@{ Lane = $lane; Clip = $c }
            }
        }
        foreach ($entryRef in $clips) {
            $t = $entryRef.Clip
            $entry = Get-AudioClipMediaElement -Clip $t
            $el = $entry.Element
            # The moment the headroom wav's extraction lands, swap the element onto it:
            # boosts above 0dB are only reachable through the pre-gained file. The play
            # branch below reseeds Position because InSpan resets.
            $extKey = Get-TrimExtAudioKey -Path ([string]$t.Path)
            $extWav = $(if ($script:TrimExtAudioWav.ContainsKey($extKey)) { [string]$script:TrimExtAudioWav[$extKey] } else { $null })
            $wantSrc = $(if ($extWav) { $extWav } else { [string]$t.Path })
            if ([string]$entry.Path -ne $wantSrc) {
                try { $el.Pause() } catch {}
                try { $el.Source = New-Object System.Uri($wantSrc) } catch {}
                $entry.Path = $wantSrc
                $entry.InSpan = $false
            }
            $span = Get-TrimClipSpan -Clip $t -SourceDuration (Get-TrimClipSourceDuration -Lane $entryRef.Lane -Clip $t)
            $inSpan = ($timelinePlayhead -ge [double]$span.Start -and $timelinePlayhead -lt [double]$span.End -and [bool]$t.Enabled)
            # With the wav: volume = 10^((dB-30)/20), the whole -30..+30 fader instant.
            # Without it yet: the old direct-file math, boosts capped at 1.0.
            $vol = if ($t.Muted) { 0.0 } `
                   elseif ($extWav) { [math]::Min(1.0, [math]::Pow(10.0, ([double]$t.GainDb - 30.0) / 20.0)) } `
                   else { [math]::Min(1.0, [math]::Pow(10.0, [double]$t.GainDb / 20.0)) }
            $el.Volume = $vol
            if ($Playing -and $inSpan) {
                if (-not $entry.InSpan) {
                    $pos = [math]::Max(0.0, ($timelinePlayhead - [double]$t.Offset + [double]$t.InStart))
                    try { $el.Position = [timespan]::FromSeconds($pos) } catch {}
                    try { $el.Play() } catch {}
                    $entry.InSpan = $true
                }
            } else {
                if ($entry.InSpan) { try { $el.Pause() } catch {} }
                $entry.InSpan = $false
            }
        }
    }

    # ---- Preview playback of the source's extra audio streams ---------------------

    # Background extraction of one source stream (same runspace + watcher shape as
    # Request-TrimThumbnail). The result registers through the write-through below --
    # the watcher tick is a GetNewClosure block, where a bare $script: write would land
    # in the closure's own module.
    function Request-TrimSourceStreamAudio {
        param([int]$StreamIdx)
        $skey = [string]$StreamIdx
        if ($script:TrimSourceStreamPending.ContainsKey($skey)) { return }
        $script:TrimSourceStreamPending[$skey] = $true
        # ONE file per stream, extracted ONCE: float PCM with the fader's whole +30dB
        # range pre-applied (see Export-TrimAudioStream -HeadroomDb). Float cannot
        # clip, so every gain the fader can ask for -- boosts included -- is reached by
        # pure element-volume attenuation, instantly. No re-extraction ever again.
        $outFile = Join-Path $script:TrimThumbDir ("srcaudio{0}.wav" -f $StreamIdx)
        $srcFile = [string]$script:TrimInputFile
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file, $idx, $outFile)
            Import-Module $modulePath -Force
            Export-TrimAudioStream -InputFile $file -StreamIndex $idx -OutputFile $outFile -HeadroomDb 30.0
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($srcFile).AddArgument($StreamIdx).AddArgument($outFile) | Out-Null
        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(500)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()
            Set-TrimSourceStreamAudio -StreamIdx $StreamIdx -Path $outFile -ForFile $srcFile
        }.GetNewClosure())
        $watcher.Start()
    }

    function Set-TrimSourceStreamAudio {
        param([int]$StreamIdx, [string]$Path, [string]$ForFile)
        $skey = [string]$StreamIdx
        $script:TrimSourceStreamPending.Remove($skey)
        # The load that asked can be gone by the time ffmpeg finishes -- a different file
        # switched in. Registering the stale result would play the OLD file's audio.
        if ([string]$script:TrimInputFile -ne $ForFile) { return }
        if (Test-Path -LiteralPath $Path) {
            $script:TrimSourceStreamAudio[$skey] = $Path
        }
        # One extraction at a time (they all read the same multi-GB recording; two ffmpegs
        # seeking it in parallel thrash the disk the preview is decoding from) -- the next
        # queued job starts only when the previous one lands.
        Start-TrimSourceStreamQueue
        # If the transport is already running, hand the freshly extracted stream its
        # element right away instead of waiting for the next tick.
        Update-TrimPreviewVolume
        # And clear the fader badge's extracting ellipsis (a rebuild repaints it; the
        # rebuild self-guards against live drags).
        Update-TrimLaneRows
    }

    function Start-TrimSourceStreamQueue {
        if (@($script:TrimSourceStreamQueue).Count -eq 0) { return }
        if (@($script:TrimSourceStreamPending.Keys).Count -gt 0) { return }
        $next = [int]$script:TrimSourceStreamQueue[0]
        $script:TrimSourceStreamQueue = @($script:TrimSourceStreamQueue | Select-Object -Skip 1)
        Request-TrimSourceStreamAudio -StreamIdx $next
    }

    # Element per extracted stream, off-tree like the audio-clip pool -- $null until the
    # extraction has landed.
    function Get-TrimSourceStreamElement {
        param([int]$StreamIdx)
        $skey = [string]$StreamIdx
        if (-not $script:TrimSourceStreamAudio.ContainsKey($skey)) { return $null }
        if (-not $script:TrimSourceStreamElements.ContainsKey($skey)) {
            $el = New-Object System.Windows.Controls.MediaElement
            $el.LoadedBehavior = "Manual"
            $el.UnloadedBehavior = "Manual"
            try { $el.Source = New-Object System.Uri([string]$script:TrimSourceStreamAudio[$skey]) } catch {}
            $script:TrimSourceStreamElements[$skey] = @{ Element = $el; Playing = $false; StartedAt = $null
                                                         Path = [string]$script:TrimSourceStreamAudio[$skey] }
        }
        return $script:TrimSourceStreamElements[$skey]
    }

    function Clear-TrimSourceStreamAudio {
        foreach ($k in @($script:TrimSourceStreamElements.Keys)) {
            try { $script:TrimSourceStreamElements[$k].Element.Stop() } catch {}
            try { $script:TrimSourceStreamElements[$k].Element.Source = $null } catch {}
        }
        $script:TrimSourceStreamElements = @{}
        $script:TrimSourceStreamAudio = @{}
        $script:TrimSourceStreamPending = @{}
        $script:TrimSourceStreamOrder = @()
        $script:TrimSourceStreamQueue = @()
        $script:TrimSourceStreamBoost = @{}
        $script:TrimSourceStreamBase = @{}
        $script:TrimExtAudioWav = @{}
        $script:TrimExtAudioPending = @{}
    }

    # Preview volumes for the SOURCE audio rows plus playback of the extracted extras:
    #   - the main element's Volume follows the FIRST stream's row (fader, mute, delete),
    #   - every later stream plays through its own element, mirroring the main element's
    #     source position: seeded on start/seek, drift-corrected past 0.35s otherwise
    #     (piece-jumps move the main element without notice, per-tick seeks stutter).
    # Volume is 10^(dB/20) clamped at 1.0 -- MediaElement cannot boost, so positive gains
    # are only audible in the export. A DELETED row silences its stream, matching what the
    # export's mix graph does. The export remains authoritative; this is the live preview.
    function Update-TrimSourceAudioPreview {
        param([bool]$Playing, [bool]$Seek = $false)
        if (-not $script:TrimInputFile -or $null -eq $mediaTrimPreview) { return }
        $rows = @{}
        foreach ($lane in @($script:TrimLanes)) {
            foreach ($c in @($lane.Clips)) {
                if ($c.Kind -ne "audio") { continue }
                if ([string]$c.Path -ne [string]$script:TrimInputFile) { continue }
                $rows[[string]([int]$c.StreamIdx)] = $c
            }
        }
        $order = @($script:TrimSourceStreamOrder)
        if ($order.Count -eq 0) { return }
        # EVERY stream -- the first included -- plays through its own extracted element.
        # Both streams of these recordings are flagged default:1, so which one the main
        # element decodes is Media Foundation's coin flip: on some files it picked the mic
        # stream, and the preview then played the mic TWICE while the system audio stayed
        # silent. Until the first stream's extraction lands, the main element carries its
        # (ambiguous) audio as a stopgap; from then on it is picture-only.
        $firstKey = [string]([int]$order[0])
        $firstReady = $script:TrimSourceStreamAudio.ContainsKey($firstKey)
        $mainVol = 0.0
        if (-not $firstReady -and $rows.ContainsKey($firstKey)) {
            $r = $rows[$firstKey]
            if (-not [bool]$r.Muted) { $mainVol = [math]::Min(1.0, [math]::Pow(10.0, [double]$r.GainDb / 20.0)) }
        }
        $mediaTrimPreview.Volume = $mainVol
        $mainPlaying = ($Playing -and -not (Test-TrimInExtension))
        $mainPos = $mediaTrimPreview.Position
        $nowStamp = [datetime]::UtcNow
        for ($si = 0; $si -lt $order.Count; $si++) {
            $idx = [int]$order[$si]
            $entry = Get-TrimSourceStreamElement -StreamIdx $idx
            if ($null -eq $entry) { continue }
            $el = $entry.Element
            $skey = [string]$idx
            # A re-extraction (boost baked in, or reset back to the base file) registered a
            # NEW file for this stream: swap the element's source and let the play branch
            # below reseed its position.
            $registered = [string]$script:TrimSourceStreamAudio[$skey]
            if ($registered -ne [string]$entry.Path) {
                try { $el.Pause() } catch {}
                try { $el.Source = New-Object System.Uri($registered) } catch {}
                $entry.Path = $registered
                $entry.Playing = $false
            }
            # The extracted file carries +30dB of headroom (float PCM, cannot clip), so
            # element volume = 10^((dB-30)/20): the fader's whole -30..+30 range maps
            # into [0..1] and EVERY gain change -- boosts included -- is instant. This is
            # what real editors do: decode once, apply gain at output time, never
            # re-encode on a slider move.
            $vol = 0.0
            if ($rows.ContainsKey($skey)) {
                $r = $rows[$skey]
                if (-not [bool]$r.Muted) { $vol = [math]::Min(1.0, [math]::Pow(10.0, ([double]$r.GainDb - 30.0) / 20.0)) }
            }
            $el.Volume = $vol
            if ($mainPlaying -and $vol -gt 0.0) {
                if (-not $entry.Playing) {
                    try { $el.Position = $mainPos } catch {}
                    try { $el.Play() } catch {}
                    $entry.Playing = $true
                    $entry.StartedAt = $nowStamp
                } elseif ($Seek) {
                    try { $el.Position = $mainPos } catch {}
                    $entry.StartedAt = $nowStamp
                } else {
                    # Drift guard with a start-up grace: right after Play() the element's
                    # Position lags while its decoder spins up, and correcting during that
                    # window re-seeked it every tick -- the burst of restarts WAS the
                    # "stutters for a while, then fixes itself".
                    $inGrace = ($null -ne $entry.StartedAt -and ($nowStamp - $entry.StartedAt).TotalSeconds -lt 1.5)
                    if (-not $inGrace) {
                        try {
                            if ([math]::Abs($el.Position.TotalSeconds - $mainPos.TotalSeconds) -gt 0.6) {
                                $el.Position = $mainPos
                                $entry.StartedAt = $nowStamp
                            }
                        } catch {}
                    }
                }
            } else {
                if ($entry.Playing) { try { $el.Pause() } catch {} }
                $entry.Playing = $false
                if ($Seek) { try { $el.Position = $mainPos } catch {} }
            }
        }
    }

    # ---- Add flows (spec 4.3) ------------------------------------------------------
    #
    # Two gestures where v2 had one. "+ Video track" / "+ Audio track" create an EMPTY lane
    # and nothing else -- an empty row is a first-class thing to want (it persists in the
    # project file and shows a "drop ... here" ghost), and it is where the header's own
    # context menu then puts media. "Add media to this track..." is the file-dialog half.
