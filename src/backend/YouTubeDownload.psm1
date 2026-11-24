# No -Force: it would demote the globally imported UI module to a nested one,
# hiding UI functions from the main script and the other modules
Import-Module (Join-Path $PSScriptRoot "UI.psm1")
Import-Module (Join-Path $PSScriptRoot "ToolPaths.psm1")

$script:YtDlpUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
# downloaded-total-estimate-eta, emitted one line at a time by --newline.
$script:YtDlpProgressTemplate = "%(progress.downloaded_bytes)s-%(progress.total_bytes)s-%(progress.total_bytes_estimate)s-%(progress.eta)s"
# One small JSON object per line. The plain "j" conversion escapes everything outside
# ASCII, so an Arabic or Japanese title survives the console codepage the pipe is read
# in, and no field can collide with a delimiter.
$script:YtDlpInfoTemplate = "%(.{id,extractor_key,height,filesize,filesize_approx,duration,thumbnail,uploader,title})j"

# Every tier asks for separate video + audio and falls back to a single-file format.
# The 1080p-and-below tiers used to ask for a single-file mp4 only; YouTube stopped
# serving those, so every one of them died with "Requested format is not available".
$script:QualityTiers = @(
    @{ height = "4320"; name = "8K" },
    @{ height = "2160"; name = "4K" },
    @{ height = "1440"; name = "2K" },
    @{ height = "1080"; name = "Full HD" },
    @{ height = "720";  name = "HD" },
    @{ height = "480";  name = "SD" },
    @{ height = "360";  name = "Low" }
)
foreach ($tier in $script:QualityTiers) {
    $tier.formatString = "bestvideo[height<=$($tier.height)]+bestaudio/best[height<=$($tier.height)]"
}

function Get-YtDlpPath {
    return Get-ToolPath -Name "yt-dlp" -ScriptRoot (Split-Path $PSScriptRoot -Parent)
}

# Parses one yt-dlp progress line into percent + ETA, or $null when the line carries no
# usable progress. Pure, so the download functions below stay free of parsing logic and
# this can be tested without spawning yt-dlp.
function ConvertFrom-YtDlpProgressLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    if ($Line -notmatch "(\d+)-(\d+|NA)-(\d+|NA)-(\d+|NA)") { return $null }

    $downloaded = [double]$matches[1]
    # total_bytes is absent for streamed formats; total_bytes_estimate is the fallback.
    $total = if ($matches[2] -ne "NA") { [double]$matches[2] }
             elseif ($matches[3] -ne "NA") { [double]$matches[3] }
             else { 0 }
    if ($total -le 0) { return $null }

    $etaString = if ($matches[4] -ne "NA") {
        ([timespan]::FromSeconds([int]$matches[4])).ToString("hh\:mm\:ss")
    } else { "--:--:--" }

    return @{
        Percent   = [math]::Round(($downloaded / $total) * 100, 1)
        EtaString = $etaString
    }
}

