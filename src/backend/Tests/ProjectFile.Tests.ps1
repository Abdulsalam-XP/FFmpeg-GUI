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
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
