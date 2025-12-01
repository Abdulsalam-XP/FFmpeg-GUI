$settingsFilePath = Join-Path (Split-Path $PSScriptRoot -Parent) "settings.json"

function Import-Config {
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