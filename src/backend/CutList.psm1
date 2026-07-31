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
    # A $null -List binds through the typed [object[]] parameter as a genuine $null
    # rather than an empty array, so @($List) above can come back $null too. Left
    # unguarded, "return ,$all" below would then hand back $null instead of the empty
    # array this function promises callers -- normalize here rather than let that
    # leak out.
    if ($null -eq $all) { $all = @() }
    if ($Index -lt 0 -or $Index -ge $all.Count) { return ,$all }
    # IndexOf compares by reference, not value: safe only because every piece is a
    # distinct PSCustomObject instance. If a caller ever reuses the same instance
    # across two slots in the list (e.g. an undo snapshot holding onto old references),
    # this would find the first match only and could drop the wrong one.
    return ,@($all | Where-Object { $all.IndexOf($_) -ne $Index })
}

# Snapping is what makes the timeline honest: the cut line is drawn where the file can
# actually be cut, so what is on screen is what gets exported.
function Find-NearestKeyframe {
    param(
        [double[]]$Keyframes,
        [Parameter(Mandatory = $true)][double]$Seconds
    )

    # -Keyframes is not Mandatory, so it may be omitted or passed as $null. @($null) is
    # a one-element array holding $null, not an empty array, so $frames.Count alone
    # would not catch that case -- check for $null explicitly first. (Deliberately not
    # "-not $Keyframes": PowerShell's array-to-bool conversion for a single-element
    # array evaluates the truthiness of that one element, so a real one-keyframe list
    # containing exactly 0.0 would read as falsy and wrongly skip snapping.)
    # No keyframe list yet (still being read) means no snapping rather than no cutting.
    if ($null -eq $Keyframes) { return $Seconds }
    $frames = @($Keyframes)
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
