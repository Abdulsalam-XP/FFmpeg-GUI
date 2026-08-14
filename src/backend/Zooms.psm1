# Zoom keyframes for the Video Editor: pure model + interpolation. No UI state.
#
# Model (since 2026-08-11, the magnet/stretch rework): a keyframe frames a RECTANGLE of
# the source, not a uniform level. W and H are the box size as fractions of the frame
# (W=H=1 is the whole frame = identity), CX/CY its centre. W and H are independent: a
# non-frame-shaped box means the picture is STRETCHED to fill the output -- that is the
# deliberate effect the magnet toggle unlocks, not an error. W/H above 1 zooms OUT: the
# whole frame is shown smaller than the output, black around it. The uniform "2x zoom"
# of the old model is simply W=H=0.5.
#
# Old-model keyframes carried Level (1..6); 1/Level maps onto both W and H.

$script:ZoomDimMin = 1.0 / 6.0   # deepest zoom-in: a sixth of the frame per axis
$script:ZoomDimMax = 3.0         # deepest zoom-out: frame at a third of the output

function New-ZoomKeyframe {
    param(
        [Parameter(Mandatory = $true)][double]$Time,
        [double]$CX = 0.5,
        [double]$CY = 0.5,
        [double]$W = 1.0,
        [double]$H = 1.0,
        # Legacy uniform level; honored only when W/H were not given, so old call
        # sites and old project entries keep meaning what they meant.
        [double]$Level = 0.0
    )
    if ($Level -gt 0.0 -and $W -eq 1.0 -and $H -eq 1.0) {
        $lvl = [math]::Max(1.0, [math]::Min(6.0, $Level))
        $W = 1.0 / $lvl
        $H = 1.0 / $lvl
    }
    return [PSCustomObject]@{
        Id   = [guid]::NewGuid().ToString("N")
        Time = $Time
        CX   = [math]::Max(0.0, [math]::Min(1.0, $CX))
        CY   = [math]::Max(0.0, [math]::Min(1.0, $CY))
        W    = [math]::Max($script:ZoomDimMin, [math]::Min($script:ZoomDimMax, $W))
        H    = [math]::Max($script:ZoomDimMin, [math]::Min($script:ZoomDimMax, $H))
    }
}

# Identity = the box IS the frame on both axes. The 0.001 band absorbs float noise the
# same way the old level>1.001 test did.
function Test-ZoomIdentity {
    param([double]$W, [double]$H)
    return ([math]::Abs($W - 1.0) -le 0.001 -and [math]::Abs($H - 1.0) -le 0.001)
}

# Reads a keyframe's box, tolerating old-model objects that only carry Level -- undo
# snapshots and project files written before the rework still resolve correctly.
function Get-ZoomKeyframeBox {
    param([Parameter(Mandatory = $true)]$Keyframe)
    $hasW = $null -ne $Keyframe.PSObject.Properties["W"] -and $null -ne $Keyframe.W
    $hasH = $null -ne $Keyframe.PSObject.Properties["H"] -and $null -ne $Keyframe.H
    if ($hasW -and $hasH) {
        return @{ W = [double]$Keyframe.W; H = [double]$Keyframe.H }
    }
    $lvl = 1.0
    if ($null -ne $Keyframe.PSObject.Properties["Level"] -and $null -ne $Keyframe.Level) {
        $lvl = [math]::Max(1.0, [math]::Min(6.0, [double]$Keyframe.Level))
    }
    return @{ W = 1.0 / $lvl; H = 1.0 / $lvl }
}

