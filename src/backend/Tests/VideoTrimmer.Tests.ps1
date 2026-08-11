$modulePath = Join-Path $PSScriptRoot "..\VideoTrimmer.psm1"
Import-Module $modulePath -Force
Import-Module (Join-Path $PSScriptRoot "..\Tracks.psm1") -Force

# Lines are shaped "<pts_time>,<flags>", matching ffprobe's
# `-show_entries packet=pts_time,flags -of csv=p=0` output, e.g. "0.249878,K__".
# This is the packet index, so every packet appears, not just keyframes -- a line
# is only kept when its flags field contains 'K'.
Describe "ConvertFrom-KeyframeOutput" {
    It "reads csv times, keeping only lines flagged K" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "0.250000,K__", "0.500000,K__")
        @($r).Count | Should Be 3
        $r[1] | Should Be 0.25
    }

    It "drops a line whose flags do not contain K" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.500000,___")
        @($r).Count | Should Be 0
    }

    It "keeps only the keyframes out of a mixed batch of packets" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "0.125000,___", "0.250000,K__", "0.375000,___")
        @($r).Count | Should Be 2
        $r[0] | Should Be 0.0
        $r[1] | Should Be 0.25
    }

    It "ignores blank lines and stderr noise" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "", "  ", "Some ffprobe warning", "0.250000,K__")
        @($r).Count | Should Be 2
    }

    It "sorts ascending regardless of input order" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.500000,K__", "0.000000,K__", "0.250000,K__")
        $r[0] | Should Be 0.0
        $r[2] | Should Be 0.5
    }

    It "returns an empty array, not null, for no usable input" {
        $r = ConvertFrom-KeyframeOutput -Lines @("", "N/A,K__", "junk", "0.5")
        @($r).Count | Should Be 0
        ($null -eq $r) | Should Be $false
    }

    It "ignores an N/A timestamp among real ones" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "N/A,K__", "0.250000,K__")
        @($r).Count | Should Be 2
    }
}

# The segment plan is what turns "these pieces, with a fade on that boundary" into the
# flat list of ffmpeg steps the export runs. A crossfade is built from footage the two
# neighbouring pieces give up, so the arithmetic that shortens them is the part worth
# pinning down: get it wrong and the export silently repeats or drops half a second.
Describe "Get-TrimSegmentPlan" {
    $pieces = @(
        [PSCustomObject]@{ Start = 0.0;  End = 10.0 },
        [PSCustomObject]@{ Start = 50.0; End = 60.0 },
        [PSCustomObject]@{ Start = 90.0; End = 100.0 }
    )

    It "is one copy step per piece when nothing is faded" {
        $r = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0, 0)
        @($r).Count | Should Be 3
        @($r | Where-Object { $_.Kind -eq "transition" }).Count | Should Be 0
        $r[0].Start | Should Be 0.0
        $r[0].Duration | Should Be 10.0
    }

    It "splices a transition between the two pieces sharing a faded boundary" {
        $r = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0.5, 0)
        @($r).Count | Should Be 4
        $r[1].Kind | Should Be "transition"
        # Built from the outgoing piece's real tail and the incoming piece's real head.
        $r[1].Start | Should Be 9.5
        $r[1].NextStart | Should Be 50.0
        $r[1].Duration | Should Be 0.5
    }

    It "shortens both donor pieces by the fade length" {
        $r = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0.5, 0)
        $r[0].Duration | Should Be 9.5
        $r[2].Start | Should Be 50.5
        $r[2].Duration | Should Be 9.5
    }

    It "takes a fade off both ends of a piece caught between two faded cuts" {
        $r = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0.5, 0.5)
        $middle = $r[2]
        $middle.Kind | Should Be "cut"
        $middle.Start | Should Be 50.5
        $middle.Duration | Should Be 9.0
    }

    It "loses exactly one fade length of total footage per faded cut" {
        $plain = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0, 0)
        $faded = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0.5, 0.5)
        # Summed by hand: the segments are hashtables, and Measure-Object -Property reads
        # object properties, not hashtable keys -- it sees nothing to sum and returns 0.
        $plainTotal = 0.0; foreach ($s in $plain) { $plainTotal += $s.Duration }
        $fadedTotal = 0.0; foreach ($s in $faded) { $fadedTotal += $s.Duration }
        [math]::Round($plainTotal - $fadedTotal, 6) | Should Be 1.0
    }

    It "honours a longer fade length" {
        $r = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(1.0, 0)
        $r[0].Duration | Should Be 9.0
        $r[1].Start | Should Be 9.0
        $r[2].Start | Should Be 51.0
    }

    It "treats an omitted fade list as no fades at all" {
        $r = Get-TrimSegmentPlan -Pieces $pieces
        @($r).Count | Should Be 3
        $r[0].Duration | Should Be 10.0
    }

    It "returns a single copy step for a single piece, with no boundary to fade" {
        $r = Get-TrimSegmentPlan -Pieces @([PSCustomObject]@{ Start = 0.0; End = 5.0 }) -FadeLengths @()
        @($r).Count | Should Be 1
        $r[0].Kind | Should Be "cut"
    }
}

