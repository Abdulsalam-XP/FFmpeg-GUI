# The Trim panel's edit model. Pure array transforms: no UI, no ffmpeg, no globals, which
# is what makes this the one part of the editor that can be tested without a window.
#
# The list IS the surviving footage. A delete removes the piece outright, so there is no
# separate "which parts survive" query -- export consumes this array directly.

# Boundaries land on keyframes, which the caller has already snapped, so exact float
# equality would work. This tolerance guards against a keyframe time round-tripping
# through ffprobe text with a sub-microsecond difference.
$script:Epsilon = 0.0005

function New-CutList {
    param([Parameter(Mandatory = $true)][double]$Duration)
    return ,@([PSCustomObject]@{ Start = 0.0; End = $Duration })
}

function Split-CutList {
    param(
        [object[]]$List,
        [Parameter(Mandatory = $true)][double]$AtSeconds
    )

    $result = @()
    $didSplit = $false

    foreach ($piece in @($List)) {
        # Strictly inside: a split exactly on a boundary would produce a zero-length
        # piece, and a split in a gap left by a delete belongs to no piece at all.
        if (-not $didSplit -and
            $AtSeconds -gt ($piece.Start + $script:Epsilon) -and
            $AtSeconds -lt ($piece.End - $script:Epsilon)) {
            $result += [PSCustomObject]@{ Start = $piece.Start; End = $AtSeconds }
            $result += [PSCustomObject]@{ Start = $AtSeconds; End = $piece.End }
            $didSplit = $true
        } else {
            $result += $piece
        }
    }

    return ,@($result)
}

function Remove-CutPiece {
    param(
        [object[]]$List,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $all = @($List)
    if ($Index -lt 0 -or $Index -ge $all.Count) { return ,$all }
    return ,@($all | Where-Object { $all.IndexOf($_) -ne $Index })
}

# Snapping is what makes the timeline honest: the cut line is drawn where the file can
# actually be cut, so what is on screen is what gets exported.
function Find-NearestKeyframe {
    param(
        [double[]]$Keyframes,
        [Parameter(Mandatory = $true)][double]$Seconds
    )

    $frames = @($Keyframes)
    # No keyframe list yet (still being read) means no snapping rather than no cutting.
    if ($frames.Count -eq 0) { return $Seconds }

    $best = $frames[0]
    $bestGap = [math]::Abs($Seconds - $best)
    foreach ($k in $frames) {
        $gap = [math]::Abs($Seconds - $k)
        # Strictly less, so an exact tie keeps the earlier keyframe.
        if ($gap -lt $bestGap) { $best = $k; $bestGap = $gap }
    }
    return $best
}

Export-ModuleMember -Function New-CutList, Split-CutList, Remove-CutPiece, Find-NearestKeyframe
