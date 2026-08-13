# Multi-track model for the Video Editor: pure model + graph builders. No UI state.
$script:TrackKinds = @("video-main", "audio-source", "audio-clip", "video-clip")

function New-TrimTrack {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$StreamIdx = 0,
        [string]$Label = "",
        [double]$Offset = 0.0,
        [double]$InStart = 0.0,
        [double]$InEnd = 0.0,
        [bool]$Muted = $false,
        [double]$GainDb = 0.0,
        [hashtable]$Pip = $null
    )
    if ($script:TrackKinds -notcontains $Kind) { throw "New-TrimTrack: unknown kind '$Kind'" }
    # Source kinds are time-locked to the video by design (spec): no offsets, no trims.
    $locked = ($Kind -eq "video-main" -or $Kind -eq "audio-source")
    return [PSCustomObject]@{
        Id        = [guid]::NewGuid().ToString("N")
        Kind      = $Kind
        Path      = $Path
        StreamIdx = $StreamIdx
        Label     = $Label
        Offset    = $(if ($locked) { 0.0 } else { [math]::Max(0.0, $Offset) })
        InStart   = $(if ($locked) { 0.0 } else { [math]::Max(0.0, $InStart) })
        InEnd     = $(if ($locked) { 0.0 } else { [math]::Max(0.0, $InEnd) })
        GainDb    = [math]::Max(-30.0, [math]::Min(30.0, $GainDb))
        Muted     = $Muted
        Pip       = $Pip
    }
}

# Parses `ffprobe -select_streams a -show_entries stream=index:stream_tags=title -of csv=p=0`
# output: one line per stream, "index" or "index,title".
function ConvertFrom-AudioStreamProbe {
    param([string[]]$Lines = @())
    $result = @()
    $ordinal = 0
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim() -split ",", 2
        $idx = 0
        if (-not [int]::TryParse($parts[0], [ref]$idx)) { continue }
        $ordinal++
        $label = if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) { $parts[1].Trim() } else { "Audio $ordinal" }
        $result += ,@{ StreamIdx = $idx; Label = $label }
    }
    return ,@($result)
}

function Get-DefaultTrackStack {
    param([Parameter(Mandatory = $true)][string]$Path, [object[]]$AudioStreams = @())
    $stack = @()
    $stack += ,(New-TrimTrack -Kind "video-main" -Path $Path -Label "Video")
    foreach ($s in @($AudioStreams)) {
        $stack += ,(New-TrimTrack -Kind "audio-source" -Path $Path -StreamIdx ([int]$s.StreamIdx) -Label ([string]$s.Label))
    }
    return ,@($stack)
}

function Get-TrimTimelineStarts {
    param([object[]]$Pieces = @(), [double[]]$FadeLengths = @())
    $starts = @()
    $t = 0.0
    for ($i = 0; $i -lt @($Pieces).Count; $i++) {
        $starts += ,$t
        $len = [double]$Pieces[$i].End - [double]$Pieces[$i].Start
        $fade = if ($i -lt @($FadeLengths).Count) { [double]$FadeLengths[$i] } else { 0.0 }
        $t += $len - $fade
    }
    return ,@($starts)
}

function Get-TrackTimelineSpan {
    param([Parameter(Mandatory = $true)]$Track, [double]$SourceDuration = 0.0)
    $inStart = [double]$Track.InStart
    $inEnd = if ([double]$Track.InEnd -gt 0.0) { [double]$Track.InEnd } else { $SourceDuration }
    $len = [math]::Max(0.0, $inEnd - $inStart)
    return @{ Start = [double]$Track.Offset; End = ([double]$Track.Offset + $len) }
}

