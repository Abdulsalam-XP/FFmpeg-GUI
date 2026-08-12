# Project persistence: cuts, fades and captions ride along next to the source video
# in "<video>.ffgui.json" so closing the app never throws away editing work.

function Get-TrimProjectPath {
    param([Parameter(Mandatory = $true)][string]$VideoPath)
    $dir = [System.IO.Path]::GetDirectoryName($VideoPath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    return [System.IO.Path]::Combine($dir, "$name.ffgui.json")
}

function Save-TrimProject {
    param(
        [Parameter(Mandatory = $true)][string]$VideoPath,
        [object[]]$CutList = @(),
        [hashtable]$Fades = @{},
        [object[]]$Captions = @(),
        [object[]]$Zooms = @(),
        [object[]]$Tracks = @(),
        [bool]$Unlinked = $false
    )
    try {
        $doc = [ordered]@{
            Version  = 2
            CutList  = @(@($CutList) | ForEach-Object { [ordered]@{ Start = $_.Start; End = $_.End } })
            Fades    = $Fades
            Captions = @(@($Captions) | ForEach-Object { $_ })
            Zooms    = @(@($Zooms) | ForEach-Object { $_ })
            Tracks   = @(@($Tracks) | ForEach-Object { $_ })
            Unlinked = $Unlinked
        }
        $json = $doc | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText((Get-TrimProjectPath -VideoPath $VideoPath), $json,
            (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Read-TrimProject {
    param([Parameter(Mandatory = $true)][string]$VideoPath)
    $path = Get-TrimProjectPath -VideoPath $VideoPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $doc -or $null -eq $doc.CutList -or $null -eq $doc.Captions) { return $null }
        # A file written by a newer schema is not ours to guess at -- the caller reports
        # "couldn't read the saved project" and starts fresh rather than half-loading it.
        if ($doc.Version -ne 1 -and $doc.Version -ne 2) { return $null }

        # ConvertFrom-Json yields PSCustomObjects; fades come back as an object whose
        # properties are the boundary keys -- rebuild the hashtable the panel expects.
        $fades = @{}
        if ($doc.Fades) {
            foreach ($p in $doc.Fades.PSObject.Properties) { $fades[$p.Name] = [double]$p.Value }
        }

        # Zoom keyframes: validate each entry individually; invalid ones drop but don't fail the load.
        $zooms = @()
        $droppedZooms = 0
        if ($doc.Zooms) {
            foreach ($z in @($doc.Zooms)) {
                try {
                    $time = [double]$z.Time
                    $cx = [double]$z.CX
                    $cy = [double]$z.CY
                    # New-model entries carry the box (W/H, fractions of the frame,
                    # 1/6..3.0); files from before the stretch rework carry a uniform
                    # Level (1..6) that maps onto both axes as 1/Level. Either shape
                    # loads; anything with neither drops.
                    if ($null -ne $z.PSObject.Properties["W"] -and $null -ne $z.PSObject.Properties["H"]) {
                        $bw = [double]$z.W
                        $bh = [double]$z.H
                    } else {
                        $level = [math]::Max(1.0, [math]::Min(6.0, [double]$z.Level))
                        $bw = 1.0 / $level
                        $bh = 1.0 / $level
                    }
                    # Clamp: W/H (1/6)..3.0, CX/CY 0.0..1.0 (double literals prevent truncation)
                    $bw = [math]::Max(1.0 / 6.0, [math]::Min(3.0, $bw))
                    $bh = [math]::Max(1.0 / 6.0, [math]::Min(3.0, $bh))
                    $cx = [math]::Max(0.0, [math]::Min(1.0, $cx))
                    $cy = [math]::Max(0.0, [math]::Min(1.0, $cy))
                    $id = if ($z.Id) { $z.Id } else { [guid]::NewGuid().ToString("N") }
                    $zooms += ,[PSCustomObject]@{ Id = $id; Time = $time; CX = $cx; CY = $cy; W = $bw; H = $bh }
                } catch {
                    $droppedZooms++
                }
            }
        }

        # Track stack: only present from schema v2 on. A v1 file has no Tracks key at all,
        # and that absence is the app's signal to build the default stack rather than a
        # signal that the saved stack is empty -- so this stays $null, not @().
        $tracks = $null
        $droppedTracks = 0
        $unlinked = $false
        if ($doc.Version -ge 2) {
            $unlinked = [bool]$doc.Unlinked
            $trackKinds = @("video-main", "audio-source", "audio-clip", "video-clip")
            $trackList = @()
            if ($doc.Tracks) {
                foreach ($t in @($doc.Tracks)) {
                    try {
                        $kind = [string]$t.Kind
                        if ($trackKinds -notcontains $kind) { throw "unknown kind" }
                        $id = if ($t.Id) { [string]$t.Id } else { [guid]::NewGuid().ToString("N") }
                        $path = [string]$t.Path
                        $streamIdx = [int]$t.StreamIdx
                        $label = [string]$t.Label
                        $offset = [double]$t.Offset
                        $inStart = [double]$t.InStart
                        $inEnd = [double]$t.InEnd
                        $muted = [bool]$t.Muted
                        # Clamp: GainDb -30.0..30.0 (double literals prevent truncation)
                        $gainDb = [math]::Max(-30.0, [math]::Min(30.0, [double]$t.GainDb))
                        # Pip is a free-form hashtable (X/Y/W/H fractions of the frame); rebuilt
                        # generically from whatever properties ConvertFrom-Json gave it rather than
                        # a fixed field list, so the reader does not silently drop fields the
                        # writer added later.
                        $pip = $null
                        if ($null -ne $t.PSObject.Properties["Pip"] -and $null -ne $t.Pip) {
                            $pip = @{}
                            foreach ($p in $t.Pip.PSObject.Properties) { $pip[$p.Name] = [double]$p.Value }
                        }
                        $trackList += ,[PSCustomObject]@{
                            Id = $id; Kind = $kind; Path = $path; StreamIdx = $streamIdx; Label = $label
                            Offset = $offset; InStart = $inStart; InEnd = $inEnd; GainDb = $gainDb; Muted = $muted; Pip = $pip
                        }
                    } catch {
                        $droppedTracks++
                    }
                }
            }
            $tracks = @($trackList)
        }

        return @{
            CutList       = @(@($doc.CutList) | ForEach-Object { [PSCustomObject]@{ Start = [double]$_.Start; End = [double]$_.End } })
            Fades         = $fades
            Captions      = @(@($doc.Captions) | ForEach-Object { $_ })
            Zooms         = @($zooms)
            DroppedZooms  = $droppedZooms
            Tracks        = $tracks
            DroppedTracks = $droppedTracks
            Unlinked      = $unlinked
        }
    } catch { return $null }
}

Export-ModuleMember -Function Get-TrimProjectPath, Save-TrimProject, Read-TrimProject
