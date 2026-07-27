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
    [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($themeDict)

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

Export-ModuleMember -Function Initialize-MainWindow, Show-Panel
