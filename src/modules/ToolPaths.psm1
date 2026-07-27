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
