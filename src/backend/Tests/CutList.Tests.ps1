$modulePath = Join-Path $PSScriptRoot "..\CutList.psm1"
Import-Module $modulePath -Force

Describe "New-CutList" {
    It "starts as one piece covering the whole clip" {
        $list = New-CutList -Duration 60
        @($list).Count | Should Be 1
        $list[0].Start | Should Be 0
        $list[0].End | Should Be 60
    }
}

Describe "Split-CutList" {
    It "turns one piece into two that meet at the split point" {
        $list = Split-CutList -List (New-CutList -Duration 60) -AtSeconds 25
        @($list).Count | Should Be 2
        $list[0].Start | Should Be 0
        $list[0].End | Should Be 25
        $list[1].Start | Should Be 25
        $list[1].End | Should Be 60
    }

    It "splits only the piece containing the point" {
        $list = Split-CutList -List (New-CutList -Duration 60) -AtSeconds 20
        $list = Split-CutList -List $list -AtSeconds 40
        @($list).Count | Should Be 3
        $list[1].Start | Should Be 20
        $list[1].End | Should Be 40
    }

    It "leaves the total duration unchanged" {
        $list = Split-CutList -List (New-CutList -Duration 60) -AtSeconds 25
        $total = ($list | ForEach-Object { $_.End - $_.Start } | Measure-Object -Sum).Sum
        $total | Should Be 60
    }

    It "does nothing when the point is already a boundary" {
        $list = Split-CutList -List (New-CutList -Duration 60) -AtSeconds 25
        $again = Split-CutList -List $list -AtSeconds 25
        @($again).Count | Should Be 2
    }

    It "does nothing at the very start or very end" {
        (Split-CutList -List (New-CutList -Duration 60) -AtSeconds 0).Count | Should Be 1
        (Split-CutList -List (New-CutList -Duration 60) -AtSeconds 60).Count | Should Be 1
    }

    It "does nothing outside the clip" {
        (Split-CutList -List (New-CutList -Duration 60) -AtSeconds 99).Count | Should Be 1
        (Split-CutList -List (New-CutList -Duration 60) -AtSeconds -5).Count | Should Be 1
    }

    It "does nothing inside a gap left by a deleted piece" {
        $list = Split-CutList -List (New-CutList -Duration 60) -AtSeconds 20
        $list = Split-CutList -List $list -AtSeconds 40
        $list = Remove-CutPiece -List $list -Index 1
        (Split-CutList -List $list -AtSeconds 30).Count | Should Be 2
    }
}

Describe "Remove-CutPiece" {
    It "removes a middle piece and leaves the outer two in order" {
        $list = Split-CutList -List (New-CutList -Duration 60) -AtSeconds 20
        $list = Split-CutList -List $list -AtSeconds 40
        $list = Remove-CutPiece -List $list -Index 1
        @($list).Count | Should Be 2
        $list[0].End | Should Be 20
        $list[1].Start | Should Be 40
    }

    It "returns an empty array, not null, when the last piece goes" {
        $list = Remove-CutPiece -List (New-CutList -Duration 60) -Index 0
        @($list).Count | Should Be 0
        ($null -eq $list) | Should Be $false
    }

    It "ignores an index that is not there" {
        (Remove-CutPiece -List (New-CutList -Duration 60) -Index 7).Count | Should Be 1
    }
}

Describe "Find-NearestKeyframe" {
    $kf = @(0.0, 0.25, 0.5, 0.75, 1.0)

    It "returns the closest keyframe below" {
        Find-NearestKeyframe -Keyframes $kf -Seconds 0.30 | Should Be 0.25
    }

    It "returns the closest keyframe above" {
        Find-NearestKeyframe -Keyframes $kf -Seconds 0.70 | Should Be 0.75
    }

    It "resolves an exact tie downward" {
        Find-NearestKeyframe -Keyframes $kf -Seconds 0.375 | Should Be 0.25
    }

    It "clamps below the first keyframe" {
        Find-NearestKeyframe -Keyframes $kf -Seconds -3 | Should Be 0.0
    }

    It "clamps past the last keyframe" {
        Find-NearestKeyframe -Keyframes $kf -Seconds 99 | Should Be 1.0
    }

    It "returns the requested time unchanged when there are no keyframes" {
        Find-NearestKeyframe -Keyframes @() -Seconds 4.2 | Should Be 4.2
    }
}
