# 15-editor-state.ps1 -- editor element lookups, all $script: state, save workflow.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

    $textTrimMeta = $panelTrim.FindName("TextTrimMeta")

    $cardTrimEditor      = $panelTrim.FindName("CardTrimEditor")
    $mediaTrimPreview    = $panelTrim.FindName("MediaTrimPreview")
    $mediaTrimFadePreview = $panelTrim.FindName("MediaTrimFadePreview")
    $buttonTrimPlay      = $panelTrim.FindName("ButtonTrimPlay")
    $textTrimPosition    = $panelTrim.FindName("TextTrimPosition")
    $canvasTrimTimeline  = $panelTrim.FindName("CanvasTrimTimeline")
    $canvasTrimRuler     = $panelTrim.FindName("CanvasTrimRuler")
    $canvasTrimFades     = $panelTrim.FindName("CanvasTrimFades")
    $canvasTrimCaptions  = $panelTrim.FindName("CanvasTrimCaptions")
    $canvasTrimZooms     = $panelTrim.FindName("CanvasTrimZooms")
    $panelTrimLanes      = $panelTrim.FindName("PanelTrimTracks")
    $panelTrimAddTracks  = $panelTrim.FindName("PanelTrimAddTracks")
    $panelTrimLaneArea   = $panelTrim.FindName("PanelTrimLaneArea")
    $scrollTrimView      = $panelTrim.FindName("ScrollTrimView")
    $canvasTrimLaneOverlay = $panelTrim.FindName("CanvasTrimLaneOverlay")
    $previewZoomHost     = $panelTrim.FindName("PreviewZoomHost")
    $previewCell         = $panelTrim.FindName("PreviewCell")
    $panelTrimFadeLength = $panelTrim.FindName("PanelTrimFadeLength")
    $textTrimFadeNote    = $panelTrim.FindName("TextTrimFadeNote")
    $textTrimFadeScope   = $panelTrim.FindName("TextTrimFadeScope")
    $panelTrimTrackProps = $panelTrim.FindName("PanelTrimTrackProps")
    $textTrackPropsName  = $panelTrim.FindName("TextTrackPropsName")
    # The strip is CLIP-scoped now (spec 3.2 moved the row's gain/mute/eye/trash into the
    # lane headers), so what it carries is the clip's display mode and its delete.
    $buttonClipDisplayMode = $panelTrim.FindName("ButtonClipDisplayMode")
    $textClipDisplayHint   = $panelTrim.FindName("TextClipDisplayHint")
    $buttonTrackDelete   = $panelTrim.FindName("ButtonTrackDelete")
    $fadeLengthButtons   = @{
        0.25 = $panelTrim.FindName("ButtonFade025")
        0.5  = $panelTrim.FindName("ButtonFade050")
        1.0  = $panelTrim.FindName("ButtonFade100")
    }
    $textTrimPieces      = $panelTrim.FindName("TextTrimPieces")
    $textTrimSelection   = $panelTrim.FindName("TextTrimSelection")
    $textTrimAccuracy    = $panelTrim.FindName("TextTrimAccuracy")
    $buttonTrimSplit     = $panelTrim.FindName("ButtonTrimSplit")
    $buttonTrimDelete    = $panelTrim.FindName("ButtonTrimDelete")
    $buttonTrimUndo      = $panelTrim.FindName("ButtonTrimUndo")
    $buttonTrimRedo      = $panelTrim.FindName("ButtonTrimRedo")
    $buttonTrimExport    = $panelTrim.FindName("ButtonTrimExport")
    $buttonTrimAddCaption = $panelTrim.FindName("ButtonTrimAddCaption")
    $buttonTrimBrowse     = $panelTrim.FindName("ButtonTrimBrowse")
    $buttonTrimOpenAnother = $panelTrim.FindName("ButtonTrimOpenAnother")
    $buttonTrimAddZoom    = $panelTrim.FindName("ButtonTrimAddZoom")
    # Two add buttons (spec 4.3): an EMPTY lane is a first-class thing to want, so "+ track"
    # is no longer the same gesture as "+ media" -- the file dialog moved to the lane header's
    # own "Add media to this track..." (Invoke-TrimAddClip).
    $buttonTrimAddVideoTrack = $panelTrim.FindName("ButtonTrimAddVideoTrack")
    $buttonTrimAddAudioTrack = $panelTrim.FindName("ButtonTrimAddAudioTrack")
    $buttonTrimUnlink     = $panelTrim.FindName("ButtonTrimUnlink")
    # Still null-guarded everywhere (see Update-TrimSnapButton): a stale MainWindow.xaml from
    # an in-place update can predate these controls, the rule this whole block follows.
    $buttonTrimSnap       = $panelTrim.FindName("ButtonTrimSnap")
    $textTrimSnapGlyph    = $panelTrim.FindName("TextTrimSnapGlyph")
    $buttonCaptionDelete  = $panelTrim.FindName("ButtonCaptionDelete")
    $panelCaptionSidebar  = $panelTrim.FindName("PanelCaptionSidebar")
    $canvasCaptionOverlay = $panelTrim.FindName("CanvasCaptionOverlay")
    $textCaptionText      = $panelTrim.FindName("TextCaptionText")
    $comboCaptionFont     = $panelTrim.FindName("ComboCaptionFont")
    $checkCaptionBold     = $panelTrim.FindName("CheckCaptionBold")
    $textCaptionFill      = $panelTrim.FindName("TextCaptionFill")
    $textCaptionOutline   = $panelTrim.FindName("TextCaptionOutline")
    $panelCaptionFillSwatches    = $panelTrim.FindName("PanelCaptionFillSwatches")
    $panelCaptionOutlineSwatches = $panelTrim.FindName("PanelCaptionOutlineSwatches")
    $sliderCaptionOutlineW = $panelTrim.FindName("SliderCaptionOutlineW")
    $checkCaptionBounce   = $panelTrim.FindName("CheckCaptionBounce")
    $textCaptionStart     = $panelTrim.FindName("TextCaptionStart")
    $textCaptionEnd       = $panelTrim.FindName("TextCaptionEnd")

    # An install updated in place can run new code against old XAML, in which case every
    # lookup above is $null and the first handler to fire takes the app down. Same guard
    # as Update-RecentList carries, for the same reason.
    $script:TrimEditorReady = ($null -ne $cardTrimEditor -and $null -ne $canvasTrimTimeline -and $null -ne $mediaTrimPreview)

    # Crossfade state. Declared here, before the first Update-TrimTimeline can run during
    # initial layout: the drawing code reads both on every pass, including the one that
    # fires before any file has been picked.
    # Boundary source time -> that cut's fade length in seconds. $script:TrimFadeSeconds
    # is only the default for the next fade added, not a setting the existing ones follow.
    $script:TrimFades = @{}
    $script:TrimFadeSeconds = 0.5
    $script:TrimActiveFade = $null
    # Rendered crossfades for the preview: key -> file path, plus the in-flight set and
    # the key currently on screen so the overlay is only re-sourced when it really changes.
    $script:TrimFadeProxies = @{}
    $script:TrimFadeProxyPending = @{}
    $script:TrimFadeProxyDir = $null
    $script:TrimFadeOverlayKey = $null

    # Caption state. Declared beside the fade state and for the same reason: the lane is
    # drawn by Update-TrimTimeline, which runs during initial layout before any file has
    # been picked, so both of these have to exist by then.
    # $script:TrimSelectedCaption is a caption Id string (or $null), never an index --
    # indexes shift on add/delete the same way the fade keys avoid.
    $script:TrimCaptions = New-Object System.Collections.ArrayList
    $script:TrimSelectedCaption = $null
    # In-flight lane drag: $null when nothing is being dragged, otherwise a hashtable of
    # Id / Mode ("move" | "start" | "end") / StartX / OrigStart / OrigEnd / Snapshot.
    # The undo snapshot is taken when the drag BEGINS and only pushed on release, so a
    # drag costs exactly one undo step no matter how many MouseMove events it produced.
    $script:TrimCaptionDrag = $null
    # In-flight preview-overlay drag (move or resize), same shape and same one-undo-per-drag
    # rule as the lane drag above.
    $script:CaptionOverlayDrag = $null
    # Set while Show-CaptionSidebar is filling the fields: every control's change handler
    # fires on a programmatic assignment exactly as it does on a user edit, and without this
    # guard selecting a caption would write each field straight back and push undo steps for
    # edits nobody made.
    $script:CaptionSidebarLoading = $false
    # Focus/capture sessions for the two controls that would otherwise produce one undo step
    # per keystroke (the text box) or per slider tick (the outline width). Each holds the
    # snapshot taken when the session began, pushed on the way out only if it changed.
    $script:CaptionTextEdit = $null
    $script:CaptionSliderEdit = $null

    # Zoom keyframe state. Declared here beside the caption state and for exactly the same
    # reason: the zoom lane is drawn from Update-TrimTimeline, which runs during initial
    # layout before any file has been picked, so both of these have to exist by then.
    # $script:TrimSelectedZoom is a keyframe Id string (or $null), never an index --
    # indexes shift on add/delete and a drag re-sorts the list on every move.
    $script:TrimZooms = New-Object System.Collections.ArrayList
    $script:TrimSelectedZoom = $null
    # In-flight diamond drag: $null when nothing is being dragged, otherwise a hashtable of
    # Id / StartX / OrigTime / Snapshot. Snapshot taken when the drag BEGINS and pushed on
    # release only if the keyframe really moved -- one undo step per completed drag, the
    # same rule the caption lane drag follows.
    $script:TrimZoomDrag = $null
    # Spotlight box + floating pill state, declared here for the same "drawn during initial
    # layout" reason as everything above it.
    # The dim rects, the gold frame and the level badge are TRANSIENT: rebuilt from the model
    # on every redraw and tracked here so they can be pulled out of the shared overlay canvas
    # individually -- the captions draw on that same canvas and a blanket Children.Clear()
    # from the zoom side would wipe them.
    $script:ZoomBoxElements = New-Object System.Collections.ArrayList
    # In-flight drag-to-draw: $null, or a hashtable of StartX / StartY / Moved / Rect /
    # Snapshot. Same snapshot-at-down, push-on-release rule as every other drag here.
    $script:ZoomBoxDrag = $null
    # The pill, by contrast, is built ONCE and lives in the canvas for the whole session --
    # see Clear-CaptionOverlayChildren for why it must not be torn out and re-added.
    $script:ZoomPillBorder = $null
    $script:ZoomPillSlider = $null
    $script:ZoomPillValueText = $null
    $script:ZoomPillMagnetButton = $null
    # Magnet ON by default: resizing keeps the box video-shaped (uniform zoom) until the
    # user opts into free-stretch. Session-wide, not per keyframe -- it is a tool mode.
    $script:ZoomMagnet = $true
    # Set while the pill is being filled from the model: WPF raises ValueChanged for a
    # programmatic assignment exactly as it does for a user drag, so without this the redraw
    # that follows a box drag would write the slider's snapped value straight back over it.
    $script:ZoomUiLoading = $false
    # One undo step per slider capture session, not per tick: snapshot taken when the slider
    # grabs the mouse, pushed when it lets go and only if the level really changed.
    $script:ZoomSliderEdit = $null
    # A drag has to beat this before it counts as drawing a box; under it the press falls
    # through to the click behaviour (deselect), so a stray click still deselects.
    $script:ZoomBoxDragThreshold = 4.0
    # And the finished box has to be at least this wide to be committed -- a 12px box is a
    # 100x zoom nobody asked for, and reading it as a click is the safer interpretation.
    $script:ZoomBoxMinWidth = 40.0

    # NLE lane/clip state. Declared here beside the zoom/caption state and for the same
    # reason: the app must never hand -Lanes $null to Export-CutListAsync (the PS 5.1
    # @($null).Count -eq 1 trap), so this is always an ArrayList, never left $null, from
    # the moment the editor exists. Each lane's own Clips is an ArrayList too (see
    # Set-TrimLanes) so a clip can be added/removed in place without rebuilding the lane.
    $script:TrimLanes = New-Object System.Collections.ArrayList
    # A CLIP Id string (or $null), never an index -- same reasoning as TrimSelectedZoom:
    # indexes shift on add/delete and a lane reorder moves whole rows around.
    $script:TrimSelectedClip = $null
    # A LANE Id string (or $null): the header selection, mutually exclusive with the clip
    # selection (single gold selection, spec 3.3 -- see Set-TrimSelectedClip/Lane).
    $script:TrimSelectedLane = $null
    # laneId -> $true for every collapsed group (spec 4.1's caret). A hashtable rather than
    # a list so the render can test membership per row without a scan.
    $script:TrimCollapsedLanes = @{}
    # Timeline snapping (N / the toolbar magnet). Seeded from settings at startup; every
    # write goes through Set-TrimSnapEnabled so the global and settings.json follow.
    # Import-Config has already run by here and always sets the global (both branches and
    # its catch), so the $null check is belt-and-suspenders for a settings load that threw
    # before reaching it -- snapping defaults ON either way.
    $script:TrimSnapEnabled = $(if ($null -ne $global:TrimSnapEnabled) { [bool]$global:TrimSnapEnabled } else { $true })
    # Live clip drag state, same shape of lifecycle as TrimCaptionDrag/TrimZoomDrag: $null
    # when idle, a hashtable (ClipId, Mode, the pre-drag values of every link-group member,
    # the snap point set, a snapshot, and direct Canvas/Border references) while a clip bar
    # is being dragged.
    $script:TrimClipDrag = $null
    # clipId -> @{Border; Canvas} for every clip body Update-TrimLaneRows renders as a
    # single draggable bar. A drag reads it ONCE at mouse-down to find its linked peers'
    # own Borders (on their own row canvases) so the whole link group visibly travels in
    # one gesture. Rebuilt from scratch on every row rebuild, like the rows themselves.
    $script:TrimClipElements = @{}
    # The green snap flash Line (spec 4.8) while a drag is on a lock, else $null. Held so
    # it can be removed again without clearing the overlay canvas the playhead shares.
    $script:TrimSnapFlashLine = $null
    # True while the playhead is being DRAGGED on the timeline canvas (mouse held after a
    # press): every mouse move keeps scrubbing until release.
    $script:TrimScrubDrag = $false
    # Live lane-reorder (⋮⋮) drag state. Same $null-when-idle convention; the rows it moves
    # are whole group blocks, see Move-TrimLaneTo.
    $script:TrimLaneReorderDrag = $null
    # The gold insertion Line a live lane reorder draws between rows, else $null.
    $script:TrimLaneReorderLine = $null
    # Live fader edit on an audio row header. Holds the undo snapshot for the whole
    # gesture (drag or a burst of Up/Down presses) plus a Dragging flag: while a fader
    # drag holds the mouse, Update-TrimLaneRows must not rebuild the very canvas that
    # owns the capture, exactly as it must not during a clip drag.
    $script:TrimLaneGainEdit = $null
    # Debounce for keyboard gain: the undo bracket closes 600ms after the last key,
    # so holding Up is one undo step rather than one per 0.5 dB.
    $script:TrimLaneGainTimer = $null
    # Lane id whose fader had keyboard focus when the rows were last rebuilt, so the
    # rebuild a keyboard gain change triggers does not eat the next key press.
    $script:TrimFaderFocusLane = $null
    # Row media pump (filmstrip frames + per row waveforms). Queue, claimed-key set,
    # the single in-flight job, the pump timer, decoded strip bitmaps, and the
    # "something landed, redraw when the queue drains" flag.
    $script:TrimStripPending = New-Object System.Collections.ArrayList
    $script:TrimRowMediaClaimed = @{}
    $script:TrimRowMediaJob = $null
    $script:TrimRowMediaTimer = $null
    $script:TrimStripImages = @{}
    $script:TrimRowMediaDirty = $false
    # Path -> probed duration (seconds) for every external clip added to the stack. Never
    # left $null for the same reason TrimLanes isn't: it feeds -ClipDurations at
    # Export-CutListAsync's call site and Get-TrimClipSpan's SourceDuration fallback
    # for InEnd = 0 ("to the end of the clip"). Reset per file load alongside TrimLanes.
    $script:TrimClipDurations = @{}
    # The PROBED count of audio streams the loaded source file itself actually has (from
    # Get-TrimAudioStreams at load time), -1 until a file has been probed. Passed as
    # Export-CutListAsync's -SourceAudioStreamCount so a stack whose audio-source tracks
    # were deleted (rather than muted) is recognized as non-trivial (deleting all of a
    # 2-stream file's audio-source tracks leaves 0 != 2) and routes to the rebuild path
    # instead of silently falling through to the trivial "-map 0 -c copy" of the source,
    # which would keep the original audio no matter what the UI shows. -1 (never left
    # unset/$null) is the legacy/unknown sentinel every downstream function treats as
    # "behave exactly as before this existed".
    $script:TrimSourceAudioStreamCount = -1
    # Preview playback of the source's OWN extra audio streams. The main MediaElement
    # decodes only the container's FIRST audio stream (WPF offers no stream selection),
    # so streams 2..N are extracted to their own files in the background and played by
    # off-tree elements synced to the main one. Keyed by ABSOLUTE stream index.
    $script:TrimSourceStreamAudio = @{}      # idx -> extracted file path (the one to PLAY)
    $script:TrimSourceStreamElements = @{}   # idx -> @{ Element; Playing; StartedAt; Path }
    $script:TrimSourceStreamPending = @{}    # idx -> $true while ffmpeg runs
    $script:TrimSourceStreamOrder = @()      # probed stream indices, file order
    $script:TrimSourceStreamQueue = @()      # @{ Idx; Gain } jobs waiting for extraction
    $script:TrimSourceStreamBoost = @{}      # retired (headroom extraction); kept for the probe dump
    $script:TrimSourceStreamBase = @{}       # retired (headroom extraction)
    # Throttle stamp for the DRAG-scrub's media seeks (see Set-TrimScrubFromX).
    $script:TrimScrubLastSeek = $null
    # True while Update-TrimTimeline itself writes the view scrollbar's Value.
    $script:TrimViewScrollSync = $false
    # Petalfall's petal list: a real empty array even when the look is off -- @($null)
    # has Count 1 (trap #5's cousin), so anything counting petals would misread null.
    $script:LookPetals = @()
    # Path -> the clip's own width/height aspect ratio, populated once at add-time
    # (Invoke-TrimAddClip) for every overlay clip so the magnet-locked resize drag can read
    # it without shelling out to ffprobe on every mouse-move.
    $script:TrimClipAspect = @{}
    # PiP preview pools: CLIP Id -> MediaElement. Video-clip elements are inserted into
    # the visual tree (PreviewCell, between PreviewZoomHost and CanvasCaptionOverlay) so
    # they actually render; audio-clip elements are deliberately kept OFF the tree -- they
    # exist only to play sound, never to be seen, and the export is authoritative for the
    # real mix regardless of what the preview does.
    # Every entry is @{ Element; InSpan } -- InSpan is what stops the 20x/sec transport tick
    # from re-seeking an element that is already playing the right thing (see
    # Update-PipPreview's -Seek plumbing); the audio pool has worked this way since Task 8.
    $script:PipMediaElements = @{}
    $script:AudioClipMediaElements = @{}
    # External audio files (music drops) get the same headroom treatment as the source
    # streams: one float-PCM wav per PATH with +30dB pre-applied, extracted in the
    # background; until it lands the pool element plays the original with boosts capped.
    $script:TrimExtAudioWav = @{}          # lowercased path -> extracted wav
    $script:TrimExtAudioPending = @{}      # lowercased path -> $true while extracting
    # Stills get an Image element rather than a MediaElement (same pool shape, same
    # clip-Id key, same visual-tree slot): a BitmapImage is decoded once at OnLoad and
    # then costs nothing per tick, where a MediaElement on a .png would not play at all.
    $script:ImageElements = @{}
    # The black montage base: one Rectangle sized to the preview box, sitting under every
    # clip element, shown only while the playhead is past V1's own end (spec 4.7). Built
    # lazily by Update-TrimBlackBase because PreviewCell is not resolved yet up here.
    $script:TrimBlackBase = $null
    # Timeline length INCLUDING anything that runs past the cut list, recomputed once per
    # redraw (Update-TrimTimelineLengthCache) rather than per tick: the transport clamps,
    # the ruler's view window and the position readout's denominator all read it 20x a
    # second while playing, and Get-TrimTimelineLength walks every clip on every lane.
    $script:TrimTimelineLengthCache = 0.0
    # How far PAST V1's own end the playhead is, in timeline seconds. 0.0 means "inside the
    # cut list", which is the only state that existed before spec 4.7's montage region:
    # there is no source second out there for $script:TrimPlayhead to hold, so the position
    # lives here and Get-TrimTimelinePlayhead adds the two together.
    $script:TrimExtensionOffset = 0.0
    # Wall-clock stamp of the last extension advance. Out past V1's end the main
    # MediaElement has no frames to give, so its Position cannot drive the transport and
    # DateTime deltas do the job instead.
    $script:TrimExtensionClock = $null
    # In-flight PiP box drag: $null, or a hashtable shaped exactly like $script:ZoomBoxDrag
    # (Mode "pipmove"/"pipresize", StartX/Y, Moved, orig Pip fields, Snapshot).
    $script:PipBoxDrag = $null
    # Magnet ON by default, same convention as $script:ZoomMagnet: resizing the PiP box
    # keeps the clip's own aspect until the user opts into free-stretch.
    $script:PipMagnet = $true
    # Transient shapes for the PiP spotlight box (frame/mover/sizer), tracked the same way
    # $script:ZoomBoxElements is so Remove-PipBoxElements can pull only these out of the
    # shared caption overlay canvas.
    $script:PipBoxElements = New-Object System.Collections.ArrayList

    # Project persistence. The save failure is reported once per file, not once per edit:
    # a read-only folder would otherwise repaint the same error over the panel every
    # second for as long as the user keeps working.
    $script:ProjectSaveWarned = $false

    # One DispatcherTimer, restarted on every edit: the file writes once things go quiet
    # Saving is EXPLICIT now (user ask 2026-08-14): edits mark the project dirty, and the
    # write happens on Ctrl+S or through the save prompt when closing / switching files.
    # The old one-second auto-save timer is gone with the sidecars-next-to-the-videos.
    $script:TrimProjectDirty = $false

    # The one place a project write actually happens. Adds the save to the recent list as
    # a "Saved file:" row so reopening the video from there restores the edit.
    function Invoke-TrimProjectSaveNow {
        param([switch]$Quiet)
        if (-not $script:TrimEditorReady -or -not $script:TrimInputFile) { return $false }
        $ok = Save-TrimProject -VideoPath $script:TrimInputFile `
            -CutList @($script:TrimCutList) -Fades $script:TrimFades -Captions @($script:TrimCaptions) `
            -Zooms @($script:TrimZooms) -Lanes @($script:TrimLanes)
        if ($ok) {
            $script:TrimProjectDirty = $false
            Add-RecentFile -Path $script:TrimInputFile -Job "Saved"
            Update-AllRecentLists
            if (-not $Quiet) {
                Show-PanelMessage -Block $textTrimMeta -IsSuccess -Text "Saved -- reopening this video restores this edit."
            }
        } elseif (-not $Quiet) {
            Show-PanelMessage -Block $textTrimMeta -IsError -Text "Couldn't write the project file."
        }
        return $ok
    }

    # Write-through for the prompt buttons: they are GetNewClosure'd handlers, where a
    # bare $script: write would land in the closure's own module.
    function Set-TrimSavePromptResult {
        param([string]$Value)
        $script:TrimSavePromptResult = $Value
    }

    # The APP-THEMED save prompt (user ask 2026-08-14: no native message boxes). Returns
    # "Yes", "No" or "Cancel". Code-built like the rest of the dynamic UI; borderless
    # with the Midnight Gold card chrome. Keys: Enter/Y = save, N = discard, Esc = cancel.
    function Show-TrimSavePrompt {
        param([string]$Leaf)
        $script:TrimSavePromptResult = "Cancel"
        $bc = (New-LookBrushConverter)

        $dlg = New-Object System.Windows.Window
        $dlg.WindowStyle = "None"
        $dlg.AllowsTransparency = $true
        $dlg.Background = [System.Windows.Media.Brushes]::Transparent
        $dlg.SizeToContent = "WidthAndHeight"
        $dlg.ResizeMode = "NoResize"
        $dlg.ShowInTaskbar = $false
        $dlg.WindowStartupLocation = "CenterOwner"
        try { $dlg.Owner = $ctx.Window } catch { $dlg.WindowStartupLocation = "CenterScreen" }

        $card = New-Object System.Windows.Controls.Border
        $card.Background = $bc.ConvertFromString("#0E1626")
        $card.BorderBrush = $bc.ConvertFromString("#2A3B52")
        $card.BorderThickness = New-Object System.Windows.Thickness(1)
        $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $card.Padding = New-Object System.Windows.Thickness(26, 22, 26, 22)
        $card.Margin = New-Object System.Windows.Thickness(12)
        $card.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
        $card.Effect.BlurRadius = 24
        $card.Effect.ShadowDepth = 0
        $card.Effect.Opacity = 0.6
        $dlg.Content = $card

        $stack = New-Object System.Windows.Controls.StackPanel
        $card.Child = $stack

        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = "Save your work?"
        $title.FontSize = 17
        $title.FontWeight = "Bold"
        $title.Foreground = $bc.ConvertFromString("#E0C48F")
        try { $title.FontFamily = $ctx.Window.FindResource("FontChrome") } catch { }
        [void]$stack.Children.Add($title)

        $body = New-Object System.Windows.Controls.TextBlock
        $body.Text = "Keep the edit for `"$Leaf`"?"
        $body.FontSize = 12.5
        $body.Foreground = $bc.ConvertFromString("#C9D6E4")
        $body.TextWrapping = "Wrap"
        $body.MaxWidth = 420
        $body.Margin = New-Object System.Windows.Thickness(0, 10, 0, 20)
        try { $body.FontFamily = $ctx.Window.FindResource("FontChrome") } catch { }
        [void]$stack.Children.Add($body)

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = "Horizontal"
        $buttons.HorizontalAlignment = "Right"
        [void]$stack.Children.Add($buttons)

        foreach ($def in @(
            @{ Label = "Save"; Result = "Yes"; Hero = $true; Default = $true; Cancel = $false },
            @{ Label = "Don't save"; Result = "No"; Hero = $false; Default = $false; Cancel = $false },
            @{ Label = "Cancel"; Result = "Cancel"; Hero = $false; Default = $false; Cancel = $true }
        )) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = [string]$def.Label
            $styleName = $(if ($def.Hero) { "HeroButtonStyle" } else { "PresetButtonStyle" })
            try { $btn.Style = $ctx.Window.FindResource($styleName) } catch { }
            $btn.MinWidth = 110
            $btn.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
            $btn.IsDefault = [bool]$def.Default
            $btn.IsCancel = [bool]$def.Cancel
            $thisResult = [string]$def.Result
            $thisDlg = $dlg
            $btn.Add_Click({
                Set-TrimSavePromptResult -Value $thisResult
                $thisDlg.Close()
            }.GetNewClosure())
            [void]$buttons.Children.Add($btn)
        }

        # Plain Y / N answer it too (the same accelerators the old native box had).
        $dlg.Add_PreviewKeyDown({
            param($eventSource, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Y) {
                Set-TrimSavePromptResult -Value "Yes"; $eventSource.Close(); $e.Handled = $true
            } elseif ($e.Key -eq [System.Windows.Input.Key]::N) {
                Set-TrimSavePromptResult -Value "No"; $eventSource.Close(); $e.Handled = $true
            }
        })

        [void]$dlg.ShowDialog()
        return [string]$script:TrimSavePromptResult
    }

    # Yes/No/Cancel before dirty work is lost. Returns $true when the caller may proceed
    # (saved or discarded), $false when the user cancelled the close/switch.
    function Confirm-TrimUnsavedWork {
        if (-not $script:TrimProjectDirty -or -not $script:TrimInputFile) { return $true }
        $leaf = [System.IO.Path]::GetFileName([string]$script:TrimInputFile)
        $answer = Show-TrimSavePrompt -Leaf $leaf
        if ($answer -eq "Cancel") { return $false }
        if ($answer -eq "Yes") { [void](Invoke-TrimProjectSaveNow -Quiet) }
        $script:TrimProjectDirty = $false
        return $true
    }

    # Zoom-gesture refinement: each Ctrl+wheel notch repaints through the cheap -TickOnly
    # path (no lane-row rebuild), and this timer runs ONE full Update-TrimTimeline shortly
    # after the last notch so the lane rows and thumbnails land at the FINAL zoom instead
    # of being rebuilt on every intermediate step -- rebuilding them per notch is what made
    # zooming feel like it "waits for the frames to render" between notches.
