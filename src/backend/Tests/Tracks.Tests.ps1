$modulePath = Join-Path $PSScriptRoot "..\Tracks.psm1"
Import-Module $modulePath -Force

Describe "New-TrimTrack" {
    It "creates a video-main track with defaults and an id" {
        $t = New-TrimTrack -Kind "video-main" -Path "C:\v\a.mp4"
        $t.Kind | Should Be "video-main"
        $t.GainDb | Should Be 0.0
        $t.Muted | Should Be $false
        $t.Offset | Should Be 0.0
        $t.Id | Should Not Be $null
    }
    It "clamps GainDb to -30..30" {
        (New-TrimTrack -Kind "audio-clip" -Path "x" -GainDb 99).GainDb | Should Be 30.0
        (New-TrimTrack -Kind "audio-clip" -Path "x" -GainDb -99).GainDb | Should Be (-30.0)
    }
    It "throws on an unknown kind" {
        { New-TrimTrack -Kind "banana" -Path "x" } | Should Throw
    }
    It "zeroes Offset/InStart/InEnd on source kinds even when passed" {
        $t = New-TrimTrack -Kind "audio-source" -Path "x" -StreamIdx 1 -Offset 5 -InStart 2
        $t.Offset | Should Be 0.0
        $t.InStart | Should Be 0.0
    }
}

Describe "ConvertFrom-AudioStreamProbe" {
    It "parses index and title" {
        $r = ConvertFrom-AudioStreamProbe -Lines @("1,Game", "2,Mic")
        $r.Count | Should Be 2
        $r[0].StreamIdx | Should Be 1
        $r[1].Label | Should Be "Mic"
    }
    It "labels untitled streams by ordinal" {
        $r = ConvertFrom-AudioStreamProbe -Lines @("1", "2")
        $r[0].Label | Should Be "Audio 1"
        $r[1].Label | Should Be "Audio 2"
    }
    It "ignores blank lines and stderr noise" {
        (ConvertFrom-AudioStreamProbe -Lines @("", "garbage text", "1,Game")).Count | Should Be 1
    }
    It "returns an empty array, not null, for no input" {
        $r = ConvertFrom-AudioStreamProbe -Lines @()
        ($null -eq $r) | Should Be $false
        @($r).Count | Should Be 0
    }
}

Describe "Get-DefaultTrackStack" {
    It "builds video-main plus one audio-source per stream" {
        $streams = @(@{StreamIdx=1;Label="Game"}, @{StreamIdx=2;Label="Mic"})
        $r = Get-DefaultTrackStack -Path "C:\v\a.mp4" -AudioStreams $streams
        $r.Count | Should Be 3
        $r[0].Kind | Should Be "video-main"
        $r[1].Kind | Should Be "audio-source"
        $r[1].StreamIdx | Should Be 1
        $r[2].Label | Should Be "Mic"
    }
    It "keeps its shape when assigned directly (return-shape guard)" {
        $r = Get-DefaultTrackStack -Path "x" -AudioStreams @()
        $r.Count | Should Be 1
    }
}

Describe "Get-TrimTimelineStarts" {
    It "accumulates piece lengths minus fade overlaps" {
        $p = @([PSCustomObject]@{Start=0.0;End=10.0}, [PSCustomObject]@{Start=20.0;End=25.0}, [PSCustomObject]@{Start=30.0;End=40.0})
        $r = Get-TrimTimelineStarts -Pieces $p -FadeLengths @(0.5, 0.0)
        $r.Count | Should Be 3
        $r[0] | Should Be 0.0
        $r[1] | Should Be 9.5
        $r[2] | Should Be 14.5
    }
    It "treats an omitted fade list as all hard cuts" {
        (Get-TrimTimelineStarts -Pieces @([PSCustomObject]@{Start=0.0;End=5.0}, [PSCustomObject]@{Start=5.0;End=8.0}))[1] | Should Be 5.0
    }
}

