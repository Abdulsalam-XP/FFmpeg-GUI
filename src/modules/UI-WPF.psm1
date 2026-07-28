# src/modules/UI-WPF.psm1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function Initialize-MainWindow {
    param([Parameter(Mandatory = $true)][string]$ScriptRoot)

    $xamlPath = Join-Path $ScriptRoot "assets\MainWindow.xaml"
    $themePath = Join-Path $ScriptRoot "assets\Theme.xaml"

    # Theme must be loaded and merged into the Application's resources *before* the
    # window XAML is parsed. MainWindow.xaml references {StaticResource ...} on the
    # Window element itself (e.g. Background), and XamlReader.Load resolves
    # StaticResourceExtension at parse time, walking up to Application.Current.Resources
    # since the Window has no resources of its own yet. Merging the theme onto the
    # window only *after* XamlReader.Load returns is too late -- the parse already
    # throws ("Provide value on 'StaticResourceExtension' threw an exception").
    [xml]$themeXaml = Get-Content -Path $themePath -Raw
    $themeReader = New-Object System.Xml.XmlNodeReader $themeXaml
    $themeDict = [System.Windows.Markup.XamlReader]::Load($themeReader)

    if (-not [System.Windows.Application]::Current) {
        $null = New-Object System.Windows.Application
    }

    # Guard against accumulating duplicate merged dictionaries if Initialize-MainWindow is
    # ever called more than once in the same process (repeated manual-repro runs, a future
    # hot-reload, etc.). Merged dictionaries flatten their keys into the parent's resource
    # lookup, so checking for one of Theme.xaml's own keys ("FontChrome") tells us whether
    # the theme has already been merged onto Application.Current without needing to track
    # dictionary identity/Source separately.
    if (-not [System.Windows.Application]::Current.Resources.Contains("FontChrome")) {
        [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($themeDict)
    }

    [xml]$xaml = Get-Content -Path $xamlPath -Raw
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    # Also merge onto the window's own resources so later tasks can look the theme
    # dictionary up via $window.Resources without depending on Application.Current.
    $window.Resources.MergedDictionaries.Add($themeDict)

    $panelNames = @("Compress", "MergeAudio", "Trim", "YouTubeMP3", "YouTubeMP4", "Settings")
    $panels = @{}
    $navButtons = @{}
    foreach ($name in $panelNames) {
        $panels[$name] = $window.FindName("Panel$name")
        $navButtons[$name] = $window.FindName("Nav$name")
    }

    return @{
        Window     = $window
        Panels     = $panels
        NavButtons = $navButtons
        Pill       = $window.FindName("NavPill")
        PillCanvas = $window.FindName("PillCanvas")
    }
}

function Show-Panel {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($key in $Context.Panels.Keys) {
        $Context.Panels[$key].Visibility = if ($key -eq $Name) { "Visible" } else { "Collapsed" }
    }

    $targetTop = [array]::IndexOf(@("Compress", "MergeAudio", "Trim", "YouTubeMP3", "YouTubeMP4", "Settings"), $Name) * 46 + 60

    if (-not $global:ShowAnimations) {
        # Clear any previously-active BeginAnimation clock on Canvas.Top first. Once a
        # property has been driven by an AnimationClock, a plain SetTop call is silently
        # ignored (the clock keeps holding its end value via the default HoldEnd fill
        # behavior) -- without this, toggling ShowAnimations off mid-session after any
        # animated move had happened would leave the pill permanently stuck in place.
        $Context.Pill.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $null)
        [System.Windows.Controls.Canvas]::SetTop($Context.Pill, $targetTop)
        return
    }

    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.To = $targetTop
    $animation.Duration = [System.Windows.Duration]::new([timespan]::FromMilliseconds(280))
    $animation.EasingFunction = New-Object System.Windows.Media.Animation.BackEase
    $animation.EasingFunction.EasingMode = "EaseOut"

    $Context.Pill.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $animation)
}

if (-not ([System.Management.Automation.PSTypeName]'FFmpegGui.NamedPipePeek').Type) {
    Add-Type -Namespace FFmpegGui -Name NamedPipePeek -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool PeekNamedPipe(
    Microsoft.Win32.SafeHandles.SafeFileHandle handle,
    byte[] buffer, uint bufferSize, out uint bytesRead,
    out uint bytesAvail, out uint bytesLeftThisMessage);
'@
}

