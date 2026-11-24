# 85-tools-card.ps1 -- tools update card, closing handlers, initial panel.
# Dot-sourced by Video-Audio-Tool.ps1 INSIDE its top-level try, so this runs in
# the main script's scope (PS 5.1 dynamic scoping: $script: state, $ctx and the
# panel variables all resolve exactly as if this text were inline). NOT standalone;
# section order matters.

    $toolRows = @{
        ffmpeg    = @{ Version = $panelSettings.FindName("TextToolVersionFfmpeg")
                       Path = $panelSettings.FindName("TextToolPathFfmpeg")
                       Button = $panelSettings.FindName("ButtonUpdateFfmpeg")
                       Badge = $panelSettings.FindName("BadgeToolFfmpeg") }
        ffprobe   = @{ Version = $panelSettings.FindName("TextToolVersionFfprobe")
                       Path = $panelSettings.FindName("TextToolPathFfprobe")
                       Button = $null }
        "yt-dlp"  = @{ Version = $panelSettings.FindName("TextToolVersionYtDlp")
                       Path = $panelSettings.FindName("TextToolPathYtDlp")
                       Button = $panelSettings.FindName("ButtonUpdateYtDlp")
                       Badge = $panelSettings.FindName("BadgeToolYtDlp") }
    }
    $toolsProgress = $panelSettings.FindName("ProgressBarTools")
    $toolsCancel = $panelSettings.FindName("ButtonToolsCancel")
    $toolsStatus = $panelSettings.FindName("TextToolsStatus")
    $binFolder = Join-Path $scriptRoot "bin"

    $script:LatestReleases = @{}
    $script:ToolInstallRunning = $false
    $script:ToolInstallState = $null
    # Kept as one string so the card can recognise its own stale warning and clear it
    # once the job ends, without clobbering an install result message sitting in the
    # same block.
    $script:JobGuardMessage = "Finish the job that's running before updating a tool."

    # ---------------- Update-available badges ----------------
    # A glowing gold "!" in two places. One sits on the Settings entry in the sidebar,
    # lit when a tool update is waiting (startup check below) or when a download just
    # failed for tool reasons (the NotifyToolAttention hook); it goes away the moment
    # Settings is opened. The other sits to the right of each tool's own update button
    # and stays there until that tool is actually updated, so the reminder survives
    # after the sidebar one has done its job of getting the user here.
    # Built entirely in code: Theme.xaml is merged into Application.Resources and
    # frozen, so a storyboard there takes startup down -- the same constraint recorded
    # on New-PanelTransition.
    function New-AttentionBadge {
        param([double]$Size = 20)

        # Through the Look map, like every code-built color, so the badge matches the
        # active accent instead of hardcoding the gold theme's.
        $accentText = Convert-LookColorText -Text "#D3A24C"
        $converter = New-Object System.Windows.Media.BrushConverter

        $mark = New-Object System.Windows.Controls.TextBlock
        $mark.Text = "!"
        $mark.FontWeight = "ExtraBold"
        $mark.FontSize = [math]::Round($Size * 0.68, 1)
        $mark.Foreground = $converter.ConvertFromString("#14100A")
        $mark.HorizontalAlignment = "Center"
        $mark.VerticalAlignment = "Center"
        $mark.Margin = New-Object System.Windows.Thickness -ArgumentList 0, -1, 0, 0

        $badge = New-Object System.Windows.Controls.Border
        $badge.Width = $Size
        $badge.Height = $Size
        $badge.CornerRadius = New-Object System.Windows.CornerRadius ($Size / 2)
        $badge.Background = $converter.ConvertFromString($accentText)
        $badge.VerticalAlignment = "Center"
        $badge.Child = $mark

        $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $glow.ShadowDepth = 0
        $glow.BlurRadius = 16
        $glow.Opacity = 0.95
        $glow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($accentText)
        $badge.Effect = $glow

        if ($global:ShowAnimations) {
            $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
            $pulse.From = 0.3
            $pulse.To = 1.0
            $pulse.Duration = [System.Windows.Duration]::new([timespan]::FromMilliseconds(900))
            $pulse.AutoReverse = $true
            $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $glow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $pulse)
        }
        return $badge
    }

    # Detaches the pulse before the badge is dropped; a running clock keeps a removed
    # effect alive and animating forever.
    function Remove-AttentionBadge {
        param($Badge)
        if ($Badge -and $Badge.Effect) {
            $Badge.Effect.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $null)
        }
    }

    $navSettingsContent = $null
    $script:NavSettingsBadge = $null
    if ($ctx.NavButtons["Settings"] -and $ctx.NavButtons["Settings"].Content) {
        # Nav content is StackPanel(Path, TextBlock); a XAML old enough to lack that
        # shape just leaves the sidebar badge disabled rather than crashing startup.
        $navContent = $ctx.NavButtons["Settings"].Content
        if ($navContent -is [System.Windows.Controls.StackPanel]) { $navSettingsContent = $navContent }
    }

    # The names are kept from when this was a halo on the cog icon; callers only ever
    # meant "make Settings ask for attention".
    function Show-SettingsGlow {
        if (-not $navSettingsContent) { return }
        if ($script:NavSettingsBadge) { return }
        # Pointing at the panel the user is already on would be noise.
        if ($ctx.Panels["Settings"].Visibility -eq "Visible") { return }

        $badge = New-AttentionBadge -Size 18
        $badge.Margin = New-Object System.Windows.Thickness -ArgumentList 12, 0, 0, 0
        $badge.ToolTip = "An update is waiting in Settings"
        [void]$navSettingsContent.Children.Add($badge)
        $script:NavSettingsBadge = $badge
    }

    function Hide-SettingsGlow {
        if (-not $script:NavSettingsBadge) { return }
        Remove-AttentionBadge -Badge $script:NavSettingsBadge
        if ($navSettingsContent) { $navSettingsContent.Children.Remove($script:NavSettingsBadge) }
        $script:NavSettingsBadge = $null
    }

    # The per-tool badge. Idempotent, and deliberately separate from Set-ToolRow: the
    # card redraws every row as "Checking..." on each visit, and the badge must sit
    # through that untouched until a real verdict says the tool is current.
    function Set-ToolAttention {
        param([string]$Name, [bool]$On)

        $badgeHost = $toolRows[$Name].Badge
        if (-not $badgeHost) { return }
        if ($On) {
            if (-not $badgeHost.Child) { $badgeHost.Child = New-AttentionBadge -Size 20 }
            $badgeHost.Visibility = "Visible"
        } else {
            if ($badgeHost.Child) { Remove-AttentionBadge -Badge $badgeHost.Child }
            $badgeHost.Child = $null
            # Hidden, not Collapsed: the slot keeps its width so the path text beside it
            # lines up with the rows that have no badge.
            $badgeHost.Visibility = "Hidden"
        }
    }

    # How the backend asks for the glow without knowing anything about nav buttons:
    # YouTubeDownload.psm1 invokes this when a download failed for tool reasons. The
    # scriptblock runs in this script scope, where Show-SettingsGlow resolves.
    $ctx.NotifyToolAttention = { Show-SettingsGlow }

    function Set-ToolRow {
        param([string]$Name, [hashtable]$Installed, [string]$ButtonText, [bool]$ButtonEnabled)

        $row = $toolRows[$Name]
        $row.Version.Text = $Installed.Display
        $row.Path.Text = switch ($Installed.Source) {
            "bin"    { "app folder" }
            "system" { "found on your PC: $($Installed.Path)" }
            default  { "not found" }
        }
        if ($row.Button) {
            $row.Button.Content = $ButtonText
            $row.Button.IsEnabled = $ButtonEnabled -and -not (Test-AnyJobRunning) -and -not $script:ToolInstallRunning
        }
    }

    # Rendered from cache when the last check was under an hour ago, so reopening
    # Settings costs nothing. -Force is what the "Couldn't check" retry uses.
    # Write-through for the same reason Set-TrimKeyframes exists: the tick handler below
    # is a .GetNewClosure()'d block, and a bare `$script:InstalledVersionsChecked = $true`
    # in there would land in that closure's own private module, invisible to every later
    # call to Update-ToolsCard -- which would then re-spawn all three processes on every
    # visit forever, exactly the bug this flag exists to prevent.
    function Set-InstalledVersionsChecked {
        $script:InstalledVersionsChecked = $true
    }

    # Write-through for the same reason: Update-ToolsCard's tick handler below is
    # .GetNewClosure()'d, and a bare `$script:LatestReleases[$name] = ...` in there
    # reads $script:LatestReleases against the closure's OWN private module -- which,
    # unlike the real script scope, never had it initialized, so the read comes back
    # $null and indexing into it throws "Cannot index into a null array". A plain
    # top-level function's `$script:` always resolves against the real script scope
    # regardless of who calls it, so routing the read through here and mutating the
    # hashtable it returns (a reference, not a copy) reaches the real one.
    function Set-LatestRelease {
        param([string]$Name, $Release)
        $script:LatestReleases[$Name] = $Release
    }

    function Get-LatestRelease {
        param([string]$Name)
        return $script:LatestReleases[$Name]
    }

    # The background fetch itself, shared verbatim by Update-ToolsCard and the startup
    # attention check so the two can never drift on how versions are read or cached.
    $script:ToolFetchScript = {
        param($modulePath, $scriptRoot, $needInstalled, $useCache, $cachedTools, $shared)
        Import-Module $modulePath -Force

        if ($needInstalled) {
            foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
                $shared.Installed[$name] = Get-InstalledToolVersion -Name $name -ScriptRoot $scriptRoot
            }
        }

        foreach ($name in @("ffmpeg", "yt-dlp")) {
            if ($useCache -and $cachedTools -and $cachedTools.$name) {
                $cached = $cachedTools.$name
                # Re-parse the timestamp exactly as Get-LatestToolRelease did, so the
                # cached and freshly-fetched paths yield the identical value. A plain
                # [datetime] cast would read ffmpeg's trailing "Z" and convert it to
                # local time, leaving it hours ahead of the date-only installed build
                # -- east of UTC that pins ffmpeg on "Update ->" forever, west of it
                # hides a genuinely newer build.
                $restored = [datetime]::MinValue
                [void][datetime]::TryParse($cached.Version,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                    [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$restored)
                $shared.Latest[$name] = @{ Name = $name; Version = $restored.Date; Display = $cached.Display
                                            DownloadUrl = $cached.DownloadUrl; AssetName = $cached.AssetName }
            } else {
                # No separate "did it fail" flag: a name simply absent from
                # $shared.Latest (never assigned, because this threw) means the
                # same thing.
                try { $shared.Latest[$name] = Get-LatestToolRelease -Name $name } catch { }
            }
        }
    }

    # Persists what a fresh (non-cache) fetch learned, reading through Get-LatestRelease
    # so it always reflects what Set-LatestRelease just stored.
    function Save-ToolCheckCache {
        $tools = @{}
        foreach ($name in @("ffmpeg", "yt-dlp")) {
            $r = Get-LatestRelease -Name $name
            if ($r) {
                $tools[$name] = @{ Version = $r.Version.ToString("o"); Display = $r.Display
                                   DownloadUrl = $r.DownloadUrl; AssetName = $r.AssetName }
            }
        }
        if ($tools.Count -gt 0) {
            $global:ToolCheckCache = @{ CheckedUtc = ([datetime]::UtcNow.ToString("o")); Tools = $tools }
            Save-Settings
        }
    }

    # Get-InstalledToolVersion actually launches ffmpeg/ffprobe/yt-dlp and waits for them
    # to exit, and Get-LatestToolRelease is a real network call -- neither is a cheap
    # file read. Both run on a background runspace (same shape as Start-TrimKeyframeRead)
    # so opening Settings never blocks the window, not even on the very first visit:
    # the panel shows "Checking…" instantly and the real values fill in a moment later.
    # The installed-version check is additionally skipped entirely after the first visit
    # each session (unless -Force, used right after an install completes, or when
    # Start-ToolInstall finds no cached release to install) -- installed binaries do not
    # change on their own mid-session, so there is nothing to re-spawn processes for.
    function Update-ToolsCard {
        param([switch]$Force)

        # The card being (re)drawn means the user is looking at Settings: whatever the
        # glow wanted them to see, they are now seeing.
        Hide-SettingsGlow

        foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
            $placeholder = if ($toolRows[$name].Installed) { $toolRows[$name].Installed } `
                           else { @{ Display = "checking…"; Source = "missing"; Path = $null } }
            Set-ToolRow -Name $name -Installed $placeholder -ButtonText "Checking…" -ButtonEnabled $false
        }

        $useCache = (-not $Force) -and $global:ToolCheckCache -and `
                    (Test-ToolCacheFresh -Timestamp $global:ToolCheckCache.CheckedUtc -MaxAgeMinutes 60)
        $needInstalled = $Force -or -not $script:InstalledVersionsChecked
        $cachedTools = if ($global:ToolCheckCache) { $global:ToolCheckCache.Tools } else { $null }

        # Written into directly by the background script below, rather than returned
        # through EndInvoke -- EndInvoke hands back a PSDataCollection wrapper, and
        # accessing properties through it via PowerShell's single-item collection
        # auto-forwarding proved genuinely unreliable live (one property on it read
        # back fine, a second property on that exact same collection came back $null,
        # and a third run hung rather than reporting either). A plain Hashtable that
        # both runspaces hold the same reference to sidesteps that boundary completely:
        # the background script fills it in directly, and nothing is read from it until
        # $handle.IsCompleted is true, by which point that write has already happened.
        $shared = [hashtable]::Synchronized(@{ Installed = @{}; Latest = @{} })

        $ps = [powershell]::Create()
        $ps.AddScript($script:ToolFetchScript).AddArgument((Join-Path $scriptRoot "backend\ToolUpdates.psm1")).AddArgument($scriptRoot).AddArgument($needInstalled).AddArgument($useCache).AddArgument($cachedTools).AddArgument($shared) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        $watcher.Interval = [timespan]::FromMilliseconds(100)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()

            if ($needInstalled) {
                foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
                    $installed = $shared.Installed[$name]
                    $toolRows[$name].Installed = $installed
                    Set-ToolRow -Name $name -Installed $installed -ButtonText "Checking…" -ButtonEnabled $false
                }
                Set-InstalledVersionsChecked
            }

            foreach ($name in @("ffmpeg", "yt-dlp")) {
                $latest = $shared.Latest[$name]
                Set-LatestRelease -Name $name -Release $latest

                if (-not $latest) {
                    Set-ToolRow -Name $name -Installed $toolRows[$name].Installed `
                        -ButtonText "Couldn't check" -ButtonEnabled $true
                    continue
                }

                $verdict = Test-ToolUpdate -Installed $toolRows[$name].Installed -Latest $latest
                switch ($verdict.Status) {
                    "Current"   { Set-ToolRow -Name $name -Installed $verdict.Installed -ButtonText "Up to date" -ButtonEnabled $false }
                    "Available" { Set-ToolRow -Name $name -Installed $verdict.Installed -ButtonText "Update → $($latest.Display)" -ButtonEnabled $true }
                    default     { Set-ToolRow -Name $name -Installed $verdict.Installed -ButtonText "Install" -ButtonEnabled $true }
                }
                # Lit for an update that is waiting, or a tool found nowhere; the same two
                # cases the startup check lights the sidebar for. It goes out only when
                # this check says otherwise, which after an install is the -Force
                # refresh that re-reads the exe from disk.
                $toolMissing = $verdict.Status -eq "Missing" -and $verdict.Installed.Source -eq "missing"
                Set-ToolAttention -Name $name -On ($verdict.Status -eq "Available" -or $toolMissing)
            }

            if (-not $useCache) { Save-ToolCheckCache }

            if (Test-AnyJobRunning) {
                Show-PanelMessage -Block $toolsStatus -Text $script:JobGuardMessage
            } elseif ($toolsStatus.Text -eq $script:JobGuardMessage) {
                # The job has since finished. Clear only this warning -- an "Updated to
                # ..." message set moments earlier by OnComplete must survive.
                Show-PanelMessage -Block $toolsStatus -Text ""
            }
        }.GetNewClosure())
        $watcher.Start()
    }

    function Start-ToolInstall {
        param([string]$Name)

        $release = $script:LatestReleases[$Name]
        if (-not $release) { Update-ToolsCard -Force; return }
        if (Test-AnyJobRunning) {
            Show-PanelMessage -Block $toolsStatus -Text $script:JobGuardMessage -IsError
            return
        }

        $script:ToolInstallRunning = $true
        $toolRows[$Name].Button.IsEnabled = $false
        if ($toolRows["ffmpeg"].Button) { $toolRows["ffmpeg"].Button.IsEnabled = $false }
        if ($toolRows["yt-dlp"].Button) { $toolRows["yt-dlp"].Button.IsEnabled = $false }
        $toolsProgress.Value = 0
        $toolsProgress.Visibility = "Visible"
        $toolsCancel.Visibility = "Visible"
        $toolsCancel.IsEnabled = $true
        Show-PanelMessage -Block $toolsStatus -Text "Downloading $Name…"

        $script:ToolInstallState = Install-ToolUpdate -Context $ctx -Release $release -BinFolder $binFolder `
            -OnProgress {
                param($received, $total)
                if ($total -gt 0) {
                    $toolsProgress.Value = [math]::Round(($received / $total) * 100, 1)
                    $toolRows[$Name].Button.Content = "{0:N0}%" -f $toolsProgress.Value
                } else {
                    $toolRows[$Name].Button.Content = "{0:N1} MB" -f ($received / 1MB)
                }
            }.GetNewClosure() `
            -OnComplete {
                param($success, $message)
                # No .GetNewClosure() on this block, deliberately. Inside a closure,
                # $script: binds to the closure's own dynamic module, so the two resets
                # below would never reach the copies Set-ToolRow reads and every update
                # button would stay disabled until the app restarted. OnProgress above
                # still needs its closure -- it captures $Name, which dies with this
                # function; this block captures nothing.
                $script:ToolInstallRunning = $false
                $script:ToolInstallState = $null
                $toolsProgress.Visibility = "Collapsed"
                $toolsCancel.Visibility = "Collapsed"
                $toolsCancel.IsEnabled = $false
                Show-PanelMessage -Block $toolsStatus -Text $message -IsError:(-not $success)
                # -Force is what actually re-reads the exe from disk: without it the
                # session-cached installed version is compared against latest, and the
                # row keeps offering the update that just finished installing.
                Update-ToolsCard -Force
            }
    }

    # Guarded for the same reason as Update-RecentList and $script:TrimEditorReady: an
    # install updated in place can run this code against a MainWindow.xaml that predates
    # these buttons, and Add_Click on a $null reference takes startup down before the
    # window ever shows. ffprobe has no button by design, which is why $toolRows already
    # tolerates a $null there.
    if ($null -ne $toolRows["ffmpeg"].Button) {
        $toolRows["ffmpeg"].Button.Add_Click({ Start-ToolInstall -Name "ffmpeg" })
    }
    if ($null -ne $toolRows["yt-dlp"].Button) {
        $toolRows["yt-dlp"].Button.Add_Click({ Start-ToolInstall -Name "yt-dlp" })
    }

    # Cancelling faults the in-flight copy; Install-ToolUpdate's next tick observes that,
    # deletes the partial file and calls OnComplete, so the reset all happens there.
    $toolsCancel.Add_Click({
        $toolsCancel.IsEnabled = $false
        if ($script:ToolInstallState) { & $script:ToolInstallState.Cancel }
    })

    # The trim editor's scratch directories live for the session. Thumbnails are a few
    # hundred KB, but the rendered fades are real mp4s, so leaving a set behind per run
    # accumulates in %TEMP% with nothing to ever clear it.
    # Saving is explicit now: closing with unsaved work ASKS (Yes = save, No = discard,
    # Cancel = stay open). This is the Closing event, not Closed -- only Closing can
    # still veto the close via e.Cancel.
    $ctx.Window.Add_Closing({
        param($eventSource, $e)
        if (-not (Confirm-TrimUnsavedWork)) { $e.Cancel = $true }
    })

    $ctx.Window.Add_Closed({
        foreach ($dir in @($script:TrimThumbDir, $script:TrimFadeProxyDir)) {
            if ($dir -and (Test-Path $dir)) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    })

    # ---------------- Startup tool-attention check ----------------
    # The same background fetch the Settings card runs, fired once right after launch:
    # it lights the Settings glow when ffmpeg or yt-dlp has an update waiting, so the
    # user hears about a stale tool before a download fails on it, not after. It also
    # seeds the card's session state through the same write-through setters, which makes
    # the first Settings visit render instantly instead of re-spawning the three
    # version-check processes. If the user opens Settings while this is still in flight,
    # both fetches run and write equivalent values -- wasteful once, but never wrong.
    function Start-ToolAttentionCheck {
        $useCache = [bool]($global:ToolCheckCache -and `
                    (Test-ToolCacheFresh -Timestamp $global:ToolCheckCache.CheckedUtc -MaxAgeMinutes 60))
        $cachedTools = if ($global:ToolCheckCache) { $global:ToolCheckCache.Tools } else { $null }
        $shared = [hashtable]::Synchronized(@{ Installed = @{}; Latest = @{} })

        $ps = [powershell]::Create()
        $ps.AddScript($script:ToolFetchScript).AddArgument((Join-Path $scriptRoot "backend\ToolUpdates.psm1")).AddArgument($scriptRoot).AddArgument($true).AddArgument($useCache).AddArgument($cachedTools).AddArgument($shared) | Out-Null

        $handle = $ps.BeginInvoke()
        $watcher = New-Object System.Windows.Threading.DispatcherTimer
        # Nothing on screen is waiting for this, so it polls lazily compared to the
        # Settings card's 100ms.
        $watcher.Interval = [timespan]::FromMilliseconds(250)
        $watcher.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $watcher.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            $ps.Dispose()

            # Seed the card's state through the same write-through setters the card
            # itself uses (the $script: closure trap documented on them applies here
            # identically). $toolRows mutation is by reference, same as the card's tick.
            foreach ($name in @("ffmpeg", "ffprobe", "yt-dlp")) {
                if ($shared.Installed[$name]) { $toolRows[$name].Installed = $shared.Installed[$name] }
            }
            Set-InstalledVersionsChecked
            foreach ($name in @("ffmpeg", "yt-dlp")) {
                if ($shared.Latest[$name]) { Set-LatestRelease -Name $name -Release $shared.Latest[$name] }
            }
            if (-not $useCache) { Save-ToolCheckCache }

            $needsAttention = $false
            foreach ($name in @("ffmpeg", "yt-dlp")) {
                if (-not $shared.Installed[$name] -or -not $shared.Latest[$name]) { continue }
                $verdict = Test-ToolUpdate -Installed $shared.Installed[$name] -Latest $shared.Latest[$name]
                if ($verdict.Status -eq "Available") {
                    $needsAttention = $true
                    # Lit now, not on the first Settings visit, so the row is already
                    # marked when the sidebar badge brings the user there.
                    Set-ToolAttention -Name $name -On $true
                }
                # A tool absent everywhere means the next job that needs it fails; one
                # found on PATH works today and is deliberately not nagged about.
                if ($verdict.Status -eq "Missing" -and $shared.Installed[$name].Source -eq "missing") {
                    $needsAttention = $true
                    Set-ToolAttention -Name $name -On $true
                }
            }
            if ($needsAttention) { Show-SettingsGlow }
        }.GetNewClosure())
        $watcher.Start()
    }

    Start-ToolAttentionCheck

    Show-Panel -Context $ctx -Name "Compress"
