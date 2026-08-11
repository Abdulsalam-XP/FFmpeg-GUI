$modulePath = Join-Path $PSScriptRoot "..\Zooms.psm1"
Import-Module $modulePath -Force

Describe "New-ZoomKeyframe" {
    It "creates a keyframe with identity box defaults and an id" {
        $k = New-ZoomKeyframe -Time 60
        $k.Time | Should Be 60
        $k.CX | Should Be 0.5
        $k.CY | Should Be 0.5
        $k.W | Should Be 1.0
        $k.H | Should Be 1.0
        $k.Id | Should Not Be $null
    }
    It "maps a legacy uniform Level onto both axes" {
        $k = New-ZoomKeyframe -Time 0 -Level 2
        $k.W | Should Be 0.5
        $k.H | Should Be 0.5
    }
    It "clamps a legacy level and the center" {
        $k = New-ZoomKeyframe -Time 0 -Level 9 -CX 1.4 -CY -0.2
        $k.W | Should Be (1.0 / 6.0)
        $k.CX | Should Be 1
        $k.CY | Should Be 0
    }
    It "clamps explicit box dimensions to 1/6..3" {
        $k = New-ZoomKeyframe -Time 0 -W 5.0 -H 0.01
        $k.W | Should Be 3.0
        $k.H | Should Be (1.0 / 6.0)
    }
    It "lets W and H differ - the stretch is the point" {
        $k = New-ZoomKeyframe -Time 0 -W 0.5 -H 0.8
        $k.W | Should Be 0.5
        $k.H | Should Be 0.8
    }
}

Describe "Test-ZoomIdentity / Get-ZoomKeyframeBox" {
    It "reads the box off a new-model keyframe" {
        $b = Get-ZoomKeyframeBox -Keyframe (New-ZoomKeyframe -Time 0 -W 0.5 -H 0.7)
        $b.W | Should Be 0.5
        $b.H | Should Be 0.7
    }
    It "converts an old-model Level-only object" {
        $legacy = [PSCustomObject]@{ Id = "x"; Time = 1.0; CX = 0.5; CY = 0.5; Level = 2.0 }
        $b = Get-ZoomKeyframeBox -Keyframe $legacy
        $b.W | Should Be 0.5
        $b.H | Should Be 0.5
    }
    It "treats the full frame as identity and anything else as not" {
        (Test-ZoomIdentity -W 1.0 -H 1.0) | Should Be $true
        (Test-ZoomIdentity -W 0.5 -H 1.0) | Should Be $false
        (Test-ZoomIdentity -W 1.0 -H 2.0) | Should Be $false
    }
}

Describe "Get-TrimZoomStateAt" {
    It "returns identity for no keyframes" {
        $s = Get-TrimZoomStateAt -Zooms @() -Seconds 10
        $s.W | Should Be 1.0
        $s.H | Should Be 1.0
        $s.CX | Should Be 0.5
    }
    It "is identity BEFORE the first keyframe - a zoom activates at its moment" {
        $k = New-ZoomKeyframe -Time 10 -W 0.5 -H 0.5 -CX 0.6 -CY 0.4
        $s = Get-TrimZoomStateAt -Zooms @($k) -Seconds 3
        $s.W | Should Be 1.0
        $s.CX | Should Be 0.5
    }
    It "takes the first keyframe's value exactly at its time" {
        $k = New-ZoomKeyframe -Time 10 -W 0.5 -H 0.5 -CX 0.6 -CY 0.4
        (Get-TrimZoomStateAt -Zooms @($k) -Seconds 10).W | Should Be 0.5
    }
    It "holds the last keyframe after it" {
        $a = New-ZoomKeyframe -Time 10
        $b = New-ZoomKeyframe -Time 12 -W 0.25 -H 0.25 -CX 0.7
        $s = Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 50
        $s.W | Should Be 0.25
        $s.CX | Should Be 0.7
    }
    It "interpolates the box linearly mid-glide, each axis on its own" {
        $a = New-ZoomKeyframe -Time 10 -W 1.0 -H 1.0 -CX 0.5 -CY 0.5
        $b = New-ZoomKeyframe -Time 14 -W 0.5 -H 0.8 -CX 0.7 -CY 0.3
        $s = Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 12
        $s.W | Should Be 0.75
        $s.H | Should Be 0.9
        $s.CX | Should Be 0.6
        $s.CY | Should Be 0.4
    }
    It "sorts keyframes by time regardless of list order" {
        $a = New-ZoomKeyframe -Time 14 -W 0.5 -H 0.5
        $b = New-ZoomKeyframe -Time 10 -W 1.0 -H 1.0
        (Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 12).W | Should Be 0.75
    }
    It "sits exactly on a keyframe" {
        $a = New-ZoomKeyframe -Time 10
        $b = New-ZoomKeyframe -Time 14 -W 0.25 -H 0.25
        (Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 14).W | Should Be 0.25
    }
    It "interpolates old-model keyframes through their converted boxes" {
        $a = [PSCustomObject]@{ Id = "a"; Time = 10.0; CX = 0.5; CY = 0.5; Level = 1.0 }
        $b = [PSCustomObject]@{ Id = "b"; Time = 14.0; CX = 0.5; CY = 0.5; Level = 2.0 }
        (Get-TrimZoomStateAt -Zooms @($a, $b) -Seconds 12).W | Should Be 0.75
    }
}

