# Zoom keyframes for the Video Editor: pure model + interpolation. No UI state.

function New-ZoomKeyframe {
    param(
        [Parameter(Mandatory = $true)][double]$Time,
        [double]$CX = 0.5,
        [double]$CY = 0.5,
        [double]$Level = 1.0
    )
    return [PSCustomObject]@{
        Id    = [guid]::NewGuid().ToString("N")
        Time  = $Time
        CX    = [math]::Max(0.0, [math]::Min(1.0, $CX))
        CY    = [math]::Max(0.0, [math]::Min(1.0, $CY))
        Level = [math]::Max(1.0, [math]::Min(6.0, $Level))
    }
}

# The glide: linear between neighbouring keyframes, held flat outside them.
function Get-TrimZoomStateAt {
    param([object[]]$Zooms = @(), [Parameter(Mandatory = $true)][double]$Seconds)
    $ks = @(@($Zooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
    if ($ks.Count -eq 0) { return @{ Level = 1.0; CX = 0.5; CY = 0.5 } }
    if ($Seconds -le [double]$ks[0].Time) {
        return @{ Level = [double]$ks[0].Level; CX = [double]$ks[0].CX; CY = [double]$ks[0].CY }
    }
    $last = $ks[$ks.Count - 1]
    if ($Seconds -ge [double]$last.Time) {
        return @{ Level = [double]$last.Level; CX = [double]$last.CX; CY = [double]$last.CY }
    }
    for ($i = 0; $i -lt $ks.Count - 1; $i++) {
        $a = $ks[$i]; $b = $ks[$i + 1]
        if ($Seconds -ge [double]$a.Time -and $Seconds -le [double]$b.Time) {
            $span = [double]$b.Time - [double]$a.Time
            $f = if ($span -le 0) { 1.0 } else { ($Seconds - [double]$a.Time) / $span }
            return @{
                Level = [double]$a.Level + ([double]$b.Level - [double]$a.Level) * $f
                CX    = [double]$a.CX + ([double]$b.CX - [double]$a.CX) * $f
                CY    = [double]$a.CY + ([double]$b.CY - [double]$a.CY) * $f
            }
        }
    }
    return @{ Level = 1.0; CX = 0.5; CY = 0.5 }
}

# Merged, sorted source-space zoom spans: consecutive keyframe pairs where either end's
# level exceeds 1.001, plus a leading hold-before span (footage start to first keyframe)
# when the first keyframe's level is > 1.001, plus a trailing hold-after span (last
# keyframe to footage end) when the last keyframe's level is > 1.001. Clipped to the
# surviving pieces, same merge idiom as Get-CaptionSpans.
function Get-TrimZoomSpans {
    param([object[]]$Zooms = @(), [object[]]$Pieces = @())
    $ks = @(@($Zooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
    if ($ks.Count -eq 0) { return ,@() }

    $candidates = @()
    for ($i = 0; $i -lt $ks.Count - 1; $i++) {
        $a = $ks[$i]; $b = $ks[$i + 1]
        if ([double]$a.Level -gt 1.001 -or [double]$b.Level -gt 1.001) {
            $candidates += ,@{ Start = [double]$a.Time; End = [double]$b.Time }
        }
    }
    $first = $ks[0]
    $last = $ks[$ks.Count - 1]
    $footageStart = 0.0
    $footageEnd = [double]$last.Time
    foreach ($p in @($Pieces)) {
        $footageEnd = [math]::Max($footageEnd, [double]$p.End)
    }
    if ([double]$first.Level -gt 1.001) {
        $candidates += ,@{ Start = $footageStart; End = [double]$first.Time }
    }
    if ([double]$last.Level -gt 1.001) {
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

# Splits cut segments further at zoom span edges and interior keyframe times, tagging
# the zoomed parts with Zoom = @{Z0;Z1;CX0;CX1;CY0;CY1} from Get-TrimZoomStateAt at the
# part's endpoints. Burn segments overlapping a span are split at exactly the same points
# -- every part keeps Kind "burn" and the SAME Captions list, because caption times are
# source-space and the export writes each burning segment its own .ass with
# -TimeOffset = that segment's Start, so a split re-times itself. Without the split, a
# zoom bump wholly inside a caption window sampled only at the caption's own endpoints
# comes out as 1x -> 1x and the punch-in vanishes from the export entirely.
# A burn part whose endpoints are both effectively 1x gets NO Zoom key at all, so it takes
# the plain ass-only path instead of an identity crop/scale re-encode.
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
                if ($s0.Level -gt 1.001 -or $s1.Level -gt 1.001) {
                    $seg.Zoom = @{ Z0 = $s0.Level; Z1 = $s1.Level; CX0 = $s0.CX; CX1 = $s1.CX; CY0 = $s0.CY; CY1 = $s1.CY }
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
                if ($s0.Level -gt 1.001 -or $s1.Level -gt 1.001) {
                    $part.Zoom = @{ Z0 = $s0.Level; Z1 = $s1.Level; CX0 = $s0.CX; CX1 = $s1.CX; CY0 = $s0.CY; CY1 = $s1.CY }
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
                    Zoom     = @{ Z0 = $s0.Level; Z1 = $s1.Level; CX0 = $s0.CX; CX1 = $s1.CX; CY0 = $s0.CY; CY1 = $s1.CY }
                }
            } else {
                $result += ,@{ Kind = "cut"; Start = $partStart; Duration = ($partEnd - $partStart) }
            }
        }
    }
    return ,@($result)
}

# Builds the ffmpeg crop/scale/setsar chain for one zoomed segment. Constant zoom (no
# glide) emits plain numbers; a glide emits segment-local-t linear expressions. All
# numeric formatting uses InvariantCulture so a comma-decimal system locale can never
# corrupt the filtergraph with a stray comma (ffmpeg's filter parser uses commas as
# separators).
function New-ZoomCropFilter {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Zoom,
        [Parameter(Mandatory = $true)][double]$Duration,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )
    if ($Duration -le 0) { throw "New-ZoomCropFilter: Duration must be positive" }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $z0 = [double]$Zoom.Z0; $z1 = [double]$Zoom.Z1
    $cx0 = [double]$Zoom.CX0; $cx1 = [double]$Zoom.CX1
    $cy0 = [double]$Zoom.CY0; $cy1 = [double]$Zoom.CY1

    $isConstant = ($z0 -eq $z1) -and ($cx0 -eq $cx1) -and ($cy0 -eq $cy1)

    if ($isConstant) {
        $w = 2 * [math]::Floor(($Width / $z0) / 2.0)
        $h = 2 * [math]::Floor(($Height / $z0) / 2.0)
        $x = $cx0 * $Width - $w / 2.0
        $x = [math]::Max(0.0, [math]::Min([double]($Width - $w), $x))
        $y = $cy0 * $Height - $h / 2.0
        $y = [math]::Max(0.0, [math]::Min([double]($Height - $h), $y))

        $wS = ([int]$w).ToString($inv)
        $hS = ([int]$h).ToString($inv)
        $xS = ([int][math]::Round($x)).ToString($inv)
        $yS = ([int][math]::Round($y)).ToString($inv)
        return "crop={0}:{1}:{2}:{3},scale={4}x{5},setsar=1" -f $wS, $hS, $xS, $yS, $Width, $Height
    }

    $zd = ($z1 - $z0).ToString("0.####", $inv)
    $z0s = $z0.ToString("0.####", $inv)
    $cx0s = $cx0.ToString("0.####", $inv)
    $cxd = ($cx1 - $cx0).ToString("0.####", $inv)
    $cy0s = $cy0.ToString("0.####", $inv)
    $cyd = ($cy1 - $cy0).ToString("0.####", $inv)
    $dS = $Duration.ToString("0.####", $inv)

    # A glide has to SCALE first and crop second, which is the opposite of the constant
    # branch. crop's w/h expressions are evaluated once, when the filter is configured, and
    # `t` does not exist yet at that point -- "crop=iw/(z0+zd*t/D)" fails outright with
    # "Error when evaluating the expression". Only crop's x/y are per-frame. scale, on the
    # other hand, re-evaluates w/h every frame when eval=frame is set, so the moving part
    # of the zoom lives there: blow the whole frame up by z(t), then cut a fixed
    # Width x Height window out of it at the moving centre. z >= 1 always, so the scaled
    # frame is never smaller than the window. trunc(../2)*2 keeps both intermediate
    # dimensions even, which yuv420p requires.
    #
    # Every comma inside an expression is backslash-escaped: the filtergraph is split on
    # commas BEFORE a filter's own arguments are parsed, so a bare "max(a,0)" is read as
    # the end of one filter and the start of another called "0)".
    $z = "({0}+({1})*t/{2})" -f $z0s, $zd, $dS
    $sw = "trunc(iw*{0}/2)*2" -f $z
    $sh = "trunc(ih*{0}/2)*2" -f $z
    # crop's x/y must NOT be written in terms of iw/ih. crop resolves those ONCE, when the
    # filter is configured, and keeps the first frame's numbers for the whole segment --
    # but its input is now resized every frame by the scale above, so "cx*iw" silently
    # tracks the wrong frame width and the zoom drifts off centre. Measured live on a
    # 1.4x->1.8x glide: the crop stayed pinned to the 1.4x width and landed on centre
    # (0.50, 0.39) where the plan asked for (0.575, 0.450). Restating the scaled size from
    # the literal source dimensions -- the same trunc() the scale filter above uses, so the
    # two agree exactly and the window can never fall outside the frame -- fixes it.
    $swNum = "trunc({0}*{1}/2)*2" -f $Width, $z
    $shNum = "trunc({0}*{1}/2)*2" -f $Height, $z
    $halfW = ($Width / 2.0).ToString("0.####", $inv)
    $halfH = ($Height / 2.0).ToString("0.####", $inv)
    $x = "min(max(({0}+({1})*t/{2})*{3}-{4}\,0)\,{3}-{5})" -f $cx0s, $cxd, $dS, $swNum, $halfW, $Width
    $y = "min(max(({0}+({1})*t/{2})*{3}-{4}\,0)\,{3}-{5})" -f $cy0s, $cyd, $dS, $shNum, $halfH, $Height

    return "scale=w={0}:h={1}:eval=frame,crop={2}:{3}:{4}:{5},setsar=1" -f $sw, $sh, $Width, $Height, $x, $y
}

Export-ModuleMember -Function New-ZoomKeyframe, Get-TrimZoomStateAt, Get-TrimZoomSpans, Split-TrimSegmentsForZooms, New-ZoomCropFilter