Describe "Get-TrackTimelineSpan" {
    It "spans a full-length clip from its offset" {
        $t = New-TrimTrack -Kind "audio-clip" -Path "m.mp3" -Offset 12.0
        $s = Get-TrackTimelineSpan -Track $t -SourceDuration 30.0
        $s.Start | Should Be 12.0
        $s.End | Should Be 42.0
    }
    It "honours InStart/InEnd trims" {
        $t = New-TrimTrack -Kind "video-clip" -Path "c.mp4" -Offset 5.0 -InStart 2.0 -InEnd 8.0
        (Get-TrackTimelineSpan -Track $t -SourceDuration 60.0).End | Should Be 11.0
    }
}

Describe "Test-TrackStackTrivial" {
    $main = New-TrimTrack -Kind "video-main" -Path "a.mp4"
    $src  = New-TrimTrack -Kind "audio-source" -Path "a.mp4" -StreamIdx 1
    It "is trivial for untouched main + source tracks" {
        Test-TrackStackTrivial -Tracks @($main, $src) | Should Be $true
    }
    It "is not trivial with a gain" {
        $g = New-TrimTrack -Kind "audio-source" -Path "a.mp4" -StreamIdx 1 -GainDb -4.5
        Test-TrackStackTrivial -Tracks @($main, $g) | Should Be $false
    }
    It "is not trivial with a mute, a clip, or a deleted video-main" {
        Test-TrackStackTrivial -Tracks @($main, (New-TrimTrack -Kind "audio-source" -Path "a" -Muted $true)) | Should Be $false
        Test-TrackStackTrivial -Tracks @($main, (New-TrimTrack -Kind "audio-clip" -Path "m.mp3")) | Should Be $false
        Test-TrackStackTrivial -Tracks @($src) | Should Be $false
    }
    It "is trivial when the audio-source count matches SourceAudioStreamCount" {
        $src2 = New-TrimTrack -Kind "audio-source" -Path "a.mp4" -StreamIdx 2
        Test-TrackStackTrivial -Tracks @($main, $src, $src2) -SourceAudioStreamCount 2 | Should Be $true
    }
    It "is not trivial when an audio-source track was deleted (count short of SourceAudioStreamCount)" {
        Test-TrackStackTrivial -Tracks @($main, $src) -SourceAudioStreamCount 2 | Should Be $false
        Test-TrackStackTrivial -Tracks @($main) -SourceAudioStreamCount 2 | Should Be $false
    }
    It "ignores SourceAudioStreamCount when -1 (legacy/unknown)" {
        Test-TrackStackTrivial -Tracks @($main, $src) -SourceAudioStreamCount -1 | Should Be $true
        Test-TrackStackTrivial -Tracks @($main) | Should Be $true
    }
}