function Test-TrackStackTrivial {
    param([object[]]$Tracks = @(), [int]$SourceAudioStreamCount = -1)
    $mains = @(@($Tracks) | Where-Object { $_.Kind -eq "video-main" })
    if ($mains.Count -ne 1) { return $false }
    foreach ($t in @($Tracks)) {
        if ($t.Kind -eq "audio-clip" -or $t.Kind -eq "video-clip") { return $false }
        if ($t.Muted) { return $false }
        if ([math]::Abs([double]$t.GainDb) -gt 0.0001) { return $false }
    }
    # -1 (the default) is the legacy/unknown sentinel: every existing caller that never
    # heard of this parameter gets EXACTLY today's behavior. >= 0 means the caller probed
    # the source file's own audio stream count and additionally requires the stack's
    # surviving audio-source tracks to match it -- catching the case the loop above cannot:
    # deleting an audio-source track outright (rather than muting it) leaves nothing in
    # $Tracks for the loop to object to, so a stack with 0 audio-source entries against a
    # 2-audio-stream file would otherwise still read as trivial and stream-copy the
    # source's original (undeleted) audio straight through.
    if ($SourceAudioStreamCount -ge 0) {
        $sourceAudioTracks = @(@($Tracks) | Where-Object { $_.Kind -eq "audio-source" })
        if ($sourceAudioTracks.Count -ne $SourceAudioStreamCount) { return $false }
    }
    return $true
}