# Turns yt-dlp's stderr into the one line the status row shows. Pure, like
# ConvertFrom-YtDlpProgressLine, and for the same reason. ToolRelated is the caller's
# cue to light the Settings badge: it means the fix is an updated ffmpeg/yt-dlp, not a
# different URL. The patterns are matched against ALL of stderr, not just ERROR: lines,
# because ffmpeg's own complaints arrive unprefixed when yt-dlp relays them.
function Get-YtDlpFailureMessage {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ErrorLines,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    $allText = $ErrorLines -join "`n"

    # Postprocessing covers both panels' ffmpeg step: mp3 extraction and the mp4 merge.
    if ($allText -match "ffmpeg not found|ffprobe and ffmpeg|ffmpeg is not installed|ffmpeg exited with code|Postprocessing") {
        return @{ Message = "Download failed: ffmpeg is missing or broken. Update ffmpeg in Settings, then try again."
                  ToolRelated = $true }
    }

    # The signatures of a yt-dlp too old for today's YouTube: extraction and signature
    # failures, and the 403 an expired signature scheme earns.
    if ($allText -match "Unable to extract|Signature extraction failed|nsig extraction failed|HTTP Error 403") {
        return @{ Message = "Download failed: YouTube may have changed. Update yt-dlp in Settings, then try again."
                  ToolRelated = $true }
    }

    $detail = @($ErrorLines | Where-Object { $_ -match "^\s*ERROR" } | Select-Object -First 1)
    if ($detail.Count -eq 0) {
        $detail = @($ErrorLines | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
    }

    if ($detail.Count -eq 0) {
        return @{ Message = "Download failed (exit $ExitCode)."; ToolRelated = $false }
    }

    $text = ($detail[0] -replace "^\s*ERROR:\s*", "").Trim()
    if ($text.Length -gt 110) { $text = $text.Substring(0, 110) + "..." }
    return @{ Message = "Download failed: $text"; ToolRelated = $false }
}

# "742 MB", "1.6 GB". Empty when the size is unknown, so callers can join it away.
function Format-ByteSize {
    param([double]$Bytes)

    if ($Bytes -le 0) { return "" }
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 10MB) { return ("{0:N0} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N0} KB" -f ([math]::Max(1.0, $Bytes / 1KB)))
}

# "10:34", "1:02:03". Empty when the length is unknown (live streams report none).
function Format-VideoLength {
    param([double]$Seconds)

    if ($Seconds -le 0) { return "" }
    $span = [timespan]::FromSeconds([math]::Round($Seconds))
    if ($span.TotalHours -ge 1) { return ("{0}:{1:00}:{2:00}" -f [int][math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds) }
    return ("{0}:{1:00}" -f $span.Minutes, $span.Seconds)
}

# One line of the JSON the info template prints, with or without the "META " prefix the
# download runs put in front of it. $null for anything else, so a caller can feed it
# every stdout line and keep what comes back.
function ConvertFrom-YtDlpInfoLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    $text = ($Line -replace "^META\s+", "").Trim()
    if (-not $text.StartsWith("{")) { return $null }
    try { $json = $text | ConvertFrom-Json } catch { return $null }
    if (-not $json -or -not $json.id) { return $null }

    $size = 0.0
    if ($json.filesize) { $size = [double]$json.filesize }
    elseif ($json.filesize_approx) { $size = [double]$json.filesize_approx }

    return @{
        Id        = [string]$json.id
        Extractor = [string]$json.extractor_key
        Height    = if ($json.height) { [int]$json.height } else { 0 }
        SizeBytes = $size
        Duration  = if ($json.duration) { [double]$json.duration } else { 0.0 }
        Thumbnail = [string]$json.thumbnail
        Uploader  = [string]$json.uploader
        Title     = [string]$json.title
    }
}

# Which quality tiers a video really offers, each with the size yt-dlp reports for it.
# The lookup asks for every tier at once and yt-dlp answers with whatever it would
# actually download for each, so a 1080p-only video answers "1080" seven times. Each
# answer is filed under the smallest tier that holds its height, which collapses those
# repeats and leaves exactly the tiers that give a different file.
# Callers wrap this in @(...); it deliberately has no unary comma on the way out.
function Get-QualityOptions {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Infos)

    $tiers = $script:QualityTiers
    $found = @{}
    foreach ($info in $Infos) {
        if (-not $info -or $info.Height -le 0) { continue }
        $tier = $tiers[0]
        for ($i = $tiers.Count - 1; $i -ge 0; $i--) {
            if ($info.Height -le [int]$tiers[$i].height) { $tier = $tiers[$i]; break }
        }
        if (-not $found.ContainsKey($tier.height)) { $found[$tier.height] = $info }
    }

    foreach ($tier in $tiers) {
        if (-not $found.ContainsKey($tier.height)) { continue }
        $sizeText = Format-ByteSize -Bytes $found[$tier.height].SizeBytes
        $label = "$($tier.name) ($($tier.height)p)"
        if ($sizeText) { $label = "$label  -  ~$sizeText" }
        @{ height = $tier.height; name = $tier.name; formatString = $tier.formatString
           SizeBytes = $found[$tier.height].SizeBytes; Label = $label }
    }
}

# Where to look for the preview image, best first. YouTube's own "thumbnail" field is
# usually a .webp, which WPF cannot decode without an optional Windows codec, so the
# jpg renditions are built from the video id instead: the big one first, and the small
# one every video has as the fallback. Other sites get whatever they reported.
function Get-ThumbnailCandidates {
    param([Parameter(Mandatory = $true)][hashtable]$Info)

    if ($Info.Extractor -eq "Youtube" -and $Info.Id) {
        return @("https://i.ytimg.com/vi/$($Info.Id)/maxresdefault.jpg",
                 "https://i.ytimg.com/vi/$($Info.Id)/hq720.jpg",
                 "https://i.ytimg.com/vi/$($Info.Id)/mqdefault.jpg")
    }
    if ($Info.Thumbnail) { return @($Info.Thumbnail) }
    return @()
}

# ---------------------------------------------------------------------------
# Panel view: the video card, the step tracker and the waiting bar. One per panel,
# built on first use and kept, so a second download reuses the same elements.
#
# Everything below is called from closures through captured scriptblocks
# (${function:Name}), never by name: Start-TrackedProcess invokes its callbacks from
# UI-WPF.psm1's module scope, where this module's functions do not resolve. A captured
# scriptblock stays bound to this module, so inside it the other functions do resolve.
# ---------------------------------------------------------------------------
$script:YtViews = @{}
$script:YtStepNames = @("Find video", "Connect", "Download", "Finish")

