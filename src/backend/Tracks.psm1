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
    param([object[]]$Tracks = @())
    $mains = @(@($Tracks) | Where-Object { $_.Kind -eq "video-main" })
    if ($mains.Count -ne 1) { return $false }
    foreach ($t in @($Tracks)) {
        if ($t.Kind -eq "audio-clip" -or $t.Kind -eq "video-clip") { return $false }
        if ($t.Muted) { return $false }
        if ([math]::Abs([double]$t.GainDb) -gt 0.0001) { return $false }
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
    $inputPaths = @($mainPath)
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

Export-ModuleMember -Function New-TrimTrack, ConvertFrom-AudioStreamProbe, Get-DefaultTrackStack, Get-TrimTimelineStarts, Get-TrackTimelineSpan, Test-TrackStackTrivial, New-TrimAudioMixPlan, New-PipOverlayChain, Test-PipTransitionClash
