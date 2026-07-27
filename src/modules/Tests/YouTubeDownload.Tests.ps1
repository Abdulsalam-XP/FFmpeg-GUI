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
        $heights = @($result | ForEach-Object { $_.height })
        $heights.Count | Should BeExactly 2
        $heights[0] | Should BeExactly "1080"
        $heights[1] | Should BeExactly "720"
    }

    It "excludes resolutions with no matching pattern in the formats text" {
        $formats = "ID  EXT  RESOLUTION FPS`n137 mp4  640x360   30"
        $result = Get-AvailableResolutions -FormatsText $formats
        $heights = @($result | ForEach-Object { $_.height })
        $heights.Count | Should BeExactly 1
        $heights[0] | Should BeExactly "360"
    }
}
