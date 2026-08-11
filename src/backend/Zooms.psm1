# Zoom keyframes for the Video Editor: pure model + interpolation. No UI state.

function New-ZoomKeyframe {
    param(
        [Parameter(Mandatory = $true)][double]$Time,
        [double]$CX = 0.5,
        [double]$CY = 0.5,
        [double]$Level = 1.0
    )
    return [PSCustomObject]@{
        Id    = [guid]::NewGuid().ToString("N")
        Time  = $Time
        CX    = [math]::Max(0.0, [math]::Min(1.0, $CX))
        CY    = [math]::Max(0.0, [math]::Min(1.0, $CY))
        Level = [math]::Max(1.0, [math]::Min(6.0, $Level))
    }
}

# The glide: linear between neighbouring keyframes, held flat outside them.
function Get-TrimZoomStateAt {
    param([object[]]$Zooms = @(), [Parameter(Mandatory = $true)][double]$Seconds)
    $ks = @(@($Zooms) | Where-Object { $_ } | Sort-Object { [double]$_.Time })
    if ($ks.Count -eq 0) { return @{ Level = 1.0; CX = 0.5; CY = 0.5 } }
    if ($Seconds -le [double]$ks[0].Time) {
        return @{ Level = [double]$ks[0].Level; CX = [double]$ks[0].CX; CY = [double]$ks[0].CY }
    }
    $last = $ks[$ks.Count - 1]
    if ($Seconds -ge [double]$last.Time) {
        return @{ Level = [double]$last.Level; CX = [double]$last.CX; CY = [double]$last.CY }
    }
    for ($i = 0; $i -lt $ks.Count - 1; $i++) {
        $a = $ks[$i]; $b = $ks[$i + 1]
        if ($Seconds -ge [double]$a.Time -and $Seconds -le [double]$b.Time) {
            $span = [double]$b.Time - [double]$a.Time
            $f = if ($span -le 0) { 1.0 } else { ($Seconds - [double]$a.Time) / $span }
            return @{
                Level = [double]$a.Level + ([double]$b.Level - [double]$a.Level) * $f
                CX    = [double]$a.CX + ([double]$b.CX - [double]$a.CX) * $f
                CY    = [double]$a.CY + ([double]$b.CY - [double]$a.CY) * $f
            }
        }
    }
    return @{ Level = 1.0; CX = 0.5; CY = 0.5 }
}

Export-ModuleMember -Function New-ZoomKeyframe, Get-TrimZoomStateAt
