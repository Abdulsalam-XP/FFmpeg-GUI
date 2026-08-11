$modulePath = Join-Path $PSScriptRoot "..\Zooms.psm1"
Import-Module $modulePath -Force

Describe "New-ZoomKeyframe" {
    It "creates a keyframe with defaults and an id" {
        $k = New-ZoomKeyframe -Time 60
        $k.Time | Should Be 60
        $k.CX | Should Be 0.5
        $k.CY | Should Be 0.5
        $k.Level | Should Be 1.0
        $k.Id | Should Not Be $null
    }
    It "clamps level and center" {
        $k = New-ZoomKeyframe -Time 0 -Level 9 -CX 1.4 -CY -0.2
        $k.Level | Should Be 6
        $k.CX | Should Be 1
        $k.CY | Should Be 0
    }
}

Describe "Get-TrimZoomStateAt" {
    It "returns identity for no keyframes" {
        $s = Get-TrimZoomStateAt -Zooms @() -Seconds 10
        $s.Level | Should Be 1.0
        $s.CX | Should Be 0.5
    }
    It "holds the first keyframe before it" {
        $k = New-ZoomKeyframe -Time 10 -Level 2 -CX 0.6 -CY 0.4
        (Get-TrimZoomStateAt -Zooms @($k) -Seconds 3).Level | Should Be 2
    }
    It "holds the last keyframe after it" {
        $a = New-ZoomKeyframe -Time 10 -Level 1
        $b = New-ZoomKeyframe -Time 12 -Level 3 -CX 0.7
        $s = Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 50
        $s.Level | Should Be 3
        $s.CX | Should Be 0.7
    }
    It "interpolates linearly mid-glide" {
        $a = New-ZoomKeyframe -Time 10 -Level 1 -CX 0.5 -CY 0.5
        $b = New-ZoomKeyframe -Time 14 -Level 3 -CX 0.7 -CY 0.3
        $s = Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 12
        $s.Level | Should Be 2
        $s.CX | Should Be 0.6
        $s.CY | Should Be 0.4
    }
    It "sorts keyframes by time regardless of list order" {
        $a = New-ZoomKeyframe -Time 14 -Level 3
        $b = New-ZoomKeyframe -Time 10 -Level 1
        (Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 12).Level | Should Be 2
    }
    It "sits exactly on a keyframe" {
        $a = New-ZoomKeyframe -Time 10 -Level 1
        $b = New-ZoomKeyframe -Time 14 -Level 3
        (Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 14).Level | Should Be 3
    }
}
