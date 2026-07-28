# src/backend/ToolUpdates.psm1
# Checks for, downloads and installs newer ffmpeg/ffprobe/yt-dlp binaries into src/bin/.

Import-Module (Join-Path $PSScriptRoot "ToolPaths.psm1")

# BtbN stamps its master builds as N-<rev>-g<hash>-<yyyyMMdd>-<variant>. That trailing
# date is the only comparable thing these builds carry, because the remote release they
# come from is tagged with the literal string "latest" and has no version at all.
# Release builds (7.1.1, n7.1) carry no date, so they deliberately return $null rather
# than a guess -- see Test-ToolUpdate, which treats null as "Unknown" and offers the
# install instead of silently claiming the user is up to date.
function ConvertFrom-FfmpegVersionString {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    # (?<!\d) and (?!\d) pin the match to an exactly-8-digit run, so a longer digit
    # sequence is rejected rather than having a date read out of the middle of it.
    $match = [regex]::Match($Line, '(?:ffmpeg|ffprobe) version \S*?(?<!\d)(20\d{6})(?!\d)')
    if (-not $match.Success) { return $null }

    return ConvertTo-DateOrNull -Text $match.Groups[1].Value -Format "yyyyMMdd"
}

# yt-dlp reports yyyy.MM.dd, with nightly builds appending a .HHmmss field that is
# ignored -- day resolution is enough to decide whether an update exists.
function ConvertFrom-YtDlpVersionString {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $match = [regex]::Match($Line.Trim(), '^(\d{4})\.(\d{2})\.(\d{2})')
    if (-not $match.Success) { return $null }

    return ConvertTo-DateOrNull -Text ("{0}{1}{2}" -f `
        $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value) -Format "yyyyMMdd"
}

# ParseExact rather than [datetime] casting: a well-formed but impossible date such as
# 20260231 must fail rather than roll over into March.
function ConvertTo-DateOrNull {
    param([string]$Text, [string]$Format)

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Text, $Format,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed)

    if ($ok) { return $parsed }
    return $null
}

# Pure comparison, no I/O -- this is the decision the whole feature turns on, so it is
# kept free of network and filesystem access to stay fully unit-testable.
function Test-ToolUpdate {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Installed,
        [hashtable]$Latest
    )

    $result = @{ Status = "Unknown"; Installed = $Installed; Latest = $Latest }

    # A tool resolved from PATH is never "updated": the app does not own that copy and
    # must not touch it. The offered action is to place a managed copy in bin/, which
    # then wins in Get-ToolPath -- so it is Missing (i.e. "Install"), regardless of how
    # the versions compare.
    if ($Installed.Source -eq "missing" -or $Installed.Source -eq "system") {
        $result.Status = "Missing"
        return $result
    }

    if ($null -eq $Latest -or $null -eq $Latest.Version) { return $result }
    if ($null -eq $Installed.Version) { return $result }

    if ($Installed.Version -ge $Latest.Version) {
        $result.Status = "Current"
    } else {
        $result.Status = "Available"
    }

    return $result
}

# A future timestamp counts as stale: a clock that jumps forward (or a hand-edited
# settings.json) would otherwise pin the cache as permanently fresh.
function Test-ToolCacheFresh {
    param(
        [string]$Timestamp,
        [datetime]$Now = ([datetime]::UtcNow),
        [int]$MaxAgeMinutes = 60
    )

    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return $false }

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParse($Timestamp, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
        [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
    if (-not $ok) { return $false }

    $age = $Now - $parsed
    if ($age.TotalMinutes -lt 0) { return $false }
    return $age.TotalMinutes -le $MaxAgeMinutes
}

# Runs the tool and parses what it prints. Never throws: a missing, corrupt or
# non-responding exe is a normal state the Settings card has to render, not an error.
function Get-InstalledToolVersion {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("ffmpeg", "ffprobe", "yt-dlp")][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    $result = @{ Name = $Name; Path = $null; Source = "missing"; Version = $null; Display = "not installed" }

    $path = Get-ToolPath -Name $Name -ScriptRoot $ScriptRoot
    $result.Path = $path

    # Get-ToolPath returns the bare name when nothing was found in bin/, which means
    # "let Windows resolve it on PATH". Resolve it here so the card can distinguish a
    # system copy from nothing at all.
    if ($path -eq $Name) {
        $onPath = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        if (-not $onPath) { return $result }
        $result.Source = "system"
        $result.Path = $onPath.Source
    } else {
        if (-not (Test-Path -LiteralPath $path)) { return $result }
        $result.Source = "bin"
    }

    $arguments = if ($Name -eq "yt-dlp") { "--version" } else { "-version" }

    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $result.Path
        $pInfo.Arguments = $arguments
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::Start($pInfo)

        # Read stdout fully *before* WaitForExit. Waiting first can deadlock if the child
        # fills the redirected pipe buffer, which is the standard trap with redirection.
        # Also drain stderr to prevent it from blocking.
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit(10000) | Out-Null

        # Kill the process if it's still running after timeout, and prevent handle leak
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(1000) | Out-Null
        }

        $firstLine = ($stdout -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
        if (-not $firstLine) { $firstLine = "" }
        $result.Display = $firstLine.Trim()

        if ($Name -eq "yt-dlp") {
            $result.Version = ConvertFrom-YtDlpVersionString -Line $firstLine
            if ($result.Version) { $result.Display = $result.Version.ToString("yyyy.MM.dd") }
        } else {
            $result.Version = ConvertFrom-FfmpegVersionString -Line $firstLine
            if ($result.Version) { $result.Display = $result.Version.ToString("yyyy-MM-dd") + " build" }
        }

        if (-not $result.Version -and $result.Display.Length -gt 40) {
            $result.Display = $result.Display.Substring(0, 40) + "…"
        }
    }
    catch {
        $result.Display = "unreadable"
    }
    finally {
        if ($process) { $process.Dispose() }
    }

    return $result
}

$script:ReleaseApi = @{
    "yt-dlp" = @{
        Uri   = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
        Asset = "yt-dlp.exe"
    }
    "ffmpeg" = @{
        # BtbN publishes one rolling release whose tag is the literal string "latest",
        # so there is no version number on the remote side -- published_at is the only
        # comparable value, which is why the ffmpeg path is date-based throughout.
        Uri   = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest"
        Asset = "ffmpeg-master-latest-win64-gpl.zip"
    }
}

function Get-LatestToolRelease {
    param([Parameter(Mandatory = $true)][ValidateSet("ffmpeg", "yt-dlp")][string]$Name)

    $api = $script:ReleaseApi[$Name]

    # GitHub rejects API requests without a User-Agent. TLS 1.2 is forced because 5.1
    # defaults to SSL3/TLS1.0 on some machines, which api.github.com refuses outright.
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.ServicePointManager]::SecurityProtocol

    $response = Invoke-RestMethod -Uri $api.Uri -Headers @{
        "User-Agent" = "FFmpeg-GUI"
        "Accept"     = "application/vnd.github+json"
    } -TimeoutSec 20

    $asset = $response.assets | Where-Object { $_.name -eq $api.Asset } | Select-Object -First 1
    if (-not $asset) {
        throw "The $Name release does not contain the expected file '$($api.Asset)'."
    }

    if ($Name -eq "yt-dlp") {
        $version = ConvertFrom-YtDlpVersionString -Line $response.tag_name
        if (-not $version) { throw "Could not read a version from the yt-dlp tag '$($response.tag_name)'." }
        $display = $version.ToString("yyyy.MM.dd")
    } else {
        $published = [datetime]::MinValue
        $ok = [datetime]::TryParse($response.published_at,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$published)
        if (-not $ok) { throw "Could not read a build date from the ffmpeg release." }
        # Compared against a date-only installed build, so the time of day is dropped.
        $version = $published.Date
        $display = $version.ToString("yyyy-MM-dd") + " build"
    }

    return @{
        Name        = $Name
        Version     = $version
        Display     = $display
        DownloadUrl = $asset.browser_download_url
        AssetName   = $asset.name
    }
}

# Windows refuses to overwrite a running exe but *does* permit renaming one, so the
# live file is moved aside before the new one is moved in. That makes the swap work
# even in the edge case where a job is somehow running despite the UI guard. The
# displaced file cannot be deleted until the process holding it exits, so it is left
# for Clear-StaleToolFiles to remove on the next launch.
function Move-ToolIntoPlace {
    param(
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $oldPath = "$TargetPath.old"
    $displaced = $false

    if (Test-Path -LiteralPath $TargetPath) {
        if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $TargetPath -Destination $oldPath -Force
        $displaced = $true
    }

    try {
        Move-Item -LiteralPath $StagedPath -Destination $TargetPath -Force
    }
    catch {
        # Put the original back before surfacing the failure, so a failed update never
        # leaves the user with no tool at all.
        if ($displaced) { Move-Item -LiteralPath $oldPath -Destination $TargetPath -Force }
        throw
    }
}

function Clear-StaleToolFiles {
    param([Parameter(Mandatory = $true)][string]$BinFolder)

    if (-not (Test-Path -LiteralPath $BinFolder)) { return }

    Get-ChildItem -LiteralPath $BinFolder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq ".old" -or $_.Extension -eq ".download" } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# Catches a truncated transfer and the classic failure where a proxy or error page is
# saved verbatim as the "executable". MZ is the DOS header every Windows exe starts
# with; PK is the local file header every zip starts with.
function Test-DownloadedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("Exe", "Zip")][string]$Kind,
        [long]$ExpectedBytes = 0
    )

    if (-not (Test-Path -LiteralPath $Path)) { return "The download did not produce a file." }

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -eq 0) { return "The download was empty." }
    if ($ExpectedBytes -gt 0 -and $length -ne $ExpectedBytes) {
        return "The download was incomplete ($length of $ExpectedBytes bytes)."
    }

    $signature = New-Object byte[] 2
    $stream = [System.IO.File]::OpenRead($Path)
    try { $read = $stream.Read($signature, 0, 2) } finally { $stream.Dispose() }
    if ($read -lt 2) { return "The download was too small to be valid." }

    $expected = if ($Kind -eq "Exe") { @(0x4D, 0x5A) } else { @(0x50, 0x4B) }
    if ($signature[0] -ne $expected[0] -or $signature[1] -ne $expected[1]) {
        return "The downloaded file is not a valid $($Kind.ToLower())."
    }

    return $null
}

Add-Type -AssemblyName System.Net.Http

# Mirrors Start-TrackedProcess in UI-WPF.psm1: the work runs as a .NET Task and a
# DispatcherTimer on the UI thread polls it. Nothing here runs a PowerShell scriptblock
# off the UI thread, so there is no runspace affinity problem, no Register-ObjectEvent
# and nothing to unregister -- the same reasoning recorded at length in that function.
function Install-ToolUpdate {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][hashtable]$Release,
        [Parameter(Mandatory = $true)][string]$BinFolder,
        [Parameter(Mandatory = $true)][scriptblock]$OnProgress,
        [Parameter(Mandatory = $true)][scriptblock]$OnComplete
    )

    if (-not (Test-Path -LiteralPath $BinFolder)) {
        New-Item -ItemType Directory -Path $BinFolder -Force | Out-Null
    }

    $isZip = $Release.AssetName.EndsWith(".zip")
    $tempPath = Join-Path $BinFolder ("{0}.download" -f $Release.AssetName)
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }

    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.ServicePointManager]::SecurityProtocol

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.Add("User-Agent", "FFmpeg-GUI")

    $state = @{
        Phase       = "Headers"
        Client      = $client
        HeadersTask = $client.GetAsync($Release.DownloadUrl,
                          [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        CopyTask    = $null
        FileStream  = $null
        Total       = [long]0
        TempPath    = $tempPath
        Cancelled   = $false
        Timer       = $null
    }

    $finish = {
        param([bool]$Success, [string]$Message)

        if ($state.Timer) { $state.Timer.Stop() }
        if ($state.FileStream) { $state.FileStream.Dispose(); $state.FileStream = $null }
        if ($state.Client) { $state.Client.Dispose(); $state.Client = $null }
        if (-not $Success -and (Test-Path -LiteralPath $state.TempPath)) {
            Remove-Item -LiteralPath $state.TempPath -Force -ErrorAction SilentlyContinue
        }
        & $OnComplete $Success $Message
    }.GetNewClosure()

    # Grabbed as scriptblocks rather than called by name: the timer's Tick handler runs
    # from this module's scope here, but the same trap that bit Compress-VideoAsync
    # (command lookup not following a closure across scopes) makes direct invocation the
    # safer habit for anything a closure calls.
    $verifyFile = ${function:Test-DownloadedFile}
    $moveIntoPlace = ${function:Move-ToolIntoPlace}

    $install = {
        # Everything from "download finished" to "new tool in place", run on the UI
        # thread. Both branches stage every file first and only then swap, so a failure
        # part-way through never leaves a half-updated pair of ffmpeg/ffprobe.
        if ($isZip) {
            $problem = & $verifyFile -Path $state.TempPath -Kind "Zip" -ExpectedBytes $state.Total
            if ($problem) { & $finish $false $problem; return }

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $wanted = @("ffmpeg.exe", "ffprobe.exe")
            $staged = @{}
            $zip = [System.IO.Compression.ZipFile]::OpenRead($state.TempPath)
            try {
                foreach ($entry in $zip.Entries) {
                    if ($wanted -notcontains $entry.Name) { continue }
                    $stagedPath = Join-Path $BinFolder ("{0}.download" -f $entry.Name)
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $stagedPath, $true)
                    $staged[$entry.Name] = $stagedPath
                }
            }
            finally { $zip.Dispose() }

            foreach ($name in $wanted) {
                if (-not $staged.ContainsKey($name)) {
                    foreach ($p in $staged.Values) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
                    & $finish $false "The ffmpeg archive did not contain $name."
                    return
                }
            }

            try {
                foreach ($name in $wanted) {
                    & $moveIntoPlace -StagedPath $staged[$name] -TargetPath (Join-Path $BinFolder $name)
                }
            }
            catch {
                & $finish $false "Could not replace the tool: $($_.Exception.Message)"
                return
            }

            Remove-Item -LiteralPath $state.TempPath -Force -ErrorAction SilentlyContinue
            & $finish $true "Updated to $($Release.Display)."
        }
        else {
            $problem = & $verifyFile -Path $state.TempPath -Kind "Exe" -ExpectedBytes $state.Total
            if ($problem) { & $finish $false $problem; return }

            try {
                & $moveIntoPlace -StagedPath $state.TempPath -TargetPath (Join-Path $BinFolder "$($Release.Name).exe")
            }
            catch {
                & $finish $false "Could not replace the tool: $($_.Exception.Message)"
                return
            }

            & $finish $true "Updated to $($Release.Display)."
        }
    }.GetNewClosure()

    $timer = New-Object System.Windows.Threading.DispatcherTimer -ArgumentList (
        [System.Windows.Threading.DispatcherPriority]::Normal, $Context.Window.Dispatcher)
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $state.Timer = $timer

    $timer.Add_Tick({
        try {
            if ($state.Cancelled) { & $finish $false "Cancelled."; return }

            if ($state.Phase -eq "Headers") {
                if (-not $state.HeadersTask.IsCompleted) { return }
                if ($state.HeadersTask.IsFaulted) {
                    & $finish $false "Could not reach the download server."
                    return
                }

                $response = $state.HeadersTask.Result
                if (-not $response.IsSuccessStatusCode) {
                    & $finish $false "The server refused the download ($([int]$response.StatusCode))."
                    return
                }

                $length = $response.Content.Headers.ContentLength
                $state.Total = if ($length) { [long]$length } else { [long]0 }

                # Completes synchronously: the body is already streaming at this point.
                $sourceStream = $response.Content.ReadAsStreamAsync().Result
                $state.FileStream = [System.IO.File]::Create($state.TempPath)
                $state.CopyTask = $sourceStream.CopyToAsync($state.FileStream)
                $state.Phase = "Copy"
                & $OnProgress ([long]0) $state.Total
                return
            }

            if ($state.Phase -eq "Copy") {
                & $OnProgress ([long]$state.FileStream.Position) $state.Total

                if (-not $state.CopyTask.IsCompleted) { return }
                if ($state.CopyTask.IsFaulted -or $state.CopyTask.IsCanceled) {
                    & $finish $false "The download was interrupted."
                    return
                }

                $state.FileStream.Dispose()
                $state.FileStream = $null
                $state.Phase = "Install"
                & $install
            }
        }
        catch {
            & $finish $false $_.Exception.Message
        }
    }.GetNewClosure())

    $state.Cancel = {
        $state.Cancelled = $true
        # Disposing the client faults the in-flight copy, which the next tick observes.
        if ($state.Client) { $state.Client.CancelPendingRequests() }
    }.GetNewClosure()

    $timer.Start()
    return $state
}

Export-ModuleMember -Function ConvertFrom-FfmpegVersionString, ConvertFrom-YtDlpVersionString, `
    Test-ToolUpdate, Test-ToolCacheFresh, Get-InstalledToolVersion, Get-LatestToolRelease, `
    Install-ToolUpdate, Clear-StaleToolFiles