# Get-TrimSegmentPlan returns ",@($segments)" so a single-segment plan stays a list.
# The cost of that idiom is that the caller must NOT wrap the call in @(): the function
# emits one object which happens to be an array, and @() around it builds a one-element
# array holding the array. Export-CutListAsync shipped that bug for exactly one session
# -- $work.Count came back 1 for a three-piece cut list, so the export ran a single step
# against a segment that was really the whole plan.
Describe "Get-TrimSegmentPlan return shape" {
    $pieces = @(
        [PSCustomObject]@{ Start = 0.0;  End = 10.0 },
        [PSCustomObject]@{ Start = 50.0; End = 60.0 }
    )

    It "assigns directly to a list of segments, not a list holding a list" {
        $plan = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0.5)
        $plan.Count | Should Be 3
        $plan[0] -is [hashtable] | Should Be $true
    }

    It "still counts correctly for a single-segment plan" {
        $plan = Get-TrimSegmentPlan -Pieces @([PSCustomObject]@{ Start = 0.0; End = 5.0 })
        $plan.Count | Should Be 1
        $plan[0] -is [hashtable] | Should Be $true
    }
}


# The whole point of a per-boundary list: two cuts in the same export can dissolve at
# different speeds. This shipped as one global length first, which made a slow dissolve
# into one scene and a snappy one into the next impossible to express.
Describe "Get-TrimSegmentPlan with per-cut fade lengths" {
    $pieces = @(
        [PSCustomObject]@{ Start = 0.0;   End = 30.0 },
        [PSCustomObject]@{ Start = 60.0;  End = 90.0 },
        [PSCustomObject]@{ Start = 120.0; End = 150.0 }
    )

    It "gives each transition its own duration" {
        $plan = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(1.0, 0.25)
        $transitions = @($plan | Where-Object { $_.Kind -eq "transition" })
        $transitions.Count | Should Be 2
        $transitions[0].Duration | Should Be 1.0
        $transitions[1].Duration | Should Be 0.25
    }

    It "takes the matching amount off each side of the piece between them" {
        $plan = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(1.0, 0.25)
        $middle = @($plan | Where-Object { $_.Kind -eq "cut" })[1]
        # 1.0s donated to the fade before it, 0.25s to the fade after it.
        $middle.Start | Should Be 61.0
        $middle.Duration | Should Be 28.75
    }

    It "builds each transition from its own boundary" {
        $plan = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(1.0, 0.25)
        $transitions = @($plan | Where-Object { $_.Kind -eq "transition" })
        $transitions[0].Start | Should Be 29.0      # 30.0 - 1.0
        $transitions[0].NextStart | Should Be 60.0
        $transitions[1].Start | Should Be 89.75     # 90.0 - 0.25
        $transitions[1].NextStart | Should Be 120.0
    }

    It "shortens the export by the SUM of the fade lengths, not a multiple of one" {
        $plain = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0, 0)
        $mixed = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(1.0, 0.25)
        $plainTotal = 0.0; foreach ($s in $plain) { $plainTotal += $s.Duration }
        $mixedTotal = 0.0; foreach ($s in $mixed) { $mixedTotal += $s.Duration }
        [math]::Round($plainTotal - $mixedTotal, 6) | Should Be 1.25
    }

    It "leaves a zero-length boundary as a plain cut between two faded ones" {
        $plan = Get-TrimSegmentPlan -Pieces $pieces -FadeLengths @(0, 0.5)
        @($plan | Where-Object { $_.Kind -eq "transition" }).Count | Should Be 1
        @($plan | Where-Object { $_.Kind -eq "cut" })[0].Duration | Should Be 30.0
    }
}