function Get-YtView {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)]$Panel,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    if ($script:YtViews.ContainsKey($Suffix)) { return $script:YtViews[$Suffix] }

    $window = $Context.Window
    $converter = New-Object System.Windows.Media.BrushConverter
    $view = @{
        Suffix      = $Suffix
        ProgressBar = $Panel.FindName("ProgressBar$Suffix")
        Status      = $Panel.FindName("Text${Suffix}Status")
        Eta         = $Panel.FindName("Text${Suffix}Eta")
        Cancel      = $Panel.FindName("Button${Suffix}Cancel")
        Start       = $Panel.FindName("Button${Suffix}Start")
        Fetch       = $Panel.FindName("Button${Suffix}Fetch")
        Glide       = $Panel.FindName("Glide$Suffix")
        StepsHost   = $Panel.FindName("Steps$Suffix")
        Card        = $Panel.FindName("Card${Suffix}Video")
        Thumb       = $Panel.FindName("Thumb$Suffix")
        ThumbHint   = $Panel.FindName("Text${Suffix}ThumbHint")
        Title       = $Panel.FindName("Text${Suffix}Title")
        Meta        = $Panel.FindName("Text${Suffix}Meta")
        LengthBadge = $Panel.FindName("Badge${Suffix}Length")
        LengthText  = $Panel.FindName("Text${Suffix}Length")
        Steps       = @()
        Step        = -1
        Running     = $false
        Clock       = New-Object System.Diagnostics.Stopwatch
        Timer       = $null
        InfoId      = $null
        Bitmap      = $null
        ThumbBrush  = $null
        GlideShift  = $null
        BrushMuted  = $window.FindResource("BrushTextMuted")
        BrushText   = $window.FindResource("BrushTextPrimary")
        BrushBody   = $window.FindResource("BrushTextBody")
        # Through the Look map like every code-built color; the green is one of the
        # semantic colors the map deliberately leaves alone.
        BrushGold   = $converter.ConvertFromString((Convert-LookColorText -Text "#D3A24C"))
        BrushIdle   = $converter.ConvertFromString((Convert-LookColorText -Text "#338890B0"))
        BrushDone   = $converter.ConvertFromString("#6EF0A8")
    }

    if ($view.Thumb) {
        $brush = New-Object System.Windows.Media.ImageBrush
        $brush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $view.Thumb.Background = $brush
        $view.ThumbBrush = $brush
    }

    if ($view.Glide) {
        $shift = New-Object System.Windows.Media.TranslateTransform
        $view.Glide.RenderTransform = $shift
        $view.GlideShift = $shift
    }

    if ($view.StepsHost) {
        $dataFont = $window.FindResource("FontData")
        foreach ($label in $script:YtStepNames) {
            $cell = New-Object System.Windows.Controls.Border
            $cell.BorderThickness = New-Object System.Windows.Thickness -ArgumentList 0, 2, 0, 0
            $cell.Padding = New-Object System.Windows.Thickness -ArgumentList 0, 8, 8, 0
            $cell.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 8, 0

            # A three-quarter ring that turns while its step is the live one.
            $spin = New-Object System.Windows.Shapes.Ellipse
            $spin.Width = 11
            $spin.Height = 11
            $spin.StrokeThickness = 2
            $spin.Stroke = $view.BrushGold
            $dashes = New-Object System.Windows.Media.DoubleCollection
            $dashes.Add(10.0)
            $dashes.Add(100.0)
            $spin.StrokeDashArray = $dashes
            $spin.RenderTransformOrigin = New-Object System.Windows.Point -ArgumentList 0.5, 0.5
            $spin.RenderTransform = New-Object System.Windows.Media.RotateTransform
            $spin.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 7, 0
            $spin.VerticalAlignment = "Center"
            $spin.Visibility = "Collapsed"

            $name = New-Object System.Windows.Controls.TextBlock
            $name.FontFamily = $dataFont
            $name.FontSize = 11.5
            $name.VerticalAlignment = "Center"

            $head = New-Object System.Windows.Controls.StackPanel
            $head.Orientation = "Horizontal"
            [void]$head.Children.Add($spin)
            [void]$head.Children.Add($name)

            $time = New-Object System.Windows.Controls.TextBlock
            $time.FontFamily = $dataFont
            $time.FontSize = 10.5
            $time.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 3, 0, 0
            $time.Text = " "

            $stack = New-Object System.Windows.Controls.StackPanel
            [void]$stack.Children.Add($head)
            [void]$stack.Children.Add($time)
            $cell.Child = $stack
            [void]$view.StepsHost.Children.Add($cell)

            $view.Steps += @{ Cell = $cell; Spin = $spin; Name = $name; Time = $time; Label = $label; Elapsed = $null }
        }

        # Ticks the live step's own timer. Ten times a second reads as running without
        # the tenths digit turning into a blur.
        $timer = New-Object System.Windows.Threading.DispatcherTimer -ArgumentList (
            [System.Windows.Threading.DispatcherPriority]::Normal, $window.Dispatcher)
        $timer.Interval = [timespan]::FromMilliseconds(100)
        $tick = ${function:Update-YtStepClock}
        $timer.Add_Tick({ & $tick -View $view }.GetNewClosure())
        $view.Timer = $timer
    }

    $script:YtViews[$Suffix] = $view
    Update-YtSteps -View $view
    return $view
}

