$modulePath = Join-Path $PSScriptRoot "..\ToolUpdates.psm1"
Import-Module $modulePath -Force

Describe "ConvertFrom-FfmpegVersionString" {
    It "reads the build date out of a BtbN master build" {
        $line = "ffmpeg version N-124716-g054dffd133-20260531-win64-gpl Copyright (c) 2000-2026 the FFmpeg developers"
        $result = ConvertFrom-FfmpegVersionString -Line $line
        $result | Should Be ([datetime]::new(2026, 5, 31))
    }

    It "returns null for a dateless release build" {
        ConvertFrom-FfmpegVersionString -Line "ffmpeg version 7.1.1-full_build-www.gyan.dev" | Should BeNullOrEmpty
    }

    It "returns null for a bare tagged build" {
        ConvertFrom-FfmpegVersionString -Line "ffmpeg version n7.1 Copyright (c) 2000-2024" | Should BeNullOrEmpty
    }

    It "returns null for an empty line" {
        ConvertFrom-FfmpegVersionString -Line "" | Should BeNullOrEmpty
    }

    It "returns null for unrelated text" {
        ConvertFrom-FfmpegVersionString -Line "'ffmpeg' is not recognized as an internal or external command" | Should BeNullOrEmpty
    }

    It "does not mistake a longer digit run for a date" {
        ConvertFrom-FfmpegVersionString -Line "ffmpeg version N-2026053112-gabcdef" | Should BeNullOrEmpty
    }
}

Describe "ConvertFrom-YtDlpVersionString" {
    It "parses a stable release version" {
        ConvertFrom-YtDlpVersionString -Line "2026.03.17" | Should Be ([datetime]::new(2026, 3, 17))
    }

    It "parses a nightly build with a time suffix" {
        ConvertFrom-YtDlpVersionString -Line "2026.07.04.232319" | Should Be ([datetime]::new(2026, 7, 4))
    }

    It "tolerates surrounding whitespace" {
        ConvertFrom-YtDlpVersionString -Line "  2026.07.04 `r`n" | Should Be ([datetime]::new(2026, 7, 4))
    }

    It "returns null for garbage" {
        ConvertFrom-YtDlpVersionString -Line "not a version" | Should BeNullOrEmpty
    }

    It "returns null for an empty line" {
        ConvertFrom-YtDlpVersionString -Line "" | Should BeNullOrEmpty
    }
}

function New-InstalledStub {
    param([string]$Source = "bin", $Version = $null, [string]$Display = "x")
    return @{ Name = "yt-dlp"; Path = "C:\app\bin\yt-dlp.exe"; Source = $Source; Version = $Version; Display = $Display }
}

function New-LatestStub {
    param($Version = [datetime]::new(2026, 7, 4))
    return @{ Name = "yt-dlp"; Version = $Version; Display = "2026.07.04"
              DownloadUrl = "https://example.invalid/yt-dlp.exe"; AssetName = "yt-dlp.exe" }
}

Describe "Test-ToolUpdate" {
    It "reports Available when the remote build is newer" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Version ([datetime]::new(2026, 3, 17))) -Latest (New-LatestStub)
        $r.Status | Should Be "Available"
    }

    It "reports Current when the versions match" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Version ([datetime]::new(2026, 7, 4))) -Latest (New-LatestStub)
        $r.Status | Should Be "Current"
    }

    It "reports Current when the installed build is newer than the remote" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Version ([datetime]::new(2026, 9, 1))) -Latest (New-LatestStub)
        $r.Status | Should Be "Current"
    }

    It "reports Unknown when the installed version could not be parsed" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Version $null) -Latest (New-LatestStub)
        $r.Status | Should Be "Unknown"
    }

    It "reports Missing when no tool is installed" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Source "missing") -Latest (New-LatestStub)
        $r.Status | Should Be "Missing"
    }

    It "reports Missing for a PATH tool even when its version is current" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Source "system" -Version ([datetime]::new(2026, 7, 4))) -Latest (New-LatestStub)
        $r.Status | Should Be "Missing"
    }

    It "reports Missing for a PATH tool even when its version is newer than the remote" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Source "system" -Version ([datetime]::new(2027, 1, 1))) -Latest (New-LatestStub)
        $r.Status | Should Be "Missing"
    }

    It "reports Unknown when the remote lookup produced nothing" {
        $r = Test-ToolUpdate -Installed (New-InstalledStub -Version ([datetime]::new(2026, 3, 17))) -Latest $null
        $r.Status | Should Be "Unknown"
    }

    It "passes the installed and latest records through unchanged" {
        $installed = New-InstalledStub -Version ([datetime]::new(2026, 3, 17))
        $r = Test-ToolUpdate -Installed $installed -Latest (New-LatestStub)
        $r.Installed.Path | Should Be "C:\app\bin\yt-dlp.exe"
        $r.Latest.Display | Should Be "2026.07.04"
    }
}

Describe "Test-ToolCacheFresh" {
    $now = [datetime]::new(2026, 7, 28, 12, 0, 0, [System.DateTimeKind]::Utc)

    It "treats a five-minute-old timestamp as fresh" {
        Test-ToolCacheFresh -Timestamp "2026-07-28T11:55:00Z" -Now $now -MaxAgeMinutes 60 | Should Be $true
    }

    It "treats a ninety-minute-old timestamp as stale" {
        Test-ToolCacheFresh -Timestamp "2026-07-28T10:30:00Z" -Now $now -MaxAgeMinutes 60 | Should Be $false
    }

    It "treats a missing timestamp as stale" {
        Test-ToolCacheFresh -Timestamp $null -Now $now -MaxAgeMinutes 60 | Should Be $false
    }

    It "treats an unparseable timestamp as stale" {
        Test-ToolCacheFresh -Timestamp "last tuesday" -Now $now -MaxAgeMinutes 60 | Should Be $false
    }

    It "treats a future timestamp as stale so a clock change cannot pin the cache" {
        Test-ToolCacheFresh -Timestamp "2026-07-29T12:00:00Z" -Now $now -MaxAgeMinutes 60 | Should Be $false
    }
}