# The path an `ass=` filter is given goes through two parsers before libass sees it:
# the filter-graph parser (backslash escapes, so a Windows path must be forward-slashed)
# and the filter's own option parser (colon separates options, so the drive colon has to
# be escaped). Getting either wrong makes ffmpeg report a missing filter or a missing
# file, both of which look nothing like a path-escaping problem.
Describe "ConvertTo-AssFilterPath" {
    It "forward-slashes a Windows path and escapes the drive colon" {
        ConvertTo-AssFilterPath -Path "C:\Temp\ffgui\seg000.ass" |
            Should Be "C\:/Temp/ffgui/seg000.ass"
    }

    It "leaves an already-forward-slashed path alone except for the colon" {
        ConvertTo-AssFilterPath -Path "D:/x/y.ass" | Should Be "D\:/x/y.ass"
    }

    It "escapes every colon, not only the first" {
        ConvertTo-AssFilterPath -Path "C:\a:b\c.ass" | Should Be "C\:/a\:b/c.ass"
    }

    It "escapes a single quote so it cannot close the filter's quoted argument" {
        # An apostrophe in a Windows username reaches %TEMP% paths.
        ConvertTo-AssFilterPath -Path "C:\Users\O'Brien\seg.ass" |
            Should Be "C\:/Users/O'\''Brien/seg.ass"
    }
}

Describe "Split-TrimSegmentsForPips" {
    It "splits a cut at pip span edges and tags the inside part" {
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 30.0 })
        $spans = @(@{ Start = 10.0; End = 15.0; Overlay = @{ TrackId = "t1"; Path = "c.mp4"; InStart = 2.0; Pip = @{X=0.5;Y=0.5;W=0.3;H=0.3} } })
        $r = Split-TrimSegmentsForPips -Segments $segs -PipSpans $spans
        $r.Count | Should Be 3
        $r[0].Duration | Should Be 10.0
        $r[1].Duration | Should Be 5.0
        @($r[1].Pips).Count | Should Be 1
        $r[1].Pips[0].SegmentClipStart | Should Be 2.0
        $r[2].ContainsKey("Pips") | Should Be $false
    }
    It "advances the clip-in for a part starting mid-span" {
        # span 10..20, but a segment boundary at 14 puts part 2 at span-time 4
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 14.0 }, @{ Kind = "cut"; Start = 14.0; Duration = 16.0 })
        $spans = @(@{ Start = 10.0; End = 20.0; Overlay = @{ TrackId = "t1"; Path = "c.mp4"; InStart = 0.0; Pip = @{X=0.5;Y=0.5;W=0.3;H=0.3} } })
        $r = Split-TrimSegmentsForPips -Segments $segs -PipSpans $spans
        $inside = @($r | Where-Object { $_.ContainsKey("Pips") })
        $inside.Count | Should Be 2
        $inside[1].Pips[0].SegmentClipStart | Should Be 4.0
    }
    It "throws when a span overlaps a transition" {
        $segs = @(@{ Kind = "transition"; Start = 9.5; NextStart = 20.0; Duration = 0.5 })
        $spans = @(@{ Start = 0.2; End = 0.4; Overlay = @{ TrackId="t"; Path="c"; InStart=0.0; Pip=@{X=0.5;Y=0.5;W=0.3;H=0.3} } })
        { Split-TrimSegmentsForPips -Segments $segs -PipSpans $spans } | Should Throw
    }
    It "conserves total duration and passes untouched segments through" {
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 30.0 })
        $spans = @(@{ Start = 5.0; End = 9.0; Overlay = @{ TrackId="t"; Path="c"; InStart=0.0; Pip=@{X=0.5;Y=0.5;W=0.3;H=0.3} } })
        $r = Split-TrimSegmentsForPips -Segments $segs -PipSpans $spans
        $total = 0.0; foreach ($s in $r) { $total += $s.Duration }
        [math]::Round($total, 6) | Should Be 30.0
    }
}