function Format-YtStepTime {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ("{0:N1}s" -f $Seconds) }
    return ("{0}:{1:00}" -f [int][math]::Floor($Seconds / 60), [int]([math]::Floor($Seconds) % 60))
}

function Update-YtStepClock {
    param($View)
    if (-not $View.Running -or $View.Step -lt 0 -or $View.Step -ge $View.Steps.Count) { return }
    $View.Steps[$View.Step].Time.Text = Format-YtStepTime -Seconds $View.Clock.Elapsed.TotalSeconds
}

# Repaints all four steps from $View.Step / $View.Running / each step's Elapsed.
function Update-YtSteps {
    param($View)

    for ($i = 0; $i -lt $View.Steps.Count; $i++) {
        $step = $View.Steps[$i]
        $live = $View.Running -and $i -eq $View.Step
        $done = $i -lt $View.Step

        $rotate = $step.Spin.RenderTransform
        if ($live) {
            $step.Spin.Visibility = "Visible"
            if ($global:ShowAnimations) {
                $turn = New-Object System.Windows.Media.Animation.DoubleAnimation
                $turn.From = 0.0
                $turn.To = 360.0
                $turn.Duration = [System.Windows.Duration]::new([timespan]::FromMilliseconds(850))
                $turn.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $rotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $turn)
            }
        } else {
            # Detach the clock before hiding: a running one keeps animating unseen.
            $rotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
            $step.Spin.Visibility = "Collapsed"
        }

        if ($live) {
            $step.Cell.BorderBrush = $View.BrushGold
            $step.Name.Foreground = $View.BrushText
            $step.Name.Text = $step.Label
            $step.Time.Foreground = $View.BrushGold
        } elseif ($done) {
            $step.Cell.BorderBrush = $View.BrushDone
            $step.Name.Foreground = $View.BrushBody
            $step.Name.Text = [string][char]0x2713 + " " + $step.Label
            $step.Time.Foreground = $View.BrushMuted
        } else {
            $step.Cell.BorderBrush = $View.BrushIdle
            $step.Name.Foreground = $View.BrushMuted
            $step.Name.Text = $step.Label
            $step.Time.Foreground = $View.BrushMuted
        }

        if (-not $live) {
            $step.Time.Text = if ($null -ne $step.Elapsed) { Format-YtStepTime -Seconds $step.Elapsed } else { " " }
        }
    }
}

# Moves the tracker to step $Index: everything before it is done, it is live, everything
# after is waiting. The step that was live keeps the time it took. -Idle marks the
# earlier steps done without starting a clock (a finished lookup, or a finished job with
# Index 4). Steps from $Index on forget their old times, so a second run starts clean
# while a lookup's "Find video" time survives into the download that follows it.
function Set-YtStep {
    param($View, [int]$Index, [switch]$Idle)

    if ($View.Steps.Count -eq 0) { $View.Step = $Index; return }

    if ($View.Running -and $View.Step -ge 0 -and $View.Step -lt $View.Steps.Count) {
        $View.Steps[$View.Step].Elapsed = $View.Clock.Elapsed.TotalSeconds
    }
    for ($i = [math]::Max(0, $Index); $i -lt $View.Steps.Count; $i++) { $View.Steps[$i].Elapsed = $null }

    $View.Step = $Index
    $View.Running = (-not $Idle) -and $Index -ge 0 -and $Index -lt $View.Steps.Count
    if ($View.Running) {
        $View.Clock.Restart()
        $View.Timer.Start()
    } else {
        $View.Clock.Stop()
        $View.Timer.Stop()
    }
    Update-YtSteps -View $View
}