Describe "Get-TrimZoomSpans" {
    $pieces = @([PSCustomObject]@{ Start = 0.0; End = 100.0 })
    It "returns empty for identity zooms" {
        $k = New-ZoomKeyframe -Time 10
        (Get-TrimZoomSpans -Zooms @($k) -Pieces $pieces).Count | Should Be 0
    }
    It "extends a glide to its enclosing keyframes" {
        $a = New-ZoomKeyframe -Time 10
        $b = New-ZoomKeyframe -Time 14 -W 0.5 -H 0.5
        $c = New-ZoomKeyframe -Time 20
        $r = Get-TrimZoomSpans -Zooms @($a, $b, $c) -Pieces $pieces
        $r.Count | Should Be 1
        $r[0].Start | Should Be 10
        $r[0].End | Should Be 20
    }
    It "extends a held zoom to the end of the footage" {
        $a = New-ZoomKeyframe -Time 10
        $b = New-ZoomKeyframe -Time 14 -W 0.5 -H 0.5
        $r = Get-TrimZoomSpans -Zooms @($a, $b) -Pieces $pieces
        $r[0].End | Should Be 100
    }
    It "counts a pure stretch (one axis only) as a zoom" {
        $a = New-ZoomKeyframe -Time 10
        $b = New-ZoomKeyframe -Time 14 -W 0.6 -H 1.0
        (Get-TrimZoomSpans -Zooms @($a, $b) -Pieces $pieces).Count | Should Be 1
    }
    It "counts a zoom-OUT as a zoom" {
        $a = New-ZoomKeyframe -Time 10
        $b = New-ZoomKeyframe -Time 14 -W 2.0 -H 2.0
        (Get-TrimZoomSpans -Zooms @($a, $b) -Pieces $pieces).Count | Should Be 1
    }
    It "clips to surviving pieces" {
        $p = @([PSCustomObject]@{Start=0.0;End=12.0})
        $a = New-ZoomKeyframe -Time 10
        $b = New-ZoomKeyframe -Time 14 -W 0.5 -H 0.5
        (Get-TrimZoomSpans -Zooms @($a,$b) -Pieces $p)[0].End | Should Be 12
    }
    It "keeps its shape when assigned directly (return-shape guard)" {
        $a = New-ZoomKeyframe -Time 1 -W 0.5 -H 0.5
        $r = Get-TrimZoomSpans -Zooms @($a) -Pieces $pieces
        $r.Count | Should Be 1
        $r[0] -is [hashtable] | Should Be $true
    }
}

