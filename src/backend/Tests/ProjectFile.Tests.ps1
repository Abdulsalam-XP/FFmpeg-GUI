$modulePath = Join-Path $PSScriptRoot "..\ProjectFile.psm1"
Import-Module $modulePath -Force
Import-Module (Join-Path $PSScriptRoot "..\Captions.psm1") -Force

Describe "Get-TrimProjectPath" {
    It "replaces the extension with .ffgui.json" {
        Get-TrimProjectPath -VideoPath "C:\v\clip.mp4" | Should Be "C:\v\clip.ffgui.json"
    }
    It "handles names with dots" {
        Get-TrimProjectPath -VideoPath "C:\v\a.b.DVR.mp4" | Should Be "C:\v\a.b.DVR.ffgui.json"
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
        $v2 = Join-Path $tmp "future.mp4"
        Set-Content -Path $v2 -Value "fake"
        Set-Content -Path (Get-TrimProjectPath -VideoPath $v2) -Value '{"Version":2,"CutList":[{"Start":0,"End":5}],"Fades":{},"Captions":[]}'
        Read-TrimProject -VideoPath $v2 | Should Be $null
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
