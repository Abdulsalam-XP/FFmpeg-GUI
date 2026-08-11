$modulePath = Join-Path $PSScriptRoot "..\Captions.psm1"
Import-Module $modulePath -Force

Describe "New-Caption" {
    It "creates a caption with the spec defaults" {
        $c = New-Caption -Start 12.4 -End 14.1 -Text "nice shot"
        $c.Start | Should Be 12.4
        $c.End | Should Be 14.1
        $c.Text | Should Be "nice shot"
        $c.X | Should Be 0.5
        $c.Y | Should Be 0.78
        $c.FontSizeFrac | Should Be 0.055
        $c.FontFamily | Should Be "Arial"
        $c.Bold | Should Be $true
        $c.FillColor | Should Be "#FFFFFF"
        $c.OutlineColor | Should Be "#000000"
        $c.OutlineWidth | Should Be 3
        $c.BounceIn | Should Be $true
    }
    It "gives every caption a distinct id" {
        (New-Caption -Start 0 -End 1).Id | Should Not Be (New-Caption -Start 0 -End 1).Id
    }
}

Describe "ConvertTo-AssColor" {
    It "converts RGB hex to ASS BGR" {
        ConvertTo-AssColor -Hex "#FFAA33" | Should Be "&H0033AAFF"
    }
    It "handles white and black" {
        ConvertTo-AssColor -Hex "#FFFFFF" | Should Be "&H00FFFFFF"
        ConvertTo-AssColor -Hex "#000000" | Should Be "&H00000000"
    }
    It "falls back to white for a malformed colour instead of throwing" {
        ConvertTo-AssColor -Hex "red" | Should Be "&H00FFFFFF"
    }
}

Describe "ConvertTo-AssTime" {
    It "formats zero" { ConvertTo-AssTime -Seconds 0 | Should Be "0:00:00.00" }
    It "formats minutes and centiseconds" {
        ConvertTo-AssTime -Seconds 74.35 | Should Be "0:01:14.35"
    }
    It "formats hours" { ConvertTo-AssTime -Seconds 3723.5 | Should Be "1:02:03.50" }
    It "truncates rather than rounds centiseconds at the edge" {
        ConvertTo-AssTime -Seconds 74.999 | Should Be "0:01:14.99"
    }
}

Describe "ConvertTo-AssText" {
    It "escapes braces so user text cannot inject override tags" {
        ConvertTo-AssText -Text "a{b}c" | Should Be "a\{b\}c"
    }
    It "turns newlines into ASS line breaks" {
        ConvertTo-AssText -Text "line1`r`nline2" | Should Be "line1\Nline2"
        ConvertTo-AssText -Text "line1`nline2" | Should Be "line1\Nline2"
    }
    It "passes plain text through, emoji included" {
        ConvertTo-AssText -Text "gg wp" | Should Be "gg wp"
    }
}

Describe "New-AssDocument" {
    $cap = New-Caption -Start 10 -End 12 -Text "nice shot"

    It "emits script info with the source resolution" {
        $doc = New-AssDocument -Captions @($cap) -PlayResX 2560 -PlayResY 1440
        $doc | Should Match "PlayResX: 2560"
        $doc | Should Match "PlayResY: 1440"
    }
    It "positions via an5 pos computed from the fractions" {
        # X 0.5, Y 0.78 on 2560x1440 -> pos(1280,1123.2)
        $doc = New-AssDocument -Captions @($cap) -PlayResX 2560 -PlayResY 1440
        $doc | Should Match "\\an5\\pos\(1280,1123\.2\)"
    }
    It "computes font size from FontSizeFrac times PlayResY" {
        # 0.055 * 1440 = 79.2 -> 79
        $doc = New-AssDocument -Captions @($cap) -PlayResX 2560 -PlayResY 1440
        $doc | Should Match ",79,"
    }
    It "adds the bounce override when BounceIn is set" {
        $doc = New-AssDocument -Captions @($cap) -PlayResX 2560 -PlayResY 1440
        $doc | Should Match "\\fscx0\\fscy0\\t\(0,80,\\fscx130\\fscy130\)\\t\(80,150,\\fscx100\\fscy100\)"
    }
    It "omits the bounce override when BounceIn is off" {
        $flat = New-Caption -Start 1 -End 2 -Text "x"
        $flat.BounceIn = $false
        (New-AssDocument -Captions @($flat) -PlayResX 100 -PlayResY 100) | Should Not Match "fscx0"
    }
    It "shifts times by TimeOffset for segment-local files" {
        $doc = New-AssDocument -Captions @($cap) -PlayResX 100 -PlayResY 100 -TimeOffset 9.5
        $doc | Should Match $([regex]::Escape("0:00:00.50,0:00:02.50"))
    }
    It "dedupes styles for captions sharing a look" {
        $a = New-Caption -Start 0 -End 1 -Text "a"
        $b = New-Caption -Start 2 -End 3 -Text "b"
        $doc = New-AssDocument -Captions @($a, $b) -PlayResX 100 -PlayResY 100
        ([regex]::Matches($doc, "^Style:", "Multiline")).Count | Should Be 1
    }
    It "skips empty-text captions" {
        $e = New-Caption -Start 0 -End 1 -Text "   "
        $doc = New-AssDocument -Captions @($e, $cap) -PlayResX 100 -PlayResY 100
        ([regex]::Matches($doc, "^Dialogue:", "Multiline")).Count | Should Be 1
    }
    It "gives two styles to captions differing only in size" {
        $a = New-Caption -Start 0 -End 1 -Text "a"
        $b = New-Caption -Start 2 -End 3 -Text "b"
        $b.FontSizeFrac = 0.1
        $doc = New-AssDocument -Captions @($a, $b) -PlayResX 100 -PlayResY 100
        ([regex]::Matches($doc, "^Style:", "Multiline")).Count | Should Be 2
    }
    It "writes dot-decimal numbers even under a comma-decimal culture" {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
            $cap = New-Caption -Start 10 -End 12 -Text "locale"
            $doc = New-AssDocument -Captions @($cap) -PlayResX 2560 -PlayResY 1440
            $doc | Should Match "\\pos\(1280,1123\.2\)"
            $doc | Should Not Match "\\pos\(1280,1123,2\)"
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig
        }
    }
}