# The glide: linear between neighbouring keyframes, held flat AFTER the last one.
# Before the FIRST keyframe the state is identity, not a hold: the user's model (stated
# directly, 2026-08-11) is that a zoom keyframe ACTIVATES at its moment -- footage before
# it plays unzoomed, and a lone 2x keyframe is a hard punch-in right there. A smooth
# push-in is still two keyframes (identity then zoomed). Hold-after stays: a zoom
# persists until keyframed back out.
function Get-TrimZoomStateAt {
    param([object[]]$Zooms = @(), [Parameter(Mandatory = $true)][double]$Seconds)
    $ks = @(@($Zooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
    if ($ks.Count -eq 0) { return @{ W = 1.0; H = 1.0; CX = 0.5; CY = 0.5 } }
    # The 10ms grace on the identity edge is for the paused preview, not the export: a
    # MediaElement scrubbed onto a keyframe reports a position a frame-fraction BEFORE
    # it, and with a strict < the picture flip-flops between unzoomed and zoomed while
    # visually standing still on the diamond. 10ms is under any frame duration, so no
    # real footage moves sides.
    if ($Seconds -lt ([double]$ks[0].Time - 0.01)) {
        return @{ W = 1.0; H = 1.0; CX = 0.5; CY = 0.5 }
    }
    if ($Seconds -le [double]$ks[0].Time) {
        $box = Get-ZoomKeyframeBox -Keyframe $ks[0]
        return @{ W = $box.W; H = $box.H; CX = [double]$ks[0].CX; CY = [double]$ks[0].CY }
    }
    $last = $ks[$ks.Count - 1]
    if ($Seconds -ge [double]$last.Time) {
        $box = Get-ZoomKeyframeBox -Keyframe $last
        return @{ W = $box.W; H = $box.H; CX = [double]$last.CX; CY = [double]$last.CY }
    }
    for ($i = 0; $i -lt $ks.Count - 1; $i++) {
        $a = $ks[$i]; $b = $ks[$i + 1]
        if ($Seconds -ge [double]$a.Time -and $Seconds -le [double]$b.Time) {
            $span = [double]$b.Time - [double]$a.Time
            $f = if ($span -le 0) { 1.0 } else { ($Seconds - [double]$a.Time) / $span }
            $boxA = Get-ZoomKeyframeBox -Keyframe $a
            $boxB = Get-ZoomKeyframeBox -Keyframe $b
            return @{
                W  = $boxA.W + ($boxB.W - $boxA.W) * $f
                H  = $boxA.H + ($boxB.H - $boxA.H) * $f
                CX = [double]$a.CX + ([double]$b.CX - [double]$a.CX) * $f
                CY = [double]$a.CY + ([double]$b.CY - [double]$a.CY) * $f
            }
        }
    }
    return @{ W = 1.0; H = 1.0; CX = 0.5; CY = 0.5 }
}

# Merged, sorted source-space zoom spans: consecutive keyframe pairs where either end is
# not identity, plus a trailing hold-after span (last keyframe to footage end) when the
# last keyframe is not identity. No leading span: before the first keyframe the state is
# identity (see Get-TrimZoomStateAt) so there is nothing to re-encode there.
# Clipped to the surviving pieces, same merge idiom as Get-CaptionSpans.
function Get-TrimZoomSpans {
    param([object[]]$Zooms = @(), [object[]]$Pieces = @())
    $ks = @(@($Zooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
    if ($ks.Count -eq 0) { return ,@() }

    $boxes = @()
    foreach ($k in $ks) { $boxes += ,(Get-ZoomKeyframeBox -Keyframe $k) }

    $candidates = @()
    for ($i = 0; $i -lt $ks.Count - 1; $i++) {
        $aId = Test-ZoomIdentity -W $boxes[$i].W -H $boxes[$i].H
        $bId = Test-ZoomIdentity -W $boxes[$i + 1].W -H $boxes[$i + 1].H
        if (-not $aId -or -not $bId) {
            $candidates += ,@{ Start = [double]$ks[$i].Time; End = [double]$ks[$i + 1].Time }
        }
    }
    $last = $ks[$ks.Count - 1]
    $footageEnd = [double]$last.Time
    foreach ($p in @($Pieces)) {
        $footageEnd = [math]::Max($footageEnd, [double]$p.End)
    }
    if (-not (Test-ZoomIdentity -W $boxes[$boxes.Count - 1].W -H $boxes[$boxes.Count - 1].H)) {
        $candidates += ,@{ Start = [double]$last.Time; End = $footageEnd }
    }

    $raw = @()
    foreach ($cand in $candidates) {
        foreach ($p in @($Pieces)) {
            $s = [math]::Max([double]$cand.Start, [double]$p.Start)
            $e = [math]::Min([double]$cand.End, [double]$p.End)
            if ($e -gt $s) { $raw += ,@{ Start = $s; End = $e } }
        }
    }
    if ($raw.Count -eq 0) { return ,@() }
    $sorted = @($raw | Sort-Object { $_.Start })
    $merged = @($sorted[0])
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $lastSpan = $merged[$merged.Count - 1]
        if ($sorted[$i].Start -le $lastSpan.End) {
            $lastSpan.End = [math]::Max($lastSpan.End, $sorted[$i].End)
        } else {
            $merged += ,$sorted[$i]
        }
    }
    return ,@($merged)
}

# Zoom tag for one part: box + centre sampled at both endpoints.
function New-ZoomTag {
    param($S0, $S1)
    return @{
        W0 = $S0.W; W1 = $S1.W; H0 = $S0.H; H1 = $S1.H
        CX0 = $S0.CX; CX1 = $S1.CX; CY0 = $S0.CY; CY1 = $S1.CY
    }
}

function Test-ZoomStateIdentity {
    param($State)
    return (Test-ZoomIdentity -W ([double]$State.W) -H ([double]$State.H))
}

# Splits cut segments further at zoom span edges and interior keyframe times, tagging
# the zoomed parts with Zoom = @{W0;W1;H0;H1;CX0;CX1;CY0;CY1} from Get-TrimZoomStateAt
# at the part's endpoints. Burn segments overlapping a span are split at exactly the same
# points -- every part keeps Kind "burn" and the SAME Captions list, because caption times
# are source-space and the export writes each burning segment its own .ass with
# -TimeOffset = that segment's Start, so a split re-times itself. Without the split, a
# zoom bump wholly inside a caption window sampled only at the caption's own endpoints
# comes out as identity -> identity and the punch-in vanishes from the export entirely.
# A burn part whose endpoints are both effectively identity gets NO Zoom key at all, so it
# takes the plain ass-only path instead of an identity crop/scale re-encode.
# Transitions overlapping a span should never reach here: the export pre-flight refuses
# that combination before this function runs, so seeing one here is a future gap, and
# we throw loudly instead of silently mis-rendering it. BOTH halves of the crossfade count
# -- the outgoing tail at Start and the incoming head at NextStart.
function Split-TrimSegmentsForZooms {
    param([object[]]$Segments = @(), [object[]]$Zooms = @())

    $ks = @(@($Zooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
    # The segment plan (whatever mix of cut/burn/transition) already tiles the entire
    # surviving footage, so its own extents stand in for "Pieces" when locating spans.
    # A transition's extent covers only its OUTGOING tail; the incoming head it also eats
    # lives at NextStart and belongs to no segment at all, so it is added explicitly --
    # otherwise Get-TrimZoomSpans clips a span over the incoming head away to nothing and
    # the backstop below can never see it.
    $pieces = @()
    foreach ($s in @($Segments)) {
        $pieces += ,([PSCustomObject]@{ Start = [double]$s.Start; End = ([double]$s.Start + [double]$s.Duration) })
        if ($s.Kind -eq "transition" -and $null -ne $s.NextStart) {
            $pieces += ,([PSCustomObject]@{ Start = [double]$s.NextStart; End = ([double]$s.NextStart + [double]$s.Duration) })
        }
    }
    $spans = Get-TrimZoomSpans -Zooms $ks -Pieces $pieces

    $result = @()
    foreach ($seg in @($Segments)) {
        $segStart = [double]$seg.Start
        $segEnd = $segStart + [double]$seg.Duration

        $overlapping = @($spans | Where-Object { [double]$_.Start -lt $segEnd -and [double]$_.End -gt $segStart })

        if ($seg.Kind -eq "transition") {
            $hit = $overlapping.Count -gt 0
            if (-not $hit -and $null -ne $seg.NextStart) {
                $inStart = [double]$seg.NextStart
                $inEnd = $inStart + [double]$seg.Duration
                $hit = @($spans | Where-Object { [double]$_.Start -lt $inEnd -and [double]$_.End -gt $inStart }).Count -gt 0
            }
            if ($hit) {
                throw "zoomed transition reached the splitter"
            }
            $result += ,$seg
            continue
        }

        if ($seg.Kind -ne "cut" -and $seg.Kind -ne "burn") { $result += ,$seg; continue }
        if ($overlapping.Count -eq 0) { $result += ,$seg; continue }

        # Split points: span edges inside the segment, plus interior keyframe times.
        $cutsSet = New-Object System.Collections.Generic.SortedSet[double]
        foreach ($sp in $overlapping) {
            if ([double]$sp.Start -gt $segStart -and [double]$sp.Start -lt $segEnd) { [void]$cutsSet.Add([double]$sp.Start) }
            if ([double]$sp.End -gt $segStart -and [double]$sp.End -lt $segEnd) { [void]$cutsSet.Add([double]$sp.End) }
        }
        foreach ($k in $ks) {
            $t = [double]$k.Time
            if ($t -gt $segStart -and $t -lt $segEnd) {
                foreach ($sp in $overlapping) {
                    if ($t -gt [double]$sp.Start -and $t -lt [double]$sp.End) { [void]$cutsSet.Add($t); break }
                }
            }
        }

        if ($seg.Kind -eq "burn") {
            # A burn with no interior split point keeps its identity (and its object), so
            # the untouched case behaves exactly as before.
            if ($cutsSet.Count -eq 0) {
                $s0 = Get-TrimZoomStateAt -Zooms $ks -Seconds $segStart
                $s1 = Get-TrimZoomStateAt -Zooms $ks -Seconds $segEnd
                if (-not (Test-ZoomStateIdentity -State $s0) -or -not (Test-ZoomStateIdentity -State $s1)) {
                    $seg.Zoom = New-ZoomTag -S0 $s0 -S1 $s1
                }
                $result += ,$seg
                continue
            }
            $bPoints = @([double]$segStart) + @($cutsSet) + @([double]$segEnd)
            for ($i = 0; $i -lt $bPoints.Count - 1; $i++) {
                $partStart = $bPoints[$i]
                $partEnd = $bPoints[$i + 1]
                if ($partEnd - $partStart -le 0.0005) { continue }
                $part = @{ Kind = "burn"; Start = $partStart; Duration = ($partEnd - $partStart); Captions = $seg.Captions }
                $s0 = Get-TrimZoomStateAt -Zooms $ks -Seconds $partStart
                $s1 = Get-TrimZoomStateAt -Zooms $ks -Seconds $partEnd
                if (-not (Test-ZoomStateIdentity -State $s0) -or -not (Test-ZoomStateIdentity -State $s1)) {
                    $part.Zoom = New-ZoomTag -S0 $s0 -S1 $s1
                }
                $result += ,$part
            }
            continue
        }

        $points = @([double]$segStart) + @($cutsSet) + @([double]$segEnd)

        for ($i = 0; $i -lt $points.Count - 1; $i++) {
            $partStart = $points[$i]
            $partEnd = $points[$i + 1]
            if ($partEnd - $partStart -le 0.0005) { continue }

            $mid = ($partStart + $partEnd) / 2.0
            $inSpan = $false
            foreach ($sp in $overlapping) {
                if ($mid -gt [double]$sp.Start -and $mid -lt [double]$sp.End) { $inSpan = $true; break }
            }

            if ($inSpan) {
                $s0 = Get-TrimZoomStateAt -Zooms $ks -Seconds $partStart
                $s1 = Get-TrimZoomStateAt -Zooms $ks -Seconds $partEnd
                $result += ,@{
                    Kind     = "zoom"
                    Start    = $partStart
                    Duration = ($partEnd - $partStart)
                    Zoom     = New-ZoomTag -S0 $s0 -S1 $s1
                }
            } else {
                $result += ,@{ Kind = "cut"; Start = $partStart; Duration = ($partEnd - $partStart) }
            }
        }
    }
    return ,@($result)
}

# Builds the ffmpeg filter chain for one zoomed segment. Constant zoom-in (no glide, box
# inside the frame) emits plain crop/scale numbers; everything else -- glides, stretches
# and zoom-outs alike -- goes through the pad+scale+crop chain below. All numeric
# formatting uses InvariantCulture so a comma-decimal system locale can never corrupt
# the filtergraph with a stray comma (ffmpeg's filter parser uses commas as separators).
function New-ZoomCropFilter {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Zoom,
        [Parameter(Mandatory = $true)][double]$Duration,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )
    if ($Duration -le 0) { throw "New-ZoomCropFilter: Duration must be positive" }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $w0 = [double]$Zoom.W0; $w1 = [double]$Zoom.W1
    $h0 = [double]$Zoom.H0; $h1 = [double]$Zoom.H1
    $cx0 = [double]$Zoom.CX0; $cx1 = [double]$Zoom.CX1
    $cy0 = [double]$Zoom.CY0; $cy1 = [double]$Zoom.CY1
    if ($w0 -le 0 -or $w1 -le 0 -or $h0 -le 0 -or $h1 -le 0) {
        throw "New-ZoomCropFilter: box dimensions must be positive"
    }

    $isConstant = ($w0 -eq $w1) -and ($h0 -eq $h1) -and ($cx0 -eq $cx1) -and ($cy0 -eq $cy1)

    if ($isConstant -and $w0 -le 1.0 -and $h0 -le 1.0) {
        # Plain punch-in (possibly stretched): crop the box, scale it to the full frame.
        # trunc-to-even on the crop keeps yuv420p happy.
        $bw = 2 * [math]::Floor(($Width * $w0) / 2.0)
        $bh = 2 * [math]::Floor(($Height * $h0) / 2.0)
        $bw = [math]::Max(2.0, $bw)
        $bh = [math]::Max(2.0, $bh)
        $x = $cx0 * $Width - $bw / 2.0
        $x = [math]::Max(0.0, [math]::Min([double]($Width - $bw), $x))
        $y = $cy0 * $Height - $bh / 2.0
        $y = [math]::Max(0.0, [math]::Min([double]($Height - $bh), $y))

        $wS = ([int]$bw).ToString($inv)
        $hS = ([int]$bh).ToString($inv)
        $xS = ([int][math]::Round($x)).ToString($inv)
        $yS = ([int][math]::Round($y)).ToString($inv)
        return "crop={0}:{1}:{2}:{3},scale={4}x{5},setsar=1" -f $wS, $hS, $xS, $yS, $Width, $Height
    }

    # General path: pad (only when zooming out needs room), then SCALE per frame, then a
    # fixed-size crop at a moving offset.
    #
    # Scale-first is forced by ffmpeg itself: crop's w/h expressions are evaluated once,
    # when the filter is configured, and `t` does not exist yet at that point. Only
    # crop's x/y are per-frame. scale re-evaluates w/h every frame under eval=frame, so
    # the moving part of the zoom lives there: resize the (padded) frame by 1/W(t)
    # horizontally and 1/H(t) vertically, then cut a fixed Width x Height window out of
    # it at the moving centre. The two axes are independent, which is exactly what makes
    # the magnet-off stretch work.
    #
    # Zoom-out (W or H above 1) shrinks the picture below the window size, so the frame
    # is padded with black FIRST until the window always fits. The +8 margin guarantees
    # the truncated scaled size can never fall below the window even at the extreme of
    # the glide. Centres are forced to 0.5 on any axis that is zoomed out (the UI does
    # the same): the pad has exactly enough room for a centred frame.
    #
    # Every comma inside an expression is backslash-escaped: the filtergraph is split on
    # commas BEFORE a filter's own arguments are parsed.
    $maxW = [math]::Max(1.0, [math]::Max($w0, $w1))
    $maxH = [math]::Max(1.0, [math]::Max($h0, $h1))
    $padW = $Width
    $padH = $Height
    if ($maxW -gt 1.0001) { $padW = 2 * [int][math]::Ceiling(($Width * $maxW + 8) / 2.0) }
    if ($maxH -gt 1.0001) { $padH = 2 * [int][math]::Ceiling(($Height * $maxH + 8) / 2.0) }
    $padX = [int][math]::Floor(($padW - $Width) / 2.0)
    $padY = [int][math]::Floor(($padH - $Height) / 2.0)
    if ($maxW -gt 1.0001) { $cx0 = 0.5; $cx1 = 0.5 }
    if ($maxH -gt 1.0001) { $cy0 = 0.5; $cy1 = 0.5 }

    # Deep-glide fast path (2026-08-15): a zoom-IN glide only ever shows the union of
    # its per-frame crop windows, and with every coordinate linear in t that union's
    # bounds sit at the ENDPOINTS -- so the chain can statically crop to the union
    # first and run the expensive per-frame upscale on just those pixels (a 0.3x
    # punch-in used to upscale the whole 1440p frame to ~8500px wide every frame).
    # Guarded three ways: zoom-in only (zoom-out needs the black pad); the RAW union
    # must sit fully inside the frame (if a box hangs off an edge, the window's
    # clamped x/y SHIFTS it inward mid-glide and can show pixels outside the endpoint
    # union -- linearity only makes the endpoint union exact when no clamping ever
    # engages); and it must actually remove >10% of the pixels.
    $preCrop = ""
    $workW = $padW
    $workH = $padH
    $offX = 0
    $offY = 0
    if ($maxW -le 1.0001 -and $maxH -le 1.0001) {
        $uL = [math]::Min($cx0 - $w0 / 2.0, $cx1 - $w1 / 2.0) * $Width
        $uR = [math]::Max($cx0 + $w0 / 2.0, $cx1 + $w1 / 2.0) * $Width
        $uT = [math]::Min($cy0 - $h0 / 2.0, $cy1 - $h1 / 2.0) * $Height
        $uB = [math]::Max($cy0 + $h0 / 2.0, $cy1 + $h1 / 2.0) * $Height
        if ($uL -ge 0.0 -and $uT -ge 0.0 -and $uR -le [double]$Width -and $uB -le [double]$Height) {
            # +4 margin each side (same spirit as the pad's +8) so trunc-to-even in
            # the scaled size can never pull the crop window outside the union.
            $ux = [math]::Max(0, 2 * [int][math]::Floor(($uL - 4.0) / 2.0))
            $uy = [math]::Max(0, 2 * [int][math]::Floor(($uT - 4.0) / 2.0))
            $uxr = [math]::Min([int]$Width, 2 * [int][math]::Ceiling(($uR + 4.0) / 2.0))
            $uyb = [math]::Min([int]$Height, 2 * [int][math]::Ceiling(($uB + 4.0) / 2.0))
            $uw = $uxr - $ux
            $uh = $uyb - $uy
            if ($uw -ge 16 -and $uh -ge 16 -and ($uw * $uh) -lt (0.9 * $Width * $Height)) {
                $preCrop = "crop={0}:{1}:{2}:{3}," -f $uw, $uh, $ux, $uy
                $workW = $uw
                $workH = $uh
                $offX = $ux
                $offY = $uy
            }
        }
    }

    $dS = $Duration.ToString("0.####", $inv)
    $wT = "({0}+({1})*t/{2})" -f $w0.ToString("0.####", $inv), ($w1 - $w0).ToString("0.####", $inv), $dS
    $hT = "({0}+({1})*t/{2})" -f $h0.ToString("0.####", $inv), ($h1 - $h0).ToString("0.####", $inv), $dS
    $cxT = "({0}+({1})*t/{2})" -f $cx0.ToString("0.####", $inv), ($cx1 - $cx0).ToString("0.####", $inv), $dS
    $cyT = "({0}+({1})*t/{2})" -f $cy0.ToString("0.####", $inv), ($cy1 - $cy0).ToString("0.####", $inv), $dS

    # Scaled (padded) size per frame. Restated from LITERAL numbers inside crop's x/y
    # too -- crop resolves iw/ih once at configure time while its input is resized every
    # frame, so any expression written in terms of iw/ih silently tracks the wrong frame
    # (measured live on the old uniform model: a 1.4x->1.8x glide stayed pinned to the
    # 1.4x width). Identical trunc() text in both places keeps scale and crop in exact
    # agreement, so the window can never fall outside the frame.
    $swExpr = "trunc({0}/{1}/2)*2" -f $workW.ToString($inv), $wT
    $shExpr = "trunc({0}/{1}/2)*2" -f $workH.ToString($inv), $hT

    # Window centre in scaled coordinates: the source-frame point (cx*Width) sits at
    # (padX + cx*Width) in padded coordinates -- or (cx*Width - offX) in pre-cropped
    # ones (pad and pre-crop are mutually exclusive) -- and is divided by W(t) when
    # scaled.
    $cxPad = "({0}+{1}*{2})/{3}" -f ($padX - $offX).ToString($inv), $cxT, $Width.ToString($inv), $wT
    $cyPad = "({0}+{1}*{2})/{3}" -f ($padY - $offY).ToString($inv), $cyT, $Height.ToString($inv), $hT
    $halfW = ($Width / 2.0).ToString("0.####", $inv)
    $halfH = ($Height / 2.0).ToString("0.####", $inv)
    $x = "min(max({0}-{1}\,0)\,{2}-{3})" -f $cxPad, $halfW, $swExpr, $Width.ToString($inv)
    $y = "min(max({0}-{1}\,0)\,{2}-{3})" -f $cyPad, $halfH, $shExpr, $Height.ToString($inv)

    $chain = "{0}scale=w={1}:h={2}:eval=frame,crop={3}:{4}:{5}:{6},setsar=1" -f $preCrop, $swExpr, $shExpr, $Width, $Height, $x, $y
    if ($padW -ne $Width -or $padH -ne $Height) {
        $chain = "pad={0}:{1}:{2}:{3}:black,{4}" -f $padW, $padH, $padX, $padY, $chain
    }
    return $chain
}

Export-ModuleMember -Function New-ZoomKeyframe, Test-ZoomIdentity, Get-ZoomKeyframeBox, Get-TrimZoomStateAt, Get-TrimZoomSpans, Split-TrimSegmentsForZooms, New-ZoomCropFilter