# A cancelled or failed run: the live step stops where it was and keeps its time, but
# is not painted as done.
function Stop-YtSteps {
    param($View)

    if ($View.Steps.Count -eq 0) { return }
    if ($View.Running -and $View.Step -ge 0 -and $View.Step -lt $View.Steps.Count) {
        $View.Steps[$View.Step].Elapsed = $View.Clock.Elapsed.TotalSeconds
    }
    $View.Running = $false
    $View.Clock.Stop()
    $View.Timer.Stop()
    Update-YtSteps -View $View
}

# The sliding highlight over the bar while there is no percentage to show. With
# animations off the step timers alone carry the "still working" signal.
function Set-YtBarWaiting {
    param($View, [bool]$On)

    if (-not $View.Glide -or -not $View.GlideShift) { return }
    $xProperty = [System.Windows.Media.TranslateTransform]::XProperty
    if ($On -and $global:ShowAnimations) {
        $width = [math]::Max(300.0, [double]$View.ProgressBar.ActualWidth)
        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation
        $slide.From = -160.0
        $slide.To = $width
        $slide.Duration = [System.Windows.Duration]::new([timespan]::FromMilliseconds(1300))
        $slide.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $View.Glide.Visibility = "Visible"
        $View.GlideShift.BeginAnimation($xProperty, $slide)
    } else {
        $View.GlideShift.BeginAnimation($xProperty, $null)
        $View.Glide.Visibility = "Collapsed"
    }
}

# The card before anything is known about the video: the frame is there so the layout
# does not jump when the details land, and the hint says what is happening.
function Show-YtCardLoading {
    param($View, [string]$Hint)

    if (-not $View.Card) { return }
    $View.InfoId = $null
    $View.Bitmap = $null
    if ($View.ThumbBrush) { $View.ThumbBrush.ImageSource = $null }
    if ($View.ThumbHint) { $View.ThumbHint.Text = $Hint }
    if ($View.Title) { $View.Title.Text = "" }
    if ($View.Meta) { $View.Meta.Text = "" }
    if ($View.LengthBadge) { $View.LengthBadge.Visibility = "Collapsed" }
    $View.Card.Visibility = "Visible"
}

function Hide-YtCard {
    param($View)
    if ($View.Card) { $View.Card.Visibility = "Collapsed" }
    $View.InfoId = $null
}

# Tries the preview images in order. BitmapImage fetches an http source on its own
# background thread, so nothing here waits on the network; a 404 arrives as
# DownloadFailed and moves on to the next candidate. $ForId guards against a slow image
# landing on the card after the user has already looked up a different video.
function Set-YtThumbnail {
    param($View, [string[]]$Candidates, [int]$Index, [string]$ForId)

    if (-not $View.ThumbBrush -or $View.InfoId -ne $ForId) { return }
    if ($Index -ge @($Candidates).Count) {
        if ($View.ThumbHint) { $View.ThumbHint.Text = "No preview image" }
        return
    }

    $self = ${function:Set-YtThumbnail}
    $next = $Index + 1
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.UriSource = [uri]$Candidates[$Index]
        $bitmap.DecodePixelWidth = 960
        $bitmap.EndInit()
    } catch {
        & $self -View $View -Candidates $Candidates -Index $next -ForId $ForId
        return
    }

    # Held on the view so the bitmap, and with it these handlers, outlives this call.
    $View.Bitmap = $bitmap
    $apply = {
        if ($View.InfoId -eq $ForId) {
            $View.ThumbBrush.ImageSource = $bitmap
            if ($View.ThumbHint) { $View.ThumbHint.Text = "" }
        }
    }.GetNewClosure()
    $retry = { & $self -View $View -Candidates $Candidates -Index $next -ForId $ForId }.GetNewClosure()

    if ($bitmap.IsDownloading) {
        $bitmap.add_DownloadCompleted($apply)
        $bitmap.add_DownloadFailed($retry)
        $bitmap.add_DecodeFailed($retry)
    } else {
        & $apply
    }
}

