$modulePath = Join-Path $PSScriptRoot "..\VideoTrimmer.psm1"
Import-Module $modulePath -Force

Describe "ConvertFrom-KeyframeOutput" {
    It "reads plain csv times" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000", "0.250000", "0.500000")
        @($r).Count | Should Be 3
        $r[1] | Should Be 0.25
    }

    It "strips the trailing comma ffprobe csv emits" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,", "0.250000,")
        @($r).Count | Should Be 2
        $r[1] | Should Be 0.25
    }

    It "ignores blank lines and stderr noise" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000", "", "  ", "Some ffprobe warning", "0.250000")
        @($r).Count | Should Be 2
    }

    It "sorts ascending regardless of input order" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.500000", "0.000000", "0.250000")
        $r[0] | Should Be 0.0
        $r[2] | Should Be 0.5
    }

    It "returns an empty array, not null, for no usable input" {
        $r = ConvertFrom-KeyframeOutput -Lines @("", "N/A", "junk")
        @($r).Count | Should Be 0
        ($null -eq $r) | Should Be $false
    }

    It "ignores an N/A timestamp among real ones" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000", "N/A", "0.250000")
        @($r).Count | Should Be 2
    }
}
