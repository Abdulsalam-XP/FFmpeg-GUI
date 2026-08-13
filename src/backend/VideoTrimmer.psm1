Import-Module "$PSScriptRoot/UI.psm1"
Import-Module "$PSScriptRoot/ToolPaths.psm1"
Import-Module "$PSScriptRoot/Captions.psm1"
Import-Module "$PSScriptRoot/Zooms.psm1"
Import-Module "$PSScriptRoot/Tracks.psm1"

# Keyframe times for the trim timeline. Cuts can only start on a keyframe without
# re-encoding, so the timeline snaps to these and the panel reports their spacing --
# on the NVIDIA DVR recordings this app is used with, that spacing is 0.25s, which is
# why the editor re-encodes nothing at all.
#
# Lines come from ffprobe's packet index (see Get-KeyframeTimes below), each shaped
# "<pts_time>,<flags>" e.g. "0.249878,K__" -- the packet index already stores every
# packet, not just keyframes, so a packet is only kept if its flags contain 'K'.
# Filtering lives here rather than between the ffprobe call and this function so the
# one place that is unit tested is the one place that decides what counts as a
# keyframe -- Get-KeyframeTimes stays a thin, untested shell-out.
function ConvertFrom-KeyframeOutput {
    param([string[]]$Lines)

    $times = @()
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        $text = $line.Trim()
        if (-not $text) { continue }
        $parts = $text -split ','
        if ($parts.Count -lt 2) { continue }
        $timeText = $parts[0].Trim()
        $flags = $parts[1].Trim()
        if ($flags -notmatch 'K') { continue }
        if ($timeText -notmatch '^\d+(\.\d+)?$') { continue }
        $times += [double]$timeText
    }
    return ,@($times | Sort-Object)
}

function Get-KeyframeTimes {
    param([Parameter(Mandatory = $true)][string]$InputFile)

    $ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    # Reads the container's packet index directly instead of decoding frames.
    # -skip_frame nokey + frame=pts_time (the original approach) decodes every
    # keyframe to report a timestamp the packet index already stores -- ~26x slower
    # for identical values. packet=pts_time,flags returns every packet; flags
    # contains 'K' for a keyframe packet, filtered out in ConvertFrom-KeyframeOutput.
    $raw = & $ffprobe -v error -select_streams v:0 `
        -show_entries packet=pts_time,flags -of csv=p=0 $InputFile 2>&1
    return ,(ConvertFrom-KeyframeOutput -Lines @($raw | ForEach-Object { "$_" }))
}

# Everything a crossfade segment has to match so it can be concatenated with the
# stream-copied pieces around it instead of forcing a full re-encode.
#
# TimeScale is the one that is easy to miss and expensive to get wrong: libx264 defaults
# an mp4 to a 1/15360 timescale while a copied piece keeps the source's 1/90000, and the
# concat demuxer then rounds two neighbouring frames onto the same DTS. Measured on the
# 1440p120 DVR clips: 59 "non monotonically increasing dts" collisions at a single join,
# gone entirely once -video_track_timescale matches.
#
# VideoEncoder matters just as much: a libx264 transition spliced between HEVC copies
# produces a file whose streams change codec halfway through. Fades are refused outright
# for a source this cannot match rather than silently producing that.
function Get-TrimSourceProfile {
    param([Parameter(Mandatory = $true)][string]$InputFile)

    $ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    # Field ORDER in the csv is ffprobe's own (the order the fields appear in its stream
    # struct), NOT the order they are requested in -- verified against these recordings:
    # codec_name,width,height,time_base. Adding a field can therefore shift the index of
    # every field after it, which is why each one below is read by its fixed position.
    $videoRaw = & $ffprobe -v error -select_streams v:0 `
        -show_entries stream=codec_name,width,height,time_base -of csv=p=0 $InputFile 2>&1
    $videoParts = ("$videoRaw").Trim() -split ','
    $codec = if ($videoParts.Count -ge 1) { $videoParts[0].Trim() } else { "" }

    # Burned captions are positioned as a fraction of the frame, so the .ass needs the
    # real frame size to turn those fractions back into pixels. Defaults match the DVR
    # recordings this app is built around rather than something arbitrary, so an
    # unreadable probe still lands captions in roughly the right place.
    $width = 2560
    $height = 1440
    if ($videoParts.Count -ge 2 -and $videoParts[1].Trim() -match '^\d+$') { $width = [int]$videoParts[1].Trim() }
    if ($videoParts.Count -ge 3 -and $videoParts[2].Trim() -match '^\d+$') { $height = [int]$videoParts[2].Trim() }

    # time_base arrives as "1/90000"; the denominator is the timescale.
    $timeScale = 90000
    if ($videoParts.Count -ge 4 -and $videoParts[3] -match '^\s*\d+\s*/\s*(\d+)\s*$') {
        $timeScale = [int]$Matches[1]
    }

    $audioRaw = @(& $ffprobe -v error -select_streams a `
        -show_entries stream=sample_rate,channels -of csv=p=0 $InputFile 2>&1 |
        ForEach-Object { "$_" } | Where-Object { $_.Trim() })

    $sampleRate = 48000
    $channels = 2
    if ($audioRaw.Count -gt 0) {
        $first = $audioRaw[0] -split ','
        if ($first.Count -ge 1 -and $first[0].Trim() -match '^\d+$') { $sampleRate = [int]$first[0].Trim() }
        if ($first.Count -ge 2 -and $first[1].Trim() -match '^\d+$') { $channels = [int]$first[1].Trim() }
    }

    $encoder = switch ($codec) {
        "h264" { "libx264" }
        "hevc" { "libx265" }
        default { $null }
    }

    return @{
        VideoCodec   = $codec
        VideoEncoder = $encoder
        TimeScale    = $timeScale
        Width        = $width
        Height       = $height
        AudioStreams = $audioRaw.Count
        SampleRate   = $sampleRate
        Channels     = $channels
    }
}

# Duration of any media file -- video or audio-only -- via -show_format, so an external
# clip added to a track (Task 10: an mp3/m4a/wav/flac has no video stream at all) can be
# probed the same way a video clip is, unlike Get-VideoProperties which requires one.
# Returns 0.0 on any probe failure rather than throwing: a clip whose duration can't be
# read still gets added, it just falls back to "InEnd 0 means to the end of the source"
# reading as an empty span until the user trims it, exactly like the pre-existing
# audio-source SourceDuration fallback in Get-TrimTrackBarBounds.
function Get-TrimClipDuration {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    $raw = & $ffprobe -v error -show_entries "format=duration" -of csv=p=0 $Path 2>$null
    $text = (@($raw) | Select-Object -First 1)
    $d = 0.0
    if ($text -and [double]::TryParse(("$text").Trim(), [System.Globalization.NumberStyles]::Float, `
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return $d
    }
    return 0.0
}

