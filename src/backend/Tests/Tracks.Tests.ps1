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
