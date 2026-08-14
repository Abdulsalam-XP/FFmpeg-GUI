# 70-editor-wiring.ps1 -- editor event wiring (if TrimEditorReady), onTrimFile, recents cards.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

    if ($script:TrimEditorReady) {
        # Sizes the zoom host and the caption overlay to the largest exact-16:9 box
        # that fits BOTH the card width and the window height. Width-only sizing (the
        # old behavior) made a preview so tall on wide windows that the timeline fell
        # below the fold and needed scrolling. The 660 is the vertical budget
        # everything except the preview needs: transport + track + lanes + ruler +
        # fades + status + buttons + card padding + window chrome.
        #
        # The host and the overlay are sized INDIVIDUALLY and the cell gets a Clip
        # geometry over the box -- there is deliberately no sized wrapper grid doing
        # this job. One was tried (2026-08-11) and the zoom's RenderTransform, while
        # verifiably attached and even reported by TransformToAncestor, simply never
        # reached the screen with the wrapper in the tree; the same transform on the
        # same host renders fine without it.
        $script:UpdatePreviewFrameSize = {
            if ($null -eq $previewCell) { return }
            $cellW = [double]$previewCell.ActualWidth
            if ($cellW -le 0) { return }
            # Window height minus what the editor below ACTUALLY needs (transport, the
            # default lane stack, caption/zoom strips, ruler+scrollbar, toolbar, progress
            # card, chrome) -- the rows are fixed-height, so a percentage split (the
            # previous 38%) just parked dead space beside the preview AND under the
            # timeline. The remainder goes to the picture; extra lanes past the default
            # stack scroll, which is what the panel's ScrollViewer is for.
            $availH = [double]$ctx.Window.ActualHeight - 760.0
            if ($availH -lt 320.0) { $availH = 320.0 }
            $w = [math]::Min($cellW, $availH * 16.0 / 9.0)
            $h = $w * 9.0 / 16.0
            foreach ($el in @($previewZoomHost, $canvasCaptionOverlay)) {
                if ($null -eq $el) { continue }
                $el.HorizontalAlignment = "Center"
                $el.VerticalAlignment = "Center"
                $el.Width = $w
                $el.Height = $h
            }
            # The cell's height is PINNED to the box: a zoomed host is laid out larger
            # than the box, and without the pin its size would grow this cell, shove
            # the whole timeline below the fold, and re-trigger SizeChanged in a loop.
            # With the pin, the oversized host simply overflows and the clip below
            # crops that overflow to exactly the video box.
            $previewCell.Height = $h
            $boxX = ($cellW - $w) / 2.0
            $boxY = 0.0
            $previewCell.Clip = New-Object System.Windows.Media.RectangleGeometry (
                New-Object System.Windows.Rect ($boxX, $boxY, $w, $h))
            # Everything the layout-based zoom needs to place the host: the box's
            # position and size within the cell. Re-asserted here because a resize
            # just re-centred the host at identity, which is wrong mid-zoom.
            $script:PreviewBox = @{ X = $boxX; Y = $boxY; W = $w; H = $h }
            Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
            # The PiP element(s) and the spotlight box are both positioned from this same
            # box, so a resize leaves them stale in exactly the way it leaves the zoom
            # transform stale.
            Update-PipPreview -SourceSeconds $script:TrimPlayhead
            # The base is sized from the same box the resize just recomputed.
            Update-TrimBlackBase
            Update-PipBoxOverlay
        }
        if ($null -ne $previewCell) {
            $previewCell.Add_SizeChanged({ & $script:UpdatePreviewFrameSize })
            $ctx.Window.Add_SizeChanged({ & $script:UpdatePreviewFrameSize })
        } else {
            # Old XAML without PreviewCell: keep the previous width-driven sizing.
            $mediaTrimPreview.Add_SizeChanged({
                param($eventSource, $e)
                if ($e.NewSize.Width -gt 0) {
                    $mediaTrimPreview.Height = $e.NewSize.Width * 9 / 16
                    if ($null -ne $canvasCaptionOverlay) {
                        $canvasCaptionOverlay.HorizontalAlignment = "Center"
                        $canvasCaptionOverlay.VerticalAlignment = "Center"
                        $canvasCaptionOverlay.Width = $e.NewSize.Width
                        $canvasCaptionOverlay.Height = $e.NewSize.Width * 9 / 16
                    }
                }
            })
        }

        # WPF MediaElement quirk, confirmed live: the very FIRST Play() after a fresh
        # Source assignment always resumes from the start, ignoring any Position set
        # beforehand -- even a plain scrub (no split/delete involved) to 1:43 then Play
        # played from 0. LoadedBehavior="Manual" does not save it; Position while paused
        # is only enough to render a single scrub-preview frame, not to seed the
        # internal cursor real playback resumes from. Playing and immediately pausing
        # once, the moment each file's media actually becomes ready, "warms up" that
        # cursor so every Play() after this -- including the user's very first click --
        # honors Position correctly. Fires once per file load, not once per app launch:
        # a second file gets a fresh Source and needs its own warm-up.
        $mediaTrimPreview.Add_MediaOpened({
            $mediaTrimPreview.Play()
            # A back-to-back Play()/Pause() with no real time between them does not
            # reliably warm up the pipeline either -- gives the decoder a genuine 80ms
            # to actually start producing frames first.
            $warmup = New-Object System.Windows.Threading.DispatcherTimer
            $warmup.Interval = [timespan]::FromMilliseconds(80)
            $warmup.Add_Tick({
                $warmup.Stop()
                $mediaTrimPreview.Pause()
                $mediaTrimPreview.Position = [timespan]::Zero
            }.GetNewClosure())
            $warmup.Start()
        })

        # ---- Transport stop / the montage extension clock (spec 4.7) ------------------
        #
        # Three ways the main MediaElement can run out of picture: it reaches the end of
        # the file (MediaEnded), it runs off the end of the last surviving piece (the tick
        # below), or the user scrubs past V1's end. In all three, if a clip on some lane
        # still has footage out there, the transport must KEEP RUNNING -- there is simply
        # nothing left for the main element to contribute, so it pauses (it is never asked
        # to seek past its own duration) and the DispatcherTimer's wall clock drives the
        # playhead the rest of the way.
        function Stop-TrimTransport {
            try { $mediaTrimPreview.Pause() } catch {}
            if ($null -ne $buttonTrimPlay) { $buttonTrimPlay.Content = "Play" }
            if ($null -ne $script:TrimTimer) { $script:TrimTimer.Stop() }
            Set-TrimExtensionClockIdle
            # Whatever the pools were playing has to stop with it.
            Update-PipPreview -SourceSeconds $script:TrimPlayhead
            Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $false
            Update-TrimSourceAudioPreview -Playing $false
            Update-TrimBlackBase
        }

        # The clock keeps its stamp only while it is actually advancing something.
        function Set-TrimExtensionClockIdle { $script:TrimExtensionClock = $null }

        function Stop-TrimAtV1End {
            $state = Get-TrimTimelineState
            $len = Get-TrimTimelineLengthCached
            $playing = ($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
            if ($playing -and $len -gt ([double]$state.TotalDuration + 0.01)) {
                try { $mediaTrimPreview.Pause() } catch {}
                # A hair past V1's end rather than exactly on it: the extension offset IS
                # the "am I out there" flag, and 0.0 means "inside the cut list".
                Set-TrimExtensionPosition -Seconds 0.001
                return
            }
            Stop-TrimTransport
        }

        # One tick's worth of wall time, added to the playhead's position past V1's end.
        function Step-TrimExtensionClock {
            if (-not (Test-TrimInExtension)) { return }
            $playing = ($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
            if (-not $playing) { Set-TrimExtensionClockIdle; return }
            $now = [datetime]::UtcNow
            $prev = $script:TrimExtensionClock
            Reset-TrimExtensionClock
            # First tick after entering the extension has nothing to measure from.
            if ($null -eq $prev) { return }
            $state = Get-TrimTimelineState
            $len = Get-TrimTimelineLengthCached
            $next = [double]$script:TrimExtensionOffset + ($now - $prev).TotalSeconds
            $max = [math]::Max(0.0, $len - [double]$state.TotalDuration)
            if ($next -ge $max) {
                Set-TrimExtensionPosition -Seconds $max
                Stop-TrimTransport
                return
            }
            Set-TrimExtensionPosition -Seconds $next
        }

        $script:TrimTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:TrimTimer.Interval = [timespan]::FromMilliseconds(50)
        $script:TrimTimer.Add_Tick({
            if (Test-TrimInExtension) {
                # Out past V1's end: MediaElement.Position is frozen on the last frame it
                # decoded and says nothing about where the timeline is, so wall time does.
                Step-TrimExtensionClock
            } else {
                $script:TrimPlayhead = $mediaTrimPreview.Position.TotalSeconds

                # MediaElement plays the raw source file start to finish -- it has no idea
                # a piece was deleted, so ordinary playback runs straight off the end of one
                # surviving piece and into the deleted footage after it. Catch that here and
                # jump to the next surviving piece (or stop, past the last one) so playback
                # matches what Export will actually produce.
                $state = Get-TrimTimelineState
                $containing = @($state.TimelinePieces | Where-Object {
                    $script:TrimPlayhead -ge $_.SourceStart -and $script:TrimPlayhead -lt $_.SourceEnd
                })
                if ($containing.Count -eq 0 -and $state.TimelinePieces.Count -gt 0) {
                    $next = @($state.TimelinePieces | Where-Object { $_.SourceStart -gt $script:TrimPlayhead } | Select-Object -First 1)
                    if ($next.Count -gt 0) {
                        $script:TrimPlayhead = $next[0].SourceStart
                        $mediaTrimPreview.Position = [timespan]::FromSeconds($script:TrimPlayhead)
                    } else {
                        # Past the last surviving piece: either the montage carries on out
                        # there, or this is the end of the timeline and the transport stops.
                        Stop-TrimAtV1End
                    }
                }
            }

            Update-TrimPosition
            Update-TrimTimeline -TickOnly
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            # After the fade overlay, not before: the fade owns the picture while it is up
            # and Update-CaptionOverlay reads the key it just set.
            Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
            # The caption redraw just cleared the overlay canvas the spotlight box (and the
            # PiP box) live on.
            Update-ZoomBoxOverlay
            Update-PipBoxOverlay
            # After the captions: the zoom transform is what makes the glide visible during
            # playback, and it has its own identity fast-path so a clip with no keyframes
            # pays almost nothing for being asked 20x a second.
            Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
            # And the PiP/audio-clip pools follow the same tick: video-clip elements seek
            # and play/pause with the main transport, audio-clip elements play only while
            # actually playing (see Update-TrimAudioClipPreview's own comment on why
            # scrubbing never reaches them).
            Update-PipPreview -SourceSeconds $script:TrimPlayhead
            Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $true
            # Source-stream players ride the same tick: volumes track the faders live and
            # the extracted streams stay in step with the main element.
            Update-TrimSourceAudioPreview -Playing $true
            Update-TrimBlackBase
        })

        $buttonTrimPlay.Add_Click({
            if ($buttonTrimPlay.Content -eq "Play") {
                # Play from inside the montage region does NOT start the main element: it
                # has no frame out there, and playing it would run the source on under a
                # timeline position it no longer matches. The extension clock takes over
                # from the moment the timer starts (Test-/Reset- rather than a bare
                # $script: read/write: this block IS a GetNewClosure'd one).
                if (Test-TrimInExtension) { Reset-TrimExtensionClock } else { $mediaTrimPreview.Play() }
                $buttonTrimPlay.Content = "Pause"
                Update-TrimSourceAudioPreview -Playing $true -Seek $true
                $script:TrimTimer.Start()
            } else {
                $mediaTrimPreview.Pause()
                $buttonTrimPlay.Content = "Play"
                $script:TrimTimer.Stop()
                # Pausing the main transport has to pause every PiP/audio-clip element too --
                # otherwise a video-clip PiP or an audio-clip keeps running silently past the
                # point the visible transport stopped.
                Update-PipPreview -SourceSeconds $script:TrimPlayhead
                Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $false
                Update-TrimSourceAudioPreview -Playing $false
                Update-TrimBlackBase
            }
        }.GetNewClosure())

        # The source file itself ran out. Same fork as the tick's: the montage carries on
        # if there is anything out past V1's end, otherwise the transport stops.
        $mediaTrimPreview.Add_MediaEnded({
            Stop-TrimAtV1End
        }.GetNewClosure())

        # Scrubbing: one shared seek used by the click AND by the playhead drag. -Light is
        # the per-mouse-move variant: it takes the tick's cheap timeline path (no lane-row
        # rebuild) and skips the PiP -Seek, whose per-move MediaElement.Position writes
        # would stutter the drag -- the full pass on release catches the pools up.
        # A top-level function so its bare $script: writes land in the real script scope.
        function Set-TrimScrubFromX {
            param([double]$X, [switch]$Light)
            if (-not $script:TrimInputFile) { return }
            $state = Get-TrimTimelineState
            # The position lands in timeline (compacted) space; convert to a real source
            # second before seeking, so a scrub can never target deleted footage.
            $t = Convert-TrimXToTime -X $X
            # 0.0, not 0 (trap #8): the int overload truncated every scrub click to a
            # whole second, so the playhead could never land between seconds.
            #
            # Clamped to the WHOLE timeline, not the cut list: past V1's end the position
            # is in the montage region, which is a real part of the export.
            $wasInExtension = Test-TrimInExtension
            $playing = ($null -ne $buttonTrimPlay -and $buttonTrimPlay.Content -eq "Pause")
            $tClamped = [math]::Max(0.0, [math]::Min((Get-TrimTimelineLengthCached), $t))
            $extra = $tClamped - [double]$state.TotalDuration
            # The source position is clamped to the end of the last surviving piece either
            # way -- the main element is never asked to seek past its own footage. Out in
            # the extension it is also PAUSED and the black base covers the stale frame.
            $script:TrimPlayhead = Convert-TrimTimelineToSource `
                -TimelineSeconds ([math]::Min($tClamped, [double]$state.TotalDuration)) `
                -TimelinePieces $state.TimelinePieces
            # Media seeks are THROTTLED on the light (per-mouse-move) path: a drag fires
            # dozens of moves a second, and MediaElement queues every Position write --
            # the decoder then visibly "fast-forwards" through the backlog for seconds
            # after the drag. The playhead/readout still track every move; the media
            # catches up at most ~6x/sec, and the full pass (click, release) always seeks.
            $seekNow = $true
            if ($Light) {
                $seekStamp = [datetime]::UtcNow
                if ($null -ne $script:TrimScrubLastSeek -and ($seekStamp - $script:TrimScrubLastSeek).TotalMilliseconds -lt 150) {
                    $seekNow = $false
                } else {
                    $script:TrimScrubLastSeek = $seekStamp
                }
            } else {
                $script:TrimScrubLastSeek = $null
            }
            if ($seekNow) { $mediaTrimPreview.Position = [timespan]::FromSeconds($script:TrimPlayhead) }
            if ($extra -gt 0) {
                Set-TrimExtensionPosition -Seconds $extra
                try { $mediaTrimPreview.Pause() } catch {}
            } else {
                Set-TrimExtensionPosition -Seconds 0.0
                # Coming BACK from the extension while the transport is still running: the
                # main element was paused out there and has to be handed the picture again.
                if ($wasInExtension -and $playing) { try { $mediaTrimPreview.Play() } catch {} }
            }
            Update-TrimPosition
            if ($Light) { Update-TrimTimeline -TickOnly } else { Update-TrimTimeline }
            # Scrubbing into a fade shows the blended frame too, not just playback.
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            # Scrubbing across a caption's window shows it appear and disappear on time.
            Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
            Update-ZoomBoxOverlay
            Update-PipBoxOverlay
            # And scrubbing across a glide shows the picture move with it, paused.
            Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
            if (-not $Light) {
                # Scrubbing repositions a PiP's video, but deliberately never seeks an
                # audio-clip (Update-TrimAudioClipPreview's own comment explains why).
                Update-PipPreview -SourceSeconds $script:TrimPlayhead -Seek $true
                Update-TrimAudioClipPreview -SourceSeconds $script:TrimPlayhead -Playing $false
                # The extracted source streams DO seek with a scrub -- they mirror the
                # main element, which just moved.
                Update-TrimSourceAudioPreview -Playing $playing -Seek $true
            }
            Update-TrimBlackBase
        }

        # Scrub press-and-drag, shared across surfaces: the RULER is the visible scrub
        # strip now that the SRC filmstrip row is hidden (the hidden timeline canvas
        # keeps the handlers too -- harmless, unreachable). Mouse capture goes on the
        # surface that took the press ($eventSource); the x always converts through the
        # hidden canvas, the x-axis authority every strip shares.
        #
        # No GetNewClosure() on these, same reason as the timer tick above: they write
        # $script: state, which a closure would rebind into its own private module.
        $script:TrimScrubDownHandler = {
            param($eventSource, $e)
            if (-not $script:TrimInputFile) { return }
            Set-TrimScrubFromX -X ($e.GetPosition($canvasTrimTimeline)).X
            $script:TrimScrubDrag = $true
            [void]$eventSource.CaptureMouse()
        }
        $script:TrimScrubMoveHandler = {
            param($eventSource, $e)
            if (-not $script:TrimScrubDrag) { return }
            Set-TrimScrubFromX -X ($e.GetPosition($canvasTrimTimeline)).X -Light
        }
        $script:TrimScrubUpHandler = {
            param($eventSource, $e)
            if (-not $script:TrimScrubDrag) { return }
            $script:TrimScrubDrag = $false
            $eventSource.ReleaseMouseCapture()
            # The full pass: lane rows recatch the final position and the PiP pools seek.
            Set-TrimScrubFromX -X ($e.GetPosition($canvasTrimTimeline)).X
        }
        foreach ($scrubSurface in @($canvasTrimTimeline, $canvasTrimRuler)) {
            if ($null -eq $scrubSurface) { continue }
            $scrubSurface.Add_MouseLeftButtonDown($script:TrimScrubDownHandler)
            $scrubSurface.Add_MouseMove($script:TrimScrubMoveHandler)
            $scrubSurface.Add_MouseLeftButtonUp($script:TrimScrubUpHandler)
        }

        # Grabbing the playhead LINE itself, anywhere it crosses the stack: a press within
        # 10px of the line starts the same scrub drag the ruler runs. PREVIEW (tunneling)
        # handlers, so the grab wins over whatever sits under the line -- a clip body's
        # own press never fires when the user is visibly aiming for the playhead.
        $script:TrimPlayheadGrabHandler = {
            param($eventSource, $e)
            if (-not $script:TrimInputFile) { return }
            $grabX = ($e.GetPosition($canvasTrimTimeline)).X
            $playheadX = Convert-TrimTimeToX -Seconds (Get-TrimTimelinePlayhead)
            if ([math]::Abs($grabX - $playheadX) -gt 10.0) { return }
            Set-TrimScrubFromX -X $grabX
            $script:TrimScrubDrag = $true
            [void]$eventSource.CaptureMouse()
            $e.Handled = $true
        }
        # Hover affordance: the HAND cursor whenever the pointer is inside the grab
        # tunnel (or a drag is live), the normal arrow everywhere else. Without it the
        # line gives no sign it can be held at all.
        $script:TrimPlayheadHoverHandler = {
            param($eventSource, $e)
            if (-not $script:TrimInputFile) { return }
            if ($script:TrimScrubDrag) { $eventSource.Cursor = [System.Windows.Input.Cursors]::Hand; return }
            $hoverX = ($e.GetPosition($canvasTrimTimeline)).X
            $playheadX = Convert-TrimTimeToX -Seconds (Get-TrimTimelinePlayhead)
            if ([math]::Abs($hoverX - $playheadX) -le 10.0) {
                $eventSource.Cursor = [System.Windows.Input.Cursors]::Hand
            } elseif ($null -ne $eventSource.Cursor) {
                $eventSource.Cursor = $null
            }
        }
        foreach ($grabSurface in @($panelTrimLanes, $canvasTrimCaptions, $canvasTrimZooms, $canvasTrimFades)) {
            if ($null -eq $grabSurface) { continue }
            $grabSurface.Add_PreviewMouseLeftButtonDown($script:TrimPlayheadGrabHandler)
            # The capture from the grab routes the rest of the gesture to this surface, so
            # it needs the shared move/up handlers too (both no-op unless a scrub is live).
            $grabSurface.Add_MouseMove($script:TrimScrubMoveHandler)
            $grabSurface.Add_MouseMove($script:TrimPlayheadHoverHandler)
            $grabSurface.Add_MouseLeftButtonUp($script:TrimScrubUpHandler)
        }
        # The ruler scrubs from ANY x, so the whole strip advertises it with the hand.
        if ($null -ne $canvasTrimRuler) { $canvasTrimRuler.Cursor = [System.Windows.Input.Cursors]::Hand }

        # Files dropped on the OPEN lane area (between/below the rows -- the rows mark
        # their own drops Handled) create a NEW track of the file's kind at the drop
        # position: "drag a video in" must never require "+ Video track" first.
        if ($null -ne $panelTrimLaneArea) {
            $panelTrimLaneArea.Add_PreviewDragOver({
                param($eventSource, $e)
                if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
                    $e.Effects = [System.Windows.DragDropEffects]::Copy
                    $e.Handled = $true
                }
            })
            $panelTrimLaneArea.Add_Drop({
                param($eventSource, $e)
                if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
                $files = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
                if ($files.Count -eq 0) { return }
                $t = Convert-TrimXToTime -X ($e.GetPosition($canvasTrimTimeline)).X
                foreach ($f in $files) {
                    Add-TrimMediaFromPath -Path ([string]$f) -AtTimeline ([math]::Max(0.0, $t)) -ForceNewLane
                }
                $e.Handled = $true
            })
        }

        # Ctrl + wheel zooms around the pointer, Shift + wheel PANS; a bare wheel is left
        # alone so the panel still scrolls the way every other screen does. Attached to
        # every timeline surface (ruler, lanes, caption/zoom/fade strips) because the strip
        # that used to take this wheel -- the SRC filmstrip -- is hidden now.
        $script:TrimWheelHandler = {
            param($eventSource, $e)
            if (-not $script:TrimInputFile) { return }
            $wheelCtrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
            $wheelShift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
            if (-not $wheelCtrl -and -not $wheelShift) { return }
            $state = Get-TrimTimelineState
            if ($state.TotalDuration -le 0) { return }
            $e.Handled = $true
            $viewMax = Get-TrimViewMax -TimelineLength (Get-TrimTimelineLengthCached)

            if ($wheelShift -and -not $wheelCtrl) {
                # PAN: a notch slides the view 10% of its span; wheel-down scrolls right,
                # the usual horizontal-scroll convention.
                $step = $script:TrimViewSpan * 0.1 * $(if ($e.Delta -gt 0) { -1.0 } else { 1.0 })
                $newStart = [math]::Max(0.0, [math]::Min($viewMax - $script:TrimViewSpan, $script:TrimViewStart + $step))
                Set-TrimView -Start $newStart -Span $script:TrimViewSpan
                Update-TrimTimeline -TickOnly
                Request-TrimZoomRefine
                return
            }

            # Anchor and span are both timeline (compacted) seconds -- zoom operates on
            # the same space the ruler and track are drawn in. Floor of 0.5s: below that
            # the pieces are narrower than their own borders. Ceiling of viewMax, not the
            # content length: the breathing room past the last clip is part of the view.
            $anchor = Convert-TrimXToTime -X ($e.GetPosition($canvasTrimTimeline)).X
            $factor = if ($e.Delta -gt 0) { 0.8 } else { 1.25 }
            $newSpan = [math]::Max(0.5, [math]::Min($viewMax, $script:TrimViewSpan * $factor))
            $ratio = if ($script:TrimViewSpan -gt 0) { ($anchor - $script:TrimViewStart) / $script:TrimViewSpan } else { 0.5 }
            $newStart = [math]::Max(0.0, [math]::Min($viewMax - $newSpan, $anchor - ($ratio * $newSpan)))
            Set-TrimView -Start $newStart -Span $newSpan
            # Cheap path per notch, full rebuild once the wheel goes quiet -- see the
            # comment on $script:ZoomRefineTimer.
            Update-TrimTimeline -TickOnly
            Request-TrimZoomRefine
        }
        foreach ($wheelSurface in @($canvasTrimTimeline, $canvasTrimRuler, $canvasTrimFades,
                                    $canvasTrimCaptions, $canvasTrimZooms, $panelTrimLanes)) {
            if ($null -eq $wheelSurface) { continue }
            $wheelSurface.Add_PreviewMouseWheel($script:TrimWheelHandler)
        }

        # The horizontal view scrollbar: dragging it pans the timeline. Sync-guarded so
        # the repaint writing Value back does not re-enter.
        if ($null -ne $scrollTrimView) {
            $scrollTrimView.Add_ValueChanged({
                param($eventSource, $e)
                if ($script:TrimViewScrollSync) { return }
                if (-not $script:TrimInputFile) { return }
                Set-TrimView -Start ([double]$eventSource.Value) -Span $script:TrimViewSpan
                Update-TrimTimeline -TickOnly
                Request-TrimZoomRefine
            })
        }

        # The canvas has no width until it is laid out, so the first paint must wait for it,
        # and a resize invalidates every x already computed.
        $canvasTrimTimeline.Add_SizeChanged({ Update-TrimTimeline })

        # Lane drags are driven from the CANVAS, not from the blocks: the lane is rebuilt on
        # every move, so a handler living on a block would be destroyed mid-drag. The canvas
        # holds the mouse capture and survives the redraw.
        #
        # No GetNewClosure() on these two, deliberately -- same reason as the timeline
        # canvas handlers above: they read and write $script: state, which a closure would
        # rebind into its own private module, and neither needs to capture anything.
        if ($null -ne $canvasTrimCaptions) {
            $canvasTrimCaptions.Add_MouseMove({
                param($eventSource, $e)
                if (-not (Test-TrimCaptionDrag)) { return }
                Update-TrimCaptionDrag -CurrentX ($e.GetPosition($canvasTrimCaptions)).X
                # Lane only: a handful of borders, cheap enough to redraw per mouse move,
                # where a full Update-TrimTimeline would re-request thumbnails.
                Update-TrimCaptionLane
            })

            $canvasTrimCaptions.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (-not (Test-TrimCaptionDrag)) { return }
                $canvasTrimCaptions.ReleaseMouseCapture()
                Complete-TrimCaptionDrag
                Update-TrimTimeline
            })

            # Empty lane space deselects. The blocks and their grips mark their own clicks
            # Handled and are children of this canvas, so OriginalSource being the canvas
            # itself means the click landed on bare background -- a drag start can never
            # reach here.
            $canvasTrimCaptions.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                if ($e.OriginalSource -ne $canvasTrimCaptions) { return }
                Clear-TrimCaptionSelection
            })

            $canvasTrimCaptions.Add_SizeChanged({ Update-TrimCaptionLane })
        }

        # Zoom lane drags, same three handlers and the same reasoning as the caption lane
        # above: capture lives on the canvas because the lane is rebuilt on every move, and
        # none of these take a GetNewClosure() -- they read and write $script: state through
        # top-level functions and capture nothing.
        if ($null -ne $canvasTrimZooms) {
            $canvasTrimZooms.Add_MouseMove({
                param($eventSource, $e)
                if (-not (Test-TrimZoomDrag)) { return }
                Update-TrimZoomDrag -CurrentX ($e.GetPosition($canvasTrimZooms)).X
                # Lane only: a handful of shapes, cheap per mouse move, where a full
                # Update-TrimTimeline would re-request thumbnails.
                Update-TrimZoomLane
            })

            $canvasTrimZooms.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (-not (Test-TrimZoomDrag)) { return }
                $canvasTrimZooms.ReleaseMouseCapture()
                Complete-TrimZoomDrag
                Update-TrimTimeline
            })

            # Empty lane space deselects. The diamonds mark their own clicks Handled and are
            # children of this canvas, and the ramps are not hit-testable at all, so an
            # OriginalSource of the canvas itself is bare background and never a drag start.
            $canvasTrimZooms.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                if ($e.OriginalSource -ne $canvasTrimZooms) { return }
                Clear-TrimZoomSelection
            })

            $canvasTrimZooms.Add_SizeChanged({ Update-TrimZoomLane })
        }

        # Track lanes: the panel itself is the stable element (its per-lane children are
        # rebuilt on every structural change), so a resize just needs the one redraw --
        # there is no per-lane capture to protect here since a resize cannot happen mid-drag.
        if ($null -ne $panelTrimLanes) {
            $panelTrimLanes.Add_SizeChanged({ Update-TrimLaneRows })
        }

        # The zoom translate is computed from the host's own width and height, so every
        # pixel of it is wrong until the next redraw once the box changes size -- opening the
        # caption sidebar takes 240px off it, exactly as it does off the caption overlay.
        if ($null -ne $previewZoomHost) {
            $previewZoomHost.Add_SizeChanged({ Update-PreviewZoom -SourceSeconds $script:TrimPlayhead })
        }
        # Preview-overlay drags. Capture lives on the overlay canvas for the same reason it
        # lives on the lane canvas: the overlay is rebuilt on every move, so a capture held
        # by the caption element itself would die after the first one. No GetNewClosure()
        # here either -- these read and write $script: state through top-level functions and
        # capture nothing.
        if ($null -ne $canvasCaptionOverlay) {
            # Empty video space deselects, same test as the lane: the caption box and its
            # resize handle are children that mark their own clicks Handled, so an
            # OriginalSource of the canvas itself is background and never a drag start.
            $canvasCaptionOverlay.Add_MouseLeftButtonDown({
                param($eventSource, $e)
                if ($e.OriginalSource -ne $canvasCaptionOverlay) { return }
                # With a zoom keyframe selected the same press means something else: it is
                # the corner of a new spotlight box. Nothing is decided here -- a press that
                # never travels far enough is settled as a plain click on release and falls
                # through to the deselect below.
                if ($null -ne (Get-TrimSelectedZoom)) {
                    $p = $e.GetPosition($canvasCaptionOverlay)
                    Start-ZoomBoxDrag -StartX $p.X -StartY $p.Y
                    $canvasCaptionOverlay.CaptureMouse() | Out-Null
                    return
                }
                Clear-TrimCaptionSelection
            })

            $canvasCaptionOverlay.Add_MouseMove({
                param($eventSource, $e)
                # PiP box first: it and the zoom box can never both be live (selecting a
                # track clears the zoom selection, selecting a zoom clears the track
                # selection -- Set-TrimSelectedClip/-Zoom's mutual-exclusion), so testing
                # order between the two never matters, only that both are checked before
                # falling through to the caption drag.
                if (Test-PipBoxDrag) {
                    $p = $e.GetPosition($canvasCaptionOverlay)
                    Update-PipBoxDrag -CurrentX $p.X -CurrentY $p.Y
                    Update-PipBoxOverlay
                    return
                }
                # The zoom box next: the cheaper test of the two remaining drags.
                if (Test-ZoomBoxDrag) {
                    $p = $e.GetPosition($canvasCaptionOverlay)
                    Update-ZoomBoxDrag -CurrentX $p.X -CurrentY $p.Y
                    # Box only: the forming rectangle is drawn straight from the drag, and
                    # nothing is written to the model until the button comes up.
                    Update-ZoomBoxOverlay
                    return
                }
                if (-not (Test-CaptionOverlayDrag)) { return }
                $p = $e.GetPosition($canvasCaptionOverlay)
                Update-CaptionOverlayDrag -CurrentX $p.X -CurrentY $p.Y
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
                Update-ZoomBoxOverlay
                Update-PipBoxOverlay
            })

            $canvasCaptionOverlay.Add_MouseLeftButtonUp({
                param($eventSource, $e)
                if (Test-PipBoxDrag) {
                    $canvasCaptionOverlay.ReleaseMouseCapture()
                    Complete-PipBoxDrag
                    Update-TrimLaneRows
                    Update-PipBoxOverlay
                    return
                }
                if (Test-ZoomBoxDrag) {
                    $canvasCaptionOverlay.ReleaseMouseCapture()
                    Complete-ZoomBoxDrag
                    # Full redraw: the level changed, so the lane's ramps did too -- and this
                    # is what puts the committed box back on screen in place of the forming
                    # one, through Update-TrimZoomLane.
                    Update-TrimTimeline
                    return
                }
                if (-not (Test-CaptionOverlayDrag)) { return }
                $canvasCaptionOverlay.ReleaseMouseCapture()
                Complete-CaptionOverlayDrag
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
                Update-ZoomBoxOverlay
                Update-PipBoxOverlay
            })

            # Opening or closing the sidebar takes 240px off the preview, so every X/Y
            # already converted to pixels is wrong until the next redraw -- and the box and
            # its pill are positioned in those same pixels.
            $canvasCaptionOverlay.Add_SizeChanged({
                Update-CaptionOverlay -SourceSeconds $script:TrimPlayhead
                Update-ZoomBoxOverlay
                Update-PipBoxOverlay
            })

            # Once, at startup: the pill is a live control, not a redrawn shape, and lives in
            # the canvas for the whole session with only its visibility and position changing.
            Initialize-ZoomPill
        }

        if ($null -ne $buttonTrimAddCaption) { $buttonTrimAddCaption.Add_Click({ Invoke-TrimAddCaption }) }
        if ($null -ne $buttonCaptionDelete) { $buttonCaptionDelete.Add_Click({ Invoke-TrimDeleteCaption }) }
        if ($null -ne $buttonTrimAddZoom) { $buttonTrimAddZoom.Add_Click({ Invoke-TrimAddZoom }) }
        if ($null -ne $buttonTrimAddVideoTrack) { $buttonTrimAddVideoTrack.Add_Click({ Invoke-TrimAddVideoTrack }) }
        if ($null -ne $buttonTrimAddAudioTrack) { $buttonTrimAddAudioTrack.Add_Click({ Invoke-TrimAddAudioTrack }) }
        if ($null -ne $buttonTrimUnlink) { $buttonTrimUnlink.Add_Click({ Invoke-TrimUnlink }) }
        if ($null -ne $buttonTrimSnap) { $buttonTrimSnap.Add_Click({ Set-TrimSnapEnabled -Value (-not (Get-TrimSnapEnabled)) }) }
        # Once at startup, after Import-Config seeded the flag: the magnet has to show its
        # restored state before the user touches anything.
        Update-TrimSnapButton

        # ---- Clip properties strip handlers ----
        #
        # No GetNewClosure on either of these: like the zoom pill's slider, they reach the
        # selection through top-level state only, never through a captured loop variable.
        # The gain slider and mute box that used to live here are gone -- gain and mute
        # belong to the ROW now, and the row header owns them (spec 3.2).
        if ($null -ne $buttonClipDisplayMode) {
            $buttonClipDisplayMode.Add_Click({
                if ($null -eq $script:TrimSelectedClip) { return }
                Invoke-TrimClipDisplayModeToggle -Id ([string]$script:TrimSelectedClip)
            })
        }
        if ($null -ne $buttonTrackDelete) {
            $buttonTrackDelete.Add_Click({
                # The strip is clip-scoped: this deletes the SELECTED CLIP and its linked
                # peers (spec 4.4). Deleting a ROW is the header's own trash / context menu.
                if ($null -eq $script:TrimSelectedClip) { return }
                Push-TrimUndo
                Remove-TrimClipWithLinks -Id ([string]$script:TrimSelectedClip)
                Update-TrimSelectionText
            })
        }

        # ---- Caption sidebar handlers ----
        #
        # Every one of these bails on the loading flag first: WPF raises the same events for
        # a programmatic fill as for a user edit, so without that first line selecting a
        # caption would write all nine fields back and push undo steps for edits nobody made.
        if ($null -ne $comboCaptionFont) {
            # Once, at startup: enumerating installed fonts is not free and the list cannot
            # change while the window is open. Strings rather than FontFamily objects so the
            # combo's SelectedItem compares equal to the caption's stored name.
            $comboCaptionFont.ItemsSource = @(
                [System.Windows.Media.Fonts]::SystemFontFamilies | Sort-Object Source | ForEach-Object { $_.Source }
            )
            $comboCaptionFont.Add_SelectionChanged({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                $font = [string]$comboCaptionFont.SelectedItem
                if ([string]::IsNullOrEmpty($font) -or $font -eq [string]$cap.FontFamily) { return }
                Push-TrimUndo
                Update-CaptionField -Id $cap.Id -Field "FontFamily" -Value $font
            })
        }

        if ($null -ne $textCaptionText) {
            $textCaptionText.Add_TextChanged({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Update-CaptionField -Id $cap.Id -Field "Text" -Value ([string]$textCaptionText.Text)
            })
            # One undo step per visit to the box, not one per keystroke.
            $textCaptionText.Add_GotFocus({ Start-CaptionTextEdit })
            $textCaptionText.Add_LostFocus({ Complete-CaptionTextEdit })
        }

        if ($null -ne $checkCaptionBold) {
            $checkCaptionBold.Add_Click({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Push-TrimUndo
                Update-CaptionField -Id $cap.Id -Field "Bold" -Value ([bool]$checkCaptionBold.IsChecked)
            })
        }

        if ($null -ne $checkCaptionBounce) {
            $checkCaptionBounce.Add_Click({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Push-TrimUndo
                Update-CaptionField -Id $cap.Id -Field "BounceIn" -Value ([bool]$checkCaptionBounce.IsChecked)
            })
        }

        if ($null -ne $sliderCaptionOutlineW) {
            $sliderCaptionOutlineW.Add_ValueChanged({
                if (Test-CaptionSidebarLoading) { return }
                $cap = Get-TrimSelectedCaption
                if ($null -eq $cap) { return }
                Update-CaptionField -Id $cap.Id -Field "OutlineWidth" -Value ([double]$sliderCaptionOutlineW.Value)
            })
            # Undo brackets the whole drag: ValueChanged fires on every tick of one.
            $sliderCaptionOutlineW.Add_GotMouseCapture({ Start-CaptionSliderEdit })
            $sliderCaptionOutlineW.Add_LostMouseCapture({ Complete-CaptionSliderEdit })
        }

        # Colours and times are validated on the way OUT of the box, not per keystroke:
        # "#00FF0" is a legitimate intermediate state of typing "#00FF00".
        # Built once at startup, not per selection: the palette is fixed, and rebuilding it
        # on every Show-CaptionSidebar would throw away twelve buttons and their handlers
        # on each click of a lane block.
        Add-CaptionSwatches -Panel $panelCaptionFillSwatches -Field "FillColor"
        Add-CaptionSwatches -Panel $panelCaptionOutlineSwatches -Field "OutlineColor"

        if ($null -ne $textCaptionFill) {
            $textCaptionFill.Add_LostFocus({ Set-CaptionColorFromBox -Box $textCaptionFill -Field "FillColor" })
        }
        if ($null -ne $textCaptionOutline) {
            $textCaptionOutline.Add_LostFocus({ Set-CaptionColorFromBox -Box $textCaptionOutline -Field "OutlineColor" })
        }
        if ($null -ne $textCaptionStart) {
            $textCaptionStart.Add_LostFocus({ Set-CaptionTimeFromBox -Box $textCaptionStart -Edge "start" })
        }
        if ($null -ne $textCaptionEnd) {
            $textCaptionEnd.Add_LostFocus({ Set-CaptionTimeFromBox -Box $textCaptionEnd -Edge "end" })
        }

        $buttonTrimSplit.Add_Click({ Invoke-TrimSplit })
        $buttonTrimDelete.Add_Click({ Invoke-TrimDelete })
        $buttonTrimUndo.Add_Click({ Invoke-TrimUndo })
        if ($null -ne $buttonTrimRedo) { $buttonTrimRedo.Add_Click({ Invoke-TrimRedo }) }
        if ($null -ne $buttonTrimOpenAnother) {
            # Funnels into the dropzone's own Click so the file-dialog flow (and any
            # future changes to it) stays in exactly one place. A collapsed button
            # still handles a programmatic RaiseEvent.
            $buttonTrimOpenAnother.Add_Click({
                $buttonTrimBrowse.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            })
        }

        # Handled at the window, then filtered to the Trim panel: the Canvas cannot hold
        # focus reliably and a panel-level handler would miss keys pressed over the preview.
        # Guarded on TextBox focus so typing a URL on another screen never triggers a split.
        $ctx.Window.Add_PreviewKeyDown({
            param($eventSource, $e)
            if ($ctx.Panels.Trim.Visibility -ne "Visible") { return }
            if (-not $script:TrimInputFile) { return }
            if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
            # The whole caption sidebar is an input surface: typing S into the font
            # dropdown must type-ahead to Sitka, not split the video. IsKeyboardFocusWithin
            # covers the combo (and its popup items), the sliders and the checkboxes in
            # one test instead of enumerating control types.
            if ($null -ne $panelCaptionSidebar -and $panelCaptionSidebar.IsKeyboardFocusWithin) { return }
            # The floating zoom pill's buttons keep keyboard focus after a click, and a
            # focused button activates on Space -- so Space alone is swallowed here, or
            # play/pause would also re-click the magnet or Delete. Everything else
            # (Ctrl+Z/Y, C, Z, S, DEL) must keep working right after tapping a pill
            # control: a blanket return here was exactly what deadened every shortcut
            # until the user happened to click elsewhere.
            if ($null -ne $script:ZoomPillBorder -and $script:ZoomPillBorder.IsKeyboardFocusWithin -and
                $e.Key -eq [System.Windows.Input.Key]::Space) { return }

            $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0

            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::Z) { Invoke-TrimUndo; $e.Handled = $true; return }
            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::Y) { Invoke-TrimRedo; $e.Handled = $true; return }
            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::S) { [void](Invoke-TrimProjectSaveNow); $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::S -and -not $ctrl) { Invoke-TrimSplit; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::C -and -not $ctrl) { Invoke-TrimAddCaption; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::Z -and -not $ctrl) { Invoke-TrimAddZoom; $e.Handled = $true; return }
            if ($e.Key -eq [System.Windows.Input.Key]::U -and -not $ctrl) { Invoke-TrimUnlink; $e.Handled = $true; return }
            # N toggles snapping (the magnet), a tool mode that outlives the session --
            # read back through Get-TrimSnapEnabled rather than the bare $script: variable.
            if ($e.Key -eq [System.Windows.Input.Key]::N -and -not $ctrl) {
                Set-TrimSnapEnabled -Value (-not (Get-TrimSnapEnabled))
                $e.Handled = $true
                return
            }
            if ($e.Key -eq [System.Windows.Input.Key]::Delete) {
                # A selected zoom keyframe wins. Selecting one clears the caption selection
                # and vice versa, so at most one of these is ever armed -- but a piece can be
                # selected at the same time as a keyframe, and deleting footage is the far
                # more destructive of the two to do by accident.
                if ($null -ne (Get-TrimSelectedZoom)) { Invoke-TrimDeleteZoom }
                # A selected CLIP comes next, for the same reason: selecting one clears the
                # caption/zoom selections (Set-TrimSelectedClip), but a cut-list PIECE can
                # still be selected alongside it, and removing one clip is far less
                # destructive than removing a stretch of the source footage.
                elseif ($null -ne $script:TrimSelectedClip) {
                    Push-TrimUndo
                    Remove-TrimClipWithLinks -Id ([string]$script:TrimSelectedClip)
                    Update-TrimSelectionText
                }
                else { Invoke-TrimDelete }
                $e.Handled = $true
                return
            }
            if ($e.Key -eq [System.Windows.Input.Key]::Space) {
                $buttonTrimPlay.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                $e.Handled = $true
            }
        })
    }

    # Extracted to a variable so the recent-files rows can invoke the identical
    # handler. Still no GetNewClosure() -- see the note above about $script: writes
    # landing in a dynamic module and silently disabling the start button.
    $onTrimFile = {
        param($path)
        if (-not $script:TrimEditorReady) { return $false }

        # Unsaved work on the OUTGOING file: ask before it is lost (saving is explicit
        # now). Cancel aborts the switch entirely and the current file stays open.
        if (-not (Confirm-TrimUnsavedWork)) { return $false }

        $props = Get-VideoProperties -inputFile $path
        if (-not $props) {
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text "Could not read that file. Is it a valid video?"
            $cardTrimEditor.Visibility = "Collapsed"
            return $false
        }

        $script:TrimInputFile = $path
        $script:TrimDuration = $props.Duration.TotalSeconds
        $script:TrimCutList = New-CutList -Duration $script:TrimDuration
        $script:TrimUndoStack = New-Object System.Collections.ArrayList
        $script:TrimRedoStack = New-Object System.Collections.ArrayList
        Update-TrimRedoButton
        # Fades belong to the file that was being edited: keys are source times, so
        # keeping them across a file swap would drop fades onto unrelated timestamps.
        $script:TrimFades = @{}
        $script:TrimActiveFade = $null
        # Captions belong to the file they were written over -- their times are source
        # seconds, so carrying them across a file swap would strand them on unrelated
        # footage. A drag in progress across a file pick is dropped for the same reason.
        $script:TrimCaptions = New-Object System.Collections.ArrayList
        $script:TrimSelectedCaption = $null
        $script:TrimCaptionDrag = $null
        # Zoom keyframes belong to the file they were written against for exactly the same
        # reason captions do -- their times are source seconds. A drag in progress across a
        # file pick is dropped with them.
        $script:TrimZooms = New-Object System.Collections.ArrayList
        $script:TrimSelectedZoom = $null
        $script:TrimZoomDrag = $null
        # Lanes belong to the file they were probed against for exactly the same reason --
        # never left $null (the Export-CutListAsync audio-only trap), always reset to an
        # empty ArrayList here and filled in below once the project/default stack is known.
        $script:TrimLanes = New-Object System.Collections.ArrayList
        $script:TrimSelectedClip = $null
        $script:TrimSelectedLane = $null
        $script:TrimCollapsedLanes = @{}
        $script:TrimClipDrag = $null
        $script:TrimLaneReorderDrag = $null
        $script:TrimClipElements = @{}
        $script:TrimSnapFlashLine = $null
        $script:TrimLaneReorderLine = $null
        # Reset to the legacy/unknown sentinel here; set to the real probed count a few
        # lines below once Get-TrimAudioStreams has run against the new file.
        $script:TrimSourceAudioStreamCount = -1
        # The previous file's external clips are unrelated to whatever the new file's
        # project restores below -- every pooled PiP/audio-clip MediaElement is torn down
        # rather than left playing (or sitting in the visual tree) against a file that is
        # no longer open, and the duration/aspect caches are keyed by path so they carry
        # no meaning across files either.
        Clear-TrimClipMediaElementPools
        # Same teardown for the extracted source-stream players: they point at temp files
        # cut from the PREVIOUS recording.
        Clear-TrimSourceStreamAudio
        $script:TrimClipDurations = @{}
        $script:TrimClipAspect = @{}
        $script:PipBoxDrag = $null
        # Whatever the previous file's glide left on the preview would otherwise sit over the
        # new file's first frame until something happens to redraw it.
        Update-PreviewZoom -SourceSeconds 0.0
        $script:TrimSelected = -1
        $script:TrimPlayhead = 0.0
        # A new file has no montage region until its own project restores one; leaving the
        # previous file's extension offset set would put the playhead past an end that no
        # longer exists.
        Set-TrimExtensionPosition -Seconds 0.0
        $script:TrimTimelineLengthCache = 0.0
        $script:TrimViewStart = 0.0
        # The view OPENS at content + breathing room -- the same Get-TrimViewMax the
        # clamps use. Setting the bare duration here (the old value) meant an UNCUT video
        # filled the strip edge to edge with no empty track to drop new clips onto; the
        # clamp only ever shrinks, so the slack has to be present from the start.
        $script:TrimViewSpan = Get-TrimViewMax -TimelineLength $script:TrimDuration
        # Empty until the async read lands; Find-NearestKeyframe treats that as "no
        # snapping" rather than "cannot cut".
        $script:TrimKeyframes = @()
        # The save warning is per file: a new pick deserves its own chance to report a
        # folder it cannot write to.
        $script:ProjectSaveWarned = $false

        # Restore whatever was last saved for this video, over the fresh state above and
        # before the first Update-TrimTimeline so the panel draws the restored edit once
        # rather than drawing the empty cut list first and flickering to it.
        # @() around the array members: Read-TrimProject hands back a hashtable whose
        # CutList/Captions values are arrays, and a one-element array unrolls to a bare
        # object on assignment without it.
        $project = Read-TrimProject -VideoPath $path
        # A file is there but unreadable (hand-edited, truncated, written by a newer
        # version). Reported rather than silently discarded -- but only further down,
        # after the unconditional message clear, which would otherwise wipe it.
        $projectUnreadable = $false
        # Keyframes the reader could not make sense of. Reported below rather than silently
        # dropped: a project that comes back with fewer zooms than it was saved with is
        # something the user needs to know about before they export.
        $droppedZooms = 0
        if ($project) {
            $script:TrimCutList = @($project.CutList)
            $script:TrimFades = $project.Fades
            $script:TrimCaptions = New-Object System.Collections.ArrayList
            foreach ($c in @($project.Captions)) { [void]$script:TrimCaptions.Add($c) }
            $script:TrimZooms = New-Object System.Collections.ArrayList
            foreach ($z in @($project.Zooms)) { [void]$script:TrimZooms.Add($z) }
            if ($project.DroppedZooms -gt 0) { $droppedZooms = [int]$project.DroppedZooms }
        } elseif (Test-Path -LiteralPath (Get-TrimProjectPath -VideoPath $path)) {
            $projectUnreadable = $true
        }

        # Lane stack: probe the file's own audio streams so the default stack (and every
        # source audio clip's StreamIdx) reflects THIS file, not whatever the previous one
        # had. Synchronous, same as the ffprobe call Get-VideoProperties already made above --
        # both are quick metadata reads, not the frame decode the keyframe scan needs async.
        $streams = Get-TrimAudioStreams -InputFile $path
        # @($streams).Count, not $streams.Count: Get-TrimAudioStreams always returns a real
        # array (ConvertFrom-AudioStreamProbe's `return ,@($result)`), so this is
        # belt-and-suspenders against the @($null).Count -eq 1 trap, not a fix for a real
        # null -- same defensive habit as the -Lanes wrapping at the export call site below.
        $script:TrimSourceAudioStreamCount = @($streams).Count
        # The preview's per-stream playback: remember the file order of the stream indices
        # (the FIRST is what the main element decodes). The extraction requests fire
        # further down, AFTER $script:TrimThumbDir is created for this file -- they write
        # into it, and on the very first load it does not exist yet at this point.
        $script:TrimSourceStreamOrder = @(@($streams) | ForEach-Object { [int]$_.StreamIdx })
        if ($project -and $null -ne $project.Lanes -and @($project.Lanes).Count -gt 0) {
            # Restored lanes carry whatever Path was on disk at save time. The MAIN lane's
            # video clip is BY DEFINITION the loaded file -- not a movable reference to it --
            # so if the file has since moved (renamed, relocated), its recorded Path is
            # stale and must be rewritten to $path (the file we just resolved to load). Its
            # linked source audio clips travel with it, as does any clip that still points
            # at the OLD main path. Genuinely external clips are left untouched.
            $restored = @($project.Lanes)
            $mainLink = ""
            $oldMainPath = ""
            foreach ($ln in $restored) {
                foreach ($c in @($ln.Clips)) {
                    if (Test-TrimClipIsMainVideo -Lane $ln -Clip $c) {
                        $mainLink = [string]$c.LinkId
                        $oldMainPath = [string]$c.Path
                        $c.Path = $path
                    }
                }
            }
            foreach ($ln in $restored) {
                foreach ($c in @($ln.Clips)) {
                    if ($c.Kind -ne "audio") { continue }
                    $matchesLink = (-not [string]::IsNullOrEmpty($mainLink) -and [string]$c.LinkId -eq $mainLink)
                    $matchesPath = (-not [string]::IsNullOrEmpty($oldMainPath) -and [string]$c.Path -eq $oldMainPath)
                    if ($matchesLink -or $matchesPath) { $c.Path = $path }
                }
            }
            Set-TrimLanes -Lanes $restored
        } else {
            # No lanes to restore (a v1 project, no project file at all, or one that saved
            # an empty stack) -- the app builds the default lane stack: the recording's own
            # V1 lane plus one always-visible audio row per stream this file actually has.
            # No @() wrapper here: Get-TrimLaneStack already does `return ,@($lanes)`, and
            # wrapping an already-real array in another @() nests it one level deeper
            # (trap #2), which delivered a "list" of Count 1 holding the whole array.
            Set-TrimLanes -Lanes (Get-TrimLaneStack -Path $path -AudioStreams $streams)
        }
        # A restored project's external clips were probed against a PREVIOUS session's cache
        # (TrimClipDurations/TrimClipAspect were just cleared above) -- without re-probing
        # here, every one of them would read InEnd 0 as "SourceDuration 0.0" and land as a
        # zero-length span, invisible on both the row and the PiP preview.
        foreach ($ln in @($script:TrimLanes)) {
            foreach ($c in @($ln.Clips)) {
                if (Test-TrimClipIsMainVideo -Lane $ln -Clip $c) { continue }
                $tp = [string]$c.Path
                if ($tp -eq [string]$path) { continue }
                if (-not $script:TrimClipDurations.ContainsKey($tp)) {
                    $script:TrimClipDurations[$tp] = Get-TrimClipDuration -Path $tp
                }
                # Images get an aspect too: ffprobe reads their dimensions fine, and the
                # magnet-locked PiP resize needs one for every visual clip.
                if (($c.Kind -eq "video" -or $c.Kind -eq "image") -and -not $script:TrimClipAspect.ContainsKey($tp)) {
                    $clipProfile = Get-TrimSourceProfile -InputFile $tp
                    $script:TrimClipAspect[$tp] = if ([double]$clipProfile.Height -gt 0) {
                        [double]$clipProfile.Width / [double]$clipProfile.Height
                    } else { 16.0 / 9.0 }
                }
            }
        }

        # A second file's thumbnails are for a different source and must not be served
        # from the first file's cache -- keyed only by second, not by file.
        if ($script:TrimThumbDir -and (Test-Path $script:TrimThumbDir)) {
            Remove-Item -LiteralPath $script:TrimThumbDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:TrimThumbDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-thumbs-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TrimThumbDir -Force | Out-Null
        $script:TrimThumbCache = @{}
        $script:TrimThumbPending = @{}
        # Now that the per-file temp dir exists: queue EVERY source audio stream for
        # extraction (see $script:TrimSourceStreamOrder / Update-TrimSourceAudioPreview --
        # the first stream needs its own element too, because which stream the main
        # element decodes is not reliable). Sequential on purpose: parallel ffmpegs
        # reading the same multi-GB recording thrash the disk playback decodes from.
        # The old file's extracted wavs died with its thumb dir above.
        $script:TrimExtAudioWav = @{}
        $script:TrimExtAudioPending = @{}
        $script:TrimSourceStreamQueue = @(@($script:TrimSourceStreamOrder) | ForEach-Object { [int]$_ })
        Start-TrimSourceStreamQueue
        # Waveform strips get a PERSISTENT on-disk cache, unlike the thumbnails: they
        # took a visible couple of seconds to re-render on every single file open, and
        # a waveform never changes for a given source file. Keyed by path + size +
        # mtime so a re-recorded file with the same name renders fresh. The in-memory
        # caches still reset per file open like everything else.
        $script:TrimWaveCache = @{}
        $script:TrimWavePending = @{}
        # Row media (filmstrips + per row waveforms): the QUEUE is dropped on a new file
        # open -- those jobs were for the previous stack -- but the claimed-key set is
        # dropped with it so the new stack can ask again. Any job already in flight is
        # left to finish and land in the (now unused) cache rather than being aborted
        # mid-ffmpeg.
        $script:TrimStripPending = New-Object System.Collections.ArrayList
        $script:TrimRowMediaClaimed = @{}
        $script:TrimStripImages = @{}
        $script:TrimRowMediaDirty = $false
        try {
            $srcInfo = Get-Item -LiteralPath $path
            $waveKeySource = "{0}|{1}|{2:o}" -f $srcInfo.FullName.ToLowerInvariant(), $srcInfo.Length, $srcInfo.LastWriteTimeUtc
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $hash = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($waveKeySource)) |
                ForEach-Object { $_.ToString("x2") }) -join ""
            $md5.Dispose()
            $script:TrimWaveCacheDir = Join-Path $env:LOCALAPPDATA ("FFmpegGUI\wavecache\" + $hash.Substring(0, 20))
            New-Item -ItemType Directory -Path $script:TrimWaveCacheDir -Force | Out-Null
        } catch {
            # Cache dir is an optimization only; on any failure fall back to the
            # per-launch temp dir and behave exactly as before.
            $script:TrimWaveCacheDir = $script:TrimThumbDir
        }

        # Same reasoning for the rendered fades, and the overlay has to be taken down as
        # well: it is keyed by source time, so leaving it up would show the previous
        # file's blend over the new file's footage.
        if ($script:TrimFadeProxyDir -and (Test-Path $script:TrimFadeProxyDir)) {
            Remove-Item -LiteralPath $script:TrimFadeProxyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:TrimFadeProxyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-fades-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TrimFadeProxyDir -Force | Out-Null
        $script:TrimFadeProxies = @{}
        $script:TrimFadeProxyPending = @{}
        $script:TrimFadeOverlayKey = $null
        if ($null -ne $mediaTrimFadePreview) {
            $mediaTrimFadePreview.Visibility = "Collapsed"
            $mediaTrimFadePreview.Source = $null
        }

        if ($projectUnreadable) {
            Show-PanelMessage -Block $textTrimMeta -IsError `
                -Text "Couldn't read the saved project for this video. Starting fresh."
        } elseif ($droppedZooms -gt 0) {
            # A warning, not an error: everything else in the project loaded fine and the
            # editor is perfectly usable -- there are simply fewer keyframes than there were.
            $noun = if ($droppedZooms -eq 1) { "zoom keyframe" } else { "zoom keyframes" }
            $verb = if ($droppedZooms -eq 1) { "couldn't be read and was skipped" }
                    else { "couldn't be read and were skipped" }
            Show-PanelMessage -Block $textTrimMeta -IsWarning `
                -Text ("{0} {1} {2}" -f $droppedZooms, $noun, $verb)
        } else {
            Show-PanelMessage -Block $textTrimMeta -Text ""
        }
        $cardTrimEditor.Visibility = "Visible"
        $mediaTrimPreview.Source = New-Object System.Uri($path)
        $mediaTrimPreview.Pause()
        $buttonTrimExport.IsEnabled = $true
        # Picking a second file must not leave the previous file's selection on screen,
        # nor its Delete button live against an index into a cut list that is now gone.
        $buttonTrimDelete.IsEnabled = $false
        # Nothing is selected in the new file, so the properties column must not be left
        # open over the previous file's caption.
        Hide-CaptionSidebar
        Update-TrimSelectionText
        Update-TrimTimeline
        # AFTER Update-TrimTimeline, not before: the readout's denominator is the cached
        # timeline length, and the load-path refresh of that cache is inside
        # Update-TrimTimeline -- painted first, a montage project shows V1's length until
        # the next repaint.
        Update-TrimPosition
        # After the load, not just the reset above: a project whose first keyframe sits AT
        # 0:00 zoomed is zoomed from the very first frame, so leaving the preview at
        # identity until the first scrub would show a picture the model does not agree
        # with. Posted at Loaded priority because PreviewZoomHost has no
        # ActualWidth yet on the pass that makes the card visible, and the translate is
        # computed from it -- called inline it would centre on a zero-sized box.
        # GetNewClosure: the block runs after this handler has returned. Read-only capture,
        # so no $script: write can land in the closure's private module.
        if ($null -ne $previewZoomHost) {
            $previewZoomHost.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Loaded,
                [action]({
                    Update-PreviewZoom -SourceSeconds $script:TrimPlayhead
                    # Same reasoning as the zoom: PreviewBox has no size yet on the pass
                    # that makes the card visible, so a restored project's PiP tracks would
                    # otherwise sit invisible/mispositioned until the next tick or scrub.
                    Update-TrimPreviewStackOrder
                    Update-PipPreview -SourceSeconds $script:TrimPlayhead -Seek $true
                    Update-TrimBlackBase
                }.GetNewClosure())) | Out-Null
        }
        Start-TrimKeyframeRead -Path $path

        # With a file open, the huge dropzone and the recent list are just 400 vertical
        # pixels standing between the user and the timeline -- the whole reason the
        # editor used to need scrolling on a 1440p screen. They collapse here and the
        # small "Open another video" button in the transport row takes over their job
        # (it raises the dropzone's own Click, so the file dialog flow stays identical).
        if ($null -ne $buttonTrimBrowse) { $buttonTrimBrowse.Visibility = "Collapsed" }
        if ($null -ne $cardRecentTrim) { $cardRecentTrim.Visibility = "Collapsed" }
        if ($null -ne $buttonTrimOpenAnother) { $buttonTrimOpenAnother.Visibility = "Visible" }
        # A fresh load IS the saved state (or a clean default) -- nothing dirty yet.
        $script:TrimProjectDirty = $false
        return $true
    }

    Register-Dropzone -Button $panelTrim.FindName("ButtonTrimBrowse") -OnFile $onTrimFile

    $cardRecentCompress = $panelCompress.FindName("CardRecentCompress")
    $panelRecentCompress = $panelCompress.FindName("PanelRecentCompress")
    $cardRecentMerge = $panelMerge.FindName("CardRecentMerge")
    $panelRecentMerge = $panelMerge.FindName("PanelRecentMerge")
    $cardRecentTrim = $panelTrim.FindName("CardRecentTrim")
    $panelRecentTrim = $panelTrim.FindName("PanelRecentTrim")

    Update-AllRecentLists

