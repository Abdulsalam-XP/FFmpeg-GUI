Import-Module "$PSScriptRoot/UI.psm1"
Import-Module "$PSScriptRoot/ToolPaths.psm1"

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

    $videoRaw = & $ffprobe -v error -select_streams v:0 `
        -show_entries stream=codec_name,time_base -of csv=p=0 $InputFile 2>&1
    $videoParts = ("$videoRaw").Trim() -split ','
    $codec = if ($videoParts.Count -ge 1) { $videoParts[0].Trim() } else { "" }

    # time_base arrives as "1/90000"; the denominator is the timescale.
    $timeScale = 90000
    if ($videoParts.Count -ge 2 -and $videoParts[1] -match '^\s*\d+\s*/\s*(\d+)\s*$') {
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
        AudioStreams = $audioRaw.Count
        SampleRate   = $sampleRate
        Channels     = $channels
    }
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

    # $work is the segment plan, not the piece list: with no fades the two are the same
    # thing (one copy step per piece), and with fades it also carries the transition
    # steps, so the runner below stays a flat "one ffmpeg per entry, then concat".
    # NOT @(Get-TrimSegmentPlan ...): the function returns ",@($segments)", which reaches
    # the caller as one object that happens to be an array. Wrapping that in @() makes a
    # one-element array holding the segment array, so $work.Count is 1 and the export
    # runs a single step against a bogus segment -- with or without fades. Assigning the
    # call directly is what keeps it a real list.
    $work = Get-TrimSegmentPlan -Pieces $Pieces -FadeLengths $FadeLengths
    $stepCount = $work.Count + 1
    $profile = Get-TrimSourceProfile -InputFile $InputFile
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-cut-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $tempFiles = @()
    for ($i = 0; $i -lt $work.Count; $i++) {
        $tempFiles += (Join-Path $tempDir ("piece{0:D3}.mp4" -f $i))
    }

    # The maps depend only on how many audio streams the source has, which cannot change
    # mid-export, so they are built once. The filter graph itself cannot be: each
    # transition now carries its own length.
    #
    # Every audio stream gets its own acrossfade. The DVR recordings carry two (system and
    # mic) and both have to survive a fade, or a crossfaded export would silently lose a
    # track that a plain export keeps.
    $audioStreamCount = $profile.AudioStreams
    $fadeMaps = @("-map", "`"[v]`"")
    for ($a = 0; $a -lt $audioStreamCount; $a++) {
        $fadeMaps += @("-map", "`"[a$a]`"")
    }
    $buildFadeFilter = {
        param([double]$Seconds)
        $graph = "[0:v][1:v]xfade=transition=fade:duration=$Seconds`:offset=0[v]"
        for ($a = 0; $a -lt $audioStreamCount; $a++) {
            $graph += ";[0:a:$a][1:a:$a]acrossfade=d=$Seconds[a$a]"
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
        $fadeMaps = $fadeMaps

        if ($StepIndex -lt $work.Count) {
            $segment = $work[$StepIndex]
            if ($segment.Kind -eq "transition") {
                # Two windows of the same file -- the outgoing tail and the incoming head
                # -- dissolved into each other. This is the only step that re-encodes.
                #
                # -video_track_timescale is what lets the result be concatenated with the
                # copied pieces by stream copy instead of re-encoding the whole export:
                # without it the encoder picks its own timescale and the join collapses
                # neighbouring frames onto duplicate timestamps.
                $fadeLength = $segment.Duration
                $args = @("-hide_banner",
                          "-ss", $segment.Start, "-t", $fadeLength, "-i", "`"$InputFile`"",
                          "-ss", $segment.NextStart, "-t", $fadeLength, "-i", "`"$InputFile`"",
                          "-filter_complex", "`"$(& $buildFadeFilter $fadeLength)`"") +
                        $fadeMaps +
                        @("-c:v", $profile.VideoEncoder, "-preset", "veryfast", "-crf", "18",
                          "-pix_fmt", "yuv420p",
                          "-video_track_timescale", $profile.TimeScale,
                          "-c:a", "aac", "-b:a", "256k",
                          "-ar", $profile.SampleRate, "-ac", $profile.Channels,
                          "`"$($tempFiles[$StepIndex])`"", "-y")
            } else {
                $args = @("-hide_banner", "-ss", $segment.Start, "-i", "`"$InputFile`"",
                          "-t", $segment.Duration, "-map", "0", "-c", "copy",
                          "-avoid_negative_ts", "make_zero", "`"$($tempFiles[$StepIndex])`"", "-y")
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
                } elseif ($work[$StepIndex].Kind -eq "transition") {
                    # Named separately because it is the slow step: the only one that
                    # re-encodes, so a stall here is expected rather than a symptom.
                    "blending cut ($($StepIndex + 1) of $($work.Count))"
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
                if ($StepIndex -lt $work.Count) {
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

Export-ModuleMember -Function Export-CutListAsync, ConvertFrom-KeyframeOutput, Get-KeyframeTimes, `
    Export-TrimThumbnail, Get-TrimSourceProfile, Get-TrimSegmentPlan, Export-TrimFadeProxy