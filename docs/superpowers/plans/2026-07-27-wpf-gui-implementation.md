# FFmpeg GUI: WPF Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the console `Read-Host` menu loop in `Video-Audio-Tool.ps1` with a native WPF window ("Midnight Gold" theme), while reusing the existing PowerShell module logic (`VideoProcessing.psm1`, `AudioProcessing.psm1`, `VideoTrimmer.psm1`, `YouTubeDownload.psm1`, `Settings.psm1`) with their console I/O stripped out.

**Architecture:** A single `MainWindow.xaml` defines a sidebar + six content panels (one per tool), loaded via `[System.Windows.Markup.XamlReader]`. A new `UI-WPF.psm1` owns window bootstrapping, panel switching (with an animated sidebar highlight), and an async ffmpeg/yt-dlp progress reader that never blocks the UI thread. Existing modules keep their argument-building/process logic but drop `Read-Host`/`Write-Host`/`Wait-KeyPress` in favor of parameters and UI callbacks. A new `ToolPaths.psm1` resolves `ffmpeg`/`ffprobe`/`yt-dlp` from a bundled `bin/` folder first, falling back to `PATH`.

**Tech Stack:** PowerShell 5.1, WPF (`PresentationFramework`/`PresentationCore` via `Add-Type -AssemblyName`), XAML, Pester (built into Windows PowerShell) for the pure-logic unit tests.

## Global Constraints

- Backend logic (ffmpeg/ffprobe/yt-dlp argument construction, GPU detection, compression presets) must not be rewritten — only its I/O seam (console vs. UI) changes. Copied verbatim from the spec.
- No dual-mode: the WPF window is the only frontend after this plan lands. The old `do/while` console menu in `Video-Audio-Tool.ps1` is deleted, not kept behind a flag.
- No boot-intro animation, page-wipe transitions, custom cursor, or particle-text dissolve in this plan — only sidebar pill-glide, hover states, and the glassmorphism drifting glow.
- `ShowAnimations` (from `Settings.psm1`, unchanged) must continue to gate whether pill-glide/glow-drift/hover transitions play.
- Visual system is "Midnight Gold": background gradient mesh (`#090D1A` base + four corner radial tones), accent gradient `#152C61 → #1F3F7A → #D3A24C`, borders `rgba(211,162,76,0.18–0.22)`, restrained glow, glassmorphism dropzone with single drifting corner glow (no diagonal shine bar). Typography: Plus Jakarta Sans for chrome/buttons, JetBrains Mono for data/metadata values.
- This codebase has no existing automated test suite; where module logic is pure (path resolution, resolution-filter matching, ffmpeg progress-line parsing), this plan adds Pester tests. Where a step is inherently a live WPF window / real ffmpeg process, this plan uses explicit manual verification instructions instead of an automated test, per the spec's testing section.

---

### Task 1: Shared tool-path resolution (`ToolPaths.psm1`)

**Files:**
- Create: `src/modules/ToolPaths.psm1`
- Test: `src/modules/Tests/ToolPaths.Tests.ps1`

