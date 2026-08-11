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
