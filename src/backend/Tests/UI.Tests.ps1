$modulePath = Join-Path $PSScriptRoot "..\UI.psm1"
Import-Module $modulePath -Force

Describe "ConvertFrom-FFmpegProgressLine" {
    It "parses a time= line into percent and ETA" {
        $line = "frame=100 fps=25 q=28.0 size=1024kB time=00:00:30.00 bitrate=512kb/s"
        $result = ConvertFrom-FFmpegProgressLine -Line $line -TotalSeconds 60 -ElapsedSeconds 15
        $result.Percent | Should Be 50.0
        $result.EtaString | Should Be "00:00:15"
    }

    It "returns null for a line with no time= field" {
        $line = "Stream mapping: Stream #0:0 -> #0:0 (h264 (native) -> h264 (libx264))"
        $result = ConvertFrom-FFmpegProgressLine -Line $line -TotalSeconds 60 -ElapsedSeconds 15
        $result | Should BeNullorEmpty
    }
}
