$modulePath = Join-Path $PSScriptRoot "..\ToolPaths.psm1"
Import-Module $modulePath -Force

Describe "Get-ToolPath" {
    It "returns the bundled bin path when the exe exists there" {
        $fakeRoot = Join-Path $TestDrive "app"
        $fakeBin = Join-Path $fakeRoot "bin"
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $fakeBin "ffmpeg.exe") -Force | Out-Null

        $result = Get-ToolPath -Name "ffmpeg" -ScriptRoot $fakeRoot
        $result | Should Be (Join-Path $fakeBin "ffmpeg.exe")
    }

    It "falls back to the bare name when no bundled exe exists" {
        $fakeRoot = Join-Path $TestDrive "app-nobundled"
        New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null

        $result = Get-ToolPath -Name "yt-dlp" -ScriptRoot $fakeRoot
        $result | Should Be "yt-dlp"
    }
}