function New-TrimAudioMixPlan {
    param(
        [object[]]$Tracks = @(),
        [object[]]$Pieces = @(),
        [double[]]$FadeLengths = @(),
        [hashtable]$ClipDurations = @{}
    )
    if (@($Pieces).Count -eq 0) { throw "New-TrimAudioMixPlan: no pieces" }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    function fmt([double]$v) { return $v.ToString("0.####", $inv) }

    $main = @(@($Tracks) | Where-Object { $_.Kind -eq "video-main" })
    $mainPath = if ($main.Count -gt 0) { [string]$main[0].Path } else {
        # audio-only export still needs the source file for its audio-source streams
        [string](@($Tracks) | Where-Object { $_.Kind -eq "audio-source" } | Select-Object -First 1).Path
    }
    # Neither a video-main nor any audio-source track exists (e.g. both deleted, an
    # audio-clip-only stack survives) -- $mainPath resolves to "" and must NOT seed
    # InputPaths[0], or export builds `-i ""` and dies on an opaque ffmpeg error. The
    # IndexOf dedupe below renumbers clip inputs automatically, and `[0:{idx}]` source
    # refs are only ever emitted from the $sources loop, which is empty in this case too.
    # Outer @(...) wraps the WHOLE if/else, not just each branch: an if/else assigned
    # directly loses array-ness when the taken branch's array has exactly one element
    # (trap #5 in the closure/array memory file) -- without it, the else branch's
    # single-path array unwraps to a bare string on assignment, and every += below
    # silently does string concatenation instead of growing a real array.
    $inputPaths = @(if ([string]::IsNullOrEmpty($mainPath)) { @() } else { @($mainPath) })
    $starts = Get-TrimTimelineStarts -Pieces $Pieces -FadeLengths $FadeLengths
    $sources = @(@($Tracks) | Where-Object { $_.Kind -eq "audio-source" -and -not $_.Muted })
    $clips   = @(@($Tracks) | Where-Object { $_.Kind -eq "audio-clip" -and -not $_.Muted })

    $graph = @()
    $pieceLabels = @()
    for ($i = 0; $i -lt @($Pieces).Count; $i++) {
        $S = [double]$Pieces[$i].Start; $E = [double]$Pieces[$i].End
        $L = $E - $S
        $T = [double]$starts[$i]
        $inputs = @("[b$i]")
        $graph += ,("anullsrc=r=48000:cl=stereo,atrim=0:{0}[b{1}]" -f (fmt $L), $i)
        $k = 0
        foreach ($src in $sources) {
            $vol = if ([math]::Abs([double]$src.GainDb) -gt 0.0001) { ",volume={0}dB" -f (fmt ([double]$src.GainDb)) } else { "" }
            # [0:{StreamIdx}] -- the ABSOLUTE ffprobe stream index, not "0:a:N" (0-based
            # within audio streams). StreamIdx means "ffprobe absolute stream index"
            # everywhere in the track model (probe parsing, project file), and an
            # audio-relative remapping computed from surviving tracks was rejected: a
            # lane's rank would shift whenever the user deletes another lane, silently
            # repointing every remaining track at the wrong stream.
            $graph += ,("[0:{0}]atrim=start={1}:end={2},asetpts=PTS-STARTPTS{3}[s{4}_{5}]" -f `
                ([int]$src.StreamIdx), (fmt $S), (fmt $E), $vol, $i, $k)
            $inputs += "[s${i}_${k}]"; $k++
        }
        $c = 0
        foreach ($clip in $clips) {
            $dur = if ($ClipDurations.ContainsKey([string]$clip.Path)) { [double]$ClipDurations[[string]$clip.Path] } else { 0.0 }
            $span = Get-TrackTimelineSpan -Track $clip -SourceDuration $dur
            $spanStart = $span.Start; $spanEnd = $span.End
            $ovS = if ($spanStart -gt $T) { $spanStart } else { $T }
            $ovE = if ($spanEnd -lt ($T + $L)) { $spanEnd } else { $T + $L }
            if ($ovE - $ovS -le 0.0005) { continue }
            $path = [string]$clip.Path
            $n = [array]::IndexOf($inputPaths, $path)
            if ($n -lt 0) { $inputPaths += $path; $n = $inputPaths.Count - 1 }
            $clipIn = [double]$clip.InStart + ($ovS - [double]$clip.Offset)
            $clipOut = $clipIn + ($ovE - $ovS)
            $vol = if ([math]::Abs([double]$clip.GainDb) -gt 0.0001) { ",volume={0}dB" -f (fmt ([double]$clip.GainDb)) } else { "" }
            $ms = [int][math]::Round(($ovS - $T) * 1000.0)
            $delay = if ($ms -gt 0) { ",adelay={0}:all=1" -f $ms } else { "" }
            $graph += ,("[{0}:a]atrim=start={1}:end={2},asetpts=PTS-STARTPTS{3}{4}[c{5}_{6}]" -f `
                $n, (fmt $clipIn), (fmt $clipOut), $vol, $delay, $i, $c)
            $inputs += "[c${i}_${c}]"; $c++
        }
        $graph += ,("{0}amix=inputs={1}:duration=first:normalize=0[p{2}]" -f ($inputs -join ""), $inputs.Count, $i)
        $pieceLabels += "[p$i]"
    }

    # Join left to right. A single piece needs no join; rename its mix to [aout].
    if ($pieceLabels.Count -eq 1) {
        $graph[$graph.Count - 1] = $graph[$graph.Count - 1] -replace [regex]::Escape("[p0]"), "[aout]"
    } else {
        $acc = $pieceLabels[0]
        for ($i = 0; $i -lt $pieceLabels.Count - 1; $i++) {
            $next = $pieceLabels[$i + 1]
            $out = if ($i -eq $pieceLabels.Count - 2) { "[aout]" } else { "[j$i]" }
            $fade = if ($i -lt @($FadeLengths).Count) { [double]$FadeLengths[$i] } else { 0.0 }
            if ($fade -gt 0.0) {
                $graph += ,("{0}{1}acrossfade=d={2}:c1=tri:c2=tri{3}" -f $acc, $next, (fmt $fade), $out)
            } else {
                $graph += ,("{0}{1}concat=n=2:v=0:a=1{2}" -f $acc, $next, $out)
            }
            $acc = $out
        }
    }
    return @{ InputPaths = @($inputPaths); FilterComplex = ($graph -join ";"); OutputLabel = "[aout]" }
}

