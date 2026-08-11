# Caption model and ASS subtitle generation for the Video Editor.
# Pure functions only: no UI, no $script: panel state, fully unit-testable.

function New-Caption {
    param(
        [Parameter(Mandatory = $true)][double]$Start,
        [Parameter(Mandatory = $true)][double]$End,
        [string]$Text = ""
    )
    return [PSCustomObject]@{
        Id           = [guid]::NewGuid().ToString("N")
        Text         = $Text
        Start        = $Start
        End          = $End
        X            = 0.5
        Y            = 0.78
        FontSizeFrac = 0.055
        FontFamily   = "Arial"
        Bold         = $true
        FillColor    = "#FFFFFF"
        OutlineColor = "#000000"
        OutlineWidth = 3.0
        BounceIn     = $true
    }
}

# ASS stores colours blue-first (&H00BBGGRR); the UI stores web-order #RRGGBB.
function ConvertTo-AssColor {
    param([Parameter(Mandatory = $true)][string]$Hex)
    # Hand-edited project files reach this path with anything at all in the colour
    # fields; the preview already hardens the same boundary, so match it here rather
    # than letting Substring throw in the middle of an export.
    if ($Hex -notmatch '^#[0-9A-Fa-f]{6}$') { $Hex = "#FFFFFF" }
    $r = $Hex.Substring(1, 2); $g = $Hex.Substring(3, 2); $b = $Hex.Substring(5, 2)
    return ("&H00{0}{1}{2}" -f $b.ToUpper(), $g.ToUpper(), $r.ToUpper())
}

function ConvertTo-AssTime {
    param([Parameter(Mandatory = $true)][double]$Seconds)
    $ts = [timespan]::FromSeconds([math]::Max([double]0, $Seconds))
    $cs = [math]::Floor($ts.Milliseconds / 10)
    return ("{0}:{1:D2}:{2:D2}.{3:D2}" -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, [int]$cs)
}

# Braces open ASS override blocks and a backslash can start a control sequence (a user
# typing a literal "\N" would otherwise burn as a hard line break). One evaluator pass so
# the characters we INSERT are never rescanned: user "\" becomes "\{}" (backslash followed
# by an empty override block, which renders as a lone backslash and cannot pair with a
# following N/n/h), and braces become their escaped forms.
function ConvertTo-AssText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $t = [regex]::Replace($Text, '[\\{}]', {
        param($m)
        switch ($m.Value) {
            '\' { '\{}' }
            '{' { '\{' }
            '}' { '\}' }
        }
    })
    # Real newline characters (typed via the multi-line box) become ASS breaks; these are
    # control characters, untouched by the pass above.
    $t = $t -replace "`r`n", '\N' -replace "`n", '\N'
    return $t
}

# Merged, sorted source-space time ranges that need caption burning, clipped to the
# surviving pieces so a caption in deleted footage costs nothing.
function Get-CaptionSpans {
    param([object[]]$Captions = @(), [object[]]$Pieces = @())
    $raw = @()
    foreach ($cap in @($Captions)) {
        if (-not $cap -or [string]::IsNullOrWhiteSpace($cap.Text)) { continue }
        foreach ($p in @($Pieces)) {
            $s = [math]::Max([double]$cap.Start, [double]$p.Start)
            $e = [math]::Min([double]$cap.End, [double]$p.End)
            if ($e -gt $s) { $raw += ,@{ Start = $s; End = $e } }
        }
    }
    if ($raw.Count -eq 0) { return ,@() }
    $sorted = @($raw | Sort-Object { $_.Start })
    $merged = @($sorted[0])
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $last = $merged[$merged.Count - 1]
        if ($sorted[$i].Start -le $last.End) {
            $last.End = [math]::Max($last.End, $sorted[$i].End)
        } else {
            $merged += ,$sorted[$i]
        }
    }
    return ,@($merged)
}