# Turns the piece list plus a per-boundary fade flag into the flat list of segments the
# export actually builds: one entry per piece, with a transition entry spliced between
# any two pieces whose shared boundary is faded.
#
# A crossfade has to come from somewhere -- it is built from the outgoing piece's last
# fade-length and the incoming piece's first fade-length, so both donor pieces are
# shortened by that much and the transition replaces what they gave up. That is why the
# export ends up SHORTER than the timeline by one fade length per faded cut.
#
# One length per boundary rather than a single length for the whole export: a fade is a
# per-cut decision, and a montage will often want a long dissolve in one place and a quick
# one in another. Zero means "no fade here", which collapses the old separate on/off flag
# array and length into one list that cannot disagree with itself.
function Get-TrimSegmentPlan {
    param(
        [Parameter(Mandatory = $true)][object[]]$Pieces,
        # $FadeLengths[$i] is the crossfade between piece $i and piece $i+1, in seconds.
        [double[]]$FadeLengths = @()
    )

    $list = @($Pieces)
    $segments = @()
    for ($i = 0; $i -lt $list.Count; $i++) {
        $start = [double]$list[$i].Start
        $end = [double]$list[$i].End
        $before = if ($i -gt 0 -and $i - 1 -lt $FadeLengths.Count) { $FadeLengths[$i - 1] } else { 0 }
        $after = if ($i -lt $list.Count - 1 -and $i -lt $FadeLengths.Count) { $FadeLengths[$i] } else { 0 }

        if ($before -gt 0) { $start += $before }
        if ($after -gt 0) { $end -= $after }

        $segments += @{
            Kind     = "cut"
            Start    = $start
            Duration = $end - $start
        }

        if ($after -gt 0) {
            $segments += @{
                Kind     = "transition"
                # The outgoing piece's real tail and the incoming piece's real head --
                # the footage the two neighbours just gave up.
                Start    = [double]$list[$i].End - $after
                NextStart = [double]$list[$i + 1].Start
                Duration = $after
            }
        }
    }
    return ,@($segments)
}

# A Windows path as ffmpeg's filter parser wants to see it inside ass='...'.
#
# Two separate escapes, both required: the filter graph is parsed before the filter's own
# arguments, so a backslash is a graph-level escape character and "C:\Users" would eat the
# U -- forward slashes avoid that entirely. The colon then still has to be escaped because
# it is the filter's own option separator, so "C:/x" would be read as filter "C" with an
# option list starting at "/x".
function ConvertTo-AssFilterPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $p = ($Path -replace '\\', '/') -replace ':', '\:'
    # The call sites wrap the result in single quotes; a literal ' in the path (an
    # apostrophe in a Windows username reaching %TEMP%) would close that quote early and
    # feed the rest of the path to the graph parser as garbage. ffmpeg's quoting rule:
    # end the quoted run, emit an escaped quote, reopen.
    return ($p -replace "'", "'\''")
}

