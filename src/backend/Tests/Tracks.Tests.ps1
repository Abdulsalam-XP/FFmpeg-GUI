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
        $r.FilterComplex | Should Match ([regex]::Escape("[0:a:1]atrim=start=10:end=20,asetpts=PTS-STARTPTS[s0_0]"))
        $r.FilterComplex | Should Match ([regex]::Escape("[0:a:2]atrim=start=10:end=20,asetpts=PTS-STARTPTS,volume=-6dB[s0_1]"))
        $r.FilterComplex | Should Match ([regex]::Escape("amix=inputs=3:duration=first:normalize=0"))
        $r.OutputLabel | Should Be "[aout]"
    }
    It "excludes muted tracks from the mix" {
        $m = New-TrimTrack -Kind "audio-source" -Path "C:\v\main.mp4" -StreamIdx 2 -Muted $true
        $r = New-TrimAudioMixPlan -Tracks @($main,$game,$m) -Pieces $p1 -FadeLengths @() -ClipDurations @{}
        $r.FilterComplex | Should Not Match ([regex]::Escape("[0:a:2]"))
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