function Start-TrackedProcess {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [ValidateSet("Output", "Error")][string]$ReadStream = "Error",
        [Parameter(Mandatory = $true)][scriptblock]$OnLine,
        [Parameter(Mandatory = $true)][scriptblock]$OnExit
    )

    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = $FileName
    $pInfo.Arguments = $Arguments
    $pInfo.WorkingDirectory = (Get-Location).Path
    $pInfo.UseShellExecute = $false
    $pInfo.CreateNoWindow = $true
    if ($ReadStream -eq "Error") { $pInfo.RedirectStandardError = $true }
    else { $pInfo.RedirectStandardOutput = $true }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pInfo
    $process.Start() | Out-Null

    $reader = if ($ReadStream -eq "Error") { $process.StandardError } else { $process.StandardOutput }
    $stream = $reader.BaseStream
    $pipeHandle = $stream.SafeFileHandle
    $encoding = $reader.CurrentEncoding
    $readBuffer = New-Object byte[] 4096
    $peekBuffer = New-Object byte[] 1

    # NOTE on the polling design (deviation from the brief's literal add_ErrorDataReceived /
    # add_OutputDataReceived / add_Exited + Register-ObjectEvent sample):
    #
    # ffmpeg reports progress by rewriting the same terminal line with a bare '\r'
    # (no '\n'). .NET's async line-based redirection (BeginErrorReadLine /
    # ErrorDataReceived) only recognizes '\n' as a line terminator, so it never delivers
    # any of ffmpeg's progress output -- confirmed empirically: a real ffmpeg run that
    # completes in 0.3s left the wrapper hung for 90+s with zero progress lines and no
    # Exited event, stalled right where the '\n'-terminated startup banner ends and
    # '\r'-only progress begins. (The existing console version avoids this because
    # StreamReader.ReadLine(), which it uses synchronously, treats bare '\r' as a line
    # terminator too -- see Invoke-FFmpegProcess in UI.psm1.)
    #
    # The fix here polls the stream on a DispatcherTimer (i.e. entirely on the UI
    # thread, so PowerShell scriptblocks can run inline with a valid runspace context --
    # no cross-thread marshaling, no Register-ObjectEvent, nothing to Unregister-Event),
    # splitting accumulated text on '\r' or '\n' like the console version does. A plain
    # StreamReader.Peek()/Read() would block the UI thread whenever no data is currently
    # available (anonymous pipes have no non-blocking read in .NET), so PeekNamedPipe is
    # used first to check the OS pipe's buffered byte count without blocking.
    #
    # The loop below reads raw bytes directly off $stream (bypassing $reader/
    # StreamReader's own internal buffering) in chunks sized to exactly what
    # PeekNamedPipe just confirmed is sitting in the OS pipe. Two earlier approaches
    # were tried and rejected:
    #   - Gating solely on PeekNamedPipe while still calling StreamReader.Read(): a
    #     single StreamReader.Read() call can pull a whole chunk (up to ~1KB) out of the
    #     OS pipe into StreamReader's private buffer in one shot, after which
    #     PeekNamedPipe correctly reports the OS pipe as empty even though StreamReader
    #     is still holding undelivered chars -- the loop exits early and lines sit stuck
    #     in managed memory until the next OS-level write (or process exit) incidentally
    #     flushes them.
    #   - Checking $reader.Peek() first to drain that managed buffer before falling back
    #     to PeekNamedPipe: StreamReader.Peek() itself performs a blocking Stream.Read()
    #     to refill its buffer whenever that buffer is empty, so this reintroduces a
    #     genuine UI-thread freeze whenever the child briefly has no output ready
    #     (confirmed empirically: froze for the length of a slow ffmpeg encode's gaps
    #     between writes).
    # Reading exactly $bytesAvail bytes straight off $stream sidesteps both: there is
    # only one buffer (ours), it's only ever filled with bytes already confirmed
    # present, and Stream.Read for that many bytes returns immediately without blocking.
    $timer = New-Object System.Windows.Threading.DispatcherTimer -ArgumentList (
        [System.Windows.Threading.DispatcherPriority]::Normal, $Context.Window.Dispatcher)
    $timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $lineBuffer = New-Object System.Text.StringBuilder
    $exitHandled = $false

    $appendChunk = {
        param([byte[]]$Bytes, [int]$Count)
        $text = $encoding.GetString($Bytes, 0, $Count)
        foreach ($ch in $text.ToCharArray()) {
            if ($ch -eq "`r" -or $ch -eq "`n") {
                if ($lineBuffer.Length -gt 0) {
                    & $OnLine $lineBuffer.ToString()
                    [void]$lineBuffer.Clear()
                }
            } else {
                [void]$lineBuffer.Append($ch)
            }
        }
    }.GetNewClosure()

    $timer.Add_Tick({
        try {
            [uint32]$bytesRead = 0
            [uint32]$bytesAvail = 0
            [uint32]$bytesLeftThisMessage = 0
            while (-not $pipeHandle.IsClosed -and
                   [FFmpegGui.NamedPipePeek]::PeekNamedPipe($pipeHandle, $peekBuffer, 0, [ref]$bytesRead, [ref]$bytesAvail, [ref]$bytesLeftThisMessage) -and
                   $bytesAvail -gt 0) {
                $toRead = [Math]::Min([int]$bytesAvail, $readBuffer.Length)
                $actuallyRead = $stream.Read($readBuffer, 0, $toRead)
                if ($actuallyRead -le 0) { break }
                & $appendChunk $readBuffer $actuallyRead
            }

            if (-not $exitHandled -and $process.HasExited) {
                $exitHandled = $true
                # HasExited becoming true doesn't guarantee every byte the child wrote
                # has been drained yet. Once the process is confirmed dead no further
                # writer can add data, so a final synchronous drain is safe here and
                # can't hang.
                while ($true) {
                    $actuallyRead = $stream.Read($readBuffer, 0, $readBuffer.Length)
                    if ($actuallyRead -le 0) { break }
                    & $appendChunk $readBuffer $actuallyRead
                }
                if ($lineBuffer.Length -gt 0) {
                    & $OnLine $lineBuffer.ToString()
                    [void]$lineBuffer.Clear()
                }
                $timer.Stop()
                & $OnExit $process.ExitCode
                $process.Dispose()
            }
        } catch {
            # A broken pipe / disposed handle (e.g. the process was killed externally,
            # or Cancel called .Kill() mid-read) must not leave the timer ticking
            # forever re-throwing, and must not crash the WPF app via an unhandled
            # DispatcherTimer.Tick exception -- surface it to the caller as a failed
            # exit instead.
            if (-not $exitHandled) {
                $exitHandled = $true
                $timer.Stop()
                & $OnExit -1
            }
        }
    }.GetNewClosure())

    $timer.Start()

    return $process
}

Export-ModuleMember -Function Initialize-MainWindow, Show-Panel, Start-TrackedProcess