# Exports the surviving pieces as one file.
#
# One ffmpeg pass per piece, then one to join them. The obvious single-pass alternative
# (concat demuxer with inpoint/outpoint against the source) was built and measured on
# 2026-07-31: it froze ~0.9s at every join and dropped 267 frames, because the pieces keep
# their original timestamps and leave a gap. Extracting each piece first gives every one
# zero-based timing, which is what makes the join clean. Do not "simplify" this back.
function Export-CutListAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][object[]]$Pieces,
        # One entry per internal boundary, in seconds; 0 means a plain cut there.
        [double[]]$FadeLengths = @(),
        # Caption objects (New-Caption shape) in SOURCE time. Empty means nothing burns
        # and every non-transition segment still stream-copies.
        [object[]]$Captions = @(),
        # Zoom keyframes (New-ZoomKeyframe shape) in SOURCE time. Empty means no segment
        # crops and the plan comes out exactly as the caption split left it.
        [object[]]$Zooms = @(),
        # Multi-track stack (New-TrimTrack shape). Empty (the default, and every existing
        # caller) means the legacy single-track pipeline below runs completely unchanged --
        # see Get-TrimExportMode. Non-empty routes through the audio-rebuild path: video
        # re-encodes muted (-an), a separate pass mixes the tracks, and a final mux joins
        # them back together.
        [object[]]$Tracks = @(),
        # Path -> seconds, probed by the app, for audio-clip tracks whose InEnd is 0 (means
        # "to the end of the clip"). Passed straight through to New-TrimAudioMixPlan.
        [hashtable]$ClipDurations = @{},
        # Picture-in-picture spans (Start/End/Overlay), SOURCE time. Non-empty forces the
        # rebuild path even on an otherwise-trivial stack, because a pip has to be composited
        # onto the video during the segment re-encode.
        [object[]]$PipSpans = @(),
        # Probed count of audio streams the SOURCE file itself has, -1 (default) for every
        # existing caller -- the legacy/unknown sentinel Test-TrackStackTrivial treats as
        # "behave exactly as before this parameter existed". >= 0 additionally routes a
        # stack whose audio-source tracks were deleted (not muted) to the rebuild path,
        # since a deleted-audio stack otherwise has nothing left in $Tracks to mark it
        # non-trivial and would silently fall through to stream-copying the source's
        # original, undeleted audio. See Get-TrimExportMode / Test-TrackStackTrivial.
        [int]$SourceAudioStreamCount = -1,
        [scriptblock]$OnFinished = $null
    )

    $panel = $Context.Panels.Trim
    $progressBar = $panel.FindName("ProgressBarTrim")
    $percentText = $panel.FindName("TextTrimPercent")
    $etaText = $panel.FindName("TextTrimEta")
    $cancelButton = $panel.FindName("ButtonTrimCancel")
    $startButton = $panel.FindName("ButtonTrimExport")

    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    $outputFile = Get-JobOutputPath -InputFile $InputFile -Suffix "Edited"

    # Everything below this line up to $stepCount is guarded by $mode so the trivial path
    # (no tracks, or an untouched stack with no pips) takes EXACTLY the pre-existing route:
    # no -an, no mix pass, no mux, no behavioral change of any kind. See Get-TrimExportMode
    # for the decision, kept pure and unit-tested there rather than inlined here.
    $mode = Get-TrimExportMode -Tracks $Tracks -PipSpans $PipSpans -SourceAudioStreamCount $SourceAudioStreamCount
    # A deleted video-main means there is no video pipeline at all -- the audio pass IS the
    # export, and it writes an audio container rather than an mp4.
    if ($mode -eq "audio-only") {
        $outputFile = [System.IO.Path]::ChangeExtension($outputFile, ".m4a")
    }
    # Muting every audio lane is NOT trivial (Test-TrackStackTrivial refuses any Muted
    # track), so a fully-muted stack lands in "rebuild" same as a gained one -- but running
    # the audio pass there would mix zero sources over New-TrimAudioMixPlan's silence base
    # and mux in a SILENT AAC stream, which is a different artifact than the spec's
    # video-only, no-audio-stream-at-all output. Checked only for rebuild mode: audio-only
    # mode already requires an audio pass to have any output at all (a fully-muted,
    # video-main-deleted stack is a degenerate empty project, out of scope here).
    $hasAudio = Test-TrackStackHasAudio -Tracks $Tracks

    # $work is the segment plan, not the piece list: with no fades the two are the same
    # thing (one copy step per piece), and with fades it also carries the transition
    # steps, so the runner below stays a flat "one ffmpeg per entry, then concat".
    # NOT @(Get-TrimSegmentPlan ...): the function returns ",@($segments)", which reaches
    # the caller as one object that happens to be an array. Wrapping that in @() makes a
    # one-element array holding the segment array, so $work.Count is 1 and the export
    # runs a single step against a bogus segment -- with or without fades. Assigning the
    # call directly is what keeps it a real list.
    $work = Get-TrimSegmentPlan -Pieces $Pieces -FadeLengths $FadeLengths
    # Captions split copy segments further: the stretches with text on screen become
    # "burn" segments that re-encode with the .ass baked in, and everything else still
    # stream-copies, so a two-second caption costs two seconds of encoding rather than
    # the whole export. Same return-shape trap as above -- assigned directly, never
    # @(...)-wrapped.
    $work = Split-TrimSegmentsForCaptions -Segments $work -Captions $Captions
    # Zooms split what is left the same way: the stretches under a zoom span become "zoom"
    # segments that re-encode with a crop/scale chain, and a caption segment that happens
    # to sit inside a span just gains a .Zoom key instead of being split again (its shape
    # is already fixed by the caption). Same return-shape trap -- direct assignment.
    # $stepCount is computed after the LAST split, because the splits are what decide how
    # many ffmpeg runs there actually are.
    $work = Split-TrimSegmentsForZooms -Segments $work -Zooms $Zooms
    # Non-trivial video pipeline: pip spans split the segments further (a segment under a
    # pip re-encodes with an overlay chain even if it would otherwise stream-copy), still
    # before $stepCount is computed -- the splits are what decide how many ffmpeg runs
    # there actually are. audio-only mode has no video-main at all, so the whole video
    # pipeline is skipped: $work becomes empty and the audio pass is the only step.
    if ($mode -eq "rebuild") {
        $work = Split-TrimSegmentsForPips -Segments $work -PipSpans $PipSpans
    } elseif ($mode -eq "audio-only") {
        $work = @()
    }
    # Captured before the audiomix/mux markers are appended below -- this is the count of
    # real video segments, used to size $tempFiles to actual piece files only (an audiomix
    # or mux marker is never extracted to piece{i}.mp4) and to know how many of $tempFiles
    # belong in the mux step's concat list.
    $segCount = $work.Count
    # Whether audiomix/mux got appended as real $work entries -- true for every
    # non-trivial mode EXCEPT a rebuild stack with no unmuted audio at all. That last case
    # skips the audio pass entirely and falls through to the SAME implicit "one step past
    # the segment list" concat trivial mode uses (unchanged code, further down): the
    # pieces are already video-only (every rebuild-mode segment encode carries -an), so a
    # plain "-map 0 -c copy" of them is already the correct video-only output -- no mux,
    # no .m4a, nothing left to append.
    $appendsFinalSteps = ($mode -eq "rebuild" -and $hasAudio) -or ($mode -eq "audio-only")
    if ($mode -eq "rebuild" -and $hasAudio) {
        # Two more RunStep entries, reusing the same progress/cancel plumbing as every
        # other step: mix the tracks' audio, then mux it onto the video-only concat.
        $work = $work + @(@{ Kind = "audiomix" }, @{ Kind = "mux" })
    } elseif ($mode -eq "audio-only") {
        # No video at all -- the mix pass writes the final output directly.
        $work = $work + @(@{ Kind = "audiomix" })
    }
    $stepCount = $work.Count + 1
    # For modes where audiomix (and mux) are now real entries INSIDE $work -- unlike the
    # trivial path's implicit "one step past the segment list is the concat", there is
    # nothing left to do after the last entry in $work, so the "+1" above (which exists
    # only to count that implicit trailing concat step) does not apply. A rebuild stack
    # with no unmuted audio did NOT get those entries appended, so it keeps the "+1" and
    # reaches the implicit concat step exactly like trivial mode does.
    if ($appendsFinalSteps) { $stepCount = $work.Count }
    $profile = Get-TrimSourceProfile -InputFile $InputFile
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-cut-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    # Dedicated path for the audio-rebuild's mix pass. Written here (rather than inline in
    # the "audiomix" step) so the "mux" step -- a separate RunStep call, on a separate
    # closure -- can find it too.
    $audioMixOutput = Join-Path $tempDir "audiomix.m4a"

    $tempFiles = @()
    for ($i = 0; $i -lt $work.Count; $i++) {
        $tempFiles += (Join-Path $tempDir ("piece{0:D3}.mp4" -f $i))
    }

    # One segment-local .ass per burning segment, all written up front rather than inside
    # the step runner: the runner's steps execute later from timer callbacks, where a
    # failed write would surface as an ffmpeg error with no obvious cause.
    #
    # Times are shifted by the segment's start because each segment is extracted with -ss
    # and therefore begins at t=0 in its own file. UTF-8 WITH a BOM -- libass wants one;
    # the concat list further down must NOT have one. Do not unify the two.
    for ($i = 0; $i -lt $work.Count; $i++) {
        $seg = $work[$i]
        if (($seg.Kind -eq "burn" -or $seg.Kind -eq "transition") -and $seg.Captions) {
            $assPath = Join-Path $tempDir ("seg{0:D3}.ass" -f $i)
            $assDoc = New-AssDocument -Captions $seg.Captions -PlayResX $profile.Width `
                -PlayResY $profile.Height -TimeOffset $seg.Start
            [System.IO.File]::WriteAllText($assPath, $assDoc, (New-Object System.Text.UTF8Encoding($true)))
            $seg.AssFile = $assPath
        }
    }

    # The maps depend only on how many audio streams the source has, which cannot change
    # mid-export, so they are built once. The filter graph itself cannot be: each
    # transition now carries its own length.
    #
    # Every audio stream gets its own acrossfade. The DVR recordings carry two (system and
    # mic) and both have to survive a fade, or a crossfaded export would silently lose a
    # track that a plain export keeps.
    $audioStreamCount = $profile.AudioStreams
    # Audio maps only. The video map is chosen per transition, because a transition that
    # also burns captions ends on a different filter label than one that does not.
    $fadeAudioMaps = @()
    for ($a = 0; $a -lt $audioStreamCount; $a++) {
        $fadeAudioMaps += @("-map", "`"[a$a]`"")
    }
    $buildFadeFilter = {
        param([double]$Seconds, [string]$AssFile = "", [bool]$IncludeAudio = $true)
        $graph = "[0:v][1:v]xfade=transition=fade:duration=$Seconds`:offset=0[v]"
        # A transition already re-encodes, so a caption that overlaps one rides along on
        # the same pass: the ass filter is chained onto the crossfade's own output instead
        # of splitting the transition into further segments (which is impossible anyway --
        # the two halves come from two different places in the source).
        if ($AssFile) {
            $graph += ";[v]ass='$(ConvertTo-AssFilterPath -Path $AssFile)'[v2]"
        }
        # The rebuild path drops audio from every segment (an audio pass mixes the tracks
        # separately), and ffmpeg treats an unconnected filter_complex OUTPUT as a hard
        # error ("... has output N unconnected") -- confirmed live, not merely unused
        # computation. So the acrossfade branches are left out of the graph entirely
        # rather than built-and-unmapped.
        if ($IncludeAudio) {
            for ($a = 0; $a -lt $audioStreamCount; $a++) {
                $graph += ";[0:a:$a][1:a:$a]acrossfade=d=$Seconds[a$a]"
            }
        }
        return $graph
    }.GetNewClosure()

    $cleanup = {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }.GetNewClosure()

    # The runner has to invoke itself for the next step, and a plain
    # "$runStep = { ... & $runStep ... }.GetNewClosure()" CANNOT work: GetNewClosure
    # captures the variable's value at capture time, which is $null on that line, so the
    # recursive call would fail on the second step. Holding it in a hashtable works
    # because the hashtable reference is captured and its contents are read at call time.
    $chain = @{}
    $chain.RunStep = {
        param([int]$StepIndex)

        # Rebinds this closure's own module-scoped captures ($cleanup, $chain, $work,
        # ...) as plain locals of THIS call. -OnLine/-OnExit below need their own
        # .GetNewClosure() -- without it they can't see $StepIndex once the timer
        # invokes them later, from a completely different call stack, after RunStep
        # has already returned. But .GetNewClosure() called from inside an
        # already-closured scriptblock only captures the IMMEDIATE local frame, not
        # this closure's own module -- confirmed live: $cleanup and $chain came back
        # $null inside -OnExit, so "& $cleanup" crashed the whole app the moment a
        # step finished ("expression after '&' ... not valid"). Assigning each one to
        # itself here makes it a genuine local of this call, which the inner
        # .GetNewClosure() DOES pick up correctly.
        $cleanup = $cleanup
        $chain = $chain
        $work = $work
        $InputFile = $InputFile
        $outputFile = $outputFile
        $OnFinished = $OnFinished
        $progressBar = $progressBar
        $percentText = $percentText
        $etaText = $etaText
        $cancelButton = $cancelButton
        $startButton = $startButton
        $stepCount = $stepCount
        $profile = $profile
        $buildFadeFilter = $buildFadeFilter
        $fadeAudioMaps = $fadeAudioMaps
        $mode = $mode
        $segCount = $segCount
        $hasAudio = $hasAudio
        $appendsFinalSteps = $appendsFinalSteps
        $Tracks = $Tracks
        $Pieces = $Pieces
        $FadeLengths = $FadeLengths
        $ClipDurations = $ClipDurations
        $audioMixOutput = $audioMixOutput
        $tempDir = $tempDir

        if ($StepIndex -lt $work.Count) {
            $segment = $work[$StepIndex]
            if ($segment.Kind -eq "audiomix") {
                # Mixes every unmuted audio-source/audio-clip track down to one AAC file.
                # Runs for both "rebuild" (feeds the mux step below) and "audio-only"
                # (writes the final output directly, already given a .m4a extension).
                $plan = New-TrimAudioMixPlan -Tracks $Tracks -Pieces $Pieces -FadeLengths $FadeLengths -ClipDurations $ClipDurations
                $audioInputArgs = @()
                foreach ($p in @($plan.InputPaths)) { $audioInputArgs += @("-i", "`"$p`"") }
                $audioDest = if ($mode -eq "audio-only") { $outputFile } else { $audioMixOutput }
                $args = @("-hide_banner") + $audioInputArgs +
                        @("-filter_complex", "`"$($plan.FilterComplex)`"",
                          "-map", "`"$($plan.OutputLabel)`"",
                          "-c:a", "aac", "-b:a", "320k",
                          "`"$audioDest`"", "-y")
            } elseif ($segment.Kind -eq "mux") {
                # Concat demuxer as the video input directly -- no separate concat pass is
                # needed, since -f concat can sit right in front of the mux's own -map.
                $listPath = Join-Path $tempDir "list.txt"
                $videoPieces = @($tempFiles | Select-Object -First $segCount)
                $body = (($videoPieces | ForEach-Object { "file '$($_ -replace '\\', '/')'" }) -join "`n") + "`n"
                [System.IO.File]::WriteAllText($listPath, $body, (New-Object System.Text.UTF8Encoding($false)))
                $args = @("-hide_banner", "-f", "concat", "-safe", "0", "-i", "`"$listPath`"",
                          "-i", "`"$audioMixOutput`"",
                          "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
                          "`"$outputFile`"", "-y")
            } elseif ($segment.Pips) {
                # A segment carrying pips re-encodes with an overlay chain even if its Kind
                # is "cut" -- the pip has to be composited onto the frame, so a stream copy
                # is impossible regardless of what the caption/zoom split left it as.
                $extraInputArgs = @()
                $overlays = @()
                $pipInputIdx = 1
                foreach ($p in @($segment.Pips)) {
                    # -t bounds this input to the SEGMENT's own duration, matching the
                    # main input's "-ss ... -t ... -i" pair two lines below. Without it,
                    # overlay's main-ends-first case is not the mirror of its documented
                    # eof_action (that option only covers the OVERLAY/second input hitting
                    # EOF first): verified against real ffmpeg that an unbounded pip input
                    # longer than the segment makes the muxed output run to roughly the
                    # PIP CLIP's own remaining length instead of stopping at the main
                    # input's -t cutoff (e.g. a 6s segment with an unbounded 10s pip input
                    # produced a ~9.9s output). Bounding the pip input the same way the
                    # main input already is fixes it (verified: 5.99s for the same case).
                    $extraInputArgs += @("-ss", $p.SegmentClipStart, "-t", $segment.Duration, "-i", "`"$($p.Path)`"")
                    $overlays += ,@{ InputIndex = $pipInputIdx; Pip = $p.Pip }
                    $pipInputIdx++
                }
                # The segment's own crop/scale (zoom) and/or burned caption still has to
                # happen -- crop first, so a caption drawn after it stays the size the user
                # set instead of being magnified along with the footage, same order as the
                # non-pip burn branch below. The result feeds the overlay chain as [vbase]
                # instead of the chain's default [0:v] start.
                $baseVf = ""
                if ($segment.Zoom) {
                    $baseVf = New-ZoomCropFilter -Zoom $segment.Zoom -Duration $segment.Duration -Width $profile.Width -Height $profile.Height
                }
                if ($segment.AssFile) {
                    $assEsc = ConvertTo-AssFilterPath -Path $segment.AssFile
                    $baseVf = if ($baseVf) { "$baseVf,ass='$assEsc'" } else { "ass='$assEsc'" }
                }
                $overlayChain = New-PipOverlayChain -Overlays $overlays -Width $profile.Width -Height $profile.Height
                if ($baseVf) {
                    # New-PipOverlayChain always starts its chain from [0:v]; that first
                    # overlay's input label is retargeted to [vbase] so it reads the
                    # already-cropped/captioned frame instead of the raw source.
                    $overlayChain = $overlayChain.Replace("[0:v][ov0]overlay", "[vbase][ov0]overlay")
                    $graph = "[0:v]$baseVf" + "[vbase];" + $overlayChain
                } else {
                    $graph = $overlayChain
                }
                $args = @("-hide_banner",
                          "-ss", $segment.Start, "-t", $segment.Duration, "-i", "`"$InputFile`"") +
                        $extraInputArgs +
                        @("-filter_complex", "`"$graph`"",
                          "-map", "`"[vout]`"",
                          "-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                          "-pix_fmt", "yuv420p",
                          "-video_track_timescale", $profile.TimeScale,
                          "-an",
                          "`"$($tempFiles[$StepIndex])`"", "-y")
            } elseif ($segment.Kind -eq "transition") {
                # Two windows of the same file -- the outgoing tail and the incoming head
                # -- dissolved into each other. This is the only step that re-encodes.
                #
                # -video_track_timescale is what lets the result be concatenated with the
                # copied pieces by stream copy instead of re-encoding the whole export:
                # without it the encoder picks its own timescale and the join collapses
                # neighbouring frames onto duplicate timestamps.
                $fadeLength = $segment.Duration
                $assFile = if ($segment.AssFile) { $segment.AssFile } else { "" }
                # The ass filter renames the video output, so the map has to follow it.
                $videoLabel = if ($assFile) { "[v2]" } else { "[v]" }
                if ($mode -eq "trivial") {
                    $args = @("-hide_banner",
                              "-ss", $segment.Start, "-t", $fadeLength, "-i", "`"$InputFile`"",
                              "-ss", $segment.NextStart, "-t", $fadeLength, "-i", "`"$InputFile`"",
                              "-filter_complex", "`"$(& $buildFadeFilter $fadeLength $assFile)`"",
                              "-map", "`"$videoLabel`"") +
                            $fadeAudioMaps +
                            @("-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                              "-pix_fmt", "yuv420p",
                              "-video_track_timescale", $profile.TimeScale,
                              "-c:a", "aac", "-b:a", "256k",
                              "-ar", $profile.SampleRate, "-ac", $profile.Channels,
                              "`"$($tempFiles[$StepIndex])`"", "-y")
                } else {
                    # Rebuild path: video-only. $buildFadeFilter -IncludeAudio:$false leaves
                    # the acrossfade branches out of the graph entirely -- an unconnected
                    # filter_complex OUTPUT is a hard ffmpeg error ("has output N
                    # unconnected"), so -an alone (leaving them built-but-unmapped) does
                    # not work here the way it does for a plain -map/-c:a pair.
                    $args = @("-hide_banner",
                              "-ss", $segment.Start, "-t", $fadeLength, "-i", "`"$InputFile`"",
                              "-ss", $segment.NextStart, "-t", $fadeLength, "-i", "`"$InputFile`"",
                              "-filter_complex", "`"$(& $buildFadeFilter $fadeLength $assFile $false)`"",
                              "-map", "`"$videoLabel`"",
                              "-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                              "-pix_fmt", "yuv420p",
                              "-video_track_timescale", $profile.TimeScale,
                              "-an",
                              "`"$($tempFiles[$StepIndex])`"", "-y")
                }
            } elseif ($segment.Kind -eq "burn") {
                # A stretch of the timeline with a caption on screen. Re-encoded under the
                # same encoder/timescale contract as a transition, which is what keeps the
                # final concat a stream copy rather than a whole-file re-encode.
                #
                # -map 0:v -map 0:a rather than -map 0: the source's data/timecode streams
                # cannot survive a filtered re-encode, and mapping them would make this
                # segment's stream layout differ from the copied ones and break the concat.
                $assEsc = ConvertTo-AssFilterPath -Path $segment.AssFile
                # A caption segment that also sits under a zoom crops FIRST and burns
                # second: the ass filter draws onto the already-rescaled full-size frame,
                # so the text stays the size the user set it instead of being magnified
                # along with the footage.
                $vf = "ass='$assEsc'"
                if ($segment.Zoom) {
                    $vf = "$(New-ZoomCropFilter -Zoom $segment.Zoom -Duration $segment.Duration -Width $profile.Width -Height $profile.Height),$vf"
                }
                if ($mode -eq "trivial") {
                    $args = @("-hide_banner",
                              "-ss", $segment.Start, "-t", $segment.Duration, "-i", "`"$InputFile`"",
                              "-vf", "`"$vf`"",
                              "-map", "0:v", "-map", "0:a",
                              "-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                              "-pix_fmt", "yuv420p",
                              "-video_track_timescale", $profile.TimeScale,
                              "-c:a", "aac", "-b:a", "256k",
                              "-ar", $profile.SampleRate, "-ac", $profile.Channels,
                              "`"$($tempFiles[$StepIndex])`"", "-y")
                } else {
                    $args = @("-hide_banner",
                              "-ss", $segment.Start, "-t", $segment.Duration, "-i", "`"$InputFile`"",
                              "-vf", "`"$vf`"",
                              "-map", "0:v",
                              "-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                              "-pix_fmt", "yuv420p",
                              "-video_track_timescale", $profile.TimeScale,
                              "-an",
                              "`"$($tempFiles[$StepIndex])`"", "-y")
                }
            } elseif ($segment.Kind -eq "zoom") {
                # A stretch under a zoom span with no caption on it. Same encoder,
                # timescale and mapping contract as the burn branch -- the crop/scale chain
                # is the only difference -- so the final concat stays a stream copy.
                if ($mode -eq "trivial") {
                    $args = @("-hide_banner",
                              "-ss", $segment.Start, "-t", $segment.Duration, "-i", "`"$InputFile`"",
                              "-vf", "`"$(New-ZoomCropFilter -Zoom $segment.Zoom -Duration $segment.Duration -Width $profile.Width -Height $profile.Height)`"",
                              "-map", "0:v", "-map", "0:a",
                              "-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                              "-pix_fmt", "yuv420p",
                              "-video_track_timescale", $profile.TimeScale,
                              "-c:a", "aac", "-b:a", "256k",
                              "-ar", $profile.SampleRate, "-ac", $profile.Channels,
                              "`"$($tempFiles[$StepIndex])`"", "-y")
                } else {
                    $args = @("-hide_banner",
                              "-ss", $segment.Start, "-t", $segment.Duration, "-i", "`"$InputFile`"",
                              "-vf", "`"$(New-ZoomCropFilter -Zoom $segment.Zoom -Duration $segment.Duration -Width $profile.Width -Height $profile.Height)`"",
                              "-map", "0:v",
                              "-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                              "-pix_fmt", "yuv420p",
                              "-video_track_timescale", $profile.TimeScale,
                              "-an",
                              "`"$($tempFiles[$StepIndex])`"", "-y")
                }
            } else {
                if ($mode -eq "trivial") {
                    $args = @("-hide_banner", "-ss", $segment.Start, "-i", "`"$InputFile`"",
                              "-t", $segment.Duration, "-map", "0", "-c", "copy",
                              "-avoid_negative_ts", "make_zero", "`"$($tempFiles[$StepIndex])`"", "-y")
                } else {
                    # Plain stream-copied cut, video-rebuild mode: still a stream copy (no
                    # re-encode needed), just with the audio stream dropped.
                    $args = @("-hide_banner", "-ss", $segment.Start, "-i", "`"$InputFile`"",
                              "-t", $segment.Duration, "-map", "0:v", "-c", "copy", "-an",
                              "-avoid_negative_ts", "make_zero", "`"$($tempFiles[$StepIndex])`"", "-y")
                }
            }
        } else {
            $listPath = Join-Path $tempDir "list.txt"
            # No BOM: Set-Content -Encoding UTF8 writes one on PS 5.1 and ffmpeg then
            # fails with "Line 1: unknown keyword 'file'". Forward slashes regardless
            # of the local separator.
            $body = (($tempFiles | ForEach-Object { "file '$($_ -replace '\\', '/')'" }) -join "`n") + "`n"
            [System.IO.File]::WriteAllText($listPath, $body, (New-Object System.Text.UTF8Encoding($false)))
            $args = @("-hide_banner", "-f", "concat", "-safe", "0", "-i", "`"$listPath`"",
                      "-map", "0", "-c", "copy", "`"$outputFile`"", "-y")
        }

        $process = Start-TrackedProcess -Context $Context -FileName $ffmpegPath `
            -Arguments ($args -join " ") -ReadStream Error `
            -OnLine {
                param($line)
                # Each step contributes an equal slice of the bar. Steps are short and
                # roughly equal, so a per-step fraction is not worth parsing out.
                $base = ($StepIndex / $stepCount) * 100
                $progressBar.Value = [math]::Min(99, $base + (100 / $stepCount) * 0.5)
                $percentText.Text = "{0:N1}%" -f $progressBar.Value
                # The step past the last segment is the concat that assembles them into
                # the final file. Calling that "step 4 of 4" tells the user nothing;
                # naming it is the difference between "still working" and "nearly there".
                $etaText.Text = if ($StepIndex -ge $work.Count) {
                    "finalizing..."
                } elseif ($work[$StepIndex].Kind -eq "audiomix") {
                    if ($mode -eq "audio-only") { "writing audio only" } else { "mixing audio" }
                } elseif ($work[$StepIndex].Kind -eq "mux") {
                    "finalizing..."
                } elseif ($work[$StepIndex].Pips) {
                    "overlaying clip video ($($StepIndex + 1) of $segCount)"
                } elseif ($work[$StepIndex].Kind -eq "transition") {
                    # Named separately because it is the slow step: the only one that
                    # re-encodes, so a stall here is expected rather than a symptom.
                    "blending cut ($($StepIndex + 1) of $($work.Count))"
                } elseif ($work[$StepIndex].Kind -eq "burn") {
                    # Also a re-encoding step, and named for the same reason: the user
                    # should be able to tell a slow caption burn from a stalled export.
                    "burning captions ($($StepIndex + 1) of $($work.Count))"
                } elseif ($work[$StepIndex].Kind -eq "zoom") {
                    # Third re-encoding step, named for the same reason as the other two.
                    "zooming ($($StepIndex + 1) of $($work.Count))"
                } else {
                    "cutting piece $($StepIndex + 1) of $($work.Count)"
                }
            }.GetNewClosure() `
            -OnExit {
                param($exitCode)
                if ($exitCode -ne 0) {
                    & $cleanup
                    $cancelButton.IsEnabled = $false
                    if ($startButton) { $startButton.IsEnabled = $true }
                    return
                }
                # Trivial mode -- and a rebuild stack with no unmuted audio, which never
                # got audiomix/mux appended to $work -- has one implicit step past the
                # segment list (the concat), so the last real StepIndex is $work.Count and
                # this condition -- read literally as "$StepIndex -lt $work.Count" -- is
                # unchanged from before. Every OTHER non-trivial mode appended audiomix
                # (and mux) INTO $work itself, so its own last entry (mux for rebuild,
                # audiomix for audio-only) is already the final step; there is no implicit
                # step after it to recurse into.
                $lastStepIndex = if ($appendsFinalSteps) { $work.Count - 1 } else { $work.Count }
                if ($StepIndex -lt $lastStepIndex) {
                    & $chain.RunStep ($StepIndex + 1)
                    return
                }
                & $cleanup
                $progressBar.Value = 100
                $percentText.Text = "100.0%"
                # "00:00:00" is what a job that has not started shows too. The panel
                # message names the file; this says the run itself is over, next to the
                # bar the user is actually watching.
                $etaText.Text = "done"
                $cancelButton.IsEnabled = $false
                if ($startButton) { $startButton.IsEnabled = $true }
                if ($OnFinished) { & $OnFinished $InputFile $outputFile }
            }.GetNewClosure()

        Set-CancelButtonTarget -Button $cancelButton -Process $process
        return $process
    }.GetNewClosure()

    if ($startButton) { $startButton.IsEnabled = $false }
    $cancelButton.IsEnabled = $true
    return (& $chain.RunStep 0)
}

# A low-resolution render of one crossfade, for the preview to play when the playhead
# reaches that cut. The editor's MediaElement decodes one position at a time and a
# crossfade is two positions blended, so there is no way to show it live from the source;
# rendering the transition once and playing the result is what makes the preview show
# what the export will actually contain.
#
# Deliberately not a scaled-down copy of the export's transition command:
#   - 360p and -preset ultrafast, because this is watched in a box a few hundred pixels
#     wide and has to be ready in about a second, not match the export's quality.
#   - -an, no audio. The main preview element keeps playing the source's audio underneath
#     the overlay, so an audio track here would play on top of it, doubled.
#   - No -video_track_timescale and no encoder matching. Nothing concatenates this file;
#     it is only ever played on its own.
function Export-TrimFadeProxy {
    param(
        [Parameter(Mandatory = $true)][string]$InputFile,
        # Where the outgoing piece ends and the incoming piece starts, in source seconds.
        [Parameter(Mandatory = $true)][double]$OutgoingEnd,
        [Parameter(Mandatory = $true)][double]$IncomingStart,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [double]$FadeSeconds = 0.5,
        [int]$Height = 360
    )
    $ffmpeg = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    $filter = "[0:v]scale=-2:$Height[a];[1:v]scale=-2:$Height[b];" +
              "[a][b]xfade=transition=fade:duration=$FadeSeconds`:offset=0[v]"
    & $ffmpeg -y -hide_banner -loglevel error `
        -ss ($OutgoingEnd - $FadeSeconds) -t $FadeSeconds -i $InputFile `
        -ss $IncomingStart -t $FadeSeconds -i $InputFile `
        -filter_complex $filter -map "[v]" -an `
        -c:v libx264 -preset ultrafast -crf 26 -pix_fmt yuv420p $OutputFile 2>&1 | Out-Null
}

# One small JPEG frame for the timeline filmstrip. -ss before -i seeks by keyframe index
# without decoding everything before it, so this stays fast even far into a long
# recording -- the frame landed on does not need to be the exact requested second, it
# only has to look like "roughly here" on the filmstrip.
function Export-TrimThumbnail {
    param(
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][double]$Seconds,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [int]$Height = 120
    )
    $ffmpeg = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    & $ffmpeg -y -ss $Seconds -i $InputFile -frames:v 1 -vf "scale=-2:$Height" -q:v 4 $OutputFile 2>&1 | Out-Null
}

# One waveform strip PNG for a source-time window, drawn by ffmpeg itself.
# showwavespic is a single decode pass over the audio only, so this is cheap
# even on the 3GB recordings.
#
# sqrt + draw=full + filter=peak, not the defaults: game audio is quiet on average
# with sharp peaks, and a linear scale renders it as a hairline scribble. Peak-held
# square-root scaling is what makes the strip read like an editor's waveform.
function Export-TrimWaveform {
    param(
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][double]$StartSeconds,
        [Parameter(Mandatory = $true)][double]$DurationSeconds,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [int]$Width = 1600,
        [int]$Height = 96
    )
    $ffmpeg = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    & $ffmpeg -y -hide_banner -loglevel error `
        -ss $StartSeconds -t $DurationSeconds -i $InputFile `
        -filter_complex "[0:a:0]aformat=channel_layouts=mono,showwavespic=s=${Width}x${Height}:colors=#3E9B84:scale=sqrt:draw=full:filter=peak" `
        -frames:v 1 $OutputFile 2>&1 | Out-Null
}

function Get-TrimAudioStreams {
    param([Parameter(Mandatory = $true)][string]$InputFile)
    $ffprobe = Get-ToolPath -Name ffprobe -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    $lines = @(& $ffprobe -v error -select_streams a -show_entries "stream=index:stream_tags=title" -of "csv=p=0" $InputFile 2>$null)
    # ConvertFrom-AudioStreamProbe already does `return ,@($result)` -- wrapping its result in
    # another ,@() here nests it one level deeper (trap #2 in the closure/array memory file):
    # a real file with 2+ audio streams came back as a 1-element array whose single element was
    # itself the 2-element array, so `foreach ($s in $streams)` bound $s to the whole array and
    # `[int]$s.StreamIdx` threw "Cannot convert System.Object[] to Int32" the moment a genuine
    # multi-stream DVR clip was loaded -- crashing the app via ShowDialog's pumped dispatcher loop.
    return ConvertFrom-AudioStreamProbe -Lines $lines
}

function Split-TrimSegmentsForPips {
    param([object[]]$Segments = @(), [object[]]$PipSpans = @())
    $result = @()
    $cursor = 0.0
    foreach ($seg in @($Segments)) {
        $segT0 = $cursor
        $segT1 = $cursor + [double]$seg.Duration
        $cursor = $segT1
        $overlapping = @(@($PipSpans) | Where-Object { [double]$_.Start -lt $segT1 -and [double]$_.End -gt $segT0 })
        if ($overlapping.Count -eq 0) { $result += ,$seg; continue }
        if ($seg.Kind -eq "transition") { throw "pip over transition reached the splitter" }

        $cutsSet = New-Object System.Collections.Generic.SortedSet[double]
        foreach ($sp in $overlapping) {
            if ([double]$sp.Start -gt $segT0 -and [double]$sp.Start -lt $segT1) { [void]$cutsSet.Add([double]$sp.Start) }
            if ([double]$sp.End -gt $segT0 -and [double]$sp.End -lt $segT1) { [void]$cutsSet.Add([double]$sp.End) }
        }
        $points = @($segT0) + @($cutsSet) + @($segT1)
        for ($i = 0; $i -lt $points.Count - 1; $i++) {
            $t0 = $points[$i]; $t1 = $points[$i + 1]
            if ($t1 - $t0 -le 0.0005) { continue }
            $part = @{}
            foreach ($kv in $seg.GetEnumerator()) { $part[$kv.Key] = $kv.Value }
            $part.Start = [double]$seg.Start + ($t0 - $segT0)
            $part.Duration = ($t1 - $t0)
            $mid = ($t0 + $t1) / 2.0
            $pips = @()
            foreach ($sp in $overlapping) {
                if ($mid -gt [double]$sp.Start -and $mid -lt [double]$sp.End) {
                    $ov = $sp.Overlay
                    $pips += ,@{
                        TrackId = $ov.TrackId; Path = $ov.Path; Pip = $ov.Pip
                        SegmentClipStart = [double]$ov.InStart + ($t0 - [double]$sp.Start)
                    }
                }
            }
            if ($pips.Count -gt 0) { $part.Pips = @($pips) }
            $result += ,$part
        }
    }
    return ,@($result)
}

# Decides which of the three export pipelines Export-CutListAsync takes, as a pure
# function so the branch is testable without running ffmpeg.
#   "trivial"    -- no tracks at all (legacy caller), or a stack with exactly one
#                   video-main and no gain/mute/clip/pip touching it: the pre-existing
#                   single-pass-per-segment + concat pipeline runs unchanged.
#   "rebuild"    -- a video-main is present but the stack (or the pip spans) is not
#                   trivial: video re-encodes with -an, then an audio pass mixes the
#                   tracks, then the two are muxed together.
#   "audio-only" -- no video-main in the stack at all: only the audio pass runs, and it
#                   writes the final output directly.
function Get-TrimExportMode {
    param(
        [object[]]$Tracks = @(), [object[]]$PipSpans = @(), [int]$SourceAudioStreamCount = -1,
        [object[]]$Lanes = @(), [string]$MainPath = ""
    )
    if (@($Lanes).Count -gt 0) {
        if (-not (Test-TrimLaneStackHasVideo -Lanes $Lanes)) { return "audio-only" }
        if (Test-TrimLaneStackTrivial -Lanes $Lanes -MainPath $MainPath -SourceAudioStreamCount $SourceAudioStreamCount) { return "trivial" }
        return "rebuild"
    }
    # ---- legacy v2 arm below: UNCHANGED, byte for byte ----
    if (@($Tracks).Count -eq 0) { return "trivial" }
    $mains = @(@($Tracks) | Where-Object { $_.Kind -eq "video-main" })
    if ($mains.Count -eq 0) { return "audio-only" }
    if ((Test-TrackStackTrivial -Tracks $Tracks -SourceAudioStreamCount $SourceAudioStreamCount) -and @($PipSpans).Count -eq 0) { return "trivial" }
    return "rebuild"
}

# True when the stack has at least one audio-source or audio-clip track that is not
# muted -- i.e. whether the "rebuild" pipeline's audio pass has anything to mix. A stack
# is never "trivial" once ANY track is muted (Test-TrackStackTrivial refuses that), so a
# fully-muted stack still lands in "rebuild"; without this check Export-CutListAsync would
# run an audio pass that mixes zero sources over New-TrimAudioMixPlan's silence base and
# mux in a silent AAC stream -- a different artifact than a true video-only, no-audio-
# stream-at-all output.
function Test-TrackStackHasAudio {
    param([object[]]$Tracks = @())
    foreach ($t in @($Tracks)) {
        if (($t.Kind -eq "audio-source" -or $t.Kind -eq "audio-clip") -and -not $t.Muted) { return $true }
    }
    return $false
}

Export-ModuleMember -Function Export-CutListAsync, ConvertFrom-KeyframeOutput, Get-KeyframeTimes, `
    Export-TrimThumbnail, Get-TrimSourceProfile, Get-TrimSegmentPlan, Export-TrimFadeProxy, `
    ConvertTo-AssFilterPath, Export-TrimWaveform, Get-TrimAudioStreams, Split-TrimSegmentsForPips, `
    Get-TrimExportMode, Test-TrackStackHasAudio, Get-TrimClipDuration