# 80-look-nebula.ps1 -- the Carina Sea nebula sky.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

    function Add-LookNebulaFilament {
        param($Dc, $Rand, $W, $H, $K, $F)
        $x = [double]$F.X * $W
        $y = [double]$F.Y * $H
        $ang = [double]$F.Ang
        $n = [int]$F.N
        for ($i = 0; $i -lt $n; $i++) {
            $u = $i / [double]$n
            $ang = $ang + ($Rand.NextDouble() - 0.5) * [double]$F.Wobble
            $step = [double]$F.Step * $K * (0.6 + $Rand.NextDouble() * 0.8)
            $x = $x + [math]::Cos($ang) * $step
            $y = $y + [math]::Sin($ang) * $step
            $r = ([double]$F.R0 + ([double]$F.R1 - [double]$F.R0) * $u + $Rand.NextDouble() * [double]$F.Rj) * $K
            $col = $F.Colors[$Rand.Next(@($F.Colors).Count)]
            $jx = $x + ($Rand.NextDouble() - 0.5) * [double]$F.Spread * $K
            $jy = $y + ($Rand.NextDouble() - 0.5) * [double]$F.Spread * $K
            # WPF composites alpha-over (not the mockup's additive 'lighter'), so these
            # alphas run about twice the mockup's to land on the same visual density.
            $c0 = [System.Windows.Media.Color]::FromArgb([byte](255.0 * [double]$F.A), [byte]$col[0], [byte]$col[1], [byte]$col[2])
            $c1 = [System.Windows.Media.Color]::FromArgb([byte](255.0 * [double]$F.A * 0.4), [byte]$col[0], [byte]$col[1], [byte]$col[2])
            $c2 = [System.Windows.Media.Color]::FromArgb(0, [byte]$col[0], [byte]$col[1], [byte]$col[2])
            $gsc = New-Object System.Windows.Media.GradientStopCollection
            $gsc.Add((New-Object System.Windows.Media.GradientStop($c0, 0.0)))
            $gsc.Add((New-Object System.Windows.Media.GradientStop($c1, 0.6)))
            $gsc.Add((New-Object System.Windows.Media.GradientStop($c2, 1.0)))
            $rb = [System.Windows.Media.RadialGradientBrush]::new($gsc)
            $rb.Freeze()
            $Dc.DrawEllipse($rb, $null, (New-Object System.Windows.Point($jx, $jy)), $r, $r)
        }
    }

    function New-LookNebulaLayer {
        param($Rand, $Filaments, $Dust)
        $W = 1600.0; $H = 900.0; $K = 1.33
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        foreach ($f in $Filaments) { Add-LookNebulaFilament -Dc $dc -Rand $Rand -W $W -H $H -K $K -F $f }
        foreach ($d in @($Dust)) {
            if ($null -eq $d) { continue }
            $x = [double]$d.X * $W; $y = [double]$d.Y * $H; $ang = [double]$d.Ang
            for ($i = 0; $i -lt [int]$d.N; $i++) {
                $ang = $ang + ($Rand.NextDouble() - 0.5) * 0.8
                $x = $x + [math]::Cos($ang) * [double]$d.Step * $K
                $y = $y + [math]::Sin($ang) * [double]$d.Step * $K
                $r = [double]$d.R * $K * (0.6 + $Rand.NextDouble() * 0.8)
                $c0 = [System.Windows.Media.Color]::FromArgb([byte](255.0 * [double]$d.A), 6, 8, 14)
                $c2 = [System.Windows.Media.Color]::FromArgb(0, 6, 8, 14)
                $gsc = New-Object System.Windows.Media.GradientStopCollection
                $gsc.Add((New-Object System.Windows.Media.GradientStop($c0, 0.0)))
                $gsc.Add((New-Object System.Windows.Media.GradientStop($c2, 1.0)))
                $rb = [System.Windows.Media.RadialGradientBrush]::new($gsc)
                $rb.Freeze()
                $dc.DrawEllipse($rb, $null, (New-Object System.Windows.Point($x, $y)), $r, $r)
            }
        }
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(1600, 900, 96.0, 96.0, ([System.Windows.Media.PixelFormats]::Pbgra32))
        $rtb.Render($dv)
        $rtb.Freeze()
        return $rtb
    }

    function Add-LookNebulaSpikes {
        # Four tapered triangles radiating from (0,0), each fading to transparent at
        # the tip; $Angle rotates the whole set (45 = the faint secondary spikes).
        param($Parent, $L, $Wd, $Alpha, $Angle)
        $spikeSet = New-Object System.Windows.Controls.Canvas
        if ([double]$Angle -ne 0.0) {
            $spikeSet.RenderTransform = New-Object System.Windows.Media.RotateTransform([double]$Angle)
        }
        $hub = [System.Windows.Media.Color]::FromArgb([byte][int]$Alpha, 235, 244, 255)
        $tip = [System.Windows.Media.Color]::FromArgb(0, 235, 244, 255)
        foreach ($dir in @(0.0, 90.0, 180.0, 270.0)) {
            $poly = New-Object System.Windows.Shapes.Polygon
            $pc = New-Object System.Windows.Media.PointCollection
            $pc.Add((New-Object System.Windows.Point(0.0, -[double]$Wd)))
            $pc.Add((New-Object System.Windows.Point(0.0, [double]$Wd)))
            $pc.Add((New-Object System.Windows.Point([double]$L, 0.0)))
            $poly.Points = $pc
            $lg = New-Object System.Windows.Media.LinearGradientBrush($hub, $tip, 0.0)
            $lg.Freeze()
            $poly.Fill = $lg
            $poly.RenderTransform = New-Object System.Windows.Media.RotateTransform($dir)
            [void]$spikeSet.Children.Add($poly)
        }
        [void]$Parent.Children.Add($spikeSet)
    }

    function Start-LookNebulaShoot {
        param($T)
        $rand = $script:LookNebulaRand
        $starC = $script:LookNebulaStarCanvas
        if ($null -eq $starC -or $null -eq $rand) { return }
        $goRight = ($rand.NextDouble() -lt 0.5)
        $ang = (18.0 + $rand.NextDouble() * 20.0) * 0.0174533
        $spd = 1000.0 + $rand.NextDouble() * 500.0
        $vx = [math]::Cos($ang) * $spd * $(if ($goRight) { 1.0 } else { -1.0 })
        $vy = [math]::Sin($ang) * $spd
        $W = [double]$ctx.Window.ActualWidth
        if ($W -le 0) { $W = 2560.0 }
        $H = [double]$ctx.Window.ActualHeight
        if ($H -le 0) { $H = 1440.0 }
        $x0 = $(if ($goRight) { $rand.NextDouble() * $W * 0.5 } else { $W * 0.5 + $rand.NextDouble() * $W * 0.5 })
        $y0 = $rand.NextDouble() * $H * 0.35
        $tail = 130.0 + $rand.NextDouble() * 90.0
        $sc = New-Object System.Windows.Controls.Canvas
        # Tail: a thin triangle trailing BEHIND the head along -X, transparent at the
        # far end; the whole canvas is rotated onto the travel direction.
        $poly = New-Object System.Windows.Shapes.Polygon
        $pc = New-Object System.Windows.Media.PointCollection
        $pc.Add((New-Object System.Windows.Point(0.0, -1.7)))
        $pc.Add((New-Object System.Windows.Point(0.0, 1.7)))
        $pc.Add((New-Object System.Windows.Point(-$tail, 0.0)))
        $poly.Points = $pc
        $tailFar = [System.Windows.Media.Color]::FromArgb(0, 255, 255, 255)
        $tailHead = [System.Windows.Media.Color]::FromArgb(235, 255, 255, 255)
        $lg = New-Object System.Windows.Media.LinearGradientBrush($tailFar, $tailHead, 0.0)
        $lg.Freeze()
        $poly.Fill = $lg
        [void]$sc.Children.Add($poly)
        $head = New-Object System.Windows.Shapes.Ellipse
        $head.Width = 3.4; $head.Height = 3.4
        $head.Fill = [System.Windows.Media.Brushes]::White
        [System.Windows.Controls.Canvas]::SetLeft($head, -1.7)
        [System.Windows.Controls.Canvas]::SetTop($head, -1.7)
        [void]$sc.Children.Add($head)
        $sc.RenderTransform = New-Object System.Windows.Media.RotateTransform(([math]::Atan2($vy, $vx) * 57.2958))
        $sc.Opacity = 0.0
        [System.Windows.Controls.Canvas]::SetLeft($sc, $x0)
        [System.Windows.Controls.Canvas]::SetTop($sc, $y0)
        [void]$starC.Children.Add($sc)
        $script:LookNebulaShoot = @{ El = $sc; X = $x0; Y = $y0; VX = $vx; VY = $vy
                                     Age = 0.0; Life = 0.75 + $rand.NextDouble() * 0.5 }
        $script:LookNebulaShootCount = [int]$script:LookNebulaShootCount + 1
    }

    function Start-LookNebula {
        if ([string]$global:AppLook -ne "MidnightGold") { return }
        $nebGrid = $ctx.Window.FindName("GridLookNebula")
        if ($null -eq $nebGrid) { return }
        # The nebula replaces the four corner glows outright (user: "completely rework
        # the background").
        $nebGlows = $ctx.Window.FindName("GridBackgroundGlows")
        if ($null -ne $nebGlows) { $nebGlows.Visibility = "Collapsed" }
        $script:LookNebulaGrid = $nebGrid
        # Fixed seed: the same sky every launch, so the backdrop reads as a place, not
        # static noise.
        $rand = New-Object System.Random(20260814)
        $teal   = @(@(42,107,102), @(58,140,128), @(30,75,78))
        $tealHi = @(@(58,140,128), @(84,168,150), @(42,107,102))
        $tealLo = @(@(30,75,78), @(42,107,102))
        $gold   = @(@(199,154,85), @(166,124,62), @(138,107,58))
        $goldHi = @(@(232,217,168), @(199,154,85))
        $layerA = New-LookNebulaLayer -Rand $rand -Filaments @(
            @{ X=0.10; Y=0.30; Ang=0.3; N=170; Step=7; Wobble=0.8; Spread=120; R0=30; R1=64; Rj=26; A=0.10; Colors=$teal },
            @{ X=0.55; Y=0.75; Ang=3.6; N=130; Step=7; Wobble=0.9; Spread=110; R0=26; R1=56; Rj=22; A=0.09; Colors=$tealHi },
            @{ X=0.40; Y=0.85; Ang=4.9; N=110; Step=6; Wobble=0.7; Spread=55; R0=18; R1=40; Rj=16; A=0.12; Colors=$gold },
            @{ X=0.52; Y=0.90; Ang=4.6; N=80; Step=6; Wobble=0.6; Spread=40; R0=14; R1=30; Rj=12; A=0.13; Colors=$goldHi },
            @{ X=0.80; Y=0.20; Ang=2.4; N=90; Step=6; Wobble=1.0; Spread=80; R0=20; R1=44; Rj=18; A=0.08; Colors=$tealLo }
        ) -Dust @(
            @{ X=0.46; Y=0.70; Ang=4.4; N=30; Step=7; R=20; A=0.45 },
            @{ X=0.86; Y=0.60; Ang=2.0; N=24; Step=8; R=24; A=0.35 }
        )
        $layerB = New-LookNebulaLayer -Rand $rand -Filaments @(
            @{ X=0.25; Y=0.55; Ang=0.9; N=120; Step=7; Wobble=1.0; Spread=110; R0=24; R1=52; Rj=22; A=0.08; Colors=$tealHi },
            @{ X=0.60; Y=0.35; Ang=2.9; N=70; Step=6; Wobble=0.8; Spread=60; R0=16; R1=36; Rj=14; A=0.09; Colors=$goldHi }
        ) -Dust $null
        # Oversize by 40px on every side so the +/-16px drift never exposes an edge.
        $imgA = New-Object System.Windows.Controls.Image
        $imgA.Source = $layerA
        $imgA.Stretch = [System.Windows.Media.Stretch]::Fill
        $imgA.Margin = New-Object System.Windows.Thickness(-40.0)
        $ttA = New-Object System.Windows.Media.TranslateTransform
        $imgA.RenderTransform = $ttA
        [void]$nebGrid.Children.Add($imgA)
        $imgB = New-Object System.Windows.Controls.Image
        $imgB.Source = $layerB
        $imgB.Stretch = [System.Windows.Media.Stretch]::Fill
        $imgB.Margin = New-Object System.Windows.Thickness(-40.0)
        $imgB.Opacity = 0.85
        $ttB = New-Object System.Windows.Media.TranslateTransform
        $imgB.RenderTransform = $ttB
        [void]$nebGrid.Children.Add($imgB)
        $starCanvas = New-Object System.Windows.Controls.Canvas
        $starCanvas.ClipToBounds = $true
        [void]$nebGrid.Children.Add($starCanvas)
        $script:LookNebulaStarCanvas = $starCanvas
        $script:LookNebulaStars = New-Object System.Collections.ArrayList
        $script:LookNebulaBrights = New-Object System.Collections.ArrayList
        # Every star is a radial-gradient ellipse (hot core into a tinted halo), so the
        # glow is baked into the fill and costs nothing per frame.
        $coolCore = [System.Windows.Media.Color]::FromArgb(245, 255, 255, 255)
        $coolHalo = [System.Windows.Media.Color]::FromArgb(150, 190, 214, 245)
        $warmHalo = [System.Windows.Media.Color]::FromArgb(150, 239, 220, 178)
        $clear = [System.Windows.Media.Color]::FromArgb(0, 255, 255, 255)
        $coolGsc = New-Object System.Windows.Media.GradientStopCollection
        $coolGsc.Add((New-Object System.Windows.Media.GradientStop($coolCore, 0.0)))
        $coolGsc.Add((New-Object System.Windows.Media.GradientStop($coolHalo, 0.3)))
        $coolGsc.Add((New-Object System.Windows.Media.GradientStop($clear, 1.0)))
        $coolGlow = [System.Windows.Media.RadialGradientBrush]::new($coolGsc)
        $coolGlow.Freeze()
        $warmGsc = New-Object System.Windows.Media.GradientStopCollection
        $warmGsc.Add((New-Object System.Windows.Media.GradientStop($coolCore, 0.0)))
        $warmGsc.Add((New-Object System.Windows.Media.GradientStop($warmHalo, 0.3)))
        $warmGsc.Add((New-Object System.Windows.Media.GradientStop($clear, 1.0)))
        $warmGlow = [System.Windows.Media.RadialGradientBrush]::new($warmGsc)
        $warmGlow.Freeze()
        # Star positions live in a nominal 2600x1460 field (same convention as the
        # petals); ClipToBounds trims whatever falls outside a smaller window. ALL stars
        # drift and ALL twinkle, but cheaply: three depth-layer canvases each moved by
        # ONE TranslateTransform (near layer = bigger stars = faster, so the field has
        # parallax). Each star has a clone one period (2600px) to the right and the
        # transform wraps at -2600 -- the field is periodic, so the snap is invisible
        # (the window is narrower than the period, a star and its clone are never both
        # on screen).
        $NW = 2600.0; $NH = 1460.0
        $script:LookNebulaStarLayers = New-Object System.Collections.ArrayList
        $layerSpeeds = @(-9.5, -6.0, -3.2)
        $layerCounts = @(80, 85, 85)
        $layerSizes = @(2.6, 1.8, 1.1)
        for ($li = 0; $li -lt 3; $li++) {
            $layerCv = New-Object System.Windows.Controls.Canvas
            $layerTt = New-Object System.Windows.Media.TranslateTransform
            $layerCv.RenderTransform = $layerTt
            [void]$starCanvas.Children.Add($layerCv)
            [void]$script:LookNebulaStarLayers.Add(@{ TT = $layerTt; VX = [double]$layerSpeeds[$li] })
            for ($i = 0; $i -lt [int]$layerCounts[$li]; $i++) {
                $d = (1.0 + $rand.NextDouble() * [double]$layerSizes[$li]) * 3.0
                $fill = $(if ($rand.NextDouble() -lt 0.22) { $warmGlow } else { $coolGlow })
                $starBase = 0.4 + $rand.NextDouble() * 0.4
                $sx = $rand.NextDouble() * $NW
                $sy = $rand.NextDouble() * $NH
                $eA = New-Object System.Windows.Shapes.Ellipse
                $eA.Width = $d; $eA.Height = $d; $eA.Fill = $fill; $eA.Opacity = $starBase
                [System.Windows.Controls.Canvas]::SetLeft($eA, $sx)
                [System.Windows.Controls.Canvas]::SetTop($eA, $sy)
                [void]$layerCv.Children.Add($eA)
                $eB = New-Object System.Windows.Shapes.Ellipse
                $eB.Width = $d; $eB.Height = $d; $eB.Fill = $fill; $eB.Opacity = $starBase
                [System.Windows.Controls.Canvas]::SetLeft($eB, $sx + $NW)
                [System.Windows.Controls.Canvas]::SetTop($eB, $sy)
                [void]$layerCv.Children.Add($eB)
                [void]$script:LookNebulaStars.Add(@{
                    ElA = $eA; ElB = $eB; Base = $starBase
                    Amp = 0.1 + $rand.NextDouble() * 0.28
                    Sp = 0.4 + $rand.NextDouble() * 1.8; Ph = $rand.NextDouble() * 6.283 })
            }
        }
        $script:LookNebulaTwinkleIdx = 0
        # The photo stars: a hot core, a soft tinted glow, and TAPERED diffraction
        # spikes -- four triangles whose fill fades out toward the tip (never plain
        # constant-width lines, which read as a plus sign), plus faint 45-degree
        # secondaries.
        $brightSpecs = @(
            @{ X=0.375; Y=0.62; S=7.0; C=@(255,214,150); Ph=0.7 },
            @{ X=0.685; Y=0.205; S=5.2; C=@(220,238,255); Ph=2.6 },
            @{ X=0.155; Y=0.145; S=4.4; C=@(255,224,170); Ph=4.1 }
        )
        foreach ($bs in $brightSpecs) {
            $g = New-Object System.Windows.Controls.Canvas
            $R = [double]$bs.S * 7.0
            $glow = New-Object System.Windows.Shapes.Ellipse
            $glow.Width = $R * 2.0; $glow.Height = $R * 2.0
            $gc0 = [System.Windows.Media.Color]::FromArgb(210, [byte]$bs.C[0], [byte]$bs.C[1], [byte]$bs.C[2])
            $gc1 = [System.Windows.Media.Color]::FromArgb(65, [byte]$bs.C[0], [byte]$bs.C[1], [byte]$bs.C[2])
            $gc2 = [System.Windows.Media.Color]::FromArgb(0, [byte]$bs.C[0], [byte]$bs.C[1], [byte]$bs.C[2])
            $ggsc = New-Object System.Windows.Media.GradientStopCollection
            $ggsc.Add((New-Object System.Windows.Media.GradientStop($gc0, 0.0)))
            $ggsc.Add((New-Object System.Windows.Media.GradientStop($gc1, 0.3)))
            $ggsc.Add((New-Object System.Windows.Media.GradientStop($gc2, 1.0)))
            $grb = [System.Windows.Media.RadialGradientBrush]::new($ggsc)
            $grb.Freeze()
            $glow.Fill = $grb
            [System.Windows.Controls.Canvas]::SetLeft($glow, -$R)
            [System.Windows.Controls.Canvas]::SetTop($glow, -$R)
            [void]$g.Children.Add($glow)
            Add-LookNebulaSpikes -Parent $g -L ([double]$bs.S * 8.0) -Wd ([math]::Max(1.2, [double]$bs.S * 0.35)) -Alpha 235 -Angle 0.0
            Add-LookNebulaSpikes -Parent $g -L ([double]$bs.S * 3.5) -Wd ([math]::Max(0.9, [double]$bs.S * 0.22)) -Alpha 110 -Angle 45.0
            $core = New-Object System.Windows.Shapes.Ellipse
            $coreD = [double]$bs.S * 1.8
            $core.Width = $coreD; $core.Height = $coreD
            $core.Fill = [System.Windows.Media.Brushes]::White
            [System.Windows.Controls.Canvas]::SetLeft($core, -$coreD / 2.0)
            [System.Windows.Controls.Canvas]::SetTop($core, -$coreD / 2.0)
            [void]$g.Children.Add($core)
            $bx = [double]$bs.X * $NW
            $by = [double]$bs.Y * $NH
            [System.Windows.Controls.Canvas]::SetLeft($g, $bx)
            [System.Windows.Controls.Canvas]::SetTop($g, $by)
            [void]$starCanvas.Children.Add($g)
            [void]$script:LookNebulaBrights.Add(@{
                El = $g; X = $bx; Y = $by; VX = -(3.0 + $rand.NextDouble() * 2.0)
                Phase = [double]$bs.Ph })
        }
        $script:LookNebula = @{ A = $ttA; B = $ttB; BImg = $imgB }
        $script:LookNebulaRand = $rand
        $script:LookNebulaShoot = $null
        $script:LookNebulaShootCount = 0
        $script:LookNebulaNextShoot = 4.0
        if (-not $global:ShowAnimations) { return }
        $script:LookNebulaClock = 0.0
        $script:LookNebulaStamp = [datetime]::UtcNow
        $script:LookNebulaTimer = New-Object System.Windows.Threading.DispatcherTimer
        # 16ms = the same 60fps cadence as the petals (user: stars, comet and all at 60).
        $script:LookNebulaTimer.Interval = [timespan]::FromMilliseconds(16)
        $script:LookNebulaTimer.Add_Tick({ Update-LookNebula })
        $script:LookNebulaTimer.Start()
    }

    function Update-LookNebula {
        $now = [datetime]::UtcNow
        $dt = ($now - $script:LookNebulaStamp).TotalSeconds
        $script:LookNebulaStamp = $now
        if ($dt -le 0 -or $dt -gt 0.5) { return }
        if ($ctx.Window.WindowState -eq [System.Windows.WindowState]::Minimized) { return }
        $script:LookNebulaClock = $script:LookNebulaClock + $dt
        $t = $script:LookNebulaClock
        $nb = $script:LookNebula
        if ($null -eq $nb) { return }
        $nb.A.X = [math]::Sin($t * 0.045) * 14.0
        $nb.A.Y = [math]::Cos($t * 0.038) * 11.0
        $nb.B.X = [math]::Cos($t * 0.03) * -16.0
        $nb.B.Y = [math]::Sin($t * 0.05) * 12.0
        $nb.BImg.Opacity = 0.75 + 0.25 * [math]::Sin($t * 0.09)
        foreach ($sl in $script:LookNebulaStarLayers) {
            $sl.TT.X = $sl.TT.X + $sl.VX * $dt
            if ($sl.TT.X -le -2600.0) { $sl.TT.X = $sl.TT.X + 2600.0 }
        }
        # Twinkle a quarter of the field per tick (each star ~15Hz): the sine is slow,
        # so this is visually identical to per-tick while quartering the property
        # writes -- the loop is the only per-star cost in the whole sky.
        $stars = $script:LookNebulaStars
        $starCount = @($stars).Count
        if ($starCount -gt 0) {
            $q = [int][math]::Ceiling($starCount / 4.0)
            $idx = [int]$script:LookNebulaTwinkleIdx
            for ($qi = 0; $qi -lt $q; $qi++) {
                $s = $stars[($idx + $qi) % $starCount]
                $op = $s.Base + $s.Amp * [math]::Sin($t * $s.Sp + $s.Ph)
                $s.ElA.Opacity = $op
                $s.ElB.Opacity = $op
            }
            $script:LookNebulaTwinkleIdx = ($idx + $q) % $starCount
        }
        foreach ($b in $script:LookNebulaBrights) {
            $b.X = $b.X + $b.VX * $dt
            if ($b.X -lt -80.0) { $b.X = 2680.0 }
            [System.Windows.Controls.Canvas]::SetLeft($b.El, $b.X)
            [System.Windows.Controls.Canvas]::SetTop($b.El, $b.Y)
            $b.El.Opacity = 0.85 + 0.15 * [math]::Sin($t * 0.8 + $b.Phase)
        }
        if ($null -ne $script:LookNebulaShoot) {
            $sh = $script:LookNebulaShoot
            $sh.Age = $sh.Age + $dt
            $sh.X = $sh.X + $sh.VX * $dt
            $sh.Y = $sh.Y + $sh.VY * $dt
            if ($sh.Age -ge $sh.Life) {
                $script:LookNebulaStarCanvas.Children.Remove($sh.El)
                $script:LookNebulaShoot = $null
                $script:LookNebulaNextShoot = $t + 5.0 + $script:LookNebulaRand.NextDouble() * 9.0
            } else {
                $u = $sh.Age / $sh.Life
                $sh.El.Opacity = $(if ($u -lt 0.12) { $u / 0.12 } elseif ($u -gt 0.6) { (1.0 - $u) / 0.4 } else { 1.0 })
                [System.Windows.Controls.Canvas]::SetLeft($sh.El, $sh.X)
                [System.Windows.Controls.Canvas]::SetTop($sh.El, $sh.Y)
            }
        } elseif ($t -ge $script:LookNebulaNextShoot) {
            Start-LookNebulaShoot -T $t
        }
    }
    Start-LookNebula

