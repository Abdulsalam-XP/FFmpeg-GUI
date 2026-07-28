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