Describe "Get-TrimExportMode" {
    $main = New-TrimTrack -Kind "video-main" -Path "a.mp4"
    $src  = New-TrimTrack -Kind "audio-source" -Path "a.mp4" -StreamIdx 1
    It "is trivial with no tracks at all (legacy callers)" {
        Get-TrimExportMode -Tracks @() -PipSpans @() | Should Be "trivial"
    }
    It "is trivial for an untouched stack" {
        Get-TrimExportMode -Tracks @($main, $src) -PipSpans @() | Should Be "trivial"
    }
    It "rebuilds on any gain, mute, clip or pip" {
        $g = New-TrimTrack -Kind "audio-source" -Path "a.mp4" -StreamIdx 1 -GainDb 2.0
        Get-TrimExportMode -Tracks @($main, $g) -PipSpans @() | Should Be "rebuild"
        Get-TrimExportMode -Tracks @($main, $src) -PipSpans @(@{Start=1.0;End=2.0}) | Should Be "rebuild"
    }
    It "is audio-only without a video-main" {
        Get-TrimExportMode -Tracks @($src) -PipSpans @() | Should Be "audio-only"
    }
}

# A muted-everything stack is "rebuild" (Test-TrackStackTrivial refuses any Muted track),
# but Export-CutListAsync must NOT run an audio pass in that case -- there is nothing
# unmuted to mix, and mixing zero sources over New-TrimAudioMixPlan's silence base would
# mux in a silent AAC stream instead of producing a true video-only output. This flag is
# what Export-CutListAsync checks (alongside $mode) to skip the audiomix/mux append.
Describe "Test-TrackStackHasAudio" {
    $main = New-TrimTrack -Kind "video-main" -Path "a.mp4"
    It "is true with at least one unmuted audio-source" {
        $src = New-TrimTrack -Kind "audio-source" -Path "a.mp4" -StreamIdx 1
        Test-TrackStackHasAudio -Tracks @($main, $src) | Should Be $true
    }
    It "is true with at least one unmuted audio-clip" {
        $clip = New-TrimTrack -Kind "audio-clip" -Path "b.mp3"
        Test-TrackStackHasAudio -Tracks @($main, $clip) | Should Be $true
    }
    It "is false when every audio track is muted" {
        $src = New-TrimTrack -Kind "audio-source" -Path "a.mp4" -StreamIdx 1 -Muted $true
        $clip = New-TrimTrack -Kind "audio-clip" -Path "b.mp3" -Muted $true
        Test-TrackStackHasAudio -Tracks @($main, $src, $clip) | Should Be $false
    }
    It "is false with no audio tracks at all" {
        Test-TrackStackHasAudio -Tracks @($main) | Should Be $false
    }
    It "is false for an empty stack" {
        Test-TrackStackHasAudio -Tracks @() | Should Be $false
    }
}
