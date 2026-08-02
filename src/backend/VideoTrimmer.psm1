Import-Module "$PSScriptRoot/UI.psm1"
Import-Module "$PSScriptRoot/ToolPaths.psm1"

# Keyframe times for the trim timeline. Cuts can only start on a keyframe without
# re-encoding, so the timeline snaps to these and the panel reports their spacing --
# on the NVIDIA DVR recordings this app is used with, that spacing is 0.25s, which is
# why the editor re-encodes nothing at all.
#
# Lines come from ffprobe's packet index (see Get-KeyframeTimes below), each shaped
# "<pts_time>,<flags>" e.g. "0.249878,K__" -- the packet index already stores every
# packet, not just keyframes, so a packet is only kept if its flags contain 'K'.
# Filtering lives here rather than between the ffprobe call and this function so the
# one place that is unit tested is the one place that decides what counts as a
# keyframe -- Get-KeyframeTimes stays a thin, untested shell-out.
function ConvertFrom-KeyframeOutput {
    param([string[]]$Lines)

    $times = @()
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        $text = $line.Trim()
        if (-not $text) { continue }
        $parts = $text -split ','
        if ($parts.Count -lt 2) { continue }
        $timeText = $parts[0].Trim()
        $flags = $parts[1].Trim()
        if ($flags -notmatch 'K') { continue }
        if ($timeText -notmatch '^\d+(\.\d+)?$') { continue }
        $times += [double]$timeText
    }
    return ,@($times | Sort-Object)
}