Describe "Split-TrimSegmentsForZooms" {
    It "splits a cut at span edges AND interior keyframes" {
        # keyframes 20(identity) 25(2x) 30(identity): span 20..30, interior keyframe at 25
        $z = @((New-ZoomKeyframe -Time 20), (New-ZoomKeyframe -Time 25 -W 0.5 -H 0.5), (New-ZoomKeyframe -Time 30))
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 60.0 })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $r.Count | Should Be 4
        $r[0].Kind | Should Be "cut";  $r[0].Duration | Should Be 20
        $r[1].Kind | Should Be "zoom"; $r[1].Start | Should Be 20; $r[1].Duration | Should Be 5
        $r[1].Zoom.W0 | Should Be 1; $r[1].Zoom.W1 | Should Be 0.5
        $r[2].Kind | Should Be "zoom"; $r[2].Zoom.W0 | Should Be 0.5; $r[2].Zoom.W1 | Should Be 1
        $r[3].Kind | Should Be "cut"; $r[3].Duration | Should Be 30
    }
    It "carries both axes through the tag - a stretch survives the split" {
        $z = @((New-ZoomKeyframe -Time 20), (New-ZoomKeyframe -Time 25 -W 0.5 -H 0.9))
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 60.0 })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $zoomPart = @($r | Where-Object { $_.Kind -eq "zoom" })[0]
        $zoomPart.Zoom.H1 | Should Be 0.9
        $zoomPart.Zoom.W1 | Should Be 0.5
    }
    It "attaches Zoom to an overlapping caption burn segment with no interior keyframe" {
        $z = @((New-ZoomKeyframe -Time 0 -W 0.5 -H 0.5))
        $segs = @(@{ Kind = "burn"; Start = 10.0; Duration = 5.0; Captions = @("x") })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $r.Count | Should Be 1
        $r[0].Kind | Should Be "burn"
        $r[0].Zoom.W0 | Should Be 0.5
    }
    It "splits a caption burn at interior zoom keyframes so the bump survives" {
        # caption 10..15 with a punch-in wholly inside it: 12(identity) 13(3x) 14(identity).
        # Sampling only the burn's own endpoints gave identity -> identity and lost the zoom.
        $z = @((New-ZoomKeyframe -Time 12), (New-ZoomKeyframe -Time 13 -Level 3), (New-ZoomKeyframe -Time 14))
        $segs = @(@{ Kind = "burn"; Start = 10.0; Duration = 5.0; Captions = @("x") })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $r.Count | Should Be 4
        @($r | Where-Object { $_.Kind -eq "burn" }).Count | Should Be 4
        @($r | Where-Object { $_.Captions }).Count | Should Be 4
        $r[0].Start | Should Be 10; $r[0].Duration | Should Be 2
        $r[0].ContainsKey("Zoom") | Should Be $false
        $r[1].Start | Should Be 12; $r[1].Duration | Should Be 1
        # Rounded: the endpoints come out of a lerp whose last ulp differs from a
        # directly-computed 1/3.
        $r[1].Zoom.W0 | Should Be 1; [math]::Round($r[1].Zoom.W1, 9) | Should Be ([math]::Round(1.0 / 3.0, 9))
        $r[2].Start | Should Be 13; $r[2].Duration | Should Be 1
        [math]::Round($r[2].Zoom.W0, 9) | Should Be ([math]::Round(1.0 / 3.0, 9)); $r[2].Zoom.W1 | Should Be 1
        $r[3].Start | Should Be 14; $r[3].Duration | Should Be 1
        $r[3].ContainsKey("Zoom") | Should Be $false
        $total = 0.0; foreach ($s in $r) { $total += $s.Duration }
        [math]::Round($total, 6) | Should Be 5
    }
    It "throws on a zoomed transition (pre-flight owns that refusal)" {
        $z = @((New-ZoomKeyframe -Time 0 -W 0.5 -H 0.5))
        $segs = @(@{ Kind = "transition"; Start = 10.0; NextStart = 50.0; Duration = 0.5 })
        { Split-TrimSegmentsForZooms -Segments $segs -Zooms $z } | Should Throw
    }
    It "throws on a zoom over the crossfade's INCOMING head, not just the outgoing tail" {
        $z = @((New-ZoomKeyframe -Time 40.2), (New-ZoomKeyframe -Time 40.5 -Level 3))
        $segs = @(@{ Kind = "transition"; Start = 29.5; NextStart = 40.0; Duration = 0.5 })
        { Split-TrimSegmentsForZooms -Segments $segs -Zooms $z } | Should Throw
    }
    It "conserves total duration across a split" {
        $z = @((New-ZoomKeyframe -Time 20), (New-ZoomKeyframe -Time 25 -Level 3))
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 60.0 })
        $r = Split-TrimSegmentsForZooms -Segments $segs -Zooms $z
        $total = 0.0; foreach ($s in $r) { $total += $s.Duration }
        [math]::Round($total, 6) | Should Be 60
    }
}

