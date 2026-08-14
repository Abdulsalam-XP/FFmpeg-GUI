# 65-media-cache.ps1 -- thumbnails, strip/waveform jobs, keyframe read.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

    function Set-TrimKeyframes {
        param([double[]]$Keyframes)
        $script:TrimKeyframes = $Keyframes
    }

    # Filmstrip thumbnails for the timeline pieces. Keyed by source-file second (rounded,
    # since a piece's thumbnail times are fixed once drawn and only change on split/delete,
    # not on zoom/pan) so the same frame is never extracted twice. $script:TrimThumbPending
    # tracks in-flight requests so a redraw mid-extraction doesn't queue duplicates.
    function Set-TrimThumbnail {
        param([string]$Key, [string]$FilePath)
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.UriSource = New-Object System.Uri($FilePath)
        $img.EndInit()
        $img.Freeze()
        $script:TrimThumbCache[$Key] = $img
        $script:TrimThumbPending.Remove($Key)
        Update-TrimTimeline
    }

    # One background job per missing frame, same shape as Start-TrimKeyframeRead below.
    # Extraction is cheap (a keyframe-index seek, not a decode of everything before it),
    # and a trim session only ever needs a few dozen thumbnails at once, so there is
    # nothing to gain from a shared worker queue here.
    function Request-TrimThumbnail {
        param([string]$File, [double]$Seconds)
        $key = "{0:N2}" -f $Seconds
        if ($script:TrimThumbCache.ContainsKey($key) -or $script:TrimThumbPending.ContainsKey($key)) { return }
        # Ceiling on concurrent extractions. Now that thumbnail times follow the viewport,
        # spinning the wheel through a dozen zoom levels asks for a fresh set at each one,
        # and every request is its own runspace plus ffmpeg process. The dropped requests
        # are not lost: the next redraw re-asks for whatever is still missing, and by then
        # the view has settled, so what actually gets extracted is the level the user
        # stopped on rather than every level they passed through.
        if ($script:TrimThumbPending.Count -ge 12) { return }
        $script:TrimThumbPending[$key] = $true

        $outFile = Join-Path $script:TrimThumbDir ("t{0}.jpg" -f ($key -replace '[^\d]', ''))
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file, $seconds, $outFile)
            Import-Module $modulePath -Force
            Export-TrimThumbnail -InputFile $file -Seconds $seconds -OutputFile $outFile
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($File).AddArgument($Seconds).AddArgument($outFile) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(120)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()
            if (Test-Path $outFile) {
                Set-TrimThumbnail -Key $key -FilePath $outFile
            } else {
                Remove-TrimThumbPending -Key $key
            }
        }.GetNewClosure())
        $watcher.Start()
    }

    # ---- Row media: filmstrip frames and per row waveforms -----------------------
    # Audio rows carry their own waveforms now and video clips carry filmstrips, so a
    # freshly loaded stack asks for a dozen renders on its first paint. Both kinds go
    # through ONE queue driven by ONE pump timer that keeps exactly one ffmpeg job in
    # flight (the "skip if a job is running" guard) -- same DispatcherTimer shape as
    # Request-TrimThumbnail's watcher, but shared, because a runspace-per-request here
    # would put ten ffmpeg processes on the box at once.
    function Get-TrimMediaHash {
        param([string]$Text)
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try {
            $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
        } finally { $md5.Dispose() }
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    }

    # A file's identity for cache-key purposes: size + last write time. A re-encode that
    # keeps the same name still gets a fresh key.
    function Get-TrimMediaStamp {
        param([string]$Path)
        try {
            $fi = New-Object System.IO.FileInfo([string]$Path)
            if (-not $fi.Exists) { return "0|0" }
            return ("{0}|{1}" -f $fi.Length, $fi.LastWriteTimeUtc.Ticks)
        } catch { return "0|0" }
    }

    # One directory per (file, in-point, out-point): the trimmed range IS part of the
    # key, so a completed edge-trim asks for a different eight frames and an undo lands
    # straight back on the cached set.
    function Get-TrimStripCacheDir {
        param([string]$Path, [double]$InStart, [double]$EffInEnd, [int]$Frames = 8)
        # Frames is part of the key: a cut-space piece asks for fewer than eight frames,
        # and a 3-frame set sharing a directory with an 8-frame set would read as a
        # half-rendered strip forever.
        $key = "{0}|{1}|{2:N1}|{3:N1}|f{4}" -f $Path, (Get-TrimMediaStamp -Path $Path), $InStart, $EffInEnd, $Frames
        return (Join-Path $env:LOCALAPPDATA ("FFmpegGUI\stripcache\" + (Get-TrimMediaHash -Text $key)))
    }

    function Add-TrimRowMediaJob {
        param([hashtable]$Job)
        $key = [string]$Job.Key
        if ($script:TrimRowMediaClaimed.ContainsKey($key)) { return }
        $script:TrimRowMediaClaimed[$key] = $true
        [void]$script:TrimStripPending.Add($Job)
        Start-TrimRowMediaPump
    }

    function Start-TrimRowMediaPump {
        if ($null -eq $script:TrimRowMediaTimer) {
            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [timespan]::FromMilliseconds(120)
            # No GetNewClosure: the tick body is a real top-level function, so its
            # $script: reads and writes hit the real script scope.
            $timer.Add_Tick({ Invoke-TrimRowMediaTick })
            $script:TrimRowMediaTimer = $timer
        }
        if (-not $script:TrimRowMediaTimer.IsEnabled) { $script:TrimRowMediaTimer.Start() }
    }

    function Invoke-TrimRowMediaTick {
        $job = $script:TrimRowMediaJob
        if ($null -ne $job) {
            # Skip-if-running guard, exactly as the thumbnail watcher's first line.
            if (-not $job.Handle.IsCompleted) { return }
            try { $job.PS.EndInvoke($job.Handle) | Out-Null } catch { }
            $job.PS.Dispose()
            $script:TrimRowMediaJob = $null
            if (Test-Path -LiteralPath ([string]$job.OutFile)) {
                if ([string]$job.Kind -eq "wave") { Set-TrimRowWaveform -Key ([string]$job.Key) -FilePath ([string]$job.OutFile) }
                $script:TrimRowMediaDirty = $true
            }
            # A render that produced nothing (unreadable file, no such stream) keeps its
            # claimed key, so the next redraw does not re-queue the same doomed job.
        }
        if (@($script:TrimStripPending).Count -eq 0) {
            $script:TrimRowMediaTimer.Stop()
            if ($script:TrimRowMediaDirty -and -not (Test-TrimClipDrag) -and -not (Test-TrimLaneGainDrag)) {
                $script:TrimRowMediaDirty = $false
                Update-TrimLaneRows
            }
            return
        }
        $next = $script:TrimStripPending[0]
        $script:TrimStripPending.RemoveAt(0)
        $script:TrimRowMediaJob = Start-TrimRowMediaJob -Job $next
    }

    function Start-TrimRowMediaJob {
        param([hashtable]$Job)
        $modulePath = Join-Path $scriptRoot "backend\VideoTrimmer.psm1"
        $ps = [powershell]::Create()
        if ([string]$Job.Kind -eq "wave") {
            $waveJobColor = $(if ($Job.ContainsKey("Color")) { [string]$Job.Color } else { "#3E9B84" })
            $ps.AddScript({
                param($modulePath, $file, $streamIndex, $start, $duration, $width, $height, $outFile, $color)
                Import-Module $modulePath -Force
                Export-TrimWaveform -InputFile $file -StreamIndex $streamIndex -StartSeconds $start `
                    -DurationSeconds $duration -Width $width -Height $height -OutputFile $outFile -Color $color
            }).AddArgument($modulePath).AddArgument([string]$Job.Path).AddArgument([int]$Job.StreamIndex).
              AddArgument([double]$Job.Start).AddArgument([double]$Job.Duration).AddArgument([int]$Job.Width).
              AddArgument([int]$Job.Height).AddArgument([string]$Job.OutFile).AddArgument($waveJobColor) | Out-Null
        } else {
            $ps.AddScript({
                param($modulePath, $file, $seconds, $outFile)
                Import-Module $modulePath -Force
                Export-TrimThumbnail -InputFile $file -Seconds $seconds -OutputFile $outFile -Height 80
            }).AddArgument($modulePath).AddArgument([string]$Job.Path).AddArgument([double]$Job.Seconds).
              AddArgument([string]$Job.OutFile) | Out-Null
        }
        return @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = [string]$Job.Kind; Key = [string]$Job.Key; OutFile = [string]$Job.OutFile }
    }

    # Write-through for the pump tick (which runs inside a DispatcherTimer handler).
    # Deliberately does NOT redraw: the tick decides when a redraw is due, so a render
    # landing mid-draw can never re-enter Update-TrimLaneRows.
    function Set-TrimRowWaveform {
        param([string]$Key, [string]$FilePath)
        try {
            $img = New-Object System.Windows.Media.Imaging.BitmapImage
            $img.BeginInit()
            $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $img.UriSource = New-Object System.Uri($FilePath)
            $img.EndInit()
            $img.Freeze()
            $script:TrimWaveCache[$Key] = $img
        } catch { }
    }

    # Decoded once per file path: a row rebuild happens on every selection change, and
    # re-decoding eight JPEGs per clip each time is what would make that feel slow.
    function Get-TrimStripImage {
        param([string]$FilePath)
        if ($script:TrimStripImages.ContainsKey($FilePath)) { return $script:TrimStripImages[$FilePath] }
        try {
            $img = New-Object System.Windows.Media.Imaging.BitmapImage
            $img.BeginInit()
            $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $img.UriSource = New-Object System.Uri($FilePath)
            $img.EndInit()
            $img.Freeze()
            $script:TrimStripImages[$FilePath] = $img
            return $img
        } catch { return $null }
    }

    # Eight frames across the clip's VISIBLE range, at the middle of each eighth so the
    # first and last cells are frames of the clip rather than its boundaries. Returns the
    # eight bitmaps once they all exist, $null (having queued the missing ones) until then.
    function Request-TrimClipStrip {
        param([string]$Path, [double]$InStart, [double]$EffInEnd, [int]$Frames = 8)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        $n = [math]::Max(1, [math]::Min(8, $Frames))
        $dir = Get-TrimStripCacheDir -Path $Path -InStart $InStart -EffInEnd $EffInEnd -Frames $n
        $files = @()
        $missing = @()
        for ($k = 0; $k -lt $n; $k++) {
            $f = Join-Path $dir ("strip{0}.jpg" -f $k)
            $files += ,$f
            if (-not (Test-Path -LiteralPath $f)) { $missing += ,$k }
        }
        if (@($missing).Count -eq 0) {
            $images = @()
            foreach ($f in $files) {
                $img = Get-TrimStripImage -FilePath $f
                if ($null -eq $img) { return $null }
                $images += ,$img
            }
            return ,@($images)
        }
        # 0.05 rather than 0: a degenerate span would ask ffmpeg for n copies of the
        # same frame, which is harmless but pointless -- this keeps the times distinct.
        $effLen = [math]::Max(0.05, $EffInEnd - $InStart)
        try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { return $null }
        foreach ($k in $missing) {
            $t = $InStart + (([double]$k + 0.5) / [double]$n) * $effLen
            Add-TrimRowMediaJob -Job @{
                Kind = "strip"; Key = ("strip|{0}|{1}" -f $dir, $k); OutFile = $files[$k]
                Path = $Path; Seconds = $t
            }
        }
        return $null
    }

    # One waveform per audio ROW, keyed by file + absolute stream + file stamp + pixel
    # size + the clip's own in/out. The in/out belong in the key: the render is of
    # exactly that window, so a trimmed clip that reused the untrimmed key would show a
    # waveform of the wrong audio.
    function Request-TrimRowWaveform {
        param([string]$Path, [int]$StreamIndex, [double]$InStart, [double]$Length, [int]$Width, [int]$Height)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if ($Length -le 0.01) { return $null }
        # The Look's waveform hue is PART OF THE KEY: the color is baked into the rendered
        # PNG, so a cached teal strip must never serve a Petalfall session (or vice versa).
        $waveColor = Convert-LookColorText -Text "#3E9B84"
        $key = "{0}|{1}|{2}|{3}x{4}|{5:N1}|{6:N1}|{7}" -f $Path, $StreamIndex, (Get-TrimMediaStamp -Path $Path), $Width, $Height, $InStart, $Length, $waveColor
        if ($script:TrimWaveCache.ContainsKey($key)) { return $script:TrimWaveCache[$key] }
        $outFile = Join-Path (Get-TrimWaveDir) ("row_{0}.png" -f (Get-TrimMediaHash -Text $key))
        # Hydrate from the disk cache before deciding this row is missing: any earlier
        # open of this file already paid the ffmpeg render.
        if (Test-Path -LiteralPath $outFile) {
            Set-TrimRowWaveform -Key $key -FilePath $outFile
            if ($script:TrimWaveCache.ContainsKey($key)) { return $script:TrimWaveCache[$key] }
        }
        Add-TrimRowMediaJob -Job @{
            Kind = "wave"; Key = $key; OutFile = $outFile; Path = $Path; StreamIndex = $StreamIndex
            Start = $InStart; Duration = $Length; Width = $Width; Height = $Height; Color = $waveColor
        }
        return $null
    }


    # Reads keyframes off the UI thread: on a long recording this decodes the whole index
    # and would otherwise freeze the window. Until it lands, snapping is inactive and the
    # accuracy line stays blank -- the editor is usable throughout.
    function Start-TrimKeyframeRead {
        param([string]$Path)

        $textTrimAccuracy.Text = "reading keyframes..."
        $ps = [powershell]::Create()
        $ps.AddScript({
            param($modulePath, $file)
            Import-Module $modulePath -Force
            Get-KeyframeTimes -InputFile $file
        }).AddArgument((Join-Path $scriptRoot "backend\VideoTrimmer.psm1")).AddArgument($Path) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(250)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            # Kept as a local rather than re-read from $script: afterwards -- inside this
            # closure $script: writes and reads both resolve against GetNewClosure()'s own
            # private module, not the real script scope, so re-reading here would risk
            # picking up that private copy instead of what Set-TrimKeyframes just wrote.
            $keyframes = try { @($ps.EndInvoke($handle)) } catch { @() }
            $ps.Dispose()
            Set-TrimKeyframes -Keyframes $keyframes
            if ($keyframes.Count -gt 1) {
                $gaps = for ($i = 1; $i -lt $keyframes.Count; $i++) {
                    $keyframes[$i] - $keyframes[$i-1]
                }
                $avg = ($gaps | Measure-Object -Average).Average
                $textTrimAccuracy.Text = ("cuts land on the nearest keyframe, every {0:N2}s in this file" -f $avg)
            } else {
                $textTrimAccuracy.Text = "keyframes unknown; cuts may shift"
            }
        }.GetNewClosure())
        $watcher.Start()
    }

    # Drives the playhead while playing. A timer rather than a MediaElement event because
    # MediaElement raises nothing per frame -- Position must be polled.
    #
    # No GetNewClosure() here, deliberately -- same reasoning as the tool-install
    # OnComplete block below: this writes $script:TrimPlayhead directly, and a closure
    # would rebind that write into its own private module where Update-TrimPosition (a
    # real top-level function) would never see it. Nothing here needs closure capture
    # anyway: this block is defined at the top-level try scope, which outlives the app,
    # so $mediaTrimPreview and friends resolve through the normal scope chain.
    #
    # Everything below is gated on $script:TrimEditorReady: on XAML that predates Task 4,
    # $buttonTrimPlay and $mediaTrimPreview are $null, and .Add_Click()/.Add_MediaEnded()
    # on a $null reference throws during startup, before the window ever shows.