# Splits the fade-aware segment plan further so caption ranges re-encode.
# Cut segments split at span boundaries; transitions already re-encode, so an
# overlapping caption just rides along on them via a Captions list.
function Split-TrimSegmentsForCaptions {
    param([object[]]$Segments = @(), [object[]]$Captions = @())

    $active = @(@($Captions) | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Text) })
    $result = @()
    foreach ($seg in @($Segments)) {
        $segStart = [double]$seg.Start
        $segEnd = $segStart + [double]$seg.Duration

        $overlapping = @($active | Where-Object { [double]$_.Start -lt $segEnd -and [double]$_.End -gt $segStart })

        if ($seg.Kind -ne "cut") {
            if ($overlapping.Count -gt 0) { $seg.Captions = $overlapping }
            $result += ,$seg
            continue
        }
        if ($overlapping.Count -eq 0) { $result += ,$seg; continue }

        # Span math local to this segment, using already-merged caption windows.
        $fakePiece = @([PSCustomObject]@{ Start = $segStart; End = $segEnd })
        $spans = Get-CaptionSpans -Captions $overlapping -Pieces $fakePiece
        $cursor = $segStart
        foreach ($span in $spans) {
            if ($span.Start -gt $cursor) {
                $result += ,@{ Kind = "cut"; Start = $cursor; Duration = ($span.Start - $cursor) }
            }
            $burnCaps = @($active | Where-Object { [double]$_.Start -lt $span.End -and [double]$_.End -gt $span.Start })
            $result += ,@{ Kind = "burn"; Start = $span.Start; Duration = ($span.End - $span.Start); Captions = $burnCaps }
            $cursor = $span.End
        }
        if ($cursor -lt $segEnd - 0.0005) {
            $result += ,@{ Kind = "cut"; Start = $cursor; Duration = ($segEnd - $cursor) }
        }
    }
    return ,@($result)
}

# Builds a complete .ass document. TimeOffset shifts caption times into segment-local
# time (the export burns per-segment files whose t=0 is the segment start).
function New-AssDocument {
    param(
        [object[]]$Captions = @(),
        [Parameter(Mandatory = $true)][int]$PlayResX,
        [Parameter(Mandatory = $true)][int]$PlayResY,
        [double]$TimeOffset = 0
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $styles = @{}       # styleKey -> style name
    $styleLines = @()
    $eventLines = @()
    foreach ($cap in @($Captions)) {
        if (-not $cap) { continue }
        if ([string]::IsNullOrWhiteSpace($cap.Text)) { continue }
        $s = [double]$cap.Start - $TimeOffset
        $e = [double]$cap.End - $TimeOffset
        if ($e -le 0 -or $e -le $s) { continue }
        if ($s -lt 0) { $s = 0 }

        $key = ("{0}|{1}|{2}|{3}|{4}|{5}" -f $cap.FontFamily, $cap.Bold, $cap.FillColor, $cap.OutlineColor, $cap.OutlineWidth, $cap.FontSizeFrac).ToUpperInvariant()
        if (-not $styles.ContainsKey($key)) {
            $name = "S{0}" -f $styles.Count
            $styles[$key] = $name
            $bold = if ($cap.Bold) { "-1" } else { "0" }
            $size = [int][math]::Floor($cap.FontSizeFrac * $PlayResY)
            $ow = ([double]$cap.OutlineWidth).ToString("0.##", $inv)
            $styleLines += ("Style: {0},{1},{2},{3},{4},{5},{6},{7},0,0,0,100,100,0,0,1,{8},0,5,0,0,0,1" -f `
                $name, $cap.FontFamily, $size,
                (ConvertTo-AssColor -Hex $cap.FillColor), (ConvertTo-AssColor -Hex $cap.FillColor),
                (ConvertTo-AssColor -Hex $cap.OutlineColor), (ConvertTo-AssColor -Hex $cap.OutlineColor),
                $bold, $ow)
        }

        $px = ([double]$cap.X * $PlayResX).ToString("0.#", $inv)
        $py = ([double]$cap.Y * $PlayResY).ToString("0.#", $inv)
        $ovr = "\an5\pos($px,$py)"
        if ($cap.BounceIn) {
            $ovr += "\fscx0\fscy0\t(0,80,\fscx130\fscy130)\t(80,150,\fscx100\fscy100)"
        }
        $eventLines += ("Dialogue: 0,{0},{1},{2},,0,0,0,,{{{3}}}{4}" -f `
            (ConvertTo-AssTime -Seconds $s), (ConvertTo-AssTime -Seconds $e),
            $styles[$key], $ovr, (ConvertTo-AssText -Text $cap.Text))
    }

    $header = @(
        "[Script Info]", "ScriptType: v4.00+",
        "PlayResX: $PlayResX", "PlayResY: $PlayResY", "WrapStyle: 0", "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
    )
    $mid = @("", "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")
    return (($header + $styleLines + $mid + $eventLines) -join "`r`n") + "`r`n"
}

Export-ModuleMember -Function New-Caption, ConvertTo-AssColor, ConvertTo-AssTime, ConvertTo-AssText, Get-CaptionSpans, Split-TrimSegmentsForCaptions, New-AssDocument
