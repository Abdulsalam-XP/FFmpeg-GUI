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
    # -Encoding UTF8 is required: Windows PowerShell 5.1's Get-Content defaults to the
    # system ANSI codepage for files without a BOM, which mangles every non-ASCII glyph
    # in the markup (en-dash, middot, ellipsis) into mojibake before the XAML is parsed.
    [xml]$themeXaml = Get-Content -Path $themePath -Raw -Encoding UTF8
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

    [xml]$xaml = Get-Content -Path $xamlPath -Raw -Encoding UTF8
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

    $context = @{
        Window     = $window
        Panels     = $panels
        NavButtons = $navButtons
        NavList    = $window.FindName("NavList")
        Pill       = $window.FindName("NavPill")
        PillCanvas = $window.FindName("PillCanvas")
    }

    Enable-NavHoverMagnify -Context $context -Order $panelNames
    return $context
}

# Hover magnification: the item under the cursor grows, everything else stays put.
#
# This lives here rather than in the item's ControlTemplate, where the rest of the nav
# styling sits, because of the exception below: hovering the already-selected item must
# do nothing. A template EventTrigger fires on MouseEnter unconditionally and cannot be
# suppressed by a state trigger, so the scaling is driven from one handler instead, with
# every item's ScaleTransform set up front.
function Enable-NavHoverMagnify {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string[]]$Order
    )

    $items = @($Order | ForEach-Object { $Context.NavButtons[$_] } | Where-Object { $_ })
    if ($items.Count -eq 0) { return }

    foreach ($item in $items) {
        $item.RenderTransform = New-Object System.Windows.Media.ScaleTransform 1, 1
    }

    $applyScales = {
        param([int]$HoveredIndex)

        for ($i = 0; $i -lt $items.Count; $i++) {
            $scale = if ($i -eq $HoveredIndex) { 1.08 } else { 1.0 }

            $transform = $items[$i].RenderTransform
            foreach ($property in @([System.Windows.Media.ScaleTransform]::ScaleXProperty,
                                    [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
                if (-not $global:ShowAnimations) {
                    # Clear the animation clock before writing directly: a held animation
                    # value silently wins over a plain property set.
                    $transform.BeginAnimation($property, $null)
                    $transform.SetValue($property, $scale)
                    continue
                }

                $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
                $animation.To = $scale
                $animation.Duration = [System.Windows.Duration]::new([timespan]::FromMilliseconds(160))
                $animation.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
                $animation.EasingFunction.EasingMode = "EaseOut"
                $transform.BeginAnimation($property, $animation)
            }
        }
    }.GetNewClosure()

    for ($index = 0; $index -lt $items.Count; $index++) {
        $captured = $index
        $items[$index].Add_MouseEnter({
            # Pointing at the item you are already on is not a navigation target, so it
            # gets no reaction: passing -1 leaves the whole list at rest.
            if ($items[$captured].IsChecked) { & $applyScales -1 }
            else { & $applyScales $captured }
        }.GetNewClosure())
    }

    # Reset from the list itself, not per-item MouseLeave. Leaving one item to enter its
    # neighbour would otherwise fire a reset immediately after that neighbour's enter,
    # flattening the effect while the cursor is still inside the list.
    if ($Context.NavList) {
        $Context.NavList.Add_MouseLeave({ & $applyScales -1 }.GetNewClosure())
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

    $navButton = $Context.NavButtons[$Name]
    if (-not $navButton) { return }

    # Drives the nav item's active styling (bold + full-contrast label and icon).
    $navButton.IsChecked = $true

    # The pill is positioned by measuring where the nav button actually landed, rather
    # than by arithmetic over a fixed row height. A hardcoded stride silently desyncs the
    # moment anything about the list changes -- adding the separator and the disabled
    # "Convert to MP4" entry was enough to leave the pill sitting a whole row off Settings.
    $placePill = {
        if ($navButton.ActualHeight -le 0) { return }

        # The Canvas and the nav StackPanel are siblings filling the same sidebar Grid,
        # so an offset measured against that Grid is already in Canvas coordinates.
        $sidebar = $Context.PillCanvas.Parent
        $offset = $navButton.TransformToAncestor($sidebar).Transform([System.Windows.Point]::new(0, 0))
        $targetTop = $offset.Y

        $Context.Pill.Height = $navButton.ActualHeight
        $Context.Pill.Width = $navButton.ActualWidth

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

        # Short and non-overshooting. The original BackEase deliberately sprang past the
        # target and settled back, which reads as the highlight wobbling into place
        # instead of simply following the click.
        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $animation.To = $targetTop
        $animation.Duration = [System.Windows.Duration]::new([timespan]::FromMilliseconds(150))
        $animation.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
        $animation.EasingFunction.EasingMode = "EaseOut"

        $Context.Pill.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $animation)
    }.GetNewClosure()

    if ($navButton.ActualHeight -gt 0) {
        & $placePill
    } else {
        # Called before the window has laid out (the initial panel selection). Measuring
        # now would read zeros, so defer until WPF has finished its first layout pass.
        $Context.Window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [Action]$placePill) | Out-Null
    }
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
    # '\r'-only progress begins. (The now-deleted console version never hit this because
    # its synchronous StreamReader.ReadLine() treats a bare '\r' as a line terminator.)
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

Export-ModuleMember -Function Initialize-MainWindow, Show-Panel, Start-TrackedProcess, Enable-NavHoverMagnify
