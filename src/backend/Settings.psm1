$assetsFolder = Join-Path (Split-Path $PSScriptRoot -Parent) "assets"
$settingsFilePath = Join-Path $assetsFolder "settings.json"

function Import-Config {
    if (-not (Test-Path $assetsFolder)) {
        New-Item -ItemType Directory -Path $assetsFolder | Out-Null
    }

    if (Test-Path $settingsFilePath) {
        try {
            $config = Get-Content $settingsFilePath -Raw | ConvertFrom-Json
            
            if ($null -ne $config.ShowAnimations) {
                $global:ShowAnimations = [bool]$config.ShowAnimations
            } else {
                $global:ShowAnimations = $true
            }

            # Absent on first run and on every settings.json written before this feature
            # existed, so a null here is normal rather than a fault.
            if ($null -ne $config.ToolCheckCache) {
                $global:ToolCheckCache = $config.ToolCheckCache
            } else {
                $global:ToolCheckCache = $null
            }

            # Same shape of check as ToolCheckCache above, for the same reason: the key
            # is absent on first run and in every settings.json written before this
            # feature existed.
            if ($null -ne $config.RecentFiles) {
                $global:RecentFiles = @($config.RecentFiles)
            } else {
                $global:RecentFiles = @()
            }

            # The editor's timeline snapping (N). Absent in every settings.json written
            # before the NLE track work, so a null here means "first run with this
            # feature" rather than "the user turned it off" -- snapping defaults ON,
            # which is what an NLE user expects of a fresh install.
            if ($null -ne $config.TrimSnapEnabled) {
                $global:TrimSnapEnabled = [bool]$config.TrimSnapEnabled
            } else {
                $global:TrimSnapEnabled = $true
            }
        }
        catch {
            $global:ShowAnimations = $true
            $global:ToolCheckCache = $null
            $global:RecentFiles = @()
            $global:TrimSnapEnabled = $true
            Save-Settings
        }
    } else {
        $global:ShowAnimations = $true
        $global:ToolCheckCache = $null
        $global:RecentFiles = @()
        $global:TrimSnapEnabled = $true
        Save-Settings
    }
}

function Save-Settings {
    try {
        if (-not (Test-Path $assetsFolder)) {
            New-Item -ItemType Directory -Path $assetsFolder | Out-Null
        }

        $settingsObj = @{
            ShowAnimations = $global:ShowAnimations
            ToolCheckCache = $global:ToolCheckCache
            RecentFiles    = $global:RecentFiles
            TrimSnapEnabled = $global:TrimSnapEnabled
        }
        # Depth 6 because the cache is nested three levels and ConvertTo-Json truncates at
        # depth 2 by default -- without this the cache round-trips as the literal string
        # "System.Collections.Hashtable".
        $settingsObj | ConvertTo-Json -Depth 6 | Set-Content -Path $settingsFilePath -Encoding UTF8
    }
    catch {
        Write-Host "Failed to save settings: $_" -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
}

Export-ModuleMember -Function Import-Config, Save-Settings