# Fills the card. Text first, straight away; the image follows whenever it arrives.
function Show-YtCardInfo {
    param($View, [hashtable]$Info, [string]$Extra)

    if (-not $View.Card -or -not $Info) { return }
    $sameVideo = $View.InfoId -eq $Info.Id
    $View.InfoId = $Info.Id
    $View.Card.Visibility = "Visible"

    if ($View.Title) { $View.Title.Text = $Info.Title }
    $length = Format-VideoLength -Seconds $Info.Duration
    $parts = @($Info.Uploader, $length, $Extra) | Where-Object { $_ }
    if ($View.Meta) { $View.Meta.Text = ($parts -join ("  " + [char]0x00B7 + "  ")) }
    if ($View.LengthBadge) {
        if ($View.LengthText) { $View.LengthText.Text = $length }
        $View.LengthBadge.Visibility = if ($length) { "Visible" } else { "Collapsed" }
    }

    # The download run reports the same video the lookup already showed; reloading the
    # image would only make it blink.
    if ($sameVideo -and $View.ThumbBrush -and $View.ThumbBrush.ImageSource) { return }
    if ($View.ThumbHint) { $View.ThumbHint.Text = "Loading preview..." }
    Set-YtThumbnail -View $View -Candidates (Get-ThumbnailCandidates -Info $Info) -Index 0 -ForId $Info.Id
}

# Shared plumbing for both downloaders: same controls, same progress parsing, same
# terminal states. Only the yt-dlp arguments and the panel differ.
#
# The run walks the four tracker steps off yt-dlp's own output: the META line it prints
# once it has found the video, the first progress line, and the PHASE line it prints
# when the download is over and ffmpeg takes its turn. $FirstStep is 0 for MP3, which
# has to find the video itself, and 1 for MP4, where the lookup already did.
function Start-YtDlpDownload {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)]$Panel,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$ControlSuffix,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [int]$FirstStep = 0,
        # Shown beside channel and length on the card when the run itself is what
        # discovers the video (MP3): the size goes there because that panel has no
        # quality list to carry it.
        [switch]$ShowSizeOnCard
    )

    $view = Get-YtView -Context $Context -Panel $Panel -Suffix $ControlSuffix
    $progressBar = $view.ProgressBar
    $statusText = $view.Status
    $etaText = $view.Eta
    $cancelButton = $view.Cancel
    # Disabled for the duration of the run -- see Compress-VideoAsync: without this a
    # second click starts a parallel download sharing this panel's progress controls.
    $startButton = $view.Start
    $fetchButton = $view.Fetch

    # Captured as scriptblocks rather than called by name: Start-TrackedProcess invokes
    # -OnLine from UI-WPF.psm1's own module scope, where a command imported into *this*
    # module does not resolve. Same fix as Compress-VideoAsync in VideoProcessing.psm1.
    $parseProgressLine = ${function:ConvertFrom-YtDlpProgressLine}
    $parseInfoLine = ${function:ConvertFrom-YtDlpInfoLine}
    $classifyFailure = ${function:Get-YtDlpFailureMessage}
    $formatSize = ${function:Format-ByteSize}
    $setStep = ${function:Set-YtStep}
    $stopSteps = ${function:Stop-YtSteps}
    $setWaiting = ${function:Set-YtBarWaiting}
    $showInfo = ${function:Show-YtCardInfo}
    $showSize = [bool]$ShowSizeOnCard

    # Progress arrives on stdout, but the reason a run died arrives on stderr -- before
    # this was captured, every failure surfaced as a bare "exit 1" with the actual
    # ERROR: line thrown away. Capped: a looping extractor can spray thousands of lines,
    # and everything after the first few adds nothing to the diagnosis.
    $errorLines = New-Object System.Collections.Generic.List[string]

    $progressBar.Value = 0
    $statusText.Text = if ($FirstStep -eq 0) { "Finding the video..." } else { "Connecting to YouTube..." }
    $statusText.ToolTip = $null
    $etaText.Text = "--:--:--"
    if ($FirstStep -eq 0) { Show-YtCardLoading -View $view -Hint "Finding the video..." }
    Set-YtStep -View $view -Index $FirstStep
    Set-YtBarWaiting -View $view -On $true

    $process = Start-TrackedProcess -Context $Context -FileName (Get-YtDlpPath) -Arguments $Arguments -ReadStream Output `
        -OnOtherLine {
            param($line)
            if ($line.Trim() -ne "" -and $errorLines.Count -lt 40) { $errorLines.Add($line) }
        }.GetNewClosure() `
        -OnLine {
            param($line)
            if ($line.StartsWith("META ")) {
                $info = & $parseInfoLine -Line $line
                if ($info) {
                    $extra = ""
                    if ($showSize) {
                        $sizeText = & $formatSize -Bytes $info.SizeBytes
                        if ($sizeText) { $extra = "~$sizeText" }
                    }
                    & $showInfo -View $view -Info $info -Extra $extra
                }
                if ($view.Step -lt 1) {
                    & $setStep -View $view -Index 1
                    $statusText.Text = "Connecting to YouTube..."
                }
                return
            }
            if ($line.StartsWith("PHASE ")) {
                # The download is over and ffmpeg takes its turn: joining the separate
                # video and audio streams, or converting to mp3. This can run for a
                # while on a long video, so it gets its own step and its own words.
                if ($view.Step -lt 3) { & $setStep -View $view -Index 3 }
                & $setWaiting -View $view -On $false
                $progressBar.Value = 100
                $statusText.Text = "Download complete, finishing the file..."
                $etaText.Text = "finishing"
                return
            }
            $progress = & $parseProgressLine -Line $line
            if ($progress -and $view.Step -le 2) {
                if ($view.Step -lt 2) {
                    & $setStep -View $view -Index 2
                    & $setWaiting -View $view -On $false
                }
                $progressBar.Value = $progress.Percent
                $statusText.Text = "{0:N1}% downloaded" -f $progress.Percent
                $etaText.Text = $progress.EtaString
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($startButton) { $startButton.IsEnabled = $true }
            if ($fetchButton) { $fetchButton.IsEnabled = $true }
            & $setWaiting -View $view -On $false
            if ($exitCode -eq 0) {
                & $setStep -View $view -Index 4 -Idle
                $progressBar.Value = 100
                $statusText.Text = "Done -- saved to $DestinationPath"
                $etaText.Text = "done"
            } elseif ($exitCode -eq -1) {
                & $stopSteps -View $view
                $statusText.Text = "Cancelled"
                $etaText.Text = "--:--:--"
            } else {
                & $stopSteps -View $view
                $failure = & $classifyFailure -ErrorLines $errorLines.ToArray() -ExitCode $exitCode
                $statusText.Text = $failure.Message
                # The status row is one line; the raw stderr survives in the tooltip for
                # anyone who wants the unabridged version.
                if ($errorLines.Count -gt 0) { $statusText.ToolTip = ($errorLines -join "`n") }
                $etaText.Text = "--:--:--"
                # A tool-related failure lights the Settings badge, so the message's
                # "update it in Settings" has a literal thing to point at.
                if ($failure.ToolRelated -and $Context.NotifyToolAttention) {
                    & $Context.NotifyToolAttention
                }
            }
        }.GetNewClosure()

    if ($startButton) { $startButton.IsEnabled = $false }
    if ($fetchButton) { $fetchButton.IsEnabled = $false }
    $cancelButton.IsEnabled = $true
    Set-CancelButtonTarget -Button $cancelButton -Process $process
    return $process
}

