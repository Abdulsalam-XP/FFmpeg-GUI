# Project persistence: cuts, fades and captions ride along next to the source video
# in "<video>.ffgui.json" so closing the app never throws away editing work.

function Get-TrimProjectPath {
    param([Parameter(Mandatory = $true)][string]$VideoPath)
    $dir = [System.IO.Path]::GetDirectoryName($VideoPath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    return [System.IO.Path]::Combine($dir, "$name.ffgui.json")
}

function Save-TrimProject {
    param(
        [Parameter(Mandatory = $true)][string]$VideoPath,
        [object[]]$CutList = @(),
        [hashtable]$Fades = @{},
        [object[]]$Captions = @()
    )
    try {
        $doc = [ordered]@{
            Version  = 1
            CutList  = @(@($CutList) | ForEach-Object { [ordered]@{ Start = $_.Start; End = $_.End } })
            Fades    = $Fades
            Captions = @(@($Captions) | ForEach-Object { $_ })
        }
        $json = $doc | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText((Get-TrimProjectPath -VideoPath $VideoPath), $json,
            (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Read-TrimProject {
    param([Parameter(Mandatory = $true)][string]$VideoPath)
    $path = Get-TrimProjectPath -VideoPath $VideoPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $doc -or $null -eq $doc.CutList -or $null -eq $doc.Captions) { return $null }

        # ConvertFrom-Json yields PSCustomObjects; fades come back as an object whose
        # properties are the boundary keys -- rebuild the hashtable the panel expects.
        $fades = @{}
        if ($doc.Fades) {
            foreach ($p in $doc.Fades.PSObject.Properties) { $fades[$p.Name] = [double]$p.Value }
        }
        return @{
            CutList  = @(@($doc.CutList) | ForEach-Object { [PSCustomObject]@{ Start = [double]$_.Start; End = [double]$_.End } })
            Fades    = $fades
            Captions = @(@($doc.Captions) | ForEach-Object { $_ })
        }
    } catch { return $null }
}

Export-ModuleMember -Function Get-TrimProjectPath, Save-TrimProject, Read-TrimProject