Describe "New-ZoomCropFilter" {
    It "emits constant crop for a constant uniform zoom" {
        $f = New-ZoomCropFilter -Zoom @{W0=0.5;W1=0.5;H0=0.5;H1=0.5;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 5 -Width 2560 -Height 1440
        $f | Should Be "crop=1280:720:640:360,scale=2560x1440,setsar=1"
    }
    It "emits a stretching crop when the axes differ" {
        # Half the width but the full height: the picture is stretched 2x horizontally.
        $f = New-ZoomCropFilter -Zoom @{W0=0.5;W1=0.5;H0=1.0;H1=1.0;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 5 -Width 2560 -Height 1440
        $f | Should Be "crop=1280:1440:640:0,scale=2560x1440,setsar=1"
    }
    It "emits t-interpolated expressions for a glide" {
        $f = New-ZoomCropFilter -Zoom @{W0=1.0;W1=0.5;H0=1.0;H1=0.5;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 4 -Width 2560 -Height 1440
        $f | Should Match $([regex]::Escape("trunc(2560/(1+(-0.5)*t/4)/2)*2"))
        $f | Should Match $([regex]::Escape("eval=frame"))
        $f | Should Match $([regex]::Escape("crop=2560:1440:"))
    }
    It "scales before cropping on a glide, because crop's w/h are configure-time only" {
        $f = New-ZoomCropFilter -Zoom @{W0=1.0;W1=0.5;H0=1.0;H1=0.5;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 4 -Width 2560 -Height 1440
        $f.IndexOf("scale=") | Should BeLessThan $f.IndexOf("crop=")
        # crop's w/h must be plain numbers: an expression in t there fails at configure time.
        $f | Should Not Match $([regex]::Escape("crop=iw"))
    }
    It "keeps iw and ih out of the whole glide chain, which crop resolves only once" {
        $f = New-ZoomCropFilter -Zoom @{W0=0.7;W1=0.55;H0=0.7;H1=0.55;CX0=0.55;CX1=0.6;CY0=0.4;CY1=0.4} -Duration 3 -Width 2560 -Height 1440
        # crop caches iw/ih at configure time, so with a per-frame scale in front of it any
        # iw in x/y silently tracks the FIRST frame's width and the zoom drifts off centre.
        # The rework restates everything from literal source dimensions instead.
        $f | Should Not Match "iw"
        $f | Should Not Match "ih"
        $f | Should Match $([regex]::Escape("trunc(2560/(0.7+(-0.15)*t/3)/2)*2"))
    }
    It "backslash-escapes the commas inside a glide expression" {
        $f = New-ZoomCropFilter -Zoom @{W0=1.0;W1=0.5;H0=1.0;H1=0.5;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 4 -Width 2560 -Height 1440
        # Every comma that is NOT a filter separator has to be escaped, or the graph
        # parser reads "max(a,0)" as the end of one filter and a new filter called "0)".
        # 2 unescaped: the scale/crop and crop/setsar separators. 4 escaped: the min/max pairs.
        ([regex]::Matches($f, "(?<!\\),")).Count | Should Be 2
        ([regex]::Matches($f, "\\,")).Count | Should Be 4
    }
    It "clamps the crop window inside the frame" {
        $f = New-ZoomCropFilter -Zoom @{W0=0.5;W1=0.5;H0=0.5;H1=0.5;CX0=1.0;CX1=1.0;CY0=0.0;CY1=0.0} -Duration 5 -Width 2560 -Height 1440
        # cx=1.0 at 2x would put x beyond iw-ow=1280; must clamp to 1280 / 0
        $f | Should Be "crop=1280:720:1280:0,scale=2560x1440,setsar=1"
    }
    It "pads first on a zoom-out so the window always fits" {
        $f = New-ZoomCropFilter -Zoom @{W0=2.0;W1=2.0;H0=2.0;H1=2.0;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 5 -Width 2560 -Height 1440
        # padW = 2*ceil((2560*2+8)/2) = 5128, padH = 2*ceil((1440*2+8)/2) = 2888,
        # centred: padX 1284, padY 724.
        $f | Should Match "^pad=5128:2888:1284:724:black,"
        $f | Should Match $([regex]::Escape("crop=2560:1440:"))
    }
    It "does not pad a pure zoom-in glide" {
        $f = New-ZoomCropFilter -Zoom @{W0=1.0;W1=0.5;H0=1.0;H1=0.5;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 4 -Width 2560 -Height 1440
        $f | Should Not Match "pad="
    }
    It "writes dot decimals under a comma-decimal culture" {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
            $w = 1.0 / 1.5
            $f = New-ZoomCropFilter -Zoom @{W0=$w;W1=$w;H0=$w;H1=$w;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 5 -Width 2560 -Height 1440
            $f | Should Match "1706"
            $f | Should Not Match "1,5"
            $f | Should Not Match "0,5"
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
    It "writes dot decimals under a comma-decimal culture on the glide branch" {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
            $f = New-ZoomCropFilter -Zoom @{W0=0.65;W1=0.4;H0=0.65;H1=0.4;CX0=0.4;CX1=0.6;CY0=0.5;CY1=0.5} -Duration 2.5 -Width 2560 -Height 1440
            $f | Should Match $([regex]::Escape("0.65"))
            $f | Should Match $([regex]::Escape("0.4"))
            $f | Should Not Match "0,65"
            $f | Should Not Match "0,4"
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
    It "throws when Duration is zero instead of emitting a broken t/0 expression" {
        { New-ZoomCropFilter -Zoom @{W0=1.0;W1=0.5;H0=1.0;H1=0.5;CX0=0.5;CX1=0.5;CY0=0.5;CY1=0.5} -Duration 0 -Width 100 -Height 100 } | Should Throw
    }
}