function New-PipOverlayChain {
    param([object[]]$Overlays = @(), [Parameter(Mandatory = $true)][int]$Width, [Parameter(Mandatory = $true)][int]$Height)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $parts = @()
    $prev = "[0:v]"
    for ($k = 0; $k -lt @($Overlays).Count; $k++) {
        $o = $Overlays[$k]
        $pip = $o.Pip
        $w = 2 * [int][math]::Round(([double]$pip.W * $Width) / 2.0)
        $h = 2 * [int][math]::Round(([double]$pip.H * $Height) / 2.0)
        $x = [int][math]::Round(([double]$pip.X - [double]$pip.W / 2.0) * $Width)
        $y = [int][math]::Round(([double]$pip.Y - [double]$pip.H / 2.0) * $Height)
        $out = if ($k -eq @($Overlays).Count - 1) { "[vout]" } else { "[vo$k]" }
        $parts += ,("[{0}:v]scale={1}:{2}[ov{3}]" -f ([int]$o.InputIndex), $w.ToString($inv), $h.ToString($inv), $k)
        $parts += ,("{0}[ov{1}]overlay={2}:{3}{4}" -f $prev, $k, $x.ToString($inv), $y.ToString($inv), $out)
        $prev = $out
    }
    return ($parts -join ";")
}

function Test-PipTransitionClash {
    param([object[]]$PipSpans = @(), [object[]]$Pieces = @(), [double[]]$FadeLengths = @())
    $starts = Get-TrimTimelineStarts -Pieces $Pieces -FadeLengths $FadeLengths
    for ($i = 0; $i -lt @($Pieces).Count - 1; $i++) {
        $d = if ($i -lt @($FadeLengths).Count) { [double]$FadeLengths[$i] } else { 0.0 }
        if ($d -le 0.0) { continue }
        $wEnd = [double]$starts[$i + 1] + $d
        $wStart = [double]$starts[$i + 1]
        foreach ($s in @($PipSpans)) {
            if ([double]$s.Start -lt $wEnd -and [double]$s.End -gt $wStart) { return $true }
        }
    }
    return $false
}

# ---- NLE lane/clip model (v3). Lanes hold clips; links are LinkId groups, computed. ----
$script:LaneKinds = @("video", "audio")
$script:ClipKinds = @("video", "image", "audio")

function New-TrimClip {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$StreamIdx = -1,
        [string]$LinkId = "",
        [double]$Offset = 0.0,
        [double]$InStart = 0.0,
        [double]$InEnd = 0.0,
        [double]$DurationOverride = 0.0,
        [double]$GainDb = 0.0,
        [bool]$Muted = $false,
        [hashtable]$Pip = $null,
        [bool]$Enabled = $true
    )
    if ($script:ClipKinds -notcontains $Kind) { throw "New-TrimClip: unknown kind '$Kind'" }
    $dur = $DurationOverride
    if ($Kind -eq "image") {
        # Spec 4.3: images default to 5.0s on screen, edge-trimmable down to 0.2s.
        if ($dur -le 0.0) { $dur = 5.0 }
        $dur = [math]::Max(0.2, $dur)
    } else {
        $dur = 0.0
    }
    return [PSCustomObject]@{
        Id               = [guid]::NewGuid().ToString("N")
        Kind             = $Kind
        Path             = $Path
        StreamIdx        = $StreamIdx
        LinkId           = $LinkId
        Offset           = [math]::Max(0.0, $Offset)
        InStart          = [math]::Max(0.0, $InStart)
        InEnd            = [math]::Max(0.0, $InEnd)
        DurationOverride = $dur
        GainDb           = [math]::Max(-30.0, [math]::Min(30.0, $GainDb))
        Muted            = $Muted
        Pip              = $Pip      # $null = full-frame (the default); hashtable = boxed PiP
        Enabled          = $Enabled
    }
}

function New-TrimLane {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$Label = "",
        [bool]$IsMain = $false,
        [object[]]$Clips = @()
    )
    if ($script:LaneKinds -notcontains $Kind) { throw "New-TrimLane: unknown kind '$Kind'" }
    return [PSCustomObject]@{
        Id     = [guid]::NewGuid().ToString("N")
        Kind   = $Kind
        Label  = $Label
        IsMain = $IsMain
        Clips  = @($Clips)
    }
}

