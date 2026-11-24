$modulePath = Join-Path $PSScriptRoot "..\YouTubeDownload.psm1"
Import-Module (Join-Path $PSScriptRoot "..\UI.psm1") -Force
Import-Module $modulePath -Force

Describe "ConvertFrom-YtDlpInfoLine" {
    $sample = '{"id": "aqz-KE-bpKQ", "extractor_key": "Youtube", "height": 1440, "filesize_approx": 322756523, "duration": 635, "thumbnail": "https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp", "uploader": "Blender", "title": "Big Buck Bunny"}'

    It "reads the fields the card and the quality list need" {
        $info = ConvertFrom-YtDlpInfoLine -Line $sample
        $info.Id | Should BeExactly "aqz-KE-bpKQ"
        $info.Height | Should BeExactly 1440
        $info.SizeBytes | Should BeExactly 322756523
        $info.Duration | Should BeExactly 635
        $info.Uploader | Should BeExactly "Blender"
        $info.Title | Should BeExactly "Big Buck Bunny"
    }

    It "accepts the META prefix the download runs print in front" {
        (ConvertFrom-YtDlpInfoLine -Line "META $sample").Id | Should BeExactly "aqz-KE-bpKQ"
    }

    It "prefers the exact filesize over the estimate when both are present" {
        $info = ConvertFrom-YtDlpInfoLine -Line '{"id": "x", "height": 720, "filesize": 1000, "filesize_approx": 2000}'
        $info.SizeBytes | Should BeExactly 1000
    }

    It "decodes the escaped non-ASCII a title arrives as" {
        # yt-dlp escapes everything outside ASCII so the title survives the pipe's
        # codepage; the escapes have to come back out as the real characters.
        $info = ConvertFrom-YtDlpInfoLine -Line '{"id": "x", "height": 720, "title": "\u0645\u0631\u062d\u0628\u0627"}'
        $info.Title.Length | Should BeExactly 5
        [int]$info.Title[0] | Should BeExactly 0x0645
    }

    It "reports zero size and length rather than failing when they are missing" {
        $info = ConvertFrom-YtDlpInfoLine -Line '{"id": "x", "height": 360}'
        $info.SizeBytes | Should BeExactly 0
        $info.Duration | Should BeExactly 0
    }

    It "returns null for progress lines and other ordinary output" {
        ConvertFrom-YtDlpInfoLine -Line "5242880-10485760-NA-42" | Should BeNullOrEmpty
        ConvertFrom-YtDlpInfoLine -Line "PHASE aqz-KE-bpKQ" | Should BeNullOrEmpty
        ConvertFrom-YtDlpInfoLine -Line "" | Should BeNullOrEmpty
    }

    It "returns null for a broken line instead of throwing" {
        ConvertFrom-YtDlpInfoLine -Line '{"id": "x", "height": ' | Should BeNullOrEmpty
    }
}

Describe "Get-QualityOptions" {
    function New-Info { param([int]$Height, [double]$Size) return @{ Id = "x"; Height = $Height; SizeBytes = $Size } }

    It "lists each tier the video really has, best first, with its size" {
        $options = @(Get-QualityOptions -Infos @(
            (New-Info 2160 1700000000), (New-Info 2160 1700000000), (New-Info 1440 778000000),
            (New-Info 1080 373000000), (New-Info 720 172000000), (New-Info 480 82000000), (New-Info 360 40000000)))
        $options.Count | Should BeExactly 6
        $options[0].height | Should BeExactly "2160"
        $options[0].Label | Should Match "4K \(2160p\)"
        $options[0].Label | Should Match "1\.6 GB"
        $options[5].height | Should BeExactly "360"
    }

    It "collapses the repeats a 1080p-only video answers every higher tier with" {
        # Asked for 8K, 4K and 2K, yt-dlp hands back the best it has: the same 1080p
        # file three more times. Those must not become three more list entries.
        $options = @(Get-QualityOptions -Infos @(
            (New-Info 1080 300000000), (New-Info 1080 300000000), (New-Info 1080 300000000),
            (New-Info 1080 300000000), (New-Info 720 150000000)))
        $options.Count | Should BeExactly 2
        $options[0].height | Should BeExactly "1080"
        $options[1].height | Should BeExactly "720"
    }

    It "returns exactly one option, still an array, for a single-quality video" {
        $options = @(Get-QualityOptions -Infos @((New-Info 240 5000000)))
        $options.Count | Should BeExactly 1
        $options[0].GetType().Name | Should BeExactly "Hashtable"
        $options[0].height | Should BeExactly "360"
    }

    It "files an in-between height under the tier that would download it" {
        # A 1920x804 film reports height 804: more than 720p gives, so it is the 1080p entry.
        $options = @(Get-QualityOptions -Infos @((New-Info 804 200000000), (New-Info 536 90000000)))
        $options[0].height | Should BeExactly "1080"
        $options[1].height | Should BeExactly "720"
    }

    It "gives every option a format that asks for separate video and audio" {
        # The single-file formats the low tiers used to ask for no longer exist on YouTube.
        $options = @(Get-QualityOptions -Infos @((New-Info 1080 1), (New-Info 360 1)))
        foreach ($option in $options) { $option.formatString | Should Match "^bestvideo\[height<=\d+\]\+bestaudio/" }
    }

    It "leaves the size off the label when yt-dlp could not report one" {
        $options = @(Get-QualityOptions -Infos @((New-Info 720 0)))
        $options[0].Label | Should BeExactly "HD (720p)"
    }

    It "returns nothing for no lines and for audio-only answers" {
        @(Get-QualityOptions -Infos @()).Count | Should BeExactly 0
        @(Get-QualityOptions -Infos @((New-Info 0 1000))).Count | Should BeExactly 0
    }
}

