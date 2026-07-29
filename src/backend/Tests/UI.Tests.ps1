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

Describe "Format-VideoMetadata" {
    It "formats a 1440p 120fps recording the way the card shows it" {
        $r = Format-VideoMetadata -Properties @{
            Resolution = "2560x1440"; FrameRate = 120; FileSizeBytes = 1750000000
            Duration = [timespan]::FromSeconds(170.15)
        }
        $r.Resolution | Should Be "2560 x 1440"
        $r.FrameRate  | Should Be "120 fps"
        $r.Length     | Should Be "2 min 50 sec"
        $r.Size       | Should Be "1.63 GB"
    }

    It "uses MB below a gigabyte so small files do not read as 0.00 GB" {
        (Format-VideoMetadata -Properties @{ FileSizeBytes = 4194304 }).Size | Should Be "4 MB"
    }

    It "includes hours only when there are hours" {
        (Format-VideoMetadata -Properties @{ Duration = [timespan]::FromSeconds(3845) }).Length | Should Be "1 hr 4 min"
    }

    It "drops the minute part for clips under a minute" {
        (Format-VideoMetadata -Properties @{ Duration = [timespan]::FromSeconds(38) }).Length | Should Be "38 sec"
    }

    It "keeps fractional frame rates" {
        (Format-VideoMetadata -Properties @{ FrameRate = 29.97 }).FrameRate | Should Be "29.97 fps"
    }

    It "shows a dash rather than N/A when ffprobe could not tell" {
        (Format-VideoMetadata -Properties @{ FrameRate = "N/A" }).FrameRate | Should Be "-"
    }

    It "shows a dash for every field when properties are missing" {
        $r = Format-VideoMetadata -Properties @{}
        $r.Resolution | Should Be "-"
        $r.Length     | Should Be "-"
        $r.Size       | Should Be "-"
    }
}

Describe "Get-JobOutputPath" {
    It "writes the result beside the source video, not into the app's folder" {
        Get-JobOutputPath -InputFile "D:\RECORDINGS\Counter-strike 2\clip.mp4" -Suffix "balanced" |
            Should Be "D:\RECORDINGS\Counter-strike 2\clip-balanced.mp4"
    }

    It "keeps spaces in the source name" {
        Get-JobOutputPath -InputFile "D:\vids\Counter-strike 2 2026.07.29 - 15.11.05.mp4" -Suffix "merged-audio" |
            Should Be "D:\vids\Counter-strike 2 2026.07.29 - 15.11.05-merged-audio.mp4"
    }

    It "keeps only the last extension when the name contains dots" {
        Get-JobOutputPath -InputFile "D:\vids\clip.2026.07.29.DVR.mp4" -Suffix "small-size" |
            Should Be "D:\vids\clip.2026.07.29.DVR-small-size.mp4"
    }

    It "falls back to a bare relative name when the input has no directory" {
        Get-JobOutputPath -InputFile "clip.mp4" -Suffix "balanced" | Should Be "clip-balanced.mp4"
    }

    It "handles a trim suffix carrying a timestamp" {
        Get-JobOutputPath -InputFile "D:\vids\clip.mp4" -Suffix "Trimmed-From-00-00-30" |
            Should Be "D:\vids\clip-Trimmed-From-00-00-30.mp4"
    }
}

Describe "Get-ThumbnailSeconds" {
    It "picks 5 percent of the way in" {
        Get-ThumbnailSeconds -Duration ([timespan]::FromSeconds(200)) | Should Be 10
    }

    It "never returns a negative offset" {
        Get-ThumbnailSeconds -Duration ([timespan]::Zero) | Should Be 0
    }

    It "caps the offset so a very long video still previews quickly" {
        Get-ThumbnailSeconds -Duration ([timespan]::FromHours(4)) | Should Be 300
    }
}