Describe "New-TrimAudioMixPlan" {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $main = New-TrimTrack -Kind "video-main" -Path "C:\v\main.mp4"
    $game = New-TrimTrack -Kind "audio-source" -Path "C:\v\main.mp4" -StreamIdx 1 -Label "Game"
    $mic  = New-TrimTrack -Kind "audio-source" -Path "C:\v\main.mp4" -StreamIdx 2 -Label "Mic" -GainDb -6.0
    $p1   = @([PSCustomObject]@{Start=10.0;End=20.0})
    $p2   = @([PSCustomObject]@{Start=10.0;End=20.0}, [PSCustomObject]@{Start=30.0;End=35.0})

    It "throws when given no pieces" {
        { New-TrimAudioMixPlan -Tracks @($main,$game) -Pieces @() -FadeLengths @() -ClipDurations @{} } | Should Throw
    }
    It "cuts each source stream to the piece and mixes over a silence base" {
        $r = New-TrimAudioMixPlan -Tracks @($main,$game,$mic) -Pieces $p1 -FadeLengths @() -ClipDurations @{}
        $r.InputPaths[0] | Should Be "C:\v\main.mp4"
        $r.FilterComplex | Should Match ([regex]::Escape("anullsrc=r=48000:cl=stereo,atrim=0:10[b0]"))
        $r.FilterComplex | Should Match ([regex]::Escape("[0:1]atrim=start=10:end=20,asetpts=PTS-STARTPTS[s0_0]"))
        $r.FilterComplex | Should Match ([regex]::Escape("[0:2]atrim=start=10:end=20,asetpts=PTS-STARTPTS,volume=-6dB[s0_1]"))
        $r.FilterComplex | Should Match ([regex]::Escape("amix=inputs=3:duration=first:normalize=0"))
        $r.OutputLabel | Should Be "[aout]"
    }
    It "excludes muted tracks from the mix" {
        $m = New-TrimTrack -Kind "audio-source" -Path "C:\v\main.mp4" -StreamIdx 2 -Muted $true
        $r = New-TrimAudioMixPlan -Tracks @($main,$game,$m) -Pieces $p1 -FadeLengths @() -ClipDurations @{}
        $r.FilterComplex | Should Not Match ([regex]::Escape("[0:2]"))
    }
    It "joins pieces with concat on a hard cut and acrossfade on a fade" {
        $r = New-TrimAudioMixPlan -Tracks @($main,$game) -Pieces $p2 -FadeLengths @(0.5) -ClipDurations @{}
        $r.FilterComplex | Should Match ([regex]::Escape("acrossfade=d=0.5:c1=tri:c2=tri"))
        $r2 = New-TrimAudioMixPlan -Tracks @($main,$game) -Pieces $p2 -FadeLengths @(0.0) -ClipDurations @{}
        $r2.FilterComplex | Should Match ([regex]::Escape("concat=n=2:v=0:a=1"))
    }
    It "trims, delays and gains an external clip against the piece timeline" {
        # clip starts at timeline 3s; piece 0 covers timeline 0..10 (source 10..20)
        $clip = New-TrimTrack -Kind "audio-clip" -Path "C:\m\song.mp3" -Offset 3.0 -GainDb 3.0
        $r = New-TrimAudioMixPlan -Tracks @($main,$game,$clip) -Pieces $p1 -FadeLengths @() -ClipDurations @{ "C:\m\song.mp3" = 4.0 }
        $r.InputPaths.Count | Should Be 2
        $r.InputPaths[1] | Should Be "C:\m\song.mp3"
        $r.FilterComplex | Should Match ([regex]::Escape("[1:a]atrim=start=0:end=4,asetpts=PTS-STARTPTS,volume=3dB,adelay=3000:all=1[c0_0]"))
    }
    It "skips a clip that never overlaps any piece" {
        $clip = New-TrimTrack -Kind "audio-clip" -Path "C:\m\late.mp3" -Offset 500.0
        $r = New-TrimAudioMixPlan -Tracks @($main,$game,$clip) -Pieces $p1 -FadeLengths @() -ClipDurations @{ "C:\m\late.mp3" = 4.0 }
        $r.InputPaths.Count | Should Be 1
    }
    It "clips a clip hanging past the piece end" {
        # piece 0 = timeline 0..10; clip at 8 with 5s of audio -> only 2s used
        $clip = New-TrimTrack -Kind "audio-clip" -Path "C:\m\song.mp3" -Offset 8.0
        $r = New-TrimAudioMixPlan -Tracks @($main,$game,$clip) -Pieces $p1 -FadeLengths @() -ClipDurations @{ "C:\m\song.mp3" = 5.0 }
        $r.FilterComplex | Should Match ([regex]::Escape("atrim=start=0:end=2"))
    }
    It "seeds InputPaths from the clip alone when no video-main or audio-source track exists" {
        # video-main + every source lane deleted, only an audio-clip track survives:
        # $mainPath resolves to "" and must not be seeded into InputPaths[0] (would
        # otherwise become an `-i ""` ffmpeg argument).
        $clip = New-TrimTrack -Kind "audio-clip" -Path "C:\m\song.mp3"
        $r = New-TrimAudioMixPlan -Tracks @($clip) -Pieces $p1 -FadeLengths @() -ClipDurations @{ "C:\m\song.mp3" = 4.0 }
        $r.InputPaths[0] | Should Be "C:\m\song.mp3"
        $r.InputPaths.Count | Should Be 1
        $r.FilterComplex | Should Match ([regex]::Escape("[0:a]"))
    }
    It "writes dot decimals under a comma-decimal culture and contains no unescaped expression commas" {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
            $r = New-TrimAudioMixPlan -Tracks @($main,$mic) -Pieces $p2 -FadeLengths @(0.5) -ClipDurations @{}
            $r.FilterComplex | Should Not Match "0,5"
            $r.FilterComplex | Should Not Match "-6,0"
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
}

Describe "New-PipOverlayChain" {
    It "scales and positions one overlay from its centered box" {
        $ov = @(@{ InputIndex = 1; Pip = @{ X = 0.5; Y = 0.5; W = 0.35; H = 0.35 } })
        $f = New-PipOverlayChain -Overlays $ov -Width 2560 -Height 1440
        $f | Should Match ([regex]::Escape("[1:v]scale=896:504[ov0]"))
        $f | Should Match ([regex]::Escape("[0:v][ov0]overlay=832:468[vout]"))
    }
    It "stacks two overlays in order, last on top" {
        $ov = @(
            @{ InputIndex = 1; Pip = @{ X = 0.25; Y = 0.25; W = 0.2; H = 0.2 } },
            @{ InputIndex = 2; Pip = @{ X = 0.75; Y = 0.75; W = 0.2; H = 0.2 } }
        )
        $f = New-PipOverlayChain -Overlays $ov -Width 2560 -Height 1440
        $f.IndexOf("[1:v]") | Should BeLessThan $f.IndexOf("[2:v]")
        $f | Should Match ([regex]::Escape("[vo0][ov1]overlay"))
        $f | Should Match ([regex]::Escape("[vout]"))
    }
    It "keeps scaled dimensions even for yuv420p" {
        $ov = @(@{ InputIndex = 1; Pip = @{ X = 0.5; Y = 0.5; W = 0.333; H = 0.333 } })
        $f = New-PipOverlayChain -Overlays $ov -Width 2560 -Height 1440
        $f -match "scale=(\d+):(\d+)" | Should Be $true
        ([int]$Matches[1]) % 2 | Should Be 0
        ([int]$Matches[2]) % 2 | Should Be 0
    }
}

Describe "Test-PipTransitionClash" {
    $p = @([PSCustomObject]@{Start=0.0;End=10.0}, [PSCustomObject]@{Start=20.0;End=30.0})
    It "flags a PiP crossing a crossfade window" {
        # fade 0.5 -> window timeline 9.5..10.0
        Test-PipTransitionClash -PipSpans @(@{Start=9.7;End=12.0}) -Pieces $p -FadeLengths @(0.5) | Should Be $true
    }
    It "passes a PiP clear of every fade, and any PiP over hard cuts" {
        Test-PipTransitionClash -PipSpans @(@{Start=2.0;End=9.0}) -Pieces $p -FadeLengths @(0.5) | Should Be $false
        Test-PipTransitionClash -PipSpans @(@{Start=9.7;End=12.0}) -Pieces $p -FadeLengths @(0.0) | Should Be $false
    }
}

Describe "New-TrimClip" {
    It "creates a video clip with defaults: full-frame, enabled, unlinked" {
        $c = New-TrimClip -Kind "video" -Path "C:\v\a.mp4"
        $c.Kind | Should Be "video"
        $c.Pip | Should Be $null
        $c.Enabled | Should Be $true
        $c.LinkId | Should Be ""
        $c.StreamIdx | Should Be (-1)
        $c.GainDb | Should Be 0.0
        $c.Id | Should Not Be $null
    }
    It "throws on an unknown kind" {
        { New-TrimClip -Kind "banana" -Path "x" } | Should Throw
    }
    It "clamps GainDb and floors Offset/InStart/InEnd at 0.0" {
        $c = New-TrimClip -Kind "audio" -Path "x" -GainDb 99 -Offset -3 -InStart -1
        $c.GainDb | Should Be 30.0
        $c.Offset | Should Be 0.0
        $c.InStart | Should Be 0.0
    }
    It "defaults an image clip to 5.0s and clamps the floor to 0.2s" {
        (New-TrimClip -Kind "image" -Path "l.png").DurationOverride | Should Be 5.0
        (New-TrimClip -Kind "image" -Path "l.png" -DurationOverride 0.05).DurationOverride | Should Be 0.2
        (New-TrimClip -Kind "video" -Path "v.mp4").DurationOverride | Should Be 0.0
    }
}

Describe "New-TrimLane" {
    It "creates lanes of both kinds and rejects others" {
        (New-TrimLane -Kind "video").Kind | Should Be "video"
        (New-TrimLane -Kind "audio" -Label "Mic").Label | Should Be "Mic"
        { New-TrimLane -Kind "caption" } | Should Throw
    }
    It "defaults IsMain false and Clips empty" {
        $l = New-TrimLane -Kind "video"
        $l.IsMain | Should Be $false
        $r = @($l.Clips)
        $r.Count | Should Be 0
    }
}

Describe "Get-TrimLaneStack" {
    It "builds the main video lane plus one linked audio lane per stream" {
        $streams = @(@{StreamIdx=1;Label="Game"}, @{StreamIdx=2;Label="Mic"})
        $r = Get-TrimLaneStack -Path "C:\v\a.mp4" -AudioStreams $streams
        $r.Count | Should Be 3
        $r[0].Kind | Should Be "video"
        $r[0].IsMain | Should Be $true
        $r[0].Label | Should Be "a.mp4"
        $r[1].Kind | Should Be "audio"
        $r[1].Label | Should Be "Game"
        $r[1].Clips[0].StreamIdx | Should Be 1
        $r[2].Clips[0].StreamIdx | Should Be 2
    }
    It "links every source row to the main video clip via one LinkId" {
        $streams = @(@{StreamIdx=1;Label="Game"}, @{StreamIdx=2;Label="Mic"})
        $r = Get-TrimLaneStack -Path "C:\v\a.mp4" -AudioStreams $streams
        $link = $r[0].Clips[0].LinkId
        $link | Should Not Be ""
        $r[1].Clips[0].LinkId | Should Be $link
        $r[2].Clips[0].LinkId | Should Be $link
    }
    It "keeps its shape at zero streams (return-shape guard)" {
        $r = Get-TrimLaneStack -Path "C:\v\a.mp4" -AudioStreams @()
        $r.Count | Should Be 1
    }
}

Describe "Get-TrimLinkedClipIds / Clear-TrimClipLinks" {
    It "finds every peer sharing the LinkId, including self" {
        $lanes = Get-TrimLaneStack -Path "a.mp4" -AudioStreams @(@{StreamIdx=1;Label="Game"}, @{StreamIdx=2;Label="Mic"})
        $vid = $lanes[0].Clips[0]
        $r = Get-TrimLinkedClipIds -Lanes $lanes -ClipId $vid.Id
        $r.Count | Should Be 3
    }
    It "returns only itself for an unlinked clip" {
        $lanes = @((New-TrimLane -Kind "audio" -Clips @((New-TrimClip -Kind "audio" -Path "m.mp3"))))
        $r = Get-TrimLinkedClipIds -Lanes $lanes -ClipId $lanes[0].Clips[0].Id
        $r.Count | Should Be 1
    }
    It "clears the whole link group and reports the count" {
        $lanes = Get-TrimLaneStack -Path "a.mp4" -AudioStreams @(@{StreamIdx=1;Label="Game"})
        $n = Clear-TrimClipLinks -Lanes $lanes -ClipId $lanes[1].Clips[0].Id
        $n | Should Be 2
        $lanes[0].Clips[0].LinkId | Should Be ""
        $lanes[1].Clips[0].LinkId | Should Be ""
    }
}

Describe "Get-TrimClipSpan" {
    It "spans video clips like Get-TrackTimelineSpan and images by DurationOverride" {
        $v = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 5.0 -InStart 2.0 -InEnd 8.0
        $s = Get-TrimClipSpan -Clip $v -SourceDuration 60.0
        $s.Start | Should Be 5.0
        $s.End | Should Be 11.0
        $img = New-TrimClip -Kind "image" -Path "l.png" -Offset 10.0 -DurationOverride 4.0
        (Get-TrimClipSpan -Clip $img -SourceDuration 0.0).End | Should Be 14.0
    }
}

Describe "Get-TrimTimelineLength" {
    $pieces = @([PSCustomObject]@{Start=0.0;End=20.0}, [PSCustomObject]@{Start=30.0;End=40.0})
    It "is V1's output length when nothing extends past it" {
        $lanes = Get-TrimLaneStack -Path "a.mp4" -AudioStreams @(@{StreamIdx=1;Label="Game"})
        $len = Get-TrimTimelineLength -Lanes $lanes -Pieces $pieces -FadeLengths @(0.5) -ClipDurations @{} -MainPath "a.mp4"
        $len | Should Be 29.5
    }
    It "extends to the last clip end across lanes (montage)" {
        $lanes = Get-TrimLaneStack -Path "a.mp4" -AudioStreams @()
        $ov = New-TrimLane -Kind "video" -Label "Overlay" -Clips @((New-TrimClip -Kind "video" -Path "c.mp4" -Offset 25.0))
        $lanes = @($lanes) + ,$ov
        $len = Get-TrimTimelineLength -Lanes $lanes -Pieces $pieces -FadeLengths @() -ClipDurations @{ "c.mp4" = 20.0 } -MainPath "a.mp4"
        $len | Should Be 45.0
    }
    It "ignores disabled clips" {
        $lanes = Get-TrimLaneStack -Path "a.mp4" -AudioStreams @()
        $c = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 100.0 -Enabled $false
        $lanes = @($lanes) + ,(New-TrimLane -Kind "video" -Clips @($c))
        (Get-TrimTimelineLength -Lanes $lanes -Pieces $pieces -FadeLengths @() -ClipDurations @{ "c.mp4" = 5.0 } -MainPath "a.mp4") | Should Be 30.0
    }
}

Describe "Get-TrimSnapPoints / Resolve-TrimSnap" {
    $pieces = @([PSCustomObject]@{Start=0.0;End=30.0})
    It "collects zero, V1 end, playhead and clip edges, sorted unique" {
        $lanes = Get-TrimLaneStack -Path "a.mp4" -AudioStreams @()
        $c = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 10.0
        $lanes = @($lanes) + ,(New-TrimLane -Kind "video" -Clips @($c))
        $r = Get-TrimSnapPoints -Lanes $lanes -Pieces $pieces -FadeLengths @() -ClipDurations @{ "c.mp4" = 5.0 } -MainPath "a.mp4" -PlayheadTimeline 12.0
        # 0, 10 (clip start), 12 (playhead), 15 (clip end), 30 (V1 end)
        $r.Count | Should Be 5
        $r[0] | Should Be 0.0
        $r[1] | Should Be 10.0
        $r[4] | Should Be 30.0
    }
    It "excludes the dragged clip's own edges" {
        $lanes = Get-TrimLaneStack -Path "a.mp4" -AudioStreams @()
        $c = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 10.0
        $lanes = @($lanes) + ,(New-TrimLane -Kind "video" -Clips @($c))
        $r = Get-TrimSnapPoints -Lanes $lanes -Pieces $pieces -FadeLengths @() -ClipDurations @{ "c.mp4" = 5.0 } -MainPath "a.mp4" -ExcludeClipIds @($c.Id)
        $r.Count | Should Be 2
    }
    It "snaps within threshold and refuses outside it" {
        $s = Resolve-TrimSnap -Position 29.8 -Points @(0.0, 30.0) -Threshold 0.3
        $s.Snapped | Should Be $true
        $s.Position | Should Be 30.0
        $s.Point | Should Be 30.0
        (Resolve-TrimSnap -Position 28.0 -Points @(0.0, 30.0) -Threshold 0.3).Snapped | Should Be $false
    }
}

Describe "Move-TrimClipLinked" {
    It "moves the whole link group by one shared clamped delta" {
        $v = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 5.0 -LinkId "L1"
        $a = New-TrimClip -Kind "audio" -Path "c.mp4" -Offset 5.0 -LinkId "L1"
        $lanes = @((New-TrimLane -Kind "video" -Clips @($v)), (New-TrimLane -Kind "audio" -Clips @($a)))
        $d = Move-TrimClipLinked -Lanes $lanes -ClipId $v.Id -NewOffset 12.0
        $d | Should Be 7.0
        $a.Offset | Should Be 12.0
        # clamp: dragging to -10 stops the GROUP at 0
        $d2 = Move-TrimClipLinked -Lanes $lanes -ClipId $a.Id -NewOffset (-10.0)
        $d2 | Should Be (-12.0)
        $v.Offset | Should Be 0.0
    }
}

Describe "Set-TrimClipInPointLinked / Set-TrimClipOutPointLinked" {
    It "trims the in-point in Offset/InStart lockstep across the pair" {
        $v = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 5.0 -InStart 0.0 -InEnd 10.0 -LinkId "L"
        $a = New-TrimClip -Kind "audio" -Path "c.mp4" -Offset 5.0 -InStart 0.0 -InEnd 10.0 -LinkId "L"
        $lanes = @((New-TrimLane -Kind "video" -Clips @($v)), (New-TrimLane -Kind "audio" -Clips @($a)))
        $d = Set-TrimClipInPointLinked -Lanes $lanes -ClipId $v.Id -Delta 2.0
        $d | Should Be 2.0
        $v.InStart | Should Be 2.0
        $v.Offset | Should Be 7.0
        $a.InStart | Should Be 2.0
        $a.Offset | Should Be 7.0
    }
    It "clamps the in-point delta group-wide (tightest member wins)" {
        $v = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 5.0 -InStart 1.0 -InEnd 10.0 -LinkId "L"
        $a = New-TrimClip -Kind "audio" -Path "c.mp4" -Offset 5.0 -InStart 0.5 -InEnd 10.0 -LinkId "L"
        $lanes = @((New-TrimLane -Kind "video" -Clips @($v)), (New-TrimLane -Kind "audio" -Clips @($a)))
        $d = Set-TrimClipInPointLinked -Lanes $lanes -ClipId $v.Id -Delta (-3.0)
        $d | Should Be (-0.5)
        $v.InStart | Should Be 0.5
        $a.InStart | Should Be 0.0
    }
    It "resolves the InEnd sentinel from ClipDurations before an out trim" {
        $v = New-TrimClip -Kind "video" -Path "c.mp4" -Offset 0.0
        $lanes = @(,(New-TrimLane -Kind "video" -Clips @($v)))
        $d = Set-TrimClipOutPointLinked -Lanes $lanes -ClipId $v.Id -Delta (-3.0) -ClipDurations @{ "c.mp4" = 10.0 }
        $d | Should Be (-3.0)
        $v.InEnd | Should Be 7.0
    }
    It "leaves the out edge inert on a duration cache miss" {
        $v = New-TrimClip -Kind "video" -Path "gone.mp4"
        $lanes = @(,(New-TrimLane -Kind "video" -Clips @($v)))
        $d = Set-TrimClipOutPointLinked -Lanes $lanes -ClipId $v.Id -Delta (-3.0) -ClipDurations @{}
        $d | Should Be 0.0
        $v.InEnd | Should Be 0.0
    }
    It "edge-trims an image by DurationOverride with the 0.2s floor" {
        $img = New-TrimClip -Kind "image" -Path "l.png" -Offset 3.0 -DurationOverride 5.0
        $lanes = @(,(New-TrimLane -Kind "video" -Clips @($img)))
        $d = Set-TrimClipOutPointLinked -Lanes $lanes -ClipId $img.Id -Delta (-10.0) -ClipDurations @{}
        $d | Should Be (-4.8)
        $img.DurationOverride | Should Be 0.2
        $d2 = Set-TrimClipInPointLinked -Lanes $lanes -ClipId $img.Id -Delta 5.0
        $d2 | Should Be 0.0
    }
}