# The stack a freshly loaded file gets: V1 (the recording) plus one always-visible audio
# row per probed stream, every row linked to the V1 clip through ONE shared LinkId --
# spec 4.1's "no U toggle needed to see them".
function Get-TrimLaneStack {
    param([Parameter(Mandatory = $true)][string]$Path, [object[]]$AudioStreams = @())
    $linkId = [guid]::NewGuid().ToString("N")
    $leaf = [System.IO.Path]::GetFileName($Path)
    $lanes = @()
    $vclip = New-TrimClip -Kind "video" -Path $Path -LinkId $linkId
    $lanes += ,(New-TrimLane -Kind "video" -Label $leaf -IsMain $true -Clips @($vclip))
    foreach ($s in @($AudioStreams)) {
        $aclip = New-TrimClip -Kind "audio" -Path $Path -StreamIdx ([int]$s.StreamIdx) -LinkId $linkId
        $lanes += ,(New-TrimLane -Kind "audio" -Label ([string]$s.Label) -Clips @($aclip))
    }
    return ,@($lanes)
}

function Get-TrimClipById2 {
    param([object[]]$Lanes = @(), [string]$ClipId)
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if ($c.Id -eq $ClipId) { return @{ Lane = $lane; Clip = $c } }
        }
    }
    return $null
}

function Get-TrimLinkedClipIds {
    param([object[]]$Lanes = @(), [Parameter(Mandatory = $true)][string]$ClipId)
    $hit = Get-TrimClipById2 -Lanes $Lanes -ClipId $ClipId
    if ($null -eq $hit) { return ,@() }
    $link = [string]$hit.Clip.LinkId
    if ([string]::IsNullOrEmpty($link)) { return ,@($ClipId) }
    $ids = @()
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if ($c.LinkId -eq $link) { $ids += ,([string]$c.Id) }
        }
    }
    return ,@($ids)
}

function Clear-TrimClipLinks {
    param([object[]]$Lanes = @(), [Parameter(Mandatory = $true)][string]$ClipId)
    $ids = Get-TrimLinkedClipIds -Lanes $Lanes -ClipId $ClipId
    $n = 0
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if ($ids -contains [string]$c.Id -and -not [string]::IsNullOrEmpty([string]$c.LinkId)) {
                $c.LinkId = ""
                $n++
            }
        }
    }
    return $n
}

function Get-TrimClipSpan {
    param([Parameter(Mandatory = $true)]$Clip, [double]$SourceDuration = 0.0)
    if ($Clip.Kind -eq "image") {
        return @{ Start = [double]$Clip.Offset; End = ([double]$Clip.Offset + [math]::Max(0.2, [double]$Clip.DurationOverride)) }
    }
    $inStart = [double]$Clip.InStart
    $inEnd = if ([double]$Clip.InEnd -gt 0.0) { [double]$Clip.InEnd } else { $SourceDuration }
    $len = [math]::Max(0.0, $inEnd - $inStart)
    return @{ Start = [double]$Clip.Offset; End = ([double]$Clip.Offset + $len) }
}

function Get-TrimOutputLength {
    param([object[]]$Pieces = @(), [double[]]$FadeLengths = @())
    $t = 0.0
    for ($i = 0; $i -lt @($Pieces).Count; $i++) {
        $t += ([double]$Pieces[$i].End - [double]$Pieces[$i].Start)
        if ($i -lt @($FadeLengths).Count) { $t -= [double]$FadeLengths[$i] }
    }
    return [math]::Max(0.0, $t)
}

# Is this clip the main recording's own video clip (the V1 base)? It is not an overlay
# and not a mixable row -- it IS the piece list -- so span math over lanes skips it.
function Test-TrimClipIsMainVideo {
    param($Lane, $Clip)
    return ([bool]$Lane.IsMain -and $Clip.Kind -eq "video")
}

