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
    It "attaches Zoom to an overlapping caption burn segment with no interior keyframe" {
        $z = @((New-ZoomKeyframe -Time 0 -Level 2))
        $segs = @(@{ Kind = "burn"; Start = 10.0; Duration = 5.0; Captions = @("x") })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $r.Count | Should Be 1
        $r[0].Kind | Should Be "burn"
        $r[0].Zoom.Z0 | Should Be 2
    }
    It "splits a caption burn at interior zoom keyframes so the bump survives" {
        # caption 10..15 with a punch-in wholly inside it: 12(1x) 13(3x) 14(1x).
        # Sampling only the burn's own endpoints gave 1x -> 1x and lost the zoom.
        $z = @((New-ZoomKeyframe -Time 12 -Level 1), (New-ZoomKeyframe -Time 13 -Level 3), (New-ZoomKeyframe -Time 14 -Level 1))
        $segs = @(@{ Kind = "burn"; Start = 10.0; Duration = 5.0; Captions = @("x") })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $r.Count | Should Be 4
        @($r | Where-Object { $_.Kind -eq "burn" }).Count | Should Be 4
        @($r | Where-Object { $_.Captions }).Count | Should Be 4
        $r[0].Start | Should Be 10; $r[0].Duration | Should Be 2
        $r[0].ContainsKey("Zoom") | Should Be $false
        $r[1].Start | Should Be 12; $r[1].Duration | Should Be 1
        $r[1].Zoom.Z0 | Should Be 1; $r[1].Zoom.Z1 | Should Be 3
        $r[2].Start | Should Be 13; $r[2].Duration | Should Be 1
        $r[2].Zoom.Z0 | Should Be 3; $r[2].Zoom.Z1 | Should Be 1
        $r[3].Start | Should Be 14; $r[3].Duration | Should Be 1
        $r[3].ContainsKey("Zoom") | Should Be $false
        $total = 0.0; foreach ($s in $r) { $total += $s.Duration }
        [math]::Round($total, 6) | Should Be 5
    }
    It "throws on a zoomed transition (pre-flight owns that refusal)" {
        $z = @((New-ZoomKeyframe -Time 0 -Level 2))
        $segs = @(@{ Kind = "transition"; Start = 10.0; NextStart = 50.0; Duration = 0.5 })
        { Split-TrimSegmentsForZooms -Segments $segs -Zooms $z } | Should Throw
    }
    It "throws on a zoom over the crossfade's INCOMING head, not just the outgoing tail" {
        $z = @((New-ZoomKeyframe -Time 40.2 -Level 1), (New-ZoomKeyframe -Time 40.5 -Level 3))
        $segs = @(@{ Kind = "transition"; Start = 29.5; NextStart = 40.0; Duration = 0.5 })
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
        $f | Should Match $([regex]::Escape("trunc(iw*(1+(1)*t/4)/2)*2"))
        $f | Should Match $([regex]::Escape("eval=frame"))
        $f | Should Match $([regex]::Escape("crop=2560:1440:"))
    }
    It "scales before cropping on a glide, because crop's w/h are configure-time only" {
        $f = New-ZoomCropFilter -Zoom @{Z0=1.0;Z1=2.0;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 4 -Width 2560 -Height 1440
        $f.IndexOf("scale=") | Should BeLessThan $f.IndexOf("crop=")
        # crop's w/h must be plain numbers: an expression in t there fails at configure time.
        $f | Should Not Match $([regex]::Escape("crop=iw"))
    }
    It "keeps iw/ih out of the crop's x and y, which crop resolves only once" {
        $f = New-ZoomCropFilter -Zoom @{Z0=1.4;Z1=1.8;CX0=0.55;CX1=0.6;CY0=0.4;CY1=0.4} -Duration 3 -Width 2560 -Height 1440
        $cropPart = $f.Substring($f.IndexOf("crop="))
        # crop caches iw/ih at configure time, so with a per-frame scale in front of it any
        # iw in x/y silently tracks the FIRST frame's width and the zoom drifts off centre.
        $cropPart | Should Not Match "iw"
        $cropPart | Should Not Match "ih"
        $f | Should Match $([regex]::Escape("trunc(2560*(1.4+(0.4)*t/3)/2)*2"))
    }
    It "backslash-escapes the commas inside a glide expression" {
        $f = New-ZoomCropFilter -Zoom @{Z0=1.0;Z1=2.0;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 4 -Width 2560 -Height 1440
        # Every comma that is NOT a filter separator has to be escaped, or the graph
        # parser reads "max(a,0)" as the end of one filter and a new filter called "0)".
        # 2 unescaped: the scale/crop and crop/setsar separators. 4 escaped: the min/max pairs.
        ([regex]::Matches($f, "(?<!\\),")).Count | Should Be 2
        ([regex]::Matches($f, "\\,")).Count | Should Be 4
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
    It "writes dot decimals under a comma-decimal culture on the glide branch" {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
            $f = New-ZoomCropFilter -Zoom @{Z0=1.5;Z1=2.5;CX0=0.4;CX1=0.6;CY0=0.5;CY1=0.5} -Duration 2.5 -Width 2560 -Height 1440
            $f | Should Match $([regex]::Escape("1.5"))
            $f | Should Match $([regex]::Escape("0.4"))
            $f | Should Not Match "1,5"
            $f | Should Not Match "0,4"
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
    It "throws when Duration is zero instead of emitting a broken t/0 expression" {
        { New-ZoomCropFilter -Zoom @{Z0=1.0;Z1=2.0;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 0 -Width 100 -Height 100 } | Should Throw
    }
}
