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
    $r = $Hex.Substring(1, 2); $g = $Hex.Substring(3, 2); $b = $Hex.Substring(5, 2)
    return ("&H00{0}{1}{2}" -f $b.ToUpper(), $g.ToUpper(), $r.ToUpper())
}

function ConvertTo-AssTime {
    param([Parameter(Mandatory = $true)][double]$Seconds)
    $ts = [timespan]::FromSeconds([math]::Max([double]0, $Seconds))
    $cs = [math]::Floor($ts.Milliseconds / 10)
    return ("{0}:{1:D2}:{2:D2}.{3:D2}" -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, [int]$cs)
}

# Braces open ASS override blocks; a user typing "{" must not be able to inject tags.
function ConvertTo-AssText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $t = $Text -replace '\{', '\{' -replace '\}', '\}'
    $t = $t -replace "`r`n", '\N' -replace "`n", '\N'
    return $t
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

Export-ModuleMember -Function New-Caption, ConvertTo-AssColor, ConvertTo-AssTime, ConvertTo-AssText, New-AssDocument