# What every yt-dlp call shares. --print would normally switch yt-dlp to "simulate",
# so the download runs add --no-simulate; it also makes yt-dlp quiet, which is why
# --progress is there to keep the percentage lines coming.
function Get-YtDlpCommonArguments {
    param([Parameter(Mandatory = $true)][string]$Url)
    return "`"$Url`" --no-playlist --no-warnings --socket-timeout 30 --user-agent `"$script:YtDlpUserAgent`""
}

function Get-YtDlpDownloadReporting {
    return "--newline --progress --no-simulate --progress-template `"$script:YtDlpProgressTemplate`" " +
           "--print `"before_dl:META $script:YtDlpInfoTemplate`" --print `"post_process:PHASE %(id)s`""
}

function Save-YouTubeMP3Async {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $downloadPath = Join-Path (Get-Location) "MP3 Downloads"
    if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

    $outputTemplate = Join-Path $downloadPath "%(title)s.%(ext)s"
    $arguments = (Get-YtDlpCommonArguments -Url $Url) + " " + (Get-YtDlpDownloadReporting) +
                 " -x --audio-format mp3 -o `"$outputTemplate`""

    return Start-YtDlpDownload -Context $Context -Panel $Context.Panels.YouTubeMP3 -Arguments $arguments `
        -ControlSuffix "YoutubeMP3" -DestinationPath $downloadPath -FirstStep 0 -ShowSizeOnCard
}