Describe "Get-CaptionSpans" {
    $pieces = @([PSCustomObject]@{ Start = 0.0; End = 100.0 })
    It "returns one span per caption, clipped to pieces" {
        $c = New-Caption -Start 10 -End 12 -Text "x"
        $r = Get-CaptionSpans -Captions @($c) -Pieces $pieces
        $r.Count | Should Be 1
        $r[0].Start | Should Be 10
        $r[0].End | Should Be 12
    }
    It "merges overlapping captions into one span" {
        $a = New-Caption -Start 10 -End 14 -Text "a"
        $b = New-Caption -Start 12 -End 16 -Text "b"
        $r = Get-CaptionSpans -Captions @($a, $b) -Pieces $pieces
        $r.Count | Should Be 1
        $r[0].End | Should Be 16
    }
    It "drops a caption wholly inside deleted footage" {
        $twoPieces = @([PSCustomObject]@{Start=0.0;End=10.0}, [PSCustomObject]@{Start=50.0;End=60.0})
        $c = New-Caption -Start 20 -End 25 -Text "gone"
        (Get-CaptionSpans -Captions @($c) -Pieces $twoPieces).Count | Should Be 0
    }
    It "clips a caption straddling a piece edge" {
        $p = @([PSCustomObject]@{Start=0.0;End=10.0})
        $c = New-Caption -Start 8 -End 15 -Text "clip me"
        $r = Get-CaptionSpans -Captions @($c) -Pieces $p
        $r[0].End | Should Be 10
    }
    It "ignores empty-text captions" {
        $e = New-Caption -Start 1 -End 2
        (Get-CaptionSpans -Captions @($e) -Pieces $pieces).Count | Should Be 0
    }
    It "keeps its shape when assigned directly (return-shape guard)" {
        $c = New-Caption -Start 1 -End 2 -Text "x"
        $r = Get-CaptionSpans -Captions @($c) -Pieces $pieces
        $r.Count | Should Be 1
        $r[0] -is [hashtable] | Should Be $true
    }
}

Describe "Split-TrimSegmentsForCaptions" {
    It "splits a cut segment into copy-burn-copy around a caption" {
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 60.0 })
        $c = New-Caption -Start 20 -End 25 -Text "x"
        $r = Split-TrimSegmentsForCaptions -Segments $segs -Captions @($c)
        $r.Count | Should Be 3
        $r[0].Kind | Should Be "cut";  $r[0].Start | Should Be 0;  $r[0].Duration | Should Be 20
        $r[1].Kind | Should Be "burn"; $r[1].Start | Should Be 20; $r[1].Duration | Should Be 5
        @($r[1].Captions).Count | Should Be 1
        $r[2].Kind | Should Be "cut";  $r[2].Start | Should Be 25; $r[2].Duration | Should Be 35
    }
    It "leaves segments untouched with no captions" {
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 60.0 })
        $r = Split-TrimSegmentsForCaptions -Segments $segs -Captions @()
        $r.Count | Should Be 1
        $r[0].Kind | Should Be "cut"
    }
    It "attaches captions to an overlapping transition instead of splitting it" {
        $segs = @(@{ Kind = "transition"; Start = 9.5; NextStart = 50.0; Duration = 0.5 })
        $c = New-Caption -Start 9.0 -End 9.8 -Text "over the fade"
        $r = Split-TrimSegmentsForCaptions -Segments $segs -Captions @($c)
        $r.Count | Should Be 1
        $r[0].Kind | Should Be "transition"
        @($r[0].Captions).Count | Should Be 1
    }
    It "produces a burn covering the whole segment when the caption does" {
        $segs = @(@{ Kind = "cut"; Start = 10.0; Duration = 5.0 })
        $c = New-Caption -Start 8 -End 20 -Text "wide"
        $r = Split-TrimSegmentsForCaptions -Segments $segs -Captions @($c)
        $r.Count | Should Be 1
        $r[0].Kind | Should Be "burn"
    }
    It "handles two separate captions in one segment" {
        $segs = @(@{ Kind = "cut"; Start = 0.0; Duration = 100.0 })
        $a = New-Caption -Start 10 -End 15 -Text "a"
        $b = New-Caption -Start 40 -End 45 -Text "b"
        $r = Split-TrimSegmentsForCaptions -Segments $segs -Captions @($a, $b)
        $r.Count | Should Be 5
        ($r | Where-Object { $_.Kind -eq "burn" }).Count | Should Be 2
    }
}