function Get-TrimTimelineLength {
    param(
        [object[]]$Lanes = @(), [object[]]$Pieces = @(), [double[]]$FadeLengths = @(),
        [hashtable]$ClipDurations = @{}, [string]$MainPath = ""
    )
    $len = Get-TrimOutputLength -Pieces $Pieces -FadeLengths $FadeLengths
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if (-not $c.Enabled) { continue }
            if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
            $dur = if ($ClipDurations.ContainsKey([string]$c.Path)) { [double]$ClipDurations[[string]$c.Path] } else { 0.0 }
            $span = Get-TrimClipSpan -Clip $c -SourceDuration $dur
            if ([double]$span.End -gt $len) { $len = [double]$span.End }
        }
    }
    return $len
}

function Get-TrimSnapPoints {
    param(
        [object[]]$Lanes = @(), [object[]]$Pieces = @(), [double[]]$FadeLengths = @(),
        [hashtable]$ClipDurations = @{}, [string]$MainPath = "",
        [double]$PlayheadTimeline = -1.0, [string[]]$ExcludeClipIds = @()
    )
    $points = New-Object System.Collections.Generic.SortedSet[double]
    [void]$points.Add(0.0)
    [void]$points.Add((Get-TrimOutputLength -Pieces $Pieces -FadeLengths $FadeLengths))
    if ($PlayheadTimeline -ge 0.0) { [void]$points.Add([math]::Round($PlayheadTimeline, 4)) }
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if (-not $c.Enabled) { continue }
            if (@($ExcludeClipIds) -contains [string]$c.Id) { continue }
            if (Test-TrimClipIsMainVideo -Lane $lane -Clip $c) { continue }
            $dur = if ($ClipDurations.ContainsKey([string]$c.Path)) { [double]$ClipDurations[[string]$c.Path] } else { 0.0 }
            $span = Get-TrimClipSpan -Clip $c -SourceDuration $dur
            [void]$points.Add([math]::Round([double]$span.Start, 4))
            [void]$points.Add([math]::Round([double]$span.End, 4))
        }
    }
    return ,@($points)
}

function Resolve-TrimSnap {
    param([double]$Position, [double[]]$Points = @(), [double]$Threshold = 0.0)
    $best = 0.0
    $bestDist = [double]::MaxValue
    foreach ($p in @($Points)) {
        $d = [math]::Abs($Position - [double]$p)
        if ($d -lt $bestDist) { $bestDist = $d; $best = [double]$p }
    }
    if ($bestDist -le $Threshold) {
        return @{ Position = $best; Snapped = $true; Point = $best }
    }
    return @{ Position = $Position; Snapped = $false; Point = 0.0 }
}

function Get-TrimLinkGroupClips {
    param([object[]]$Lanes = @(), [string]$ClipId)
    $ids = Get-TrimLinkedClipIds -Lanes $Lanes -ClipId $ClipId
    $clips = @()
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if ($ids -contains [string]$c.Id) { $clips += ,$c }
        }
    }
    return ,@($clips)
}

function Move-TrimClipLinked {
    param([object[]]$Lanes = @(), [Parameter(Mandatory = $true)][string]$ClipId, [double]$NewOffset)
    $hit = Get-TrimClipById2 -Lanes $Lanes -ClipId $ClipId
    if ($null -eq $hit) { return 0.0 }
    $delta = $NewOffset - [double]$hit.Clip.Offset
    $group = Get-TrimLinkGroupClips -Lanes $Lanes -ClipId $ClipId
    # One shared clamp: the group's leftmost member decides how far left everyone may go.
    $minOffset = [double]::MaxValue
    foreach ($c in $group) { if ([double]$c.Offset -lt $minOffset) { $minOffset = [double]$c.Offset } }
    $applied = [math]::Max(-$minOffset, $delta)
    foreach ($c in $group) { $c.Offset = [double]$c.Offset + $applied }
    return $applied
}

