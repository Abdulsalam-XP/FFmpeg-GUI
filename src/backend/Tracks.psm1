# Multi-track model for the Video Editor: pure model + graph builders. No UI state.
$script:TrackKinds = @("video-main", "audio-source", "audio-clip", "video-clip")

function New-TrimTrack {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$StreamIdx = 0,
        [string]$Label = "",
        [double]$Offset = 0.0,
        [double]$InStart = 0.0,
        [double]$InEnd = 0.0,
        [bool]$Muted = $false,
        [double]$GainDb = 0.0,
        [hashtable]$Pip = $null
    )
    if ($script:TrackKinds -notcontains $Kind) { throw "New-TrimTrack: unknown kind '$Kind'" }
    # Source kinds are time-locked to the video by design (spec): no offsets, no trims.
    $locked = ($Kind -eq "video-main" -or $Kind -eq "audio-source")
    return [PSCustomObject]@{
        Id        = [guid]::NewGuid().ToString("N")
        Kind      = $Kind
        Path      = $Path
        StreamIdx = $StreamIdx
        Label     = $Label
        Offset    = $(if ($locked) { 0.0 } else { [math]::Max(0.0, $Offset) })
        InStart   = $(if ($locked) { 0.0 } else { [math]::Max(0.0, $InStart) })
        InEnd     = $(if ($locked) { 0.0 } else { [math]::Max(0.0, $InEnd) })
        GainDb    = [math]::Max(-30.0, [math]::Min(30.0, $GainDb))
        Muted     = $Muted
        Pip       = $Pip
    }
}

# Parses `ffprobe -select_streams a -show_entries stream=index:stream_tags=title -of csv=p=0`
# output: one line per stream, "index" or "index,title".
function ConvertFrom-AudioStreamProbe {
    param([string[]]$Lines = @())
    $result = @()
    $ordinal = 0
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim() -split ",", 2
        $idx = 0
        if (-not [int]::TryParse($parts[0], [ref]$idx)) { continue }
        $ordinal++
        $label = if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) { $parts[1].Trim() } else { "Audio $ordinal" }
        $result += ,@{ StreamIdx = $idx; Label = $label }
    }
    if ($result.Count -eq 0) { return @() }
    return ,@($result)
}

function Get-DefaultTrackStack {
    param([Parameter(Mandatory = $true)][string]$Path, [object[]]$AudioStreams = @())
    $stack = @()
    $stack += ,(New-TrimTrack -Kind "video-main" -Path $Path -Label "Video")
    foreach ($s in @($AudioStreams)) {
        $stack += ,(New-TrimTrack -Kind "audio-source" -Path $Path -StreamIdx ([int]$s.StreamIdx) -Label ([string]$s.Label))
    }
    return ,@($stack)
}

Export-ModuleMember -Function New-TrimTrack, ConvertFrom-AudioStreamProbe, Get-DefaultTrackStack
