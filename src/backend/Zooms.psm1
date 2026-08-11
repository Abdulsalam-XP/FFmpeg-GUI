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
# part's endpoints. Burn segments overlapping a span keep their shape (captions already
# sized them) and just gain the same Zoom key evaluated at the BURN segment's own start
# and end -- a burn spanning an interior keyframe therefore approximates the glide
# linearly straight across it rather than bending at the keyframe; acceptable for v1.
# Transitions overlapping a span should never reach here: the export pre-flight refuses
# that combination before this function runs, so seeing one here is a future gap, and
# we throw loudly instead of silently mis-rendering it.
function Split-TrimSegmentsForZooms {
    param([object[]]$Segments = @(), [object[]]$Zooms = @())

    $ks = @(@($Zooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
    # The segment plan (whatever mix of cut/burn/transition) already tiles the entire
    # surviving footage, so its own extents stand in for "Pieces" when locating spans.
    $pieces = @(@($Segments) | ForEach-Object { [PSCustomObject]@{ Start = [double]$_.Start; End = ([double]$_.Start + [double]$_.Duration) } })
    $spans = Get-TrimZoomSpans -Zooms $ks -Pieces $pieces

    $result = @()
    foreach ($seg in @($Segments)) {
        $segStart = [double]$seg.Start
        $segEnd = $segStart + [double]$seg.Duration

        $overlapping = @($spans | Where-Object { [double]$_.Start -lt $segEnd -and [double]$_.End -gt $segStart })

        if ($seg.Kind -eq "transition") {
            if ($overlapping.Count -gt 0) {
                throw "zoomed transition reached the splitter"
            }
            $result += ,$seg
            continue
        }

        if ($seg.Kind -eq "burn") {
            if ($overlapping.Count -gt 0) {
                $s0 = Get-TrimZoomStateAt -Zooms $ks -Seconds $segStart
                $s1 = Get-TrimZoomStateAt -Zooms $ks -Seconds $segEnd
                $seg.Zoom = @{ Z0 = $s0.Level; Z1 = $s1.Level; CX0 = $s0.CX; CX1 = $s1.CX; CY0 = $s0.CY; CY1 = $s1.CY }
            }
            $result += ,$seg
            continue
        }

        if ($seg.Kind -ne "cut" -or $overlapping.Count -eq 0) { $result += ,$seg; continue }

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

    $w = "iw/({0}+({1})*t/{2})" -f $z0s, $zd, $dS
    $h = "ih/({0}+({1})*t/{2})" -f $z0s, $zd, $dS
    $x = "min(max(({0}+({1})*t/{2})*iw-ow/2,0),iw-ow)" -f $cx0s, $cxd, $dS
    $y = "min(max(({0}+({1})*t/{2})*ih-oh/2,0),ih-oh)" -f $cy0s, $cyd, $dS

    return "crop={0}:{1}:{2}:{3},scale={4}x{5},setsar=1" -f $w, $h, $x, $y, $Width, $Height
}

Export-ModuleMember -Function New-ZoomKeyframe, Get-TrimZoomStateAt, Get-TrimZoomSpans, Split-TrimSegmentsForZooms, New-ZoomCropFilter
