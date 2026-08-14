$modulePath = Join-Path $PSScriptRoot "..\ProjectFile.psm1"
Import-Module $modulePath -Force
Import-Module (Join-Path $PSScriptRoot "..\Captions.psm1") -Force

# Every test writes into ITS OWN store, never the app's assets\projects.
$script:TestStore = Join-Path $env:TEMP ("pf-store-" + [guid]::NewGuid().ToString("N"))
Set-TrimProjectStore -Path $script:TestStore

Describe "Get-TrimProjectPath" {
    It "lives in the project STORE, named leaf + path hash + .ffgui.json" {
        $p = Get-TrimProjectPath -VideoPath "C:\v\clip.mp4"
        (Split-Path $p -Parent) | Should Be $script:TestStore
        (Split-Path $p -Leaf) | Should Match '^clip-[0-9a-f]{8}\.ffgui\.json$'
    }
    It "is stable for the same path and distinct for same-named clips elsewhere" {
        $a = Get-TrimProjectPath -VideoPath "C:\v\clip.mp4"
        $b = Get-TrimProjectPath -VideoPath "C:\v\clip.mp4"
        $c = Get-TrimProjectPath -VideoPath "C:\other\clip.mp4"
        $a | Should Be $b
        $a | Should Not Be $c
    }
    It "keeps dotted names readable" {
        (Split-Path (Get-TrimProjectPath -VideoPath "C:\v\a.b.DVR.mp4") -Leaf) | Should Match '^a\.b\.DVR-[0-9a-f]{8}\.ffgui\.json$'
    }
    It "still knows the legacy sidecar location" {
        Get-TrimLegacyProjectPath -VideoPath "C:\v\clip.mp4" | Should Be "C:\v\clip.ffgui.json"
    }
}