**Interfaces:**
- Produces: `Get-ToolPath -Name <string>` → returns the full path to `bin/<Name>.exe` next to the script if it exists, otherwise returns `<Name>` (bare, so it resolves via `PATH` exactly like today's `$ffmpeg = "ffmpeg"` behavior). Later tasks (2, 4, 5, 6, 7, 8) call this instead of hardcoding `"ffmpeg"`/`"ffprobe"`/`"yt-dlp"`.

- [ ] **Step 1: Write the failing test**

```powershell
# src/modules/Tests/ToolPaths.Tests.ps1
$modulePath = Join-Path $PSScriptRoot "..\ToolPaths.psm1"
Import-Module $modulePath -Force

Describe "Get-ToolPath" {
    It "returns the bundled bin path when the exe exists there" {
        $fakeRoot = Join-Path $TestDrive "app"
        $fakeBin = Join-Path $fakeRoot "bin"
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $fakeBin "ffmpeg.exe") -Force | Out-Null

        $result = Get-ToolPath -Name "ffmpeg" -ScriptRoot $fakeRoot
        $result | Should -Be (Join-Path $fakeBin "ffmpeg.exe")
    }

    It "falls back to the bare name when no bundled exe exists" {
        $fakeRoot = Join-Path $TestDrive "app-nobundled"
        New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null

        $result = Get-ToolPath -Name "yt-dlp" -ScriptRoot $fakeRoot
        $result | Should -Be "yt-dlp"
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester "D:\FFmpeg-GUI\src\modules\Tests\ToolPaths.Tests.ps1" -Output Detailed`
Expected: FAIL — `Get-ToolPath` is not recognized (module doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

```powershell
# src/modules/ToolPaths.psm1
function Get-ToolPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ScriptRoot = $PSScriptRoot
    )

    $binPath = Join-Path (Join-Path $ScriptRoot "bin") "$Name.exe"
    if (Test-Path -LiteralPath $binPath) {
        return $binPath
    }

    return $Name
}

Export-ModuleMember -Function Get-ToolPath
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester "D:\FFmpeg-GUI\src\modules\Tests\ToolPaths.Tests.ps1" -Output Detailed`
Expected: PASS (2/2)

- [ ] **Step 5: Commit**

```bash
git add src/modules/ToolPaths.psm1 src/modules/Tests/ToolPaths.Tests.ps1
git commit -m "Add bundled-binary path resolution for ffmpeg/ffprobe/yt-dlp"
```

---

### Task 2: Extract YouTube resolution filter as a pure, tested function

**Files:**
- Modify: `src/modules/YouTubeDownload.psm1` (the `$resolutions`/`$availableResolutions` block inside `Save-YouTubeMP4`, currently around lines 126–143)
- Test: `src/modules/Tests/YouTubeDownload.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Get-AvailableResolutions -FormatsText <string>` → returns the filtered array of resolution hashtables (`height`/`name`/`code`/`formatString`), same shape as today's inline `$availableResolutions`. `Save-YouTubeMP4` (modified in Task 8) calls this instead of inlining the loop.

- [ ] **Step 1: Write the failing test**

```powershell
# src/modules/Tests/YouTubeDownload.Tests.ps1
$modulePath = Join-Path $PSScriptRoot "..\YouTubeDownload.psm1"
Import-Module (Join-Path $PSScriptRoot "..\UI.psm1") -Force
Import-Module $modulePath -Force

Describe "Get-AvailableResolutions" {
    It "only includes resolutions actually present in the yt-dlp -F output" {
        $formats = @"
ID  EXT  RESOLUTION FPS |  FILESIZE   TBR PROTO | VCODEC
137 mp4  1920x1080   30 |   45.20MiB  4000 https | avc1.640028
248 webm 1280x720    30 |   20.10MiB  1800 https | vp9
"@
        $result = Get-AvailableResolutions -FormatsText $formats
        ($result | ForEach-Object { $_.height }) | Should -Be @("1080", "720")
    }

    It "excludes resolutions with no matching pattern in the formats text" {
        $formats = "ID  EXT  RESOLUTION FPS`n137 mp4  640x360   30"
        $result = Get-AvailableResolutions -FormatsText $formats
        ($result | ForEach-Object { $_.height }) | Should -Be @("360")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester "D:\FFmpeg-GUI\src\modules\Tests\YouTubeDownload.Tests.ps1" -Output Detailed`
Expected: FAIL — `Get-AvailableResolutions` is not recognized.

- [ ] **Step 3: Write minimal implementation**

Add this function to `src/modules/YouTubeDownload.psm1` (near the top, after the `Import-Module UI.psm1` line), and add it to the `Export-ModuleMember` list at the bottom:

```powershell
function Get-AvailableResolutions {
    param([Parameter(Mandatory = $true)][string]$FormatsText)

    $resolutions = @(
        @{height = "4320"; name = "8K"; code = "2160p60"; formatString = "bestvideo[height<=4320]+bestaudio/best[height<=4320]" },
        @{height = "2160"; name = "4K"; code = "2160p"; formatString = "bestvideo[height<=2160]+bestaudio/best[height<=2160]" },
        @{height = "1440"; name = "2K"; code = "1440p"; formatString = "bestvideo[height<=1440]+bestaudio/best[height<=1440]" },
        @{height = "1080"; name = "Full HD"; code = "1080p"; formatString = "best[height<=1080][ext=mp4]/best[ext=mp4]/best" },
        @{height = "720"; name = "HD"; code = "720p"; formatString = "best[height<=720][ext=mp4]/best[ext=mp4]/best" },
        @{height = "480"; name = "SD"; code = "480p"; formatString = "best[height<=480][ext=mp4]/best[ext=mp4]/best" },
        @{height = "360"; name = "Low"; code = "360p"; formatString = "best[height<=360][ext=mp4]/best[ext=mp4]/best" }
    )

    $available = @()
    foreach ($res in $resolutions) {
        if ($FormatsText -match "$($res.height)p" -or $FormatsText -match "x$($res.height)\b") {
            $available += $res
        }
    }
    return $available
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester "D:\FFmpeg-GUI\src\modules\Tests\YouTubeDownload.Tests.ps1" -Output Detailed`
Expected: PASS (2/2)

- [ ] **Step 5: Commit**

```bash
git add src/modules/YouTubeDownload.psm1 src/modules/Tests/YouTubeDownload.Tests.ps1
git commit -m "Extract YouTube resolution filtering into a tested pure function"
```

---

### Task 3: Extract the ffmpeg progress-line parser as a pure, tested function

**Files:**
- Modify: `src/modules/UI.psm1` (the `time=` regex block inside `Invoke-FFmpegProcess`, currently lines 316–332)
- Test: `src/modules/Tests/UI.Tests.ps1`

**Interfaces:**
- Produces: `ConvertFrom-FFmpegProgressLine -Line <string> -TotalSeconds <double> -ElapsedSeconds <double>` → returns `$null` if the line has no `time=` match, otherwise a hashtable `@{ Percent = <double>; EtaString = <string> }`. Task 4's `Invoke-FFmpegProcessAsync` calls this on every stderr line instead of inlining the regex.

- [ ] **Step 1: Write the failing test**

```powershell
# src/modules/Tests/UI.Tests.ps1
$modulePath = Join-Path $PSScriptRoot "..\UI.psm1"
Import-Module $modulePath -Force

Describe "ConvertFrom-FFmpegProgressLine" {
    It "parses a time= line into percent and ETA" {
        $line = "frame=100 fps=25 q=28.0 size=1024kB time=00:00:30.00 bitrate=512kb/s"
        $result = ConvertFrom-FFmpegProgressLine -Line $line -TotalSeconds 60 -ElapsedSeconds 15
        $result.Percent | Should -Be 50.0
        $result.EtaString | Should -Be "00:00:15"
    }

    It "returns null for a line with no time= field" {
        $line = "Stream mapping: Stream #0:0 -> #0:0 (h264 (native) -> h264 (libx264))"
        $result = ConvertFrom-FFmpegProgressLine -Line $line -TotalSeconds 60 -ElapsedSeconds 15
        $result | Should -Be $null
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester "D:\FFmpeg-GUI\src\modules\Tests\UI.Tests.ps1" -Output Detailed`
Expected: FAIL — `ConvertFrom-FFmpegProgressLine` is not recognized.

- [ ] **Step 3: Write minimal implementation**

Add this function to `src/modules/UI.psm1` above `Invoke-FFmpegProcess`, and add `ConvertFrom-FFmpegProgressLine` to the `Export-ModuleMember` list at the bottom:

```powershell
function ConvertFrom-FFmpegProgressLine {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][double]$TotalSeconds,
        [Parameter(Mandatory = $true)][double]$ElapsedSeconds
    )

    if ($Line -notmatch "time=(\d{2}):(\d{2}):(\d{2}\.\d{2})") {
        return $null
    }

    $hours, $minutes, $seconds = [int]$matches[1], [int]$matches[2], [double]$matches[3]
    $currentPos = ($hours * 3600) + ($minutes * 60) + $seconds

    if ($TotalSeconds -le 0) {
        return @{ Percent = 0; EtaString = "--:--:--" }
    }

    $percent = [math]::Min(100, [math]::Round(($currentPos / $TotalSeconds) * 100, 1))

    if ($percent -gt 0) {
        $totalEstimatedSeconds = ($ElapsedSeconds / $percent) * 100
        $remaining = [timespan]::FromSeconds($totalEstimatedSeconds - $ElapsedSeconds)
        $etaString = $remaining.ToString("hh\:mm\:ss")
    } else {
        $etaString = "--:--:--"
    }

    return @{ Percent = $percent; EtaString = $etaString }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester "D:\FFmpeg-GUI\src\modules\Tests\UI.Tests.ps1" -Output Detailed`
Expected: PASS (2/2)

- [ ] **Step 5: Commit**

```bash
git add src/modules/UI.psm1 src/modules/Tests/UI.Tests.ps1
git commit -m "Extract ffmpeg progress-line parsing into a tested pure function"
```

---

### Task 4: Midnight Gold theme resources (`Theme.xaml`)

**Files:**
- Create: `src/assets/Theme.xaml`

**Interfaces:**
- Produces: a `ResourceDictionary` with keyed brushes/fonts that Task 5's `MainWindow.xaml` merges in via `Application.Resources` / `Window.Resources`: `BrushShellBackground`, `BrushAccentGradient`, `BrushBorderGold`, `BrushCardBackground`, `FontChrome` (Plus Jakarta Sans, falls back to Segoe UI), `FontData` (JetBrains Mono, falls back to Consolas).

- [ ] **Step 1: Write the resource dictionary**

```xml
<!-- src/assets/Theme.xaml -->
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                     xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

    <FontFamily x:Key="FontChrome">Segoe UI</FontFamily>
    <FontFamily x:Key="FontData">Consolas</FontFamily>

    <SolidColorBrush x:Key="BrushShellBase" Color="#090D1A"/>

    <RadialGradientBrush x:Key="BrushGlowGold" GradientOrigin="0.5,0.5" Center="0.5,0.5" RadiusX="0.6" RadiusY="0.6">
        <GradientStop Color="#29D3A24C" Offset="0"/>
        <GradientStop Color="#00D3A24C" Offset="1"/>
    </RadialGradientBrush>

    <RadialGradientBrush x:Key="BrushGlowNavy" GradientOrigin="0.5,0.5" Center="0.5,0.5" RadiusX="0.6" RadiusY="0.6">
        <GradientStop Color="#471F3F7A" Offset="0"/>
        <GradientStop Color="#001F3F7A" Offset="1"/>
    </RadialGradientBrush>

    <LinearGradientBrush x:Key="BrushAccentGradient" StartPoint="0,0" EndPoint="1,0">
        <GradientStop Color="#152C61" Offset="0"/>
        <GradientStop Color="#1F3F7A" Offset="0.5"/>
        <GradientStop Color="#D3A24C" Offset="1"/>
    </LinearGradientBrush>

    <SolidColorBrush x:Key="BrushBorderGold" Color="#3AD3A24C"/>
    <SolidColorBrush x:Key="BrushCardBackground" Color="#0C1626"/>
    <SolidColorBrush x:Key="BrushTextPrimary" Color="#F2EDE0"/>
    <SolidColorBrush x:Key="BrushTextMuted" Color="#8890B0"/>
    <SolidColorBrush x:Key="BrushGoldValue" Color="#E0C48F"/>

    <Style x:Key="SidebarItemStyle" TargetType="Button">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Foreground" Value="{StaticResource BrushTextMuted}"/>
        <Setter Property="FontFamily" Value="{StaticResource FontChrome}"/>
        <Setter Property="HorizontalContentAlignment" Value="Left"/>
        <Setter Property="Padding" Value="14,10"/>
        <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style x:Key="PresetButtonStyle" TargetType="Button">
        <Setter Property="Background" Value="#101B30"/>
        <Setter Property="Foreground" Value="{StaticResource BrushTextMuted}"/>
        <Setter Property="FontFamily" Value="{StaticResource FontChrome}"/>
        <Setter Property="BorderBrush" Value="{StaticResource BrushBorderGold}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="10,8"/>
        <Setter Property="Cursor" Value="Hand"/>
    </Style>

</ResourceDictionary>
```

- [ ] **Step 2: Manual verification**

This file has no runtime behavior on its own — it's verified indirectly in Task 5 when `MainWindow.xaml` loads it via `Merge­DictionaryDictionaries` and the window renders with these colors. No standalone test for a resource dictionary.

- [ ] **Step 3: Commit**

```bash
git add src/assets/Theme.xaml
git commit -m "Add Midnight Gold WPF theme resource dictionary"
```

---

### Task 5: Main window shell — sidebar with sliding pill, six empty panels

**Files:**
- Create: `src/assets/MainWindow.xaml`
- Create: `src/modules/UI-WPF.psm1`

**Interfaces:**
- Consumes: `src/assets/Theme.xaml` (Task 4).
- Produces:
  - `Initialize-MainWindow -ScriptRoot <string>` → loads `MainWindow.xaml`, merges `Theme.xaml`, returns a hashtable `@{ Window = <Window>; Panels = @{ Compress=<Grid>; MergeAudio=<Grid>; Trim=<Grid>; YouTubeMP3=<Grid>; YouTubeMP4=<Grid>; Settings=<Grid> }; NavButtons = @{ ... same keys ... }; Pill = <Border> }`. Later tasks (5–9) use `.Panels.<Name>` to find/populate controls inside each panel via `FindName` on the panel itself, and wire `.NavButtons.<Name>.Add_Click(...)`.
  - `Show-Panel -Context <hashtable from Initialize-MainWindow> -Name <string>` → collapses all panels except `Name`, and animates `Pill`'s `Margin`/`Canvas.Top` to the selected nav button's position (skips the animation, snapping instead, when `$global:ShowAnimations` is `$false`).

- [ ] **Step 1: Write the XAML shell**

```xml
<!-- src/assets/MainWindow.xaml -->
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FFmpeg GUI" Height="620" Width="960"
        WindowStartupLocation="CenterScreen"
        Background="{StaticResource BrushShellBase}">

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="180"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Grid Grid.Column="0" Background="#0B0F1C">
            <Canvas x:Name="PillCanvas">
                <Border x:Name="NavPill" Width="150" Height="38" CornerRadius="8"
                        Background="{StaticResource BrushAccentGradient}"
                        Canvas.Left="10" Canvas.Top="70"/>
            </Canvas>
            <StackPanel Margin="0,60,0,0">
                <Button x:Name="NavCompress" Content="Compress" Style="{StaticResource SidebarItemStyle}" Tag="Compress"/>
                <Button x:Name="NavMergeAudio" Content="Merge Audio" Style="{StaticResource SidebarItemStyle}" Tag="MergeAudio"/>
                <Button x:Name="NavTrim" Content="Trim" Style="{StaticResource SidebarItemStyle}" Tag="Trim"/>
                <Button x:Name="NavYouTubeMP3" Content="YouTube MP3" Style="{StaticResource SidebarItemStyle}" Tag="YouTubeMP3"/>
                <Button x:Name="NavYouTubeMP4" Content="YouTube MP4" Style="{StaticResource SidebarItemStyle}" Tag="YouTubeMP4"/>
                <Button x:Name="NavSettings" Content="Settings" Style="{StaticResource SidebarItemStyle}" Tag="Settings"/>
            </StackPanel>
        </Grid>

        <!-- Content -->
        <Grid Grid.Column="1" Margin="30,24">
            <Grid x:Name="PanelCompress" Visibility="Visible"/>
            <Grid x:Name="PanelMergeAudio" Visibility="Collapsed"/>
            <Grid x:Name="PanelTrim" Visibility="Collapsed"/>
            <Grid x:Name="PanelYouTubeMP3" Visibility="Collapsed"/>
            <Grid x:Name="PanelYouTubeMP4" Visibility="Collapsed"/>
            <Grid x:Name="PanelSettings" Visibility="Collapsed"/>
        </Grid>
    </Grid>
</Window>
```

- [ ] **Step 2: Write `UI-WPF.psm1`**

```powershell
# src/modules/UI-WPF.psm1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function Initialize-MainWindow {
    param([Parameter(Mandatory = $true)][string]$ScriptRoot)

    $xamlPath = Join-Path $ScriptRoot "assets\MainWindow.xaml"
    $themePath = Join-Path $ScriptRoot "assets\Theme.xaml"

    [xml]$xaml = Get-Content -Path $xamlPath -Raw
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    [xml]$themeXaml = Get-Content -Path $themePath -Raw
    $themeReader = New-Object System.Xml.XmlNodeReader $themeXaml
    $themeDict = [System.Windows.Markup.XamlReader]::Load($themeReader)
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

Export-ModuleMember -Function Initialize-MainWindow, Show-Panel
```

- [ ] **Step 3: Manual verification**

Run:
```powershell
powershell -NoProfile -Command "
Import-Module 'D:\FFmpeg-GUI\src\modules\UI-WPF.psm1' -Force
`$ctx = Initialize-MainWindow -ScriptRoot 'D:\FFmpeg-GUI\src'
foreach (`$name in `$ctx.NavButtons.Keys) {
    `$n = `$name
    `$ctx.NavButtons[`$n].Add_Click({ Show-Panel -Context `$ctx -Name `$n }.GetNewClosure())
}
`$ctx.Window.ShowDialog() | Out-Null
"
```
Expected: a window opens with the dark gradient sidebar and a gold-gradient pill next to "Compress". Clicking each sidebar button glides the pill to that button's position. Set `assets/settings.json`'s `ShowAnimations` to `false` and re-run — the pill should snap instantly instead of gliding.

- [ ] **Step 4: Commit**

```bash
git add src/assets/MainWindow.xaml src/modules/UI-WPF.psm1
git commit -m "Add WPF main window shell with animated sidebar navigation"
```

---

### Task 6: Async, non-blocking ffmpeg/yt-dlp process runner with Cancel support

**Files:**
- Modify: `src/modules/UI-WPF.psm1`

**Interfaces:**
- Consumes: `ConvertFrom-FFmpegProgressLine` (Task 3, from `UI.psm1`).
- Produces: `Start-TrackedProcess -FileName <string> -Arguments <string> -OnOutputLine <scriptblock> -OnExit <scriptblock>` → starts the process with async output reading (`add_OutputDataReceived`/`BeginOutputReadLine` for stdout-based tools like yt-dlp, `add_ErrorDataReceived`/`BeginErrorReadLine` for ffmpeg which writes progress to stderr — selected via a `-ReadStream Output|Error` parameter), returns the raw `System.Diagnostics.Process` object so callers can later call `.Kill()` from a Cancel button. `OnOutputLine` and `OnExit` scriptblocks are invoked via `$window.Dispatcher.Invoke(...)` internally so callers can safely touch UI controls from inside them.

- [ ] **Step 1: Write the implementation**

Add to `src/modules/UI-WPF.psm1` (needs a module-level reference to the dispatcher; store it on the context hashtable returned by `Initialize-MainWindow`, and pass `$Context` into this function):

```powershell
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
    $process.EnableRaisingEvents = $true

    $dispatcher = $Context.Window.Dispatcher

    $handler = {
        param($sender, $e)
        if ([string]::IsNullOrEmpty($e.Data)) { return }
        $dispatcher.Invoke([action]{ & $OnLine $e.Data }.GetNewClosure())
    }.GetNewClosure()

    if ($ReadStream -eq "Error") {
        $process.add_ErrorDataReceived($handler)
    } else {
        $process.add_OutputDataReceived($handler)
    }

    $process.add_Exited({
        $dispatcher.Invoke([action]{ & $OnExit $process.ExitCode }.GetNewClosure())
    }.GetNewClosure())

    $process.Start() | Out-Null
    if ($ReadStream -eq "Error") { $process.BeginErrorReadLine() } else { $process.BeginOutputReadLine() }

    return $process
}

Export-ModuleMember -Function Initialize-MainWindow, Show-Panel, Start-TrackedProcess
```

(Replace the previous `Export-ModuleMember` line from Task 5 with this one.)

- [ ] **Step 2: Manual verification**

Run a short real compress to confirm the window doesn't freeze:
```powershell
powershell -NoProfile -Command "
Import-Module 'D:\FFmpeg-GUI\src\modules\UI-WPF.psm1' -Force
`$ctx = Initialize-MainWindow -ScriptRoot 'D:\FFmpeg-GUI\src'
`$proc = Start-TrackedProcess -Context `$ctx -FileName 'ffmpeg' -Arguments '-i test.mp4 -c:v libx264 -crf 28 -y out.mp4' -ReadStream Error -OnLine { param(`$line) Write-Host `$line } -OnExit { param(`$code) Write-Host \"exit: `$code\" }
`$ctx.Window.ShowDialog() | Out-Null
"
```
Expected: the window remains draggable and repaints normally while `ffmpeg` runs in the background; console shows streamed stderr lines; `out.mp4` is produced. Confirm you can move/resize the window mid-run — if the UI thread were blocked, this would hang.

- [ ] **Step 3: Commit**

```bash
git add src/modules/UI-WPF.psm1
git commit -m "Add async non-blocking process runner for ffmpeg/yt-dlp with cancel support"
```

---

### Task 7: Compress screen

**Files:**
- Modify: `src/assets/MainWindow.xaml` (fill in `PanelCompress`)
- Modify: `src/modules/VideoProcessing.psm1` (adapt `Compress-Video`, `Get-CompressionSuggestions`; use `Get-ToolPath` for `$ffprobe`)
- Modify: `src/Video-Audio-Tool.ps1` (wire the panel)

**Interfaces:**
- Consumes: `Get-ToolPath` (Task 1), `Start-TrackedProcess`/`Show-Panel` (Tasks 5–6), `ConvertFrom-FFmpegProgressLine` (Task 3).
- Produces: `Compress-VideoAsync -Context <hashtable> -InputFile <string> -Preset <string> -Mode <string>` in `VideoProcessing.psm1` — builds the same ffmpeg argument list `Compress-Video` already builds, but calls `Start-TrackedProcess` instead of the console `Invoke-FFmpegProcess`, and updates the panel's `ProgressBarCompress`/`TextCompressPercent`/`TextCompressEta` controls instead of `Write-Host`. Returns the live `Process` object so the Cancel button can kill it.

- [ ] **Step 1: Add the Compress panel markup**

Replace `<Grid x:Name="PanelCompress" Visibility="Visible"/>` in `src/assets/MainWindow.xaml` with:

```xml
<Grid x:Name="PanelCompress" Visibility="Visible">
    <StackPanel>
        <TextBlock Text="Compress Video" FontSize="20" FontWeight="Bold"
                   Foreground="{StaticResource BrushTextPrimary}" FontFamily="{StaticResource FontChrome}"/>
        <TextBlock x:Name="TextCompressMeta" Text="No file selected" FontSize="11"
                   Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontData}" Margin="0,4,0,16"/>

        <Button x:Name="ButtonCompressBrowse" Content="Browse for a .mp4..." Style="{StaticResource PresetButtonStyle}"
                HorizontalAlignment="Left" Padding="16,10" Margin="0,0,0,16"/>

        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
            <Button x:Name="ButtonPresetHigh" Content="High Quality" Style="{StaticResource PresetButtonStyle}" Width="140" Margin="0,0,8,0"/>
            <Button x:Name="ButtonPresetBalanced" Content="Balanced" Style="{StaticResource PresetButtonStyle}" Width="140" Margin="0,0,8,0"/>
            <Button x:Name="ButtonPresetSmall" Content="Small Size" Style="{StaticResource PresetButtonStyle}" Width="140"/>
        </StackPanel>

        <ProgressBar x:Name="ProgressBarCompress" Height="10" Minimum="0" Maximum="100" Value="0"
                     Foreground="{StaticResource BrushAccentGradient}" Background="#0D1526"/>
        <Grid Margin="0,4,0,0">
            <TextBlock x:Name="TextCompressPercent" Text="0.0%" FontFamily="{StaticResource FontData}"
                       Foreground="{StaticResource BrushTextMuted}" HorizontalAlignment="Left"/>
            <TextBlock x:Name="TextCompressEta" Text="--:--:--" FontFamily="{StaticResource FontData}"
                       Foreground="{StaticResource BrushTextMuted}" HorizontalAlignment="Right"/>
        </Grid>

        <Button x:Name="ButtonCompressCancel" Content="Cancel" Style="{StaticResource PresetButtonStyle}"
                HorizontalAlignment="Left" Width="100" Margin="0,16,0,0" IsEnabled="False"/>
    </StackPanel>
</Grid>
```

- [ ] **Step 2: Adapt `VideoProcessing.psm1`**

Change line 2 (`$ffprobe = "ffprobe"`) to use the resolved path, and add `Compress-VideoAsync`. At the top of the file:

```powershell
Import-Module "$PSScriptRoot/ToolPaths.psm1"
$ffprobe = Get-ToolPath -Name "ffprobe" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
```

Add this function (leave the existing console `Compress-Video` in place for now — it becomes dead code removed in Task 10's cleanup pass, since other console-menu call sites are all deleted together in that task):

```powershell
function Compress-VideoAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$Preset,
        [hashtable]$VideoProps
    )

    if (-not $VideoProps) { $VideoProps = Get-VideoProperties -inputFile $InputFile }
    $totalSeconds = $VideoProps.Duration.TotalSeconds
    $selectedPreset = $script:CompressionPresets[$Preset]
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $outputFile = "$baseName-$($Preset.ToLower().Replace(' ', '-')).mp4"

    $argList = @("-i", "`"$InputFile`"")
    if ($selectedPreset.MapAll) { $argList += "-map", "0" }
    if ($selectedPreset.Codec -like "*nvenc") {
        $argList += "-c:v", $selectedPreset.Codec, "-rc", "vbr", "-cq", $selectedPreset.CRF, "-preset", $selectedPreset.Preset, "-b:v", "0"
    } else {
        $argList += "-c:v", $selectedPreset.Codec, "-crf", $selectedPreset.CRF, "-preset", $selectedPreset.Preset
    }
    $argList += "-c:a", "copy", "`"$outputFile`"", "-y"

    $panel = $Context.Panels.Compress
    $progressBar = $panel.FindName("ProgressBarCompress")
    $percentText = $panel.FindName("TextCompressPercent")
    $etaText = $panel.FindName("TextCompressEta")
    $cancelButton = $panel.FindName("ButtonCompressCancel")
    $startTime = Get-Date

    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    $process = Start-TrackedProcess -Context $Context -FileName $ffmpegPath -Arguments ($argList -join " ") -ReadStream Error `
        -OnLine {
            param($line)
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $progress = ConvertFrom-FFmpegProgressLine -Line $line -TotalSeconds $totalSeconds -ElapsedSeconds $elapsed
            if ($progress) {
                $progressBar.Value = $progress.Percent
                $percentText.Text = "{0:N1}%" -f $progress.Percent
                $etaText.Text = $progress.EtaString
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%"; $etaText.Text = "00:00:00" }
        }.GetNewClosure()

    $cancelButton.IsEnabled = $true
    $cancelButton.Add_Click({ if (-not $process.HasExited) { $process.Kill() } }.GetNewClosure())

    return $process
}
```

Add `Compress-VideoAsync` to the module's `Export-ModuleMember -Function` list.

- [ ] **Step 3: Wire the panel in `Video-Audio-Tool.ps1`**

(This wiring is finalized alongside all other panels in Task 10 — the entry-point rewrite — since that's where the window is actually shown. For this task, verify in isolation per Step 4 below.)

- [ ] **Step 4: Manual verification**

```powershell
powershell -NoProfile -Command "
Import-Module 'D:\FFmpeg-GUI\src\modules\UI-WPF.psm1' -Force
Import-Module 'D:\FFmpeg-GUI\src\modules\VideoProcessing.psm1' -Force
`$ctx = Initialize-MainWindow -ScriptRoot 'D:\FFmpeg-GUI\src'
`$props = Get-VideoProperties -inputFile 'D:\FFmpeg-GUI\test.mp4'
Compress-VideoAsync -Context `$ctx -InputFile 'D:\FFmpeg-GUI\test.mp4' -Preset 'Balanced' -VideoProps `$props
`$ctx.Window.ShowDialog() | Out-Null
"
```
Expected: progress bar and percent/ETA text update live as ffmpeg runs; Cancel button is enabled during the run and killing the process (click Cancel) stops ffmpeg immediately and disables the button; a real `test.mp4-balanced.mp4` file is produced on success.

- [ ] **Step 5: Commit**

```bash
git add src/assets/MainWindow.xaml src/modules/VideoProcessing.psm1
git commit -m "Add Compress screen with async progress and cancel"
```

---

### Task 8: Merge Audio and Trim screens

**Files:**
- Modify: `src/assets/MainWindow.xaml` (fill in `PanelMergeAudio`, `PanelTrim`)
- Modify: `src/modules/AudioProcessing.psm1` (adapt `Merge-AudioStreams` → `Merge-AudioStreamsAsync`, drop `Read-Host` volume prompts in favor of parameters, use `Get-ToolPath`)
- Modify: `src/modules/VideoTrimmer.psm1` (adapt `Split-Video` → `Split-VideoAsync`, use `Start-TrackedProcess` instead of the console `Invoke-FFmpegProcess`)

**Interfaces:**
- Produces: `Merge-AudioStreamsAsync -Context <hashtable> -InputVideo <string> -SystemVolume <double> -MicVolume <double>` (volumes default to `1.0`, sourced from new slider/dropdown controls in the panel instead of `Read-Host`). `Split-VideoAsync -Context <hashtable> -InputFile <string> -Mode <string> -Timestamp <string>`. Both follow the exact same `Start-TrackedProcess`/progress-control-update pattern established in Task 7's `Compress-VideoAsync`.

- [ ] **Step 1: Add Merge Audio and Trim panel markup**

Replace the two placeholder `Grid` elements in `src/assets/MainWindow.xaml`:

```xml
<Grid x:Name="PanelMergeAudio" Visibility="Collapsed">
    <StackPanel>
        <TextBlock Text="Merge Audio Streams" FontSize="20" FontWeight="Bold"
                   Foreground="{StaticResource BrushTextPrimary}" FontFamily="{StaticResource FontChrome}"/>
        <TextBlock x:Name="TextMergeMeta" Text="No file selected" FontSize="11"
                   Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontData}" Margin="0,4,0,16"/>
        <Button x:Name="ButtonMergeBrowse" Content="Browse for a .mp4..." Style="{StaticResource PresetButtonStyle}"
                HorizontalAlignment="Left" Padding="16,10" Margin="0,0,0,16"/>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
            <TextBlock Text="System volume:" Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontChrome}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="ComboSystemVolume" Width="100" SelectedIndex="0">
                <ComboBoxItem Content="1.0x"/><ComboBoxItem Content="2.0x"/><ComboBoxItem Content="3.5x"/><ComboBoxItem Content="5.0x"/>
            </ComboBox>
            <TextBlock Text="Mic volume:" Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontChrome}" VerticalAlignment="Center" Margin="16,0,8,0"/>
            <ComboBox x:Name="ComboMicVolume" Width="100" SelectedIndex="0">
                <ComboBoxItem Content="1.0x"/><ComboBoxItem Content="2.0x"/><ComboBoxItem Content="3.5x"/><ComboBoxItem Content="5.0x"/>
            </ComboBox>
        </StackPanel>
        <Button x:Name="ButtonMergeStart" Content="Merge" Style="{StaticResource PresetButtonStyle}" Width="140" HorizontalAlignment="Left" Margin="0,0,0,12"/>
        <ProgressBar x:Name="ProgressBarMerge" Height="10" Minimum="0" Maximum="100" Value="0"
                     Foreground="{StaticResource BrushAccentGradient}" Background="#0D1526"/>
        <Grid Margin="0,4,0,0">
            <TextBlock x:Name="TextMergePercent" Text="0.0%" FontFamily="{StaticResource FontData}" Foreground="{StaticResource BrushTextMuted}" HorizontalAlignment="Left"/>
            <TextBlock x:Name="TextMergeEta" Text="--:--:--" FontFamily="{StaticResource FontData}" Foreground="{StaticResource BrushTextMuted}" HorizontalAlignment="Right"/>
        </Grid>
        <Button x:Name="ButtonMergeCancel" Content="Cancel" Style="{StaticResource PresetButtonStyle}" HorizontalAlignment="Left" Width="100" Margin="0,16,0,0" IsEnabled="False"/>
    </StackPanel>
</Grid>
```

```xml
<Grid x:Name="PanelTrim" Visibility="Collapsed">
    <StackPanel>
        <TextBlock Text="Trim Video" FontSize="20" FontWeight="Bold"
                   Foreground="{StaticResource BrushTextPrimary}" FontFamily="{StaticResource FontChrome}"/>
        <TextBlock x:Name="TextTrimMeta" Text="No file selected" FontSize="11"
                   Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontData}" Margin="0,4,0,16"/>
        <Button x:Name="ButtonTrimBrowse" Content="Browse for a .mp4..." Style="{StaticResource PresetButtonStyle}"
                HorizontalAlignment="Left" Padding="16,10" Margin="0,0,0,16"/>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
            <RadioButton x:Name="RadioTrimBefore" Content="Remove content BEFORE timestamp" GroupName="TrimMode" IsChecked="True"
                         Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontChrome}" Margin="0,0,20,0"/>
            <RadioButton x:Name="RadioTrimAfter" Content="Remove content AFTER timestamp" GroupName="TrimMode"
                         Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontChrome}"/>
        </StackPanel>
        <TextBox x:Name="TextTrimTimestamp" Width="140" HorizontalAlignment="Left" FontFamily="{StaticResource FontData}" Text="00:00:00" Margin="0,0,0,12"/>
        <Button x:Name="ButtonTrimStart" Content="Trim" Style="{StaticResource PresetButtonStyle}" Width="140" HorizontalAlignment="Left" Margin="0,0,0,12"/>
        <ProgressBar x:Name="ProgressBarTrim" Height="10" Minimum="0" Maximum="100" Value="0"
                     Foreground="{StaticResource BrushAccentGradient}" Background="#0D1526"/>
        <Grid Margin="0,4,0,0">
            <TextBlock x:Name="TextTrimPercent" Text="0.0%" FontFamily="{StaticResource FontData}" Foreground="{StaticResource BrushTextMuted}" HorizontalAlignment="Left"/>
            <TextBlock x:Name="TextTrimEta" Text="--:--:--" FontFamily="{StaticResource FontData}" Foreground="{StaticResource BrushTextMuted}" HorizontalAlignment="Right"/>
        </Grid>
        <Button x:Name="ButtonTrimCancel" Content="Cancel" Style="{StaticResource PresetButtonStyle}" HorizontalAlignment="Left" Width="100" Margin="0,16,0,0" IsEnabled="False"/>
    </StackPanel>
</Grid>
```

- [ ] **Step 2: Adapt `AudioProcessing.psm1`**

Replace `$ffprobe = "ffprobe"` with the resolved path (same pattern as Task 7), and add:

```powershell
function Merge-AudioStreamsAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputVideo,
        [double]$SystemVolume = 1.0,
        [double]$MicVolume = 1.0
    )

    $durationOutput = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $InputVideo 2>&1
    $totalSeconds = [double]$durationOutput
    $videoInfo = & $ffprobe -v quiet -print_format json -show_streams -select_streams a $InputVideo 2>&1 | ConvertFrom-Json
    $audioStreams = $videoInfo.streams

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputVideo)
    $outputFile = "$baseName-merged-audio.mp4"

    $filterComplex = ""
    for ($i = 0; $i -lt $audioStreams.Count; $i++) {
        $volume = if ($i -eq 0) { $SystemVolume } else { $MicVolume }
        if ($volume -ne 1.0) { $filterComplex += "[0:a:$i]volume=$volume[a$i];" }
        else { $filterComplex += "[0:a:$i]asetpts=PTS-STARTPTS[a$i];" }
    }
    $mixInputs = (0..($audioStreams.Count - 1) | ForEach-Object { "[a$_]" }) -join ""
    $filterComplex += "$mixInputs amix=inputs=$($audioStreams.Count):duration=longest:normalize=0[aout]"

    $argList = @("-i", "`"$InputVideo`"", "-filter_complex", "`"$filterComplex`"", "-map", "0:v:0", "-map", "`"[aout]`"",
        "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "`"$outputFile`"", "-y")

    $panel = $Context.Panels.MergeAudio
    $progressBar = $panel.FindName("ProgressBarMerge")
    $percentText = $panel.FindName("TextMergePercent")
    $etaText = $panel.FindName("TextMergeEta")
    $cancelButton = $panel.FindName("ButtonMergeCancel")
    $startTime = Get-Date
    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    $process = Start-TrackedProcess -Context $Context -FileName $ffmpegPath -Arguments ($argList -join " ") -ReadStream Error `
        -OnLine {
            param($line)
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $progress = ConvertFrom-FFmpegProgressLine -Line $line -TotalSeconds $totalSeconds -ElapsedSeconds $elapsed
            if ($progress) { $progressBar.Value = $progress.Percent; $percentText.Text = "{0:N1}%" -f $progress.Percent; $etaText.Text = $progress.EtaString }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%" }
        }.GetNewClosure()

    $cancelButton.IsEnabled = $true
    $cancelButton.Add_Click({ if (-not $process.HasExited) { $process.Kill() } }.GetNewClosure())
    return $process
}
```

Add `Merge-AudioStreamsAsync` to `Export-ModuleMember`.

- [ ] **Step 3: Adapt `VideoTrimmer.psm1`**

Add (leaving the existing console `Split-Video` in place until Task 10's cleanup):

```powershell
function Split-VideoAsync {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $videoProps = Get-VideoProperties -inputFile $InputFile
    $totalSeconds = if ($videoProps) { $videoProps.Duration.TotalSeconds } else { 0 }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $cleanTimestamp = $Timestamp -replace ':', '-'
    $trimSeconds = [timespan]::Parse($Timestamp).TotalSeconds
    $targetSeconds = if ($Mode -eq "After") { $trimSeconds } elseif ($totalSeconds -gt 0) { $totalSeconds - $trimSeconds } else { 0 }

    $argList = @()
    if ($Mode -eq "Before") {
        $outputFile = "$baseName-Trimmed-From-$cleanTimestamp.mp4"
        $argList += "-ss", $Timestamp, "-i", "`"$InputFile`"", "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
    } else {
        $outputFile = "$baseName-Trimmed-Until-$cleanTimestamp.mp4"
        $argList += "-i", "`"$InputFile`"", "-to", $Timestamp, "-map", "0", "-c", "copy", "`"$outputFile`"", "-y"
    }

    $panel = $Context.Panels.Trim
    $progressBar = $panel.FindName("ProgressBarTrim")
    $percentText = $panel.FindName("TextTrimPercent")
    $etaText = $panel.FindName("TextTrimEta")
    $cancelButton = $panel.FindName("ButtonTrimCancel")
    $startTime = Get-Date
    $ffmpegPath = Get-ToolPath -Name "ffmpeg" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    $process = Start-TrackedProcess -Context $Context -FileName $ffmpegPath -Arguments ($argList -join " ") -ReadStream Error `
        -OnLine {
            param($line)
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $progress = ConvertFrom-FFmpegProgressLine -Line $line -TotalSeconds $targetSeconds -ElapsedSeconds $elapsed
            if ($progress) { $progressBar.Value = $progress.Percent; $percentText.Text = "{0:N1}%" -f $progress.Percent; $etaText.Text = $progress.EtaString }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($exitCode -eq 0) { $progressBar.Value = 100; $percentText.Text = "100.0%" }
        }.GetNewClosure()

    $cancelButton.IsEnabled = $true
    $cancelButton.Add_Click({ if (-not $process.HasExited) { $process.Kill() } }.GetNewClosure())
    return $process
}
```

Add `Split-VideoAsync` to `Export-ModuleMember`.

- [ ] **Step 4: Manual verification**

Run each in isolation the same way as Task 7 Step 4 (swap in `Merge-AudioStreamsAsync`/`Split-VideoAsync` against a real multi-audio-stream test file and a real test file for trimming). Expected: progress bars update live, Cancel works, correct output filenames are produced (`*-merged-audio.mp4`, `*-Trimmed-From-*.mp4` / `*-Trimmed-Until-*.mp4`).

- [ ] **Step 5: Commit**

```bash
git add src/assets/MainWindow.xaml src/modules/AudioProcessing.psm1 src/modules/VideoTrimmer.psm1
git commit -m "Add Merge Audio and Trim screens with async progress and cancel"
```

---

### Task 9: YouTube MP3/MP4 and Settings screens

**Files:**
- Modify: `src/assets/MainWindow.xaml` (fill in `PanelYouTubeMP3`, `PanelYouTubeMP4`, `PanelSettings`)
- Modify: `src/modules/YouTubeDownload.psm1` (adapt `Save-YouTubeMP3`/`Save-YouTubeMP4` → `Save-YouTubeMP3Async`/`Save-YouTubeMP4Async`, drop `Read-Host`, use `Get-ToolPath` and `Get-AvailableResolutions` from Task 2, use `Start-TrackedProcess` with `-ReadStream Output`)

**Interfaces:**
- Produces: `Save-YouTubeMP3Async -Context <hashtable> -Url <string>`, `Save-YouTubeMP4Async -Context <hashtable> -Url <string> -Resolution <hashtable>` (the hashtable shape from `Get-AvailableResolutions`).

- [ ] **Step 1: Add YouTube MP3/MP4 and Settings panel markup**

```xml
<Grid x:Name="PanelYouTubeMP3" Visibility="Collapsed">
    <StackPanel>
        <TextBlock Text="YouTube MP3 Downloader" FontSize="20" FontWeight="Bold"
                   Foreground="{StaticResource BrushTextPrimary}" FontFamily="{StaticResource FontChrome}"/>
        <TextBox x:Name="TextYoutubeMP3Url" Margin="0,12,0,12" FontFamily="{StaticResource FontData}"/>
        <Button x:Name="ButtonYoutubeMP3Start" Content="Download" Style="{StaticResource PresetButtonStyle}" Width="140" HorizontalAlignment="Left" Margin="0,0,0,12"/>
        <ProgressBar x:Name="ProgressBarYoutubeMP3" Height="10" Minimum="0" Maximum="100" Value="0"
                     Foreground="{StaticResource BrushAccentGradient}" Background="#0D1526"/>
        <TextBlock x:Name="TextYoutubeMP3Status" Text="" FontFamily="{StaticResource FontData}" Foreground="{StaticResource BrushGoldValue}" Margin="0,8,0,0"/>
    </StackPanel>
</Grid>
```

```xml
<Grid x:Name="PanelYouTubeMP4" Visibility="Collapsed">
    <StackPanel>
        <TextBlock Text="YouTube MP4 Downloader" FontSize="20" FontWeight="Bold"
                   Foreground="{StaticResource BrushTextPrimary}" FontFamily="{StaticResource FontChrome}"/>
        <TextBox x:Name="TextYoutubeMP4Url" Margin="0,12,0,12" FontFamily="{StaticResource FontData}"/>
        <Button x:Name="ButtonYoutubeMP4Fetch" Content="Fetch Available Qualities" Style="{StaticResource PresetButtonStyle}" Width="200" HorizontalAlignment="Left" Margin="0,0,0,12"/>
        <ComboBox x:Name="ComboYoutubeMP4Quality" Width="200" HorizontalAlignment="Left" Margin="0,0,0,12"/>
        <Button x:Name="ButtonYoutubeMP4Start" Content="Download" Style="{StaticResource PresetButtonStyle}" Width="140" HorizontalAlignment="Left" Margin="0,0,0,12" IsEnabled="False"/>
        <ProgressBar x:Name="ProgressBarYoutubeMP4" Height="10" Minimum="0" Maximum="100" Value="0"
                     Foreground="{StaticResource BrushAccentGradient}" Background="#0D1526"/>
        <TextBlock x:Name="TextYoutubeMP4Status" Text="" FontFamily="{StaticResource FontData}" Foreground="{StaticResource BrushGoldValue}" Margin="0,8,0,0"/>
    </StackPanel>
</Grid>
```

```xml
<Grid x:Name="PanelSettings" Visibility="Collapsed">
    <StackPanel>
        <TextBlock Text="Settings" FontSize="20" FontWeight="Bold"
                   Foreground="{StaticResource BrushTextPrimary}" FontFamily="{StaticResource FontChrome}"/>
        <CheckBox x:Name="CheckShowAnimations" Content="Enable animations" Margin="0,16,0,0"
                  Foreground="{StaticResource BrushTextMuted}" FontFamily="{StaticResource FontChrome}"/>
    </StackPanel>
</Grid>
```

- [ ] **Step 2: Adapt `YouTubeDownload.psm1`**

Add (leaving the existing console `Save-YouTubeMP3`/`Save-YouTubeMP4` in place until Task 10's cleanup):

```powershell
function Save-YouTubeMP3Async {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $downloadPath = Join-Path (Get-Location) "MP3 Downloads"
    if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    $outputTemplate = Join-Path $downloadPath "%(title)s.%(ext)s"
    $progressTemplate = "%(progress.downloaded_bytes)s-%(progress.total_bytes)s-%(progress.total_bytes_estimate)s-%(progress.eta)s"
    $arguments = "$Url --no-playlist --no-warnings --socket-timeout 30 --user-agent `"$ua`" -x --audio-format mp3 -o `"$outputTemplate`" --newline --progress-template ""$progressTemplate"""

    $panel = $Context.Panels.YouTubeMP3
    $progressBar = $panel.FindName("ProgressBarYoutubeMP3")
    $statusText = $panel.FindName("TextYoutubeMP3Status")
    $ytDlpPath = Get-ToolPath -Name "yt-dlp" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    $process = Start-TrackedProcess -Context $Context -FileName $ytDlpPath -Arguments $arguments -ReadStream Output `
        -OnLine {
            param($line)
            if ($line -match "(\d+)-(\d+|NA)-(\d+|NA)-(\d+|NA)") {
                $downloaded = [double]$matches[1]
                $total = if ($matches[2] -ne "NA") { [double]$matches[2] } elseif ($matches[3] -ne "NA") { [double]$matches[3] } else { 0 }
                if ($total -gt 0) {
                    $percent = [math]::Round(($downloaded / $total) * 100, 1)
                    $progressBar.Value = $percent
                    $statusText.Text = "$percent% downloaded"
                }
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $statusText.Text = if ($exitCode -eq 0) { "Download complete: $downloadPath" } else { "Download failed (exit $exitCode)" }
        }.GetNewClosure()

    return $process
}

function Save-YouTubeMP4Async {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][hashtable]$Resolution
    )

    $downloadPath = Join-Path (Get-Location) "MP4 Downloads"
    if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    $outputTemplate = Join-Path $downloadPath "%(title)s-$($Resolution.height)P.%(ext)s"
    $progressTemplate = "%(progress.downloaded_bytes)s-%(progress.total_bytes)s-%(progress.total_bytes_estimate)s-%(progress.eta)s"
    $arguments = "$Url --no-playlist --no-warnings --socket-timeout 30 --user-agent `"$ua`" --newline --progress-template ""$progressTemplate"" -f $($Resolution.formatString) -o `"$outputTemplate`" --merge-output-format mp4 --postprocessor-args ""Merger: -c:v copy -c:a aac"""

    $panel = $Context.Panels.YouTubeMP4
    $progressBar = $panel.FindName("ProgressBarYoutubeMP4")
    $statusText = $panel.FindName("TextYoutubeMP4Status")
    $ytDlpPath = Get-ToolPath -Name "yt-dlp" -ScriptRoot (Split-Path $PSScriptRoot -Parent)

    $process = Start-TrackedProcess -Context $Context -FileName $ytDlpPath -Arguments $arguments -ReadStream Output `
        -OnLine {
            param($line)
            if ($line -match "(\d+)-(\d+|NA)-(\d+|NA)-(\d+|NA)") {
                $downloaded = [double]$matches[1]
                $total = if ($matches[2] -ne "NA") { [double]$matches[2] } elseif ($matches[3] -ne "NA") { [double]$matches[3] } else { 0 }
                if ($total -gt 0) {
                    $percent = [math]::Round(($downloaded / $total) * 100, 1)
                    $progressBar.Value = $percent
                    $statusText.Text = "$percent% downloaded"
                }
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $statusText.Text = if ($exitCode -eq 0) { "Download complete: $downloadPath" } else { "Download failed (exit $exitCode)" }
        }.GetNewClosure()

    return $process
}
```

Add both to `Export-ModuleMember`.

- [ ] **Step 3: Manual verification**

Verify MP3 download against a real short YouTube URL: progress bar and status text update live, output lands in `MP3 Downloads/`. Verify MP4: click "Fetch Available Qualities" (wired in Task 10) populates `ComboYoutubeMP4Quality` from `Get-AvailableResolutions`, selecting one and clicking Download produces a file in `MP4 Downloads/` named `<title>-<height>P.mp4`.

- [ ] **Step 4: Commit**

```bash
git add src/assets/MainWindow.xaml src/modules/YouTubeDownload.psm1
git commit -m "Add YouTube MP3/MP4 and Settings screens"
```

---

### Task 10: Entry-point rewrite — replace the console menu, wire all panels, hide the console

**Files:**
- Modify: `src/Video-Audio-Tool.ps1` (delete the `do/while` console loop; bootstrap the WPF window and wire every button)
- Modify: `src/modules/VideoProcessing.psm1`, `src/modules/AudioProcessing.psm1`, `src/modules/VideoTrimmer.psm1`, `src/modules/YouTubeDownload.psm1` (delete the now-dead console-only functions: `Compress-Video`, `Merge-AudioStreams`, `Split-Video`, `Save-YouTubeMP3`, `Save-YouTubeMP4`, and `Get-CompressionSuggestions`'s console-printing body — keep only the `*Async` versions and the still-used pure functions `Get-VideoProperties`/`Get-SystemSpecs`/`Set-CompressionMode`)
- Modify: `src/modules/UI.psm1` (delete now-unused console-only functions: `Show-AsciiBanner`, `Show-RotatingFFmpegLogo`, `Show-Banner`, `Write-AnimatedLine`, `Update-ProgressBar`, `Show-CompletionAnimation`, `Wait-KeyPress`, `Select-VideoFile`, `Invoke-FFmpegProcess`; keep `ConvertFrom-FFmpegProgressLine` from Task 3)
- Modify: `src/assets/Launcher Config.bat`
- Modify: `src/assets/Launcher Source.cs`

**Interfaces:**
- Consumes: everything from Tasks 1–9.
- Produces: a fully working application — no new interfaces exported from here, this is the integration point.

- [ ] **Step 1: Rewrite `Video-Audio-Tool.ps1`'s body**

Keep the existing self-update bootstrap (module download, `Test-ScriptUpdates`, lines 1–163 of the current file) unchanged. Replace everything from `Test-ScriptUpdates` / `Show-AsciiBanner` onward (the old animated intro + `do/while` menu) with:

```powershell
Import-Module (Join-Path $modulePath "UI-WPF.psm1") -Force

$ctx = Initialize-MainWindow -ScriptRoot $scriptRoot

foreach ($name in @("Compress", "MergeAudio", "Trim", "YouTubeMP3", "YouTubeMP4", "Settings")) {
    $panelName = $name
    $ctx.NavButtons[$panelName].Add_Click({ Show-Panel -Context $ctx -Name $panelName }.GetNewClosure())
}

# Compress
$panelCompress = $ctx.Panels.Compress
$panelCompress.FindName("ButtonCompressBrowse").Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = "MP4 files (*.mp4)|*.mp4"
    if ($dialog.ShowDialog()) {
        $script:CompressInputFile = $dialog.FileName
        $props = Get-VideoProperties -inputFile $script:CompressInputFile
        $script:CompressVideoProps = $props
        $panelCompress.FindName("TextCompressMeta").Text = "$([System.IO.Path]::GetFileName($script:CompressInputFile)) - $($props.Resolution) - $($props.Duration)"
    }
})
foreach ($presetPair in @{ ButtonPresetHigh = "High Quality"; ButtonPresetBalanced = "Balanced"; ButtonPresetSmall = "Small Size" }.GetEnumerator()) {
    $btnName = $presetPair.Key
    $presetName = $presetPair.Value
    $panelCompress.FindName($btnName).Add_Click({
        if (-not $script:CompressInputFile) { return }
        Compress-VideoAsync -Context $ctx -InputFile $script:CompressInputFile -Preset $presetName -VideoProps $script:CompressVideoProps
    }.GetNewClosure())
}

# Merge Audio
$panelMerge = $ctx.Panels.MergeAudio
$panelMerge.FindName("ButtonMergeBrowse").Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = "MP4 files (*.mp4)|*.mp4"
    if ($dialog.ShowDialog()) {
        $script:MergeInputFile = $dialog.FileName
        $panelMerge.FindName("TextMergeMeta").Text = [System.IO.Path]::GetFileName($script:MergeInputFile)
    }
})
$panelMerge.FindName("ButtonMergeStart").Add_Click({
    if (-not $script:MergeInputFile) { return }
    $volumeMap = @{ 0 = 1.0; 1 = 2.0; 2 = 3.5; 3 = 5.0 }
    $sysVol = $volumeMap[$panelMerge.FindName("ComboSystemVolume").SelectedIndex]
    $micVol = $volumeMap[$panelMerge.FindName("ComboMicVolume").SelectedIndex]
    Merge-AudioStreamsAsync -Context $ctx -InputVideo $script:MergeInputFile -SystemVolume $sysVol -MicVolume $micVol
})

# Trim
$panelTrim = $ctx.Panels.Trim
$panelTrim.FindName("ButtonTrimBrowse").Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = "MP4 files (*.mp4)|*.mp4"
    if ($dialog.ShowDialog()) {
        $script:TrimInputFile = $dialog.FileName
        $panelTrim.FindName("TextTrimMeta").Text = [System.IO.Path]::GetFileName($script:TrimInputFile)
    }
})
$panelTrim.FindName("ButtonTrimStart").Add_Click({
    if (-not $script:TrimInputFile) { return }
    $mode = if ($panelTrim.FindName("RadioTrimBefore").IsChecked) { "Before" } else { "After" }
    $timestamp = $panelTrim.FindName("TextTrimTimestamp").Text
    Split-VideoAsync -Context $ctx -InputFile $script:TrimInputFile -Mode $mode -Timestamp $timestamp
})

# YouTube MP3
$panelYtMp3 = $ctx.Panels.YouTubeMP3
$panelYtMp3.FindName("ButtonYoutubeMP3Start").Add_Click({
    $url = $panelYtMp3.FindName("TextYoutubeMP3Url").Text
    if ($url -match '^https?://') { Save-YouTubeMP3Async -Context $ctx -Url $url }
})

# YouTube MP4
$panelYtMp4 = $ctx.Panels.YouTubeMP4
$panelYtMp4.FindName("ButtonYoutubeMP4Fetch").Add_Click({
    $url = $panelYtMp4.FindName("TextYoutubeMP4Url").Text
    if ($url -notmatch '^https?://') { return }
    $ytDlpPath = Get-ToolPath -Name "yt-dlp" -ScriptRoot $scriptRoot
    $formats = & $ytDlpPath -F $url --no-playlist --no-warnings 2>&1 | Out-String
    $script:YoutubeMP4Resolutions = Get-AvailableResolutions -FormatsText $formats
    $combo = $panelYtMp4.FindName("ComboYoutubeMP4Quality")
    $combo.Items.Clear()
    foreach ($res in $script:YoutubeMP4Resolutions) { $combo.Items.Add("$($res.name) ($($res.height)p)") | Out-Null }
    $panelYtMp4.FindName("ButtonYoutubeMP4Start").IsEnabled = ($combo.Items.Count -gt 0)
})
$panelYtMp4.FindName("ButtonYoutubeMP4Start").Add_Click({
    $url = $panelYtMp4.FindName("TextYoutubeMP4Url").Text
    $index = $panelYtMp4.FindName("ComboYoutubeMP4Quality").SelectedIndex
    if ($index -lt 0 -or -not $script:YoutubeMP4Resolutions) { return }
    Save-YouTubeMP4Async -Context $ctx -Url $url -Resolution $script:YoutubeMP4Resolutions[$index]
})

# Settings
$panelSettings = $ctx.Panels.Settings
$panelSettings.FindName("CheckShowAnimations").IsChecked = $global:ShowAnimations
$panelSettings.FindName("CheckShowAnimations").Add_Click({
    $global:ShowAnimations = $panelSettings.FindName("CheckShowAnimations").IsChecked
    Save-Settings
})

$ctx.Window.ShowDialog() | Out-Null
```

- [ ] **Step 2: Delete dead console-only code**

Remove from `VideoProcessing.psm1`: `Compress-Video` (the console version), and the console-printing body of `Get-CompressionSuggestions` (its data-gathering role is now inlined in `Video-Audio-Tool.ps1`'s Compress browse handler via a direct `Get-VideoProperties` call — remove `Get-CompressionSuggestions`, `Show-PresetDetails`, `Write-SectionHeader` entirely since nothing calls them anymore). Remove from `AudioProcessing.psm1`: `Merge-AudioStreams`. Remove from `VideoTrimmer.psm1`: `Split-Video`. Remove from `YouTubeDownload.psm1`: `Save-YouTubeMP3`, `Save-YouTubeMP4`. Remove from `UI.psm1`: `Show-AsciiBanner`, `Show-RotatingFFmpegLogo`, `Show-Banner`, `Write-AnimatedLine`, `Update-ProgressBar`, `Show-CompletionAnimation`, `Wait-KeyPress`, `Select-VideoFile`, `Invoke-FFmpegProcess`, and their entries in each file's `Export-ModuleMember` list.

- [ ] **Step 3: Hide the console window**

`src/assets/Launcher Config.bat`:

```bat
@echo off
cd /d "%~dp0.."
powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "Video-Audio-Tool.ps1"
```

(Drop the `if %errorlevel% neq 0 pause` line — with the window hidden there's nothing for the user to see it pause on, and startup errors should surface as a WPF/WinForms message box instead, matching how `Launcher Source.cs` already reports its own failures.)

`src/assets/Launcher Source.cs`, change the `ProcessStartInfo` block:

```csharp
var psi = new ProcessStartInfo
{
    FileName = "powershell.exe",
    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"",
    WorkingDirectory = dir,
    UseShellExecute = false,
    CreateNoWindow = true
};
```

Rebuild per the comment already in that file:
```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:"assets\Icon.ico" /r:System.Windows.Forms.dll /out:Launcher.exe "assets\Launcher Source.cs"
```

- [ ] **Step 4: Manual verification (full app)**

Run `Launcher.exe` from `src/`. Expected:
- No console window ever appears.
- The WPF window opens directly to the Compress screen.
- Clicking every sidebar item switches panels with the pill gliding smoothly.
- Each of the 5 active tools (Compress, Merge Audio, Trim, YouTube MP3, YouTube MP4) completes a real end-to-end run against real test input, with live progress and working Cancel.
- Settings' animation checkbox toggling persists across a restart (check `assets/settings.json`).
- Closing and reopening the app doesn't error (confirms no leftover reference to deleted console functions).

- [ ] **Step 5: Commit**

```bash
git add src/Video-Audio-Tool.ps1 src/modules/VideoProcessing.psm1 src/modules/AudioProcessing.psm1 src/modules/VideoTrimmer.psm1 src/modules/YouTubeDownload.psm1 src/modules/UI.psm1 "src/assets/Launcher Config.bat" "src/assets/Launcher Source.cs"
git commit -m "Replace console menu with WPF window end-to-end; hide console"
```

---

### Task 11: Bundle ffmpeg/ffprobe/yt-dlp and update README

**Files:**
- Modify: `README.md`
- Create: `src/bin/.gitkeep` (placeholder — the actual `.exe` binaries are intentionally **not** committed to git; they're added to `src/bin/` at release-packaging time, same principle as `*.mp4`/`*.mp3` already being gitignored)
- Modify: `.gitignore` at repo root (add `src/bin/*.exe`)

**Interfaces:**
- None — this task only affects packaging/documentation, all runtime path-resolution logic already exists from Task 1.

- [ ] **Step 1: Add the `.gitignore` rule and placeholder**

```bash
echo "src/bin/*.exe" >> .gitignore
mkdir -p src/bin
touch src/bin/.gitkeep
```

- [ ] **Step 2: Update `README.md`**

Replace the "Installation – ffmpeg & Yt-dlp" section with a note that the release zip already includes `ffmpeg.exe`, `ffprobe.exe`, and `yt-dlp.exe` in `bin/`, so no winget/PATH setup is required — and that anyone building from source (rather than downloading a release zip) needs to place those three executables into `src/bin/` themselves (or rely on having them on `PATH`, which `Get-ToolPath` still supports as a fallback).

- [ ] **Step 3: Manual verification**

Place real `ffmpeg.exe`/`ffprobe.exe`/`yt-dlp.exe` copies into `src/bin/`, run the app, and confirm every tool works without those binaries being on `PATH` (e.g. temporarily rename/remove them from `PATH` to prove `Get-ToolPath`'s bundled-first resolution is actually being used, not silently falling through).

- [ ] **Step 4: Commit**

```bash
git add .gitignore src/bin/.gitkeep README.md
git commit -m "Support bundled ffmpeg/ffprobe/yt-dlp binaries for zero-setup installs"
```

---

## Self-Review Notes

- **Spec coverage:** backend-unchanged constraint → Tasks 7–9 keep argument-building logic verbatim, only swap the I/O seam. Bundle requirement → Tasks 1, 11. Sidebar+pill nav → Task 5. Midnight Gold palette/glow/glass/fonts → Task 4 (palette base) plus inline `Foreground`/`Background` bindings throughout Tasks 5, 7–9 (glassmorphism `BlurEffect` treatment on the Compress dropzone and gold-glow drift animation are intentionally left as a follow-on polish pass beyond this plan's functional scope — flag this to the user before executing if full visual fidelity to the mockups is expected in this pass, not just the functional layout/colors). Async non-blocking requirement + Cancel → Task 6, consumed by 7–9. Console hidden → Task 10 Step 3. No dual-mode → Task 10 Step 2 deletes the console-only functions outright.
- **Placeholder scan:** no TBD/TODO strings; every code step has real code.
- **Type consistency:** `Context` hashtable shape (`Window`/`Panels`/`NavButtons`/`Pill`/`PillCanvas`) defined in Task 5 is used identically in Tasks 6–10. `Get-ToolPath -Name -ScriptRoot` signature from Task 1 is used identically everywhere it's called. `Get-AvailableResolutions` hashtable shape (`height`/`name`/`code`/`formatString`) from Task 2 matches its usage in Task 9/10.
