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
        }
        catch {
            $global:ShowAnimations = $true
            Save-Settings
        }
    } else {
        $global:ShowAnimations = $true
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
        }
        $settingsObj | ConvertTo-Json | Set-Content -Path $settingsFilePath
    }
    catch {
        Write-Host "Failed to save settings: $_" -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
}

Export-ModuleMember -Function Import-Config, Save-Settings