Describe "Read-TrimProject legacy sidecar migration" {
    $tmp = Join-Path $env:TEMP ("pf-legacy-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $video = Join-Path $tmp "old.mp4"
    Set-Content -Path $video -Value "fake"

    It "reads a sidecar from beside the video and MOVES it into the store" {
        Set-Content -Path (Get-TrimLegacyProjectPath -VideoPath $video) -Encoding UTF8 -Value `
            '{"Version":1,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[]}'
        $r = Read-TrimProject -VideoPath $video
        @($r.CutList).Count | Should Be 1
        (Test-Path (Get-TrimLegacyProjectPath -VideoPath $video)) | Should Be $false
        (Test-Path (Get-TrimProjectPath -VideoPath $video)) | Should Be $true
    }
}

Describe "Save-TrimProject / Read-TrimProject round trip" {
    $tmp = Join-Path $env:TEMP ("pf-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $video = Join-Path $tmp "clip.mp4"
    Set-Content -Path $video -Value "fake"

    It "round-trips cuts, fades and captions" {
        $cuts = @([PSCustomObject]@{Start=0.0;End=61.0}, [PSCustomObject]@{Start=61.0;End=320.2})
        $fades = @{ "61.000" = 0.5 }
        $cap = New-Caption -Start 10 -End 12 -Text "hi {there}"
        (Save-TrimProject -VideoPath $video -CutList $cuts -Fades $fades -Captions @($cap)) | Should Be $true
        $r = Read-TrimProject -VideoPath $video
        @($r.CutList).Count | Should Be 2
        $r.CutList[1].End | Should Be 320.2
        $r.Fades["61.000"] | Should Be 0.5
        @($r.Captions).Count | Should Be 1
        $r.Captions[0].Text | Should Be "hi {there}"
        $r.Captions[0].BounceIn | Should Be $true
    }
    It "returns null when no project file exists" {
        Read-TrimProject -VideoPath (Join-Path $tmp "other.mp4") | Should Be $null
    }
    It "returns null for corrupt json instead of throwing" {
        $bad = Join-Path $tmp "bad.mp4"
        Set-Content -Path $bad -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $bad) -Value "{ not json"
        Read-TrimProject -VideoPath $bad | Should Be $null
    }
    It "returns null for json missing the expected shape" {
        $odd = Join-Path $tmp "odd.mp4"
        Set-Content -Path $odd -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $odd) -Value '{"Version":1}'
        Read-TrimProject -VideoPath $odd | Should Be $null
    }
    It "returns null when values are the wrong type instead of throwing" {
        $wt = Join-Path $tmp "wrongtype.mp4"
        Set-Content -Path $wt -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $wt) -Value '{"Version":1,"CutList":[{"Start":"abc","End":5}],"Fades":{},"Captions":[]}'
        Read-TrimProject -VideoPath $wt | Should Be $null
    }
    It "returns null for a project written by a newer schema version" {
        # v3 is now a supported schema (this task); the "too new" boundary moved to v4.
        $v4 = Join-Path $tmp "future.mp4"
        Set-Content -Path $v4 -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $v4) -Value '{"Version":4,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[]}'
        Read-TrimProject -VideoPath $v4 | Should Be $null
    }
    It "round-trips zoom keyframes" {
        Import-Module (Join-Path $PSScriptRoot "..\Zooms.psm1") -Force
        $z = New-ZoomKeyframe -Time 12.5 -CX 0.65 -CY 0.4 -W 0.4 -H 0.7
        (Save-TrimProject -VideoPath $video -CutList @() -Fades @{} -Captions @() -Zooms @($z)) | Should Be $true
        $r = Read-TrimProject -VideoPath $video
        @($r.Zooms).Count | Should Be 1
        $r.Zooms[0].W | Should Be 0.4
        $r.Zooms[0].H | Should Be 0.7
        $r.DroppedZooms | Should Be 0
    }
    It "migrates an old Level-model project onto the box model" {
        $lv = Join-Path $tmp "levelmodel.mp4"
        Set-Content -Path $lv -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $lv) -Value '{"Version":1,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[],"Zooms":[{"Id":"a","Time":3,"CX":0.6,"CY":0.4,"Level":2}]}'
        $r = Read-TrimProject -VideoPath $lv
        @($r.Zooms).Count | Should Be 1
        $r.Zooms[0].W | Should Be 0.5
        $r.Zooms[0].H | Should Be 0.5
        $r.DroppedZooms | Should Be 0
    }
    It "loads old projects without a Zooms field as zero zooms" {
        $old = Join-Path $tmp "old.mp4"
        Set-Content -Path $old -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $old) -Value '{"Version":1,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[]}'
        $r = Read-TrimProject -VideoPath $old
        @($r.Zooms).Count | Should Be 0
    }
    It "drops corrupt zoom entries instead of failing the whole load" {
        $zc = Join-Path $tmp "zc.mp4"
        Set-Content -Path $zc -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $zc) -Value '{"Version":1,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[],"Zooms":[{"Id":"a","Time":"junk","CX":0.5,"CY":0.5,"Level":2},{"Id":"b","Time":3,"CX":0.5,"CY":0.5,"Level":2}]}'
        $r = Read-TrimProject -VideoPath $zc
        @($r.Zooms).Count | Should Be 1
        $r.DroppedZooms | Should Be 1
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "Save-TrimProject / Read-TrimProject schema v2 (tracks + unlinked)" {
    $tmp = Join-Path $env:TEMP ("pf-v2-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $video = Join-Path $tmp "clip.mp4"
    Set-Content -Path $video -Value "fake"

    It "migrates a saved audio-source track onto a lane" {
        Import-Module (Join-Path $PSScriptRoot "..\Tracks.psm1") -Force
        $v2 = Join-Path $tmp "v2save.mp4"
        Set-Content -Path $v2 -Value "fake"
        $json = '{"Version":2,"CutList":[],"Fades":{},"Captions":[],"Zooms":[],"Unlinked":true,"Tracks":[' +
            '{"Id":"b","Kind":"audio-source","Path":"' + ($v2 -replace '\\','\\\\') + '","StreamIdx":1,"Label":"Game","Offset":0,"InStart":0,"InEnd":0,"GainDb":-4.5,"Muted":false}]}'
        Set-Content -Path (Get-TrimProjectPath -VideoPath $v2) -Value $json
        $r = Read-TrimProject -VideoPath $v2
        @($r.Lanes).Count | Should Be 1
        $r.Lanes[0].Clips[0].GainDb | Should Be (-4.5)
    }
    It "loads v1 files with null Tracks so the app builds defaults" {
        $v1 = Join-Path $tmp "v1.mp4"
        Set-Content -Path $v1 -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $v1) -Value '{"Version":1,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[]}'
        $r = Read-TrimProject -VideoPath $v1
        $r.Lanes | Should Be $null
    }
    It "drops corrupt track entries and counts them" {
        $tc = Join-Path $tmp "tc.mp4"
        Set-Content -Path $tc -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $tc) -Value '{"Version":2,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[],"Zooms":[],"Unlinked":false,"Tracks":[{"Kind":"banana"},{"Id":"b","Kind":"audio-source","Path":"x","StreamIdx":1,"Label":"g","Offset":0,"InStart":0,"InEnd":0,"GainDb":0,"Muted":false}]}'
        $r = Read-TrimProject -VideoPath $tc
        @($r.Lanes).Count | Should Be 1
        $r.DroppedClips | Should Be 0
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "Save-TrimProject / Read-TrimProject schema v3 (lanes)" {
    $tmp = Join-Path $env:TEMP ("pf-v3-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $video = Join-Path $tmp "clip.mp4"
    Set-Content -Path $video -Value "fake"

    It "round-trips a lane stack as schema v3" {
        Import-Module (Join-Path $PSScriptRoot "..\Tracks.psm1") -Force
        $lanes = Get-TrimLaneStack -Path $video -AudioStreams @(@{StreamIdx=1;Label="Game"})
        $lanes[1].Clips[0].GainDb = -4.5
        $img = New-TrimClip -Kind "image" -Path "C:\art\logo.png" -Offset 3.0 -DurationOverride 4.0
        $lanes = @($lanes) + ,(New-TrimLane -Kind "video" -Label "V2" -Clips @($img))
        (Save-TrimProject -VideoPath $video -CutList @() -Fades @{} -Captions @() -Zooms @() -Lanes @($lanes)) | Should Be $true
        (Get-Content (Get-TrimProjectPath -VideoPath $video) -Raw | ConvertFrom-Json).Version | Should Be 3
        $r = Read-TrimProject -VideoPath $video
        $l = @($r.Lanes)
        $l.Count | Should Be 3
        $l[0].IsMain | Should Be $true
        $l[1].Clips[0].GainDb | Should Be (-4.5)
        $l[1].Clips[0].LinkId | Should Be $l[0].Clips[0].LinkId
        $l[2].Clips[0].Kind | Should Be "image"
        $l[2].Clips[0].DurationOverride | Should Be 4.0
        $l[2].Clips[0].Pip | Should Be $null
    }
    It "loads v1 files with null Lanes so the app builds defaults" {
        $v1 = Join-Path $tmp "v1nle.mp4"
        Set-Content -Path $v1 -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $v1) -Value '{"Version":1,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[]}'
        (Read-TrimProject -VideoPath $v1).Lanes | Should Be $null
    }
    It "migrates a v2 track stack onto lanes" {
        $v2 = Join-Path $tmp "v2nle.mp4"
        Set-Content -Path $v2 -Value "fake"
        $json = '{"Version":2,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[],"Zooms":[],"Unlinked":true,"Tracks":[' +
            '{"Id":"a","Kind":"video-main","Path":"x.mp4","StreamIdx":0,"Label":"Video","Offset":0,"InStart":0,"InEnd":0,"GainDb":0,"Muted":false},' +
            '{"Id":"b","Kind":"audio-source","Path":"x.mp4","StreamIdx":1,"Label":"Game","Offset":0,"InStart":0,"InEnd":0,"GainDb":-6,"Muted":true},' +
            '{"Id":"c","Kind":"video-clip","Path":"c.mp4","StreamIdx":0,"Label":"c.mp4","Offset":8,"InStart":1,"InEnd":5,"GainDb":0,"Muted":false,"Pip":{"X":0.5,"Y":0.5,"W":0.3,"H":0.3}},' +
            '{"Id":"d","Kind":"audio-clip","Path":"m.mp3","StreamIdx":0,"Label":"m.mp3","Offset":2,"InStart":0,"InEnd":0,"GainDb":3,"Muted":false}]}'
        Set-Content -Path (Get-TrimProjectPath -VideoPath $v2) -Value $json
        $r = Read-TrimProject -VideoPath $v2
        $l = @($r.Lanes)
        $l.Count | Should Be 4
        $l[0].IsMain | Should Be $true
        $l[1].Kind | Should Be "audio"
        $l[1].Clips[0].GainDb | Should Be (-6.0)
        $l[1].Clips[0].Muted | Should Be $true
        $l[1].Clips[0].LinkId | Should Be $l[0].Clips[0].LinkId
        $l[2].Kind | Should Be "video"
        $l[2].Clips[0].Pip.W | Should Be 0.3   # Pip preserved: stays boxed
        $l[3].Kind | Should Be "audio"
        $l[3].Clips[0].Offset | Should Be 2.0
    }
    It "drops corrupt lane and clip entries and counts them" {
        $tc = Join-Path $tmp "tcnle.mp4"
        Set-Content -Path $tc -Value "fake"
        $json = '{"Version":3,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[],"Zooms":[],"Lanes":[' +
            '{"Id":"l1","Kind":"banana","Label":"x","IsMain":false,"Clips":[{"Id":"z","Kind":"video","Path":"v.mp4"}]},' +
            '{"Id":"l2","Kind":"video","Label":"ok","IsMain":true,"Clips":[' +
            '{"Id":"g","Kind":"audio","Path":"v.mp4"},' +
            '{"Id":"h","Kind":"video","Path":"v.mp4","StreamIdx":-1,"LinkId":"","Offset":0,"InStart":0,"InEnd":0,"DurationOverride":0,"GainDb":0,"Muted":false,"Pip":null,"Enabled":true}]}]}'
        Set-Content -Path (Get-TrimProjectPath -VideoPath $tc) -Value $json
        $r = Read-TrimProject -VideoPath $tc
        $l = @($r.Lanes)
        $l.Count | Should Be 1
        $c = @($l[0].Clips)
        $c.Count | Should Be 1
        $r.DroppedClips | Should Be 2
    }
    It "clamps a hand-edited Pip on read" {
        $pc = Join-Path $tmp "pcnle.mp4"
        Set-Content -Path $pc -Value "fake"
        $json = '{"Version":3,"CutList":[],"Fades":{},"Captions":[],"Zooms":[],"Lanes":[' +
            '{"Id":"l","Kind":"video","Label":"v","IsMain":true,"Clips":[' +
            '{"Id":"c","Kind":"video","Path":"v.mp4","Pip":{"X":9.0,"Y":-2.0,"W":4.0,"H":0.001}}]}]}'
        Set-Content -Path (Get-TrimProjectPath -VideoPath $pc) -Value $json
        $r = Read-TrimProject -VideoPath $pc
        $pip = $r.Lanes[0].Clips[0].Pip
        $pip.W | Should Be 1.0
        $pip.H | Should Be 0.05
        $pip.X | Should Be 0.5    # clamped to [W/2, 1-W/2] = [0.5, 0.5]
        $pip.Y | Should Be 0.025
    }
    It "refuses v4" {
        $v4 = Join-Path $tmp "v4nle.mp4"
        Set-Content -Path $v4 -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $v4) -Value '{"Version":4,"CutList":[],"Fades":{},"Captions":[]}'
        Read-TrimProject -VideoPath $v4 | Should Be $null
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