function Save-YouTubeMP4Async {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][hashtable]$Resolution
    )

    $downloadPath = Join-Path (Get-Location) "MP4 Downloads"
    if (-not (Test-Path $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

    $outputTemplate = Join-Path $downloadPath "%(title)s-$($Resolution.height)P.%(ext)s"
    $arguments = (Get-YtDlpCommonArguments -Url $Url) + " " + (Get-YtDlpDownloadReporting) +
                 " -f `"$($Resolution.formatString)`" -o `"$outputTemplate`" --merge-output-format mp4 " +
                 "--postprocessor-args `"Merger: -c:v copy -c:a aac`""

    return Start-YtDlpDownload -Context $Context -Panel $Context.Panels.YouTubeMP4 -Arguments $arguments `
        -ControlSuffix "YoutubeMP4" -DestinationPath $downloadPath -FirstStep 1
}

# Asks yt-dlp what a video offers, in the background: one call that returns the name,
# channel, length, preview image and, for every quality tier, the size of what would
# actually be downloaded. This used to be a blocking call on the window's own thread,
# which froze the whole app for as long as YouTube took to answer.
#
# -OnDone receives ($options, $message, $isError): the Get-QualityOptions hashtables
# (empty on failure or cancel) and the line for the status row. It is invoked from the
# tracked process's tick, so pass a plain scriptblock, not a closure, if it needs to
# reach the caller's $script: state.
function Start-YouTubeLookup {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][scriptblock]$OnDone
    )

    $view = Get-YtView -Context $Context -Panel $Context.Panels.YouTubeMP4 -Suffix "YoutubeMP4"
    $cancelButton = $view.Cancel
    $fetchButton = $view.Fetch
    $statusText = $view.Status

    $parseInfoLine = ${function:ConvertFrom-YtDlpInfoLine}
    $classifyFailure = ${function:Get-YtDlpFailureMessage}
    $getOptions = ${function:Get-QualityOptions}
    $setStep = ${function:Set-YtStep}
    $stopSteps = ${function:Stop-YtSteps}
    $setWaiting = ${function:Set-YtBarWaiting}
    $showInfo = ${function:Show-YtCardInfo}
    $hideCard = ${function:Hide-YtCard}

    $infos = New-Object System.Collections.Generic.List[hashtable]
    $errorLines = New-Object System.Collections.Generic.List[string]

    $selectors = @($script:QualityTiers | ForEach-Object { $_.formatString }) -join ","
    $arguments = (Get-YtDlpCommonArguments -Url $Url) + " -f `"$selectors`" --print `"$script:YtDlpInfoTemplate`""

    $view.ProgressBar.Value = 0
    $statusText.ToolTip = $null
    $view.Eta.Text = "--:--:--"
    Show-YtCardLoading -View $view -Hint "Finding the video..."
    Set-YtStep -View $view -Index 0
    Set-YtBarWaiting -View $view -On $true

    $process = Start-TrackedProcess -Context $Context -FileName (Get-YtDlpPath) -Arguments $arguments -ReadStream Output `
        -OnOtherLine {
            param($line)
            if ($line.Trim() -ne "" -and $errorLines.Count -lt 40) { $errorLines.Add($line) }
        }.GetNewClosure() `
        -OnLine {
            param($line)
            $info = & $parseInfoLine -Line $line
            if ($info) {
                # The name and picture are the same on every line; show them the moment
                # the first one lands instead of waiting for yt-dlp to exit.
                if ($infos.Count -eq 0) { & $showInfo -View $view -Info $info -Extra "" }
                $infos.Add($info)
            }
        }.GetNewClosure() `
        -OnExit {
            param($exitCode)
            $cancelButton.IsEnabled = $false
            if ($fetchButton) { $fetchButton.IsEnabled = $true }
            & $setWaiting -View $view -On $false

            $options = @()
            if ($exitCode -ne -1 -and $infos.Count -gt 0) { $options = @(& $getOptions -Infos $infos.ToArray()) }

            if ($options.Count -gt 0) {
                & $setStep -View $view -Index 1 -Idle
                $word = if ($options.Count -eq 1) { "quality" } else { "qualities" }
                & $OnDone $options "$($options.Count) $word available. Pick one and press Download." $false
            } elseif ($exitCode -eq -1) {
                & $stopSteps -View $view
                & $hideCard -View $view
                & $OnDone @() "Cancelled" $false
            } else {
                & $stopSteps -View $view
                & $hideCard -View $view
                $message = "No downloadable formats found for that link."
                if ($errorLines.Count -gt 0) {
                    $failure = & $classifyFailure -ErrorLines $errorLines.ToArray() -ExitCode $exitCode
                    $message = $failure.Message -replace "^Download failed", "Lookup failed"
                    $statusText.ToolTip = ($errorLines -join "`n")
                    if ($failure.ToolRelated -and $Context.NotifyToolAttention) { & $Context.NotifyToolAttention }
                }
                & $OnDone @() $message $true
            }
        }.GetNewClosure()

    if ($fetchButton) { $fetchButton.IsEnabled = $false }
    $cancelButton.IsEnabled = $true
    Set-CancelButtonTarget -Button $cancelButton -Process $process
    return $process
}

Export-ModuleMember -Function Save-YouTubeMP3Async, Save-YouTubeMP4Async, Start-YouTubeLookup, `
    ConvertFrom-YtDlpProgressLine, Get-YtDlpFailureMessage, ConvertFrom-YtDlpInfoLine, Get-QualityOptions, `
    Get-ThumbnailCandidates, Format-ByteSize, Format-VideoLength
