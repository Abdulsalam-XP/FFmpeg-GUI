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

Describe "ConvertFrom-YtDlpProgressLine" {
    It "parses a progress line into percent and ETA" {
        $result = ConvertFrom-YtDlpProgressLine -Line "5242880-10485760-NA-42"
        $result.Percent | Should BeExactly 50
        $result.EtaString | Should BeExactly "00:00:42"
    }

    It "falls back to the estimated total when the exact total is NA" {
        # Streamed formats report no total_bytes, only total_bytes_estimate. Ignoring the
        # estimate would leave the progress bar frozen at zero for the whole download.
        $result = ConvertFrom-YtDlpProgressLine -Line "2000-NA-8000-10"
        $result.Percent | Should BeExactly 25
    }

    It "reports an unknown ETA rather than a bogus time when eta is NA" {
        $result = ConvertFrom-YtDlpProgressLine -Line "2000-8000-NA-NA"
        $result.EtaString | Should BeExactly "--:--:--"
    }

    It "returns null when neither total is known, so percent is unknowable" {
        ConvertFrom-YtDlpProgressLine -Line "2000-NA-NA-NA" | Should BeNullOrEmpty
    }

    It "returns null for yt-dlp's ordinary non-progress output" {
        ConvertFrom-YtDlpProgressLine -Line "[youtube] Extracting URL: https://example.com" | Should BeNullOrEmpty
    }

    It "returns null for an empty line" {
        ConvertFrom-YtDlpProgressLine -Line "" | Should BeNullOrEmpty
    }
}