function Get-KeyframeTimes {
    param([Parameter(Mandatory = $true)][string]$InputFile)

    $ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    # Reads the container's packet index directly instead of decoding frames.
    # -skip_frame nokey + frame=pts_time (the original approach) decodes every
    # keyframe to report a timestamp the packet index already stores -- ~26x slower
    # for identical values. packet=pts_time,flags returns every packet; flags
    # contains 'K' for a keyframe packet, filtered out in ConvertFrom-KeyframeOutput.
    $raw = & $ffprobe -v error -select_streams v:0 `
        -show_entries packet=pts_time,flags -of csv=p=0 $InputFile 2>&1
    return ,(ConvertFrom-KeyframeOutput -Lines @($raw | ForEach-Object { "$_" }))
}

# Exports the surviving pieces as one file.
#
# One ffmpeg pass per piece, then one to join them. The obvious single-pass alternative
# (concat demuxer with inpoint/outpoint against the source) was built and measured on
# 2026-07-31: it froze ~0.9s at every join and dropped 267 frames, because the pieces keep
# their original timestamps and leave a gap. Extracting each piece first gives every one
# zero-based timing, which is what makes the join clean. Do not "simplify" this back.
function Export-CutListAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][object[]]$Pieces,
        [scriptblock]$OnFinished = $null
    )

    $panel = $Context.Panels.Trim
    $progressBar = $panel.FindName("ProgressBarTrim")
    $percentText = $panel.FindName("TextTrimPercent")
    $etaText = $panel.FindName("TextTrimEta")
    $cancelButton = $panel.FindName("ButtonTrimCancel")
    $startButton = $panel.FindName("ButtonTrimExport")

    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
    $outputFile = Get-JobOutputPath -InputFile $InputFile -Suffix "Edited"

    $work = @($Pieces)
    $stepCount = $work.Count + 1
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ffgui-cut-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $tempFiles = @()
    for ($i = 0; $i -lt $work.Count; $i++) {
        $tempFiles += (Join-Path $tempDir ("piece{0:D3}.mp4" -f $i))
    }

    $cleanup = {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }.GetNewClosure()

    # The runner has to invoke itself for the next step, and a plain
    # "$runStep = { ... & $runStep ... }.GetNewClosure()" CANNOT work: GetNewClosure
    # captures the variable's value at capture time, which is $null on that line, so the
    # recursive call would fail on the second step. Holding it in a hashtable works
    # because the hashtable reference is captured and its contents are read at call time.
    $chain = @{}
    $chain.RunStep = {
        param([int]$StepIndex)

        # Rebinds this closure's own module-scoped captures ($cleanup, $chain, $work,
        # ...) as plain locals of THIS call. -OnLine/-OnExit below need their own
        # .GetNewClosure() -- without it they can't see $StepIndex once the timer
        # invokes them later, from a completely different call stack, after RunStep
        # has already returned. But .GetNewClosure() called from inside an
        # already-closured scriptblock only captures the IMMEDIATE local frame, not
        # this closure's own module -- confirmed live: $cleanup and $chain came back
        # $null inside -OnExit, so "& $cleanup" crashed the whole app the moment a
        # step finished ("expression after '&' ... not valid"). Assigning each one to
        # itself here makes it a genuine local of this call, which the inner
        # .GetNewClosure() DOES pick up correctly.
        $cleanup = $cleanup
        $chain = $chain
        $work = $work
        $InputFile = $InputFile
        $outputFile = $outputFile
        $OnFinished = $OnFinished
        $progressBar = $progressBar
        $percentText = $percentText
        $etaText = $etaText
        $cancelButton = $cancelButton
        $startButton = $startButton
        $stepCount = $stepCount

        if ($StepIndex -lt $work.Count) {
            $piece = $work[$StepIndex]
            $duration = $piece.End - $piece.Start
            $args = @("-hide_banner", "-ss", $piece.Start, "-i", "`"$InputFile`"",
                      "-t", $duration, "-map", "0", "-c", "copy",
                      "-avoid_negative_ts", "make_zero", "`"$($tempFiles[$StepIndex])`"", "-y")
        } else {
            $listPath = Join-Path $tempDir "list.txt"
            # No BOM: Set-Content -Encoding UTF8 writes one on PS 5.1 and ffmpeg then
            # fails with "Line 1: unknown keyword 'file'". Forward slashes regardless
            # of the local separator.
            $body = (($tempFiles | ForEach-Object { "file '$($_ -replace '\\', '/')'" }) -join "`n") + "`n"
            [System.IO.File]::WriteAllText($listPath, $body, (New-Object System.Text.UTF8Encoding($false)))
            $args = @("-hide_banner", "-f", "concat", "-safe", "0", "-i", "`"$listPath`"",
                      "-map", "0", "-c", "copy", "`"$outputFile`"", "-y")
        }

        $process = Start-TrackedProcess -Context $Context -FileName $ffmpegPath `
            -Arguments ($args -join " ") -ReadStream Error `
            -OnLine {
                param($line)
                # Each step contributes an equal slice of the bar. Steps are short and
                # roughly equal, so a per-step fraction is not worth parsing out.
                $base = ($StepIndex / $stepCount) * 100
                $progressBar.Value = [math]::Min(99, $base + (100 / $stepCount) * 0.5)
                $percentText.Text = "{0:N1}%" -f $progressBar.Value
                $etaText.Text = "step $($StepIndex + 1) of $stepCount"
            }.GetNewClosure() `
            -OnExit {
                param($exitCode)
                if ($exitCode -ne 0) {
                    & $cleanup
                    $cancelButton.IsEnabled = $false
                    if ($startButton) { $startButton.IsEnabled = $true }
                    return
                }
                if ($StepIndex -lt $work.Count) {
                    & $chain.RunStep ($StepIndex + 1)
                    return
                }
                & $cleanup
                $progressBar.Value = 100
                $percentText.Text = "100.0%"
                $etaText.Text = "00:00:00"
                $cancelButton.IsEnabled = $false
                if ($startButton) { $startButton.IsEnabled = $true }
                if ($OnFinished) { & $OnFinished $InputFile $outputFile }
            }.GetNewClosure()

        Set-CancelButtonTarget -Button $cancelButton -Process $process
        return $process
    }.GetNewClosure()

    if ($startButton) { $startButton.IsEnabled = $false }
    $cancelButton.IsEnabled = $true
    return (& $chain.RunStep 0)
}

Export-ModuleMember -Function Export-CutListAsync, ConvertFrom-KeyframeOutput, Get-KeyframeTimes