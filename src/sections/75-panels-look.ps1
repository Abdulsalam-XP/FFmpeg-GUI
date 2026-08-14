# 75-panels-look.ps1 -- transport/keys wiring, YouTube panels, settings toggles, look picker, petals.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

    if ($script:TrimEditorReady) {
        # Fade length picker. Selection is carried on Tag, which the button template's
        # trigger styles -- the same "set state from code, let the template react" shape
        # the rest of this panel uses.
        #
        # It edits the ACTIVE fade (the pill last clicked), falling back to setting the
        # default for the next one when no fade is selected. Applying to every fade at
        # once, which is what this used to do, makes a per-cut decision impossible.
        function Sync-TrimFadeLengthButtons {
            $current = if ($null -ne $script:TrimActiveFade) {
                Get-TrimFadeLength -SourceSeconds $script:TrimActiveFade
            } else {
                $script:TrimFadeSeconds
            }
            foreach ($entry in $fadeLengthButtons.GetEnumerator()) {
                if ($null -eq $entry.Value) { continue }
                $entry.Value.Tag = if ([math]::Abs($entry.Key - $current) -lt 0.001) { "selected" } else { "" }
            }
        }

        function Set-TrimFadeSeconds {
            param([double]$Seconds)
            # Retiming an EXISTING fade is undoable; merely changing the default for the
            # next fade is not model state and must not burn a no-op undo step.
            if ($null -ne $script:TrimActiveFade) { Push-TrimUndo }
            # Always update the default too, so the next fade added matches the last
            # length chosen rather than snapping back to 0.5s.
            $script:TrimFadeSeconds = $Seconds
            if ($null -ne $script:TrimActiveFade) {
                Set-TrimFade -SourceSeconds $script:TrimActiveFade -Enabled $true -Seconds $Seconds
            }
            Sync-TrimFadeLengthButtons
            Update-TrimTimeline
            Update-TrimFadeOverlay -SourceSeconds $script:TrimPlayhead
            Request-TrimProjectSave
        }

        foreach ($entry in $fadeLengthButtons.GetEnumerator()) {
            if ($null -eq $entry.Value) { continue }
            $seconds = [double]$entry.Key
            $entry.Value.Add_Click({ Set-TrimFadeSeconds -Seconds $seconds }.GetNewClosure())
        }
        Sync-TrimFadeLengthButtons

        $buttonTrimExport.Add_Click({
            if (-not $script:TrimInputFile) {
                Show-PanelMessage -Block $textTrimMeta -Text "Pick a video first." -IsError
                return
            }
            $pieces = @($script:TrimCutList)
            if ($pieces.Count -eq 0) {
                Show-PanelMessage -Block $textTrimMeta -IsError `
                    -Text "Nothing left to export -- every piece was deleted."
                return
            }

            # Assigned directly, never wrapped in @(): Get-TrimFadeFlags returns a
            # [bool[]] via ",(...)", and @() around that produces a one-element array
            # holding the bool[] -- which then fails to bind to Export-CutListAsync's
            # [bool[]] parameter with "cannot convert Boolean[] to Boolean" and takes
            # the whole window down, since this runs inside the message loop.
            $fadeLengths = Get-TrimFadeLengths -Pieces $pieces
            $anyFade = @($fadeLengths | Where-Object { $_ -gt 0 }).Count -gt 0

            # [object[]] cast for the same reason Get-TrimFadeLengths casts: an empty
            # bare @() binds to a typed array parameter as $null, and an empty caption
            # list is the normal case for a plain trim.
            $captions = [object[]]@($script:TrimCaptions)
            $anyCaption = @($captions | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Text) }).Count -gt 0

            # [object[]] cast for the same reason the captions get one: an empty bare @()
            # binds to a typed array parameter as $null, and no keyframes at all is the
            # normal case for a plain trim.
            $zooms = [object[]]@($script:TrimZooms)
            $zoomSpans = Get-TrimZoomSpans -Zooms $zooms -Pieces $pieces
            $anyZoom = $zoomSpans.Count -gt 0

            if ($anyFade -or $anyCaption -or $anyZoom) {
                # Both crossfades and burned captions re-encode the segments they touch,
                # and only h264/hevc have an encoder mapped. Anything else would splice a
                # differently-coded segment between copied ones and produce a file that
                # changes codec halfway through.
                $sourceProfile = Get-TrimSourceProfile -InputFile $script:TrimInputFile
                if (-not $sourceProfile.VideoEncoder) {
                    $reason = if ($anyFade) { "Fades need to re-encode across each cut" }
                        elseif ($anyCaption) { "Burning captions needs to re-encode the parts they cover" }
                        else { "Zooming needs to re-encode the parts it covers" }
                    Show-PanelMessage -Block $textTrimMeta -IsError -Text (
                        "{0}, and this file's video codec ({1}) is not one this app can re-encode. Remove them to export with plain cuts." -f $reason, $sourceProfile.VideoCodec)
                    return
                }
            }
            if ($anyFade) {
                $problem = Get-TrimFadeProblem -Pieces $pieces
                if ($problem) {
                    Show-PanelMessage -Block $textTrimMeta -IsError -Text $problem
                    return
                }
            }

            # A crossfade eats the outgoing piece's last fade-length of footage and blends
            # it with the next piece's head in one xfade pass. There is nowhere in that
            # pass to also apply a per-side crop, so a zoom overlapping a fade would have
            # to be silently dropped -- refuse instead. The windows match exactly the
            # footage the transition segment consumes, which is what
            # Split-TrimSegmentsForZooms throws on if one ever slips through.
            #
            # BOTH halves have to be tested. The transition eats the outgoing piece's last
            # $len seconds AND the incoming piece's first $len seconds, and a zoom sitting
            # only over the incoming head is just as impossible to render: the preview
            # glides through it while the export hard-cuts to the zoom level the following
            # segment starts at.
            if ($anyZoom -and $anyFade) {
                $clash = $false
                for ($b = 0; $b -lt $pieces.Count - 1 -and -not $clash; $b++) {
                    if ($b -ge $fadeLengths.Count) { break }
                    $len = [double]$fadeLengths[$b]
                    if ($len -le 0) { continue }
                    $windows = @(
                        @{ Start = ([double]$pieces[$b].End - $len); End = [double]$pieces[$b].End },
                        @{ Start = [double]$pieces[$b + 1].Start; End = ([double]$pieces[$b + 1].Start + $len) }
                    )
                    foreach ($w in $windows) {
                        foreach ($span in $zoomSpans) {
                            if ([double]$span.Start -lt [double]$w.End -and [double]$span.End -gt [double]$w.Start) {
                                $clash = $true
                                break
                            }
                        }
                        if ($clash) { break }
                    }
                }
                if ($clash) {
                    Show-PanelMessage -Block $textTrimMeta -IsError `
                        -Text "Move the zoom or the fade -- a zoomed crossfade isn't supported yet."
                    return
                }
            }

            # ---- Lane pre-flight refusals ----
            #
            # An empty stack (every lane, or every clip, deleted) has nothing left to
            # export -- checked before the missing-file scan below, which would otherwise
            # just report nothing at all with no explanation.
            $laneCount = @($script:TrimLanes).Count
            $clipTotal = 0
            foreach ($l in @($script:TrimLanes)) { $clipTotal += @($l.Clips).Count }
            if ($laneCount -eq 0 -or $clipTotal -eq 0) {
                Show-PanelMessage -Block $textTrimMeta -IsError -Text "Every track was deleted -- nothing to export."
                return
            }
            # Missing external files (main-path clips are the loaded file, always present).
            # A clip's file can vanish between being added and export time (moved, renamed,
            # deleted, or a removable drive unplugged) -- caught here rather than letting
            # ffmpeg fail deep inside the rebuild pipeline with an opaque error.
            $missing = $null
            foreach ($l in @($script:TrimLanes)) {
                foreach ($c in @($l.Clips)) {
                    if ($c.Path -ne $script:TrimInputFile -and -not (Test-Path -LiteralPath $c.Path)) { $missing = $c; break }
                }
                if ($null -ne $missing) { break }
            }
            if ($null -ne $missing) {
                Show-PanelMessage -Block $textTrimMeta -IsError `
                    -Text ("Can't find {0} -- it moved or was deleted." -f [System.IO.Path]::GetFileName($missing.Path))
                return
            }
            # Overlay spans, TIMELINE (compacted) time -- built once here and reused both for
            # the transition-clash refusal and the export call site itself.
            $overlaySpans = Get-TrimOverlaySpans -Lanes @($script:TrimLanes) -MainPath $script:TrimInputFile -ClipDurations $script:TrimClipDurations
            # Same reasoning as the zoomed-crossfade refusal above: an overlay has nowhere to
            # composite onto during a crossfade's own xfade pass. Test-PipTransitionClash
            # (Tracks.psm1) already carries the Task 4-adjudicated [T, T+d] window semantics
            # -- called here rather than reimplemented, and the overlay spans carry the same
            # Start/End keys the v2 pip spans did.
            if (Test-PipTransitionClash -PipSpans @($overlaySpans) -Pieces $pieces -FadeLengths $fadeLengths) {
                Show-PanelMessage -Block $textTrimMeta -IsError `
                    -Text "Move the clip or the fade -- a clip over a crossfade isn't supported yet."
                return
            }
            # The full timeline, including any lane content that runs past the last piece --
            # the export extends the video with black rather than truncating it.
            $timelineLength = Get-TrimTimelineLength -Lanes @($script:TrimLanes) -Pieces $pieces -FadeLengths $fadeLengths `
                -ClipDurations $script:TrimClipDurations -MainPath $script:TrimInputFile

            # Fonts are resolved by libass at burn time, from the fonts installed on THIS
            # machine. A name that is not installed still exports -- libass substitutes --
            # so this warns and carries on rather than refusing: a blocked export helps
            # nobody when the only consequence is a different typeface.
            $missingFonts = @(@($captions |
                Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Text) } |
                ForEach-Object { [string]$_.FontFamily } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique) |
                Where-Object { $name = $_
                    -not (@([System.Windows.Media.Fonts]::SystemFontFamilies) |
                        Where-Object { $_.Source -eq $name }).Count })
            if ($missingFonts.Count -gt 0) {
                Show-PanelMessage -Block $textTrimMeta -IsWarning -Text (
                    "This PC has no font called {0}, so those captions will burn in a substitute typeface." -f ($missingFonts -join ", "))
            } else {
                Show-PanelMessage -Block $textTrimMeta -Text ""
            }
            # -Lanes @($script:TrimLanes), never a bare $script:TrimLanes: the PS 5.1
            # @($null).Count -eq 1 trap means a null reaching the binder here would silently
            # take a different export branch instead of erroring -- but TrimLanes is never
            # actually $null (same invariant Set-TrimLanes/the file-load reset both keep),
            # so this is belt-and-suspenders, not a fix for a real null. $overlaySpans is
            # already a real array built above; @() around it is the same defensive habit.
            Register-Job (Export-CutListAsync -Context $ctx -InputFile $script:TrimInputFile -Pieces $pieces `
                -FadeLengths $fadeLengths -Captions $captions -Zooms $zooms `
                -Lanes @($script:TrimLanes) -ClipDurations $script:TrimClipDurations -OverlaySpans @($overlaySpans) `
                -TimelineLength $timelineLength `
                -SourceAudioStreamCount $script:TrimSourceAudioStreamCount `
                -OnFinished { param($src, $out) & $recordJob "Trim" $src $out }.GetNewClosure())
        })
    }

    # ---------------- YouTube MP3 ----------------
    $panelYtMp3.FindName("ButtonYoutubeMP3Start").Add_Click({
        $url = $panelYtMp3.FindName("TextYoutubeMP3Url").Text.Trim()
        $status = $panelYtMp3.FindName("TextYoutubeMP3Status")
        if ($url -notmatch '^https?://') {
            Show-PanelMessage -Block $status -Text "Enter a full video URL starting with http." -IsError
            return
        }
        Register-Job (Save-YouTubeMP3Async -Context $ctx -Url $url)
    })

    # ---------------- YouTube MP4 ----------------
    $comboQuality = $panelYtMp4.FindName("ComboYoutubeMP4Quality")
    $buttonMp4Start = $panelYtMp4.FindName("ButtonYoutubeMP4Start")
    $statusMp4 = $panelYtMp4.FindName("TextYoutubeMP4Status")

    $panelYtMp4.FindName("ButtonYoutubeMP4Fetch").Add_Click({
        $url = $panelYtMp4.FindName("TextYoutubeMP4Url").Text.Trim()
        if ($url -notmatch '^https?://') {
            Show-PanelMessage -Block $statusMp4 -Text "Enter a full video URL starting with http." -IsError
            return
        }

        Show-PanelMessage -Block $statusMp4 -Text "Looking up available qualities..."
        # Blocks the UI thread briefly. Acceptable for a short metadata call, and far
        # simpler than marshalling a background runspace for a one-shot lookup.
        $ctx.Window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $script:YoutubeMP4Resolutions = @(Get-YouTubeResolutions -Url $url)
        } catch {
            $script:YoutubeMP4Resolutions = @()
        } finally {
            $ctx.Window.Cursor = $null
        }

        $comboQuality.Items.Clear()
        foreach ($res in $script:YoutubeMP4Resolutions) {
            $comboQuality.Items.Add("$($res.name) ($($res.height)p)") | Out-Null
        }

        $found = $comboQuality.Items.Count -gt 0
        if ($found) { $comboQuality.SelectedIndex = 0 }
        $comboQuality.IsEnabled = $found
        $buttonMp4Start.IsEnabled = $found
        if ($found) {
            Show-PanelMessage -Block $statusMp4 -Text "$($comboQuality.Items.Count) qualities available"
        } else {
            Show-PanelMessage -Block $statusMp4 -Text "No downloadable formats found for that link." -IsError
        }
    })

    $buttonMp4Start.Add_Click({
        $url = $panelYtMp4.FindName("TextYoutubeMP4Url").Text.Trim()
        $index = $comboQuality.SelectedIndex
        if ($index -lt 0 -or $index -ge $script:YoutubeMP4Resolutions.Count) { return }
        Register-Job (Save-YouTubeMP4Async -Context $ctx -Url $url -Resolution $script:YoutubeMP4Resolutions[$index])
    })

    # ---------------- Settings ----------------
    $checkAnimations = $panelSettings.FindName("CheckShowAnimations")
    $checkAnimations.IsChecked = [bool]$global:ShowAnimations
    Register-ToggleSwitch -Toggle $checkAnimations
    $checkAnimations.Add_Click({
        $global:ShowAnimations = [bool]$checkAnimations.IsChecked
        Save-Settings
    }.GetNewClosure())

    # The Look picker. Selection paints the ACTIVE button gold; a change saves and tells
    # the user the app reopens with the new look -- StaticResource resolves at parse
    # time, so a live re-theme is not possible without rebuilding the window.
    $buttonLookGold = $panelSettings.FindName("ButtonLookGold")
    $buttonLookPetalfall = $panelSettings.FindName("ButtonLookPetalfall")
    $textLookHint = $panelSettings.FindName("TextLookHint")
    function Update-LookButtons {
        if ($null -eq $buttonLookGold -or $null -eq $buttonLookPetalfall) { return }
        $goldBrushLook = ((New-LookBrushConverter)).ConvertFromString("#D3A24C")
        $lineBrushLook = ((New-LookBrushConverter)).ConvertFromString("#2A3B52")
        if ([string]$global:AppLook -eq "Petalfall") {
            $buttonLookPetalfall.BorderBrush = $goldBrushLook
            $buttonLookGold.BorderBrush = $lineBrushLook
        } else {
            $buttonLookGold.BorderBrush = $goldBrushLook
            $buttonLookPetalfall.BorderBrush = $lineBrushLook
        }
    }
    function Set-AppLook {
        param([string]$Look)
        if ([string]$global:AppLook -eq $Look) { return }
        # Unsaved edit? Same Yes/No/Cancel as closing -- Cancel keeps the current look.
        if (-not (Confirm-TrimUnsavedWork)) { return }
        $global:AppLook = $Look
        Save-Settings
        Update-LookButtons
        if ($null -ne $textLookHint) { $textLookHint.Text = "Switching look..." }
        # One click switches the theme: StaticResource resolves at parse time, so the
        # window cannot re-skin itself -- instead the app RELAUNCHES itself (2-3s) and
        # this instance closes once the new one is on its way up.
        Start-Process powershell -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $scriptRoot "Video-Audio-Tool.ps1")
        ) -WindowStyle Hidden | Out-Null
        $ctx.Window.Close()
    }
    if ($null -ne $buttonLookGold) { $buttonLookGold.Add_Click({ Set-AppLook -Look "MidnightGold" }) }
    if ($null -ne $buttonLookPetalfall) { $buttonLookPetalfall.Add_Click({ Set-AppLook -Look "Petalfall" }) }
    Update-LookButtons

    # ---- Petalfall: the falling petals ------------------------------------------------
    # 40 Path elements on the window-spanning canvas,
    # repositioned ~60x/sec by one DispatcherTimer. Cheap by construction: transform and
    # Canvas position writes only, no layout passes; petals recycle at the edges; the
    # layer only exists when the look AND animations are both on.
    function Start-LookPetals {
        if ([string]$global:AppLook -ne "Petalfall") { return }
        # No corner glows in Petalfall (user: "remove the bubbles") -- the ink ground
        # stays clean and the petals alone carry the motion.
        $glowGrid = $ctx.Window.FindName("GridBackgroundGlows")
        if ($null -ne $glowGrid) { $glowGrid.Visibility = "Collapsed" }
        if (-not $global:ShowAnimations) { return }
        $canvas = $ctx.Window.FindName("CanvasLookPetals")
        if ($null -eq $canvas) { return }
        $script:LookPetalCanvas = $canvas
        $script:LookPetalRand = New-Object System.Random
        $script:LookPetals = New-Object System.Collections.ArrayList
        # Petals keep their own reds -- a plain converter, never the look-mapped one.
        $petalBc = New-Object "System.Windows.Media.BrushConverter"
        $petalColors = @("#C22F2F", "#A82531", "#D8434F", "#8E1F26")
        $geoText = "M 0,-6 Q 5.4,-1.5 0,6 Q -5.4,-1.5 0,-6 Z"
        for ($i = 0; $i -lt 40; $i++) {
            $depth = 0.35 + $script:LookPetalRand.NextDouble() * 0.65
            $path = New-Object System.Windows.Shapes.Path
            $path.Data = [System.Windows.Media.Geometry]::Parse($geoText)
            $path.Fill = $petalBc.ConvertFromString($petalColors[$script:LookPetalRand.Next($petalColors.Count)])
            $path.Opacity = 0.30 + $depth * 0.5
            $scaleT = New-Object System.Windows.Media.ScaleTransform((0.7 + $depth), 1.0)
            $rotT = New-Object System.Windows.Media.RotateTransform($script:LookPetalRand.NextDouble() * 360.0)
            $tg = New-Object System.Windows.Media.TransformGroup
            [void]$tg.Children.Add($scaleT)
            [void]$tg.Children.Add($rotT)
            $path.RenderTransform = $tg
            [void]$canvas.Children.Add($path)
            [void]$script:LookPetals.Add(@{
                El = $path; Scale = $scaleT; Rot = $rotT
                X = $script:LookPetalRand.NextDouble() * 2600.0
                Y = $script:LookPetalRand.NextDouble() * 1400.0
                Spin = ($script:LookPetalRand.NextDouble() - 0.5) * 140.0
                SwayPhase = $script:LookPetalRand.NextDouble() * 6.283
                SwaySpeed = 0.6 + $script:LookPetalRand.NextDouble() * 0.9
                SwayAmp = 14.0 + $script:LookPetalRand.NextDouble() * 26.0
                Fall = (26.0 + $script:LookPetalRand.NextDouble() * 34.0) * (0.5 + $depth * 0.8)
                Drift = 8.0 + $script:LookPetalRand.NextDouble() * 26.0
                Flutter = 0.55 + $script:LookPetalRand.NextDouble() * 0.45
            })
        }
        $script:LookPetalClock = 0.0
        $script:LookPetalStamp = [datetime]::UtcNow
        $script:LookPetalTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:LookPetalTimer.Interval = [timespan]::FromMilliseconds(16)
        $script:LookPetalTimer.Add_Tick({ Update-LookPetals })
        $script:LookPetalTimer.Start()
    }

    function Update-LookPetals {
        $now = [datetime]::UtcNow
        $dt = ($now - $script:LookPetalStamp).TotalSeconds
        $script:LookPetalStamp = $now
        # A resume from sleep (or a long UI stall) hands one huge dt; skipping the frame
        # beats teleporting every petal off screen at once.
        if ($dt -le 0 -or $dt -gt 0.25) { return }
        if ($ctx.Window.WindowState -eq [System.Windows.WindowState]::Minimized) { return }
        $W = [double]$ctx.Window.ActualWidth
        $H = [double]$ctx.Window.ActualHeight
        if ($W -le 0 -or $H -le 0) { return }
        $script:LookPetalClock = $script:LookPetalClock + $dt
        $t = $script:LookPetalClock
        foreach ($p in $script:LookPetals) {
            $p.Y = $p.Y + $p.Fall * $dt
            $p.X = $p.X + ($p.Drift + [math]::Cos($t * $p.SwaySpeed + $p.SwayPhase) * $p.SwayAmp) * $dt
            $p.Rot.Angle = $p.Rot.Angle + $p.Spin * $dt
            # flutter: the petal turns edge-on as it rocks, exactly like the mockup
            $p.Scale.ScaleY = 0.35 + [math]::Abs([math]::Sin($t * $p.SwaySpeed * 1.3 + $p.SwayPhase)) * $p.Flutter
            if ($p.Y -gt $H + 30.0 -or $p.X -gt $W + 80.0) {
                $p.X = $script:LookPetalRand.NextDouble() * ($W + 120.0) - 60.0
                $p.Y = -20.0 - $script:LookPetalRand.NextDouble() * 80.0
            }
            [System.Windows.Controls.Canvas]::SetLeft($p.El, $p.X)
            [System.Windows.Controls.Canvas]::SetTop($p.El, $p.Y)
        }
    }
    Start-LookPetals

    # ---- Midnight Gold: the "Carina Sea" nebula sky -----------------------------------
    # The mockup the user picked: a teal-green nebula sea with golden pillar clouds, a
    # star field, and a few bright stars with four-point diffraction spikes. The clouds
    # are painted ONCE into two frozen bitmaps (soft radial puffs deposited along
    # momentum random-walk filaments, plus dark dust puffs) and per frame the two
    # bitmaps only drift and breathe against each other -- transform and opacity writes,
    # zero layout passes, no per-frame drawing.