Describe "Format-ByteSize" {
    It "uses GB with one decimal from a gigabyte up" { Format-ByteSize -Bytes (1.6 * 1GB) | Should BeExactly "1.6 GB" }
    It "uses whole MB for ordinary video sizes" { Format-ByteSize -Bytes (742 * 1MB) | Should BeExactly "742 MB" }
    It "keeps one decimal for small files where it matters" { Format-ByteSize -Bytes (9.7 * 1MB) | Should BeExactly "9.7 MB" }
    It "uses KB below a megabyte" { Format-ByteSize -Bytes (500 * 1KB) | Should BeExactly "500 KB" }
    It "returns empty for an unknown size" { Format-ByteSize -Bytes 0 | Should BeExactly "" }
}

Describe "Format-VideoLength" {
    It "formats minutes and seconds" { Format-VideoLength -Seconds 635 | Should BeExactly "10:35" }
    It "pads seconds under ten" { Format-VideoLength -Seconds 19 | Should BeExactly "0:19" }
    It "adds hours for long videos" { Format-VideoLength -Seconds 3723 | Should BeExactly "1:02:03" }
    It "returns empty when the length is unknown" { Format-VideoLength -Seconds 0 | Should BeExactly "" }
}

Describe "Get-ThumbnailCandidates" {
    It "builds jpg urls from the id for YouTube, biggest first" {
        $urls = @(Get-ThumbnailCandidates -Info @{ Extractor = "Youtube"; Id = "abc123"; Thumbnail = "https://i.ytimg.com/vi_webp/abc123/maxresdefault.webp" })
        $urls.Count | Should BeExactly 3
        $urls[0] | Should BeExactly "https://i.ytimg.com/vi/abc123/maxresdefault.jpg"
        $urls[2] | Should BeExactly "https://i.ytimg.com/vi/abc123/mqdefault.jpg"
        ($urls -join " ") | Should Not Match "webp"
    }

    It "uses the reported thumbnail for other sites" {
        $urls = @(Get-ThumbnailCandidates -Info @{ Extractor = "Vimeo"; Id = "1"; Thumbnail = "https://example.com/t.jpg" })
        $urls.Count | Should BeExactly 1
        $urls[0] | Should BeExactly "https://example.com/t.jpg"
    }

    It "returns nothing when there is no image to try" {
        @(Get-ThumbnailCandidates -Info @{ Extractor = "Vimeo"; Id = "1"; Thumbnail = "" }).Count | Should BeExactly 0
    }
}

Describe "Get-YtDlpFailureMessage" {
    It "blames ffmpeg and points at Settings when yt-dlp cannot find it" {
        $result = Get-YtDlpFailureMessage -ErrorLines @(
            "ERROR: Postprocessing: ffprobe and ffmpeg not found. Please install or provide the path using --ffmpeg-location") -ExitCode 1
        $result.Message | Should Match "ffmpeg"
        $result.Message | Should Match "Settings"
        $result.ToolRelated | Should BeExactly $true
    }

    It "treats a postprocessing failure as an ffmpeg problem" {
        # Extraction to mp3 and the mp4 merge both run through ffmpeg; when that step
        # dies the fix lives in Settings, not in the URL the user typed.
        $result = Get-YtDlpFailureMessage -ErrorLines @(
            "ERROR: Postprocessing: Error opening output files: Invalid argument") -ExitCode 1
        $result.Message | Should Match "ffmpeg"
        $result.ToolRelated | Should BeExactly $true
    }

    It "suggests updating yt-dlp when YouTube extraction fails" {
        $result = Get-YtDlpFailureMessage -ErrorLines @(
            "ERROR: [youtube] dQw4w9WgXcQ: Unable to extract player response") -ExitCode 1
        $result.Message | Should Match "yt-dlp"
        $result.Message | Should Match "Settings"
        $result.ToolRelated | Should BeExactly $true
    }

    It "suggests updating yt-dlp on an HTTP 403, the classic stale-signature symptom" {
        $result = Get-YtDlpFailureMessage -ErrorLines @(
            "ERROR: unable to download video data: HTTP Error 403: Forbidden") -ExitCode 1
        $result.Message | Should Match "yt-dlp"
        $result.ToolRelated | Should BeExactly $true
    }

    It "shows the actual error text for failures that are not tool problems" {
        $result = Get-YtDlpFailureMessage -ErrorLines @(
            "ERROR: Unsupported URL: https://example.com/notavideo") -ExitCode 1
        $result.Message | Should Match "Unsupported URL"
        $result.ToolRelated | Should BeExactly $false
    }

    It "strips yt-dlp's ERROR: prefix so the message reads as a sentence" {
        $result = Get-YtDlpFailureMessage -ErrorLines @("ERROR: Video unavailable") -ExitCode 1
        $result.Message | Should Not Match "ERROR:"
        $result.Message | Should Match "Video unavailable"
    }

    It "truncates a very long error line instead of flooding the status row" {
        $longDetail = "ERROR: " + ("x" * 300)
        $result = Get-YtDlpFailureMessage -ErrorLines @($longDetail) -ExitCode 1
        $result.Message.Length | Should BeLessThan 160
    }

    It "falls back to the exit code when nothing was written to stderr" {
        $result = Get-YtDlpFailureMessage -ErrorLines @() -ExitCode 1
        $result.Message | Should Match "exit 1"
        $result.ToolRelated | Should BeExactly $false
    }

    It "prefers the ERROR line over earlier stderr noise" {
        $result = Get-YtDlpFailureMessage -ErrorLines @(
            "some transient stderr chatter",
            "ERROR: Video unavailable") -ExitCode 1
        $result.Message | Should Match "Video unavailable"
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