function Set-TrimClipInPointLinked {
    param([object[]]$Lanes = @(), [Parameter(Mandatory = $true)][string]$ClipId, [double]$Delta)
    $hit = Get-TrimClipById2 -Lanes $Lanes -ClipId $ClipId
    if ($null -eq $hit) { return 0.0 }
    $group = Get-TrimLinkGroupClips -Lanes $Lanes -ClipId $ClipId
    # Group-wide delta bounds, tightened member by member (never clamped per clip -- a
    # pair whose members clamp differently drifts apart, the exact drift the lockstep
    # in-point math exists to prevent).
    $dMin = -[double]::MaxValue; $dMax = [double]::MaxValue
    foreach ($c in $group) {
        if ($c.Kind -eq "image") {
            $dMin = [math]::Max($dMin, -[double]$c.Offset)
            $dMax = [math]::Min($dMax, [double]$c.DurationOverride - 0.2)
        } else {
            $minGap = 0.1
            $dMin = [math]::Max($dMin, [math]::Max(-[double]$c.InStart, -[double]$c.Offset))
            if ([double]$c.InEnd -gt 0.0) { $dMax = [math]::Min($dMax, [double]$c.InEnd - $minGap - [double]$c.InStart) }
        }
    }
    if ($dMax -lt $dMin) { return 0.0 }
    $applied = [math]::Max($dMin, [math]::Min($dMax, $Delta))
    foreach ($c in $group) {
        if ($c.Kind -eq "image") {
            $c.Offset = [double]$c.Offset + $applied
            $c.DurationOverride = [double][math]::Round([double]$c.DurationOverride - $applied, 10)
            if ($c.DurationOverride -lt 0.2) { $c.DurationOverride = 0.2 }
        } else {
            $c.InStart = [double]$c.InStart + $applied
            $c.Offset = [double]$c.Offset + $applied
        }
    }
    return $applied
}

function Set-TrimClipOutPointLinked {
    param(
        [object[]]$Lanes = @(), [Parameter(Mandatory = $true)][string]$ClipId,
        [double]$Delta, [hashtable]$ClipDurations = @{}
    )
    $hit = Get-TrimClipById2 -Lanes $Lanes -ClipId $ClipId
    if ($null -eq $hit) { return 0.0 }
    $group = Get-TrimLinkGroupClips -Lanes $Lanes -ClipId $ClipId
    $dMin = -[double]::MaxValue; $dMax = [double]::MaxValue
    foreach ($c in $group) {
        if ($c.Kind -eq "image") {
            $dMin = [math]::Max($dMin, 0.2 - [double]$c.DurationOverride)
        } else {
            $minGap = 0.1
            $src = if ($ClipDurations.ContainsKey([string]$c.Path)) { [double]$ClipDurations[[string]$c.Path] } else { 0.0 }
            # Resolve the sentinel ONCE, here, so the trim math below works on literal ends
            # (same resolution Start-TrimTrackDrag documented for the v2 bars). A cache
            # miss leaves the whole edge inert rather than clamping against an invented
            # value.
            if ([double]$c.InEnd -le 0.0 -and $src -gt 0.0) { $c.InEnd = $src }
            if ([double]$c.InEnd -le 0.0) { return 0.0 }
            $dMin = [math]::Max($dMin, ([double]$c.InStart + $minGap) - [double]$c.InEnd)
            if ($src -gt 0.0) { $dMax = [math]::Min($dMax, $src - [double]$c.InEnd) } else { if ([double]$c.InEnd -gt 0.0) { $dMax = [math]::Min($dMax, 0.0) } }
        }
    }
    if ($dMax -lt $dMin) { return 0.0 }
    $applied = [math]::Max($dMin, [math]::Min($dMax, $Delta))
    foreach ($c in $group) {
        if ($c.Kind -eq "image") {
            $c.DurationOverride = [double][math]::Round([double]$c.DurationOverride + $applied, 10)
            if ($c.DurationOverride -lt 0.2) { $c.DurationOverride = 0.2 }
        } else {
            $c.InEnd = [double]$c.InEnd + $applied
        }
    }
    return $applied
}

