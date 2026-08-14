# Project persistence: cuts, fades and captions ride along next to the source video
# in "<video>.ffgui.json" so closing the app never throws away editing work.

# Where project saves live: the app's own assets\projects folder, NOT beside the
# recordings (user ask 2026-08-14 -- the sidecars were cluttering the recordings dir).
# Tests and special hosts can point the store elsewhere.
$script:TrimProjectStore = [System.IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), "assets", "projects")

function Set-TrimProjectStore {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:TrimProjectStore = $Path
}

function Get-TrimProjectStore { return $script:TrimProjectStore }

function Get-TrimProjectPath {
    param([Parameter(Mandatory = $true)][string]$VideoPath)
    # Leaf + a short path hash: the leaf keeps the file recognizable in the store, the
    # hash keeps two same-named clips in different folders from sharing one save.
    $name = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($VideoPath.ToLowerInvariant()))
    $hash = -join (@($bytes[0], $bytes[1], $bytes[2], $bytes[3]) | ForEach-Object { $_.ToString("x2") })
    return [System.IO.Path]::Combine($script:TrimProjectStore, "$name-$hash.ffgui.json")
}

# The pre-2026-08-14 location: a sidecar next to the video. Still READ (and migrated
# into the store) so no one's existing edits are lost by the move.
function Get-TrimLegacyProjectPath {
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
        [object[]]$Lanes = @()
    )
    try {
        $doc = [ordered]@{
            Version  = 3
            CutList  = @(@($CutList) | ForEach-Object { [ordered]@{ Start = $_.Start; End = $_.End } })
            Fades    = $Fades
            Captions = @(@($Captions) | ForEach-Object { $_ })
            Zooms    = @(@($Zooms) | ForEach-Object { $_ })
            Lanes    = @(@($Lanes) | ForEach-Object { $_ })
        }
        $json = $doc | ConvertTo-Json -Depth 8
        if (-not (Test-Path -LiteralPath $script:TrimProjectStore)) {
            New-Item -ItemType Directory -Path $script:TrimProjectStore -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Get-TrimProjectPath -VideoPath $VideoPath), $json,
            (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Read-TrimProject {
    param([Parameter(Mandatory = $true)][string]$VideoPath)
    $path = Get-TrimProjectPath -VideoPath $VideoPath
    if (-not (Test-Path -LiteralPath $path)) {
        # One-time migration: an old sidecar beside the video is relocated into the
        # store, then read from there. If the move fails (locked, read-only folder),
        # reading it in place still works -- the next Save writes to the store.
        $legacy = Get-TrimLegacyProjectPath -VideoPath $VideoPath
        if (-not (Test-Path -LiteralPath $legacy)) { return $null }
        try {
            if (-not (Test-Path -LiteralPath $script:TrimProjectStore)) {
                New-Item -ItemType Directory -Path $script:TrimProjectStore -Force | Out-Null
            }
            Move-Item -LiteralPath $legacy -Destination $path -Force
        } catch { $path = $legacy }
    }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $doc -or $null -eq $doc.CutList -or $null -eq $doc.Captions) { return $null }
        # A file written by a newer schema is not ours to guess at -- the caller reports
        # "couldn't read the saved project" and starts fresh rather than half-loading it.
        if ($doc.Version -lt 1 -or $doc.Version -gt 3) { return $null }

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
                            # Same clamp as the v3 lane reader below: a corrupt Pip (zeroed
                            # or hand-edited) must never reach ffmpeg as scale=0:0.
                            $pip.W = [math]::Max(0.05, [math]::Min(1.0, [double]$pip.W))
                            $pip.H = [math]::Max(0.05, [math]::Min(1.0, [double]$pip.H))
                            $pip.X = [math]::Max([double]$pip.W / 2.0, [math]::Min(1.0 - [double]$pip.W / 2.0, [double]$pip.X))
                            $pip.Y = [math]::Max([double]$pip.H / 2.0, [math]::Min(1.0 - [double]$pip.H / 2.0, [double]$pip.Y))
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

        $lanes = $null
        $droppedClips = 0
        if ($doc.Version -eq 2) {
            # v2 -> v3 migration (spec 6): tracks map onto lanes; Unlinked is discarded.
            $linkId = [guid]::NewGuid().ToString("N")
            $laneList = @()
            $mainTracks = @($trackList | Where-Object { $_.Kind -eq "video-main" })
            if ($mainTracks.Count -gt 0) {
                $vclip = [PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "video"; Path = $mainTracks[0].Path
                    StreamIdx = -1; LinkId = $linkId; Offset = 0.0; InStart = 0.0; InEnd = 0.0
                    DurationOverride = 0.0; GainDb = 0.0; Muted = $false; Pip = $null; Enabled = $true }
                $laneList += ,[PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "video"
                    Label = [System.IO.Path]::GetFileName([string]$mainTracks[0].Path); IsMain = $true; Clips = @($vclip) }
            }
            foreach ($t in @($trackList | Where-Object { $_.Kind -eq "audio-source" })) {
                $aclip = [PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "audio"; Path = $t.Path
                    StreamIdx = [int]$t.StreamIdx; LinkId = $(if ($mainTracks.Count -gt 0) { $linkId } else { "" })
                    Offset = 0.0; InStart = 0.0; InEnd = 0.0; DurationOverride = 0.0
                    GainDb = [double]$t.GainDb; Muted = [bool]$t.Muted; Pip = $null; Enabled = $true }
                $laneList += ,[PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "audio"
                    Label = [string]$t.Label; IsMain = $false; Clips = @($aclip) }
            }
            foreach ($t in @($trackList | Where-Object { $_.Kind -eq "video-clip" })) {
                # One lane per v2 clip track: two v2 pips could overlap in time, which one
                # shared lane cannot represent. Pip preserved -> they stay boxed.
                $vclip = [PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "video"; Path = $t.Path
                    StreamIdx = -1; LinkId = ""; Offset = [double]$t.Offset; InStart = [double]$t.InStart; InEnd = [double]$t.InEnd
                    DurationOverride = 0.0; GainDb = 0.0; Muted = $false; Pip = $t.Pip; Enabled = $true }
                $laneList += ,[PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "video"
                    Label = [string]$t.Label; IsMain = $false; Clips = @($vclip) }
            }
            foreach ($t in @($trackList | Where-Object { $_.Kind -eq "audio-clip" })) {
                $aclip = [PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "audio"; Path = $t.Path
                    StreamIdx = -1; LinkId = ""; Offset = [double]$t.Offset; InStart = [double]$t.InStart; InEnd = [double]$t.InEnd
                    DurationOverride = 0.0; GainDb = [double]$t.GainDb; Muted = [bool]$t.Muted; Pip = $null; Enabled = $true }
                $laneList += ,[PSCustomObject]@{ Id = [guid]::NewGuid().ToString("N"); Kind = "audio"
                    Label = [string]$t.Label; IsMain = $false; Clips = @($aclip) }
            }
            $lanes = @($laneList)
        } elseif ($doc.Version -eq 3) {
            $laneList = @()
            $seenMain = $false
            $laneKinds = @("video", "audio")
            if ($doc.Lanes) {
                foreach ($ln in @($doc.Lanes)) {
                    try {
                        $lk = [string]$ln.Kind
                        if ($laneKinds -notcontains $lk) { throw "unknown lane kind" }
                        $clipList = @()
                        $allowed = @(if ($lk -eq "video") { @("video", "image") } else { @("audio") })
                        if ($ln.Clips) {
                            foreach ($cl in @($ln.Clips)) {
                                try {
                                    $ck = [string]$cl.Kind
                                    if ($allowed -notcontains $ck) { throw "clip kind not allowed on this lane" }
                                    $pip = $null
                                    if ($null -ne $cl.PSObject.Properties["Pip"] -and $null -ne $cl.Pip) {
                                        $pip = @{}
                                        foreach ($p in $cl.Pip.PSObject.Properties) { $pip[$p.Name] = [double]$p.Value }
                                        # Backlog item: clamp W/H then X/Y on READ (double literals).
                                        $pip.W = [math]::Max(0.05, [math]::Min(1.0, [double]$pip.W))
                                        $pip.H = [math]::Max(0.05, [math]::Min(1.0, [double]$pip.H))
                                        $pip.X = [math]::Max([double]$pip.W / 2.0, [math]::Min(1.0 - [double]$pip.W / 2.0, [double]$pip.X))
                                        $pip.Y = [math]::Max([double]$pip.H / 2.0, [math]::Min(1.0 - [double]$pip.H / 2.0, [double]$pip.Y))
                                    }
                                    $dur = [double]$cl.DurationOverride
                                    if ($ck -eq "image") { $dur = [math]::Max(0.2, $(if ($dur -le 0.0) { 5.0 } else { $dur })) } else { $dur = 0.0 }
                                    $clipList += ,[PSCustomObject]@{
                                        Id = $(if ($cl.Id) { [string]$cl.Id } else { [guid]::NewGuid().ToString("N") })
                                        Kind = $ck; Path = [string]$cl.Path; StreamIdx = [int]$cl.StreamIdx
                                        LinkId = [string]$cl.LinkId
                                        Offset = [math]::Max(0.0, [double]$cl.Offset)
                                        InStart = [math]::Max(0.0, [double]$cl.InStart)
                                        InEnd = [math]::Max(0.0, [double]$cl.InEnd)
                                        DurationOverride = $dur
                                        GainDb = [math]::Max(-30.0, [math]::Min(30.0, [double]$cl.GainDb))
                                        Muted = [bool]$cl.Muted; Pip = $pip
                                        Enabled = $(if ($null -ne $cl.PSObject.Properties["Enabled"]) { [bool]$cl.Enabled } else { $true })
                                    }
                                } catch { $droppedClips++ }
                            }
                        }
                        $isMain = ($null -ne $ln.PSObject.Properties["IsMain"] -and [bool]$ln.IsMain -and -not $seenMain)
                        if ($isMain) { $seenMain = $true }
                        $laneList += ,[PSCustomObject]@{
                            Id = $(if ($ln.Id) { [string]$ln.Id } else { [guid]::NewGuid().ToString("N") })
                            Kind = $lk; Label = [string]$ln.Label; IsMain = $isMain; Clips = @($clipList)
                        }
                    } catch {
                        $droppedClips += @(if ($ln.Clips) { @($ln.Clips) } else { @() }).Count
                    }
                }
            }
            $lanes = @($laneList)
        }

        return @{
            CutList      = @(@($doc.CutList) | ForEach-Object { [PSCustomObject]@{ Start = [double]$_.Start; End = [double]$_.End } })
            Fades        = $fades
            Captions     = @(@($doc.Captions) | ForEach-Object { $_ })
            Zooms        = @($zooms)
            DroppedZooms = $droppedZooms
            Lanes        = $lanes
            DroppedClips = $droppedClips
        }
    } catch { return $null }
}

Export-ModuleMember -Function Get-TrimProjectPath, Get-TrimLegacyProjectPath, `
    Set-TrimProjectStore, Get-TrimProjectStore, Save-TrimProject, Read-TrimProject
