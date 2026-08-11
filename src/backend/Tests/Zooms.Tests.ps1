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

Describe "Get-TrimZoomSpans" {
    $pieces = @([PSCustomObject]@{ Start = 0.0; End = 100.0 })
    It "returns empty for identity zooms" {
        $k = New-ZoomKeyframe -Time 10 -Level 1
        (Get-TrimZoomSpans -Zooms @($k) -Pieces $pieces).Count | Should Be 0
    }
    It "extends a glide to its enclosing keyframes" {
        $a = New-ZoomKeyframe -Time 10 -Level 1
        $b = New-ZoomKeyframe -Time 14 -Level 2
        $c = New-ZoomKeyframe -Time 20 -Level 1
        $r = Get-TrimZoomSpans -Zooms @($a, $b, $c) -Pieces $pieces
        $r.Count | Should Be 1
        $r[0].Start | Should Be 10
        $r[0].End | Should Be 20
    }
    It "extends a held zoom to the end of the footage" {
        $a = New-ZoomKeyframe -Time 10 -Level 1
        $b = New-ZoomKeyframe -Time 14 -Level 2
        $r = Get-TrimZoomSpans -Zooms @($a, $b) -Pieces $pieces
        $r[0].End | Should Be 100
    }
    It "clips to surviving pieces" {
        $p = @([PSCustomObject]@{Start=0.0;End=12.0})
        $a = New-ZoomKeyframe -Time 10 -Level 1
        $b = New-ZoomKeyframe -Time 14 -Level 2
        (Get-TrimZoomSpans -Zooms @($a,$b) -Pieces $p)[0].End | Should Be 12
    }
    It "keeps its shape when assigned directly (return-shape guard)" {
        $a = New-ZoomKeyframe -Time 1 -Level 2
        $r = Get-TrimZoomSpans -Zooms @($a) -Pieces $pieces
        $r.Count | Should Be 1
        $r[0] -is [hashtable] | Should Be $true
    }
}

Describe "Split-TrimSegmentsForZooms" {
    It "splits a cut at span edges AND interior keyframes" {
        # keyframes 20(1x) 25(2x) 30(1x): span 20..30, interior keyframe at 25
        $z = @((New-ZoomKeyframe -Time 20 -Level 1), (New-ZoomKeyframe -Time 25 -Level 2), (New-ZoomKeyframe -Time 30 -Level 1))
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 60.0 })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $r.Count | Should Be 4
        $r[0].Kind | Should Be "cut";  $r[0].Duration | Should Be 20
        $r[1].Kind | Should Be "zoom"; $r[1].Start | Should Be 20; $r[1].Duration | Should Be 5
        $r[1].Zoom.Z0 | Should Be 1; $r[1].Zoom.Z1 | Should Be 2
        $r[2].Kind | Should Be "zoom"; $r[2].Zoom.Z0 | Should Be 2; $r[2].Zoom.Z1 | Should Be 1
        $r[3].Kind | Should Be "cut"; $r[3].Duration | Should Be 30
    }
    It "attaches Zoom to an overlapping caption burn segment instead of splitting it" {
        $z = @((New-ZoomKeyframe -Time 0 -Level 2))
        $segs = @(@{ Kind = "burn"; Start = 10.0; Duration = 5.0; Captions = @("x") })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $r.Count | Should Be 1
        $r[0].Kind | Should Be "burn"
        $r[0].Zoom.Z0 | Should Be 2
    }
    It "throws on a zoomed transition (pre-flight owns that refusal)" {
        $z = @((New-ZoomKeyframe -Time 0 -Level 2))
        $segs = @(@{ Kind = "transition"; Start = 10.0; NextStart = 50.0; Duration = 0.5 })
        { Split-TrimSegmentsForZooms -Segments $segs -Zooms $z } | Should Throw
    }
    It "conserves total duration across a split" {
        $z = @((New-ZoomKeyframe -Time 20 -Level 1), (New-ZoomKeyframe -Time 25 -Level 3))
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 60.0 })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $total = 0.0; foreach ($s in $r) { $total += $s.Duration }
        [math]::Round($total, 6) | Should Be 60
    }
}

Describe "New-ZoomCropFilter" {
    It "emits constant crop for a constant zoom" {
        $f = New-ZoomCropFilter -Zoom @{Z0=2.0;Z1=2.0;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 5 -Width 2560 -Height 1440
        $f | Should Be "crop=1280:720:640:360,scale=2560x1440,setsar=1"
    }
    It "emits t-interpolated expressions for a glide" {
        $f = New-ZoomCropFilter -Zoom @{Z0=1.0;Z1=2.0;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 4 -Width 2560 -Height 1440
        $f | Should Match $([regex]::Escape("iw/(1+(1)*t/4)"))
        $f | Should Match "scale=2560x1440"
    }
    It "clamps the crop window inside the frame" {
        $f = New-ZoomCropFilter -Zoom @{Z0=2.0;Z1=2.0;CX0=1.0;CX1=1.0;CY0=0.0;CY1=0.0} -Duration 5 -Width 2560 -Height 1440
        # cx=1.0 at 2x would put x at 1920+... beyond iw-ow=1280; must clamp to 1280 / 0
        $f | Should Be "crop=1280:720:1280:0,scale=2560x1440,setsar=1"
    }
    It "writes dot decimals under a comma-decimal culture" {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
            $f = New-ZoomCropFilter -Zoom @{Z0=1.5;Z1=1.5;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 5 -Width 2560 -Height 1440
            $f | Should Match "1706"
            $f | Should Not Match "1,5"
            $f | Should Not Match "0,5"
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
}