# Lane-stack triviality (spec 5.1): the fast path for the montage/black-base design.
# Exactly one video lane, IsMain, holding exactly one enabled, untouched V1 clip of
# MainPath, linked; every other lane is an audio lane holding exactly one enabled,
# linked, untrimmed, unslid, ungained/unmuted audio clip of MainPath. This supersedes
# Test-TrackStackTrivial's role for the app -- but that function stays exported and
# untouched for the legacy -Tracks arm (see Get-TrimExportMode).
function Test-TrimLaneStackTrivial {
    param([object[]]$Lanes = @(), [string]$MainPath = "", [int]$SourceAudioStreamCount = -1)
    $videoLanes = @(@($Lanes) | Where-Object { $_.Kind -eq "video" })
    if ($videoLanes.Count -ne 1) { return $false }
    $main = $videoLanes[0]
    if (-not [bool]$main.IsMain) { return $false }
    $mainClips = @($main.Clips)
    if ($mainClips.Count -ne 1) { return $false }
    $v = $mainClips[0]
    if ($v.Kind -ne "video" -or $v.Path -ne $MainPath -or -not $v.Enabled) { return $false }
    if ([double]$v.Offset -ne 0.0 -or [double]$v.InStart -ne 0.0 -or [double]$v.InEnd -ne 0.0) { return $false }
    if ([string]::IsNullOrEmpty([string]$v.LinkId)) { return $false }
    $audioLaneCount = 0
    foreach ($lane in @($Lanes)) {
        if ($lane.Id -eq $main.Id) { continue }
        if ($lane.Kind -ne "audio") { return $false }
        $clips = @($lane.Clips)
        if ($clips.Count -ne 1) { return $false }   # empty added lanes break triviality too (spec 5.1: "no other tracks/clips")
        $a = $clips[0]
        if ($a.Kind -ne "audio" -or $a.Path -ne $MainPath -or [int]$a.StreamIdx -lt 0) { return $false }
        if ($a.LinkId -ne $v.LinkId) { return $false }
        if (-not $a.Enabled -or $a.Muted) { return $false }
        if ([math]::Abs([double]$a.GainDb) -gt 0.0001) { return $false }
        if ([double]$a.Offset -ne 0.0 -or [double]$a.InStart -ne 0.0 -or [double]$a.InEnd -ne 0.0) { return $false }
        $audioLaneCount++
    }
    # -SourceAudioStreamCount: -1 keeps the legacy sentinel semantics (no check); >= 0
    # requires the linked source rows to match the file's probed stream count, so a
    # DELETED row (nothing left in the stack to object to) still breaks triviality --
    # the exact hole Test-TrackStackTrivial's parameter was added to close.
    if ($SourceAudioStreamCount -ge 0 -and $audioLaneCount -ne $SourceAudioStreamCount) { return $false }
    return $true
}

function Test-TrimLaneStackHasAudio {
    param([object[]]$Lanes = @())
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if ($c.Kind -eq "audio" -and $c.Enabled -and -not $c.Muted) { return $true }
        }
    }
    return $false
}

function Test-TrimLaneStackHasVideo {
    param([object[]]$Lanes = @())
    foreach ($lane in @($Lanes)) {
        foreach ($c in @($lane.Clips)) {
            if (($c.Kind -eq "video" -or $c.Kind -eq "image") -and $c.Enabled) { return $true }
        }
    }
    return $false
}

Export-ModuleMember -Function New-TrimTrack, ConvertFrom-AudioStreamProbe, Get-DefaultTrackStack, Get-TrimTimelineStarts, Get-TrackTimelineSpan, Test-TrackStackTrivial, New-TrimAudioMixPlan, New-PipOverlayChain, Test-PipTransitionClash, New-TrimClip, New-TrimLane, Get-TrimLaneStack, Get-TrimClipById2, Get-TrimLinkedClipIds, Clear-TrimClipLinks, Get-TrimClipSpan, Get-TrimOutputLength, Test-TrimClipIsMainVideo, Get-TrimTimelineLength, Get-TrimSnapPoints, Resolve-TrimSnap, Get-TrimLinkGroupClips, Move-TrimClipLinked, Set-TrimClipInPointLinked, Set-TrimClipOutPointLinked, Test-TrimLaneStackTrivial, Test-TrimLaneStackHasAudio, Test-TrimLaneStackHasVideo
