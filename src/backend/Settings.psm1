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
        }
        catch {
            $global:ShowAnimations = $true
            $global:ToolCheckCache = $null
            $global:RecentFiles = @()
            Save-Settings
        }
    } else {
        $global:ShowAnimations = $true
        $global:ToolCheckCache = $null
        $global:RecentFiles = @()
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