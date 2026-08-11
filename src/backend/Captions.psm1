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

Export-ModuleMember -Function New-Caption, ConvertTo-AssColor, ConvertTo-AssTime, ConvertTo-AssText
