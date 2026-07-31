$modulePath = Join-Path $PSScriptRoot "..\VideoTrimmer.psm1"
Import-Module $modulePath -Force

# Lines are shaped "<pts_time>,<flags>", matching ffprobe's
# `-show_entries packet=pts_time,flags -of csv=p=0` output, e.g. "0.249878,K__".
# This is the packet index, so every packet appears, not just keyframes -- a line
# is only kept when its flags field contains 'K'.
Describe "ConvertFrom-KeyframeOutput" {
    It "reads csv times, keeping only lines flagged K" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "0.250000,K__", "0.500000,K__")
        @($r).Count | Should Be 3
        $r[1] | Should Be 0.25
    }

    It "drops a line whose flags do not contain K" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.500000,___")
        @($r).Count | Should Be 0
    }

    It "keeps only the keyframes out of a mixed batch of packets" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "0.125000,___", "0.250000,K__", "0.375000,___")
        @($r).Count | Should Be 2
        $r[0] | Should Be 0.0
        $r[1] | Should Be 0.25
    }

    It "ignores blank lines and stderr noise" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "", "  ", "Some ffprobe warning", "0.250000,K__")
        @($r).Count | Should Be 2
    }

    It "sorts ascending regardless of input order" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.500000,K__", "0.000000,K__", "0.250000,K__")
        $r[0] | Should Be 0.0
        $r[2] | Should Be 0.5
    }

    It "returns an empty array, not null, for no usable input" {
        $r = ConvertFrom-KeyframeOutput -Lines @("", "N/A,K__", "junk", "0.5")
        @($r).Count | Should Be 0
        ($null -eq $r) | Should Be $false
    }

    It "ignores an N/A timestamp among real ones" {
        $r = ConvertFrom-KeyframeOutput -Lines @("0.000000,K__", "N/A,K__", "0.250000,K__")
        @($r).Count | Should Be 2
    }
}
