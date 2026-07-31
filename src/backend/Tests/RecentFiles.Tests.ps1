$modulePath = Join-Path $PSScriptRoot "..\RecentFiles.psm1"
Import-Module $modulePath -Force

$when = [datetime]::new(2026, 7, 31, 12, 0, 0)

Describe "Add-RecentEntry" {
    It "puts a new entry first" {
        $list = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        $list.Count | Should Be 1
        $list[0].Path | Should Be "C:\a.mp4"
        $list[0].Job | Should Be "Trim"
    }

    It "keeps the newest at the front" {
        $list = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        $list = Add-RecentEntry -Entries $list -Path "C:\b.mp4" -Job "Compress" -When $when
        $list[0].Path | Should Be "C:\b.mp4"
        $list[1].Path | Should Be "C:\a.mp4"
    }

    It "never exceeds three entries and drops the oldest" {
        $list = @()
        foreach ($n in 1..4) {
            $list = Add-RecentEntry -Entries $list -Path "C:\$n.mp4" -Job "Trim" -When $when
        }
        $list.Count | Should Be 3
        $list[0].Path | Should Be "C:\4.mp4"
        ($list | Where-Object { $_.Path -eq "C:\1.mp4" }) | Should BeNullOrEmpty
    }

    It "moves an existing path to the top instead of duplicating it" {
        $list = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        $list = Add-RecentEntry -Entries $list -Path "C:\b.mp4" -Job "Trim" -When $when
        $list = Add-RecentEntry -Entries $list -Path "C:\a.mp4" -Job "Compress" -When $when
        $list.Count | Should Be 2
        $list[0].Path | Should Be "C:\a.mp4"
        $list[0].Job | Should Be "Compress"
    }

    It "treats a path differing only by case as the same file" {
        $list = Add-RecentEntry -Entries @() -Path "C:\A.mp4" -Job "Trim" -When $when
        $list = Add-RecentEntry -Entries $list -Path "c:\a.mp4" -Job "Trim" -When $when
        $list.Count | Should Be 1
    }
}

Describe "Remove-RecentEntry" {
    It "drops only the named entry" {
        $list = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        $list = Add-RecentEntry -Entries $list -Path "C:\b.mp4" -Job "Trim" -When $when
        $list = Remove-RecentEntry -Entries $list -Path "C:\a.mp4"
        $list.Count | Should Be 1
        $list[0].Path | Should Be "C:\b.mp4"
    }

    It "leaves the list alone when the path is not present" {
        $list = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        (Remove-RecentEntry -Entries $list -Path "C:\zzz.mp4").Count | Should Be 1
    }

    It "returns an empty list rather than null when the last entry goes" {
        $list = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        $result = Remove-RecentEntry -Entries $list -Path "C:\a.mp4"
        @($result).Count | Should Be 0
    }
}

Describe "Format-RecentAge" {
    $now = [datetime]::new(2026, 7, 31, 12, 0, 0)

    It "says just now under a minute" {
        Format-RecentAge -When $now.AddSeconds(-20) -Now $now | Should Be "just now"
    }

    It "reports whole minutes" {
        Format-RecentAge -When $now.AddMinutes(-5) -Now $now | Should Be "5m ago"
    }

    It "reports whole hours" {
        Format-RecentAge -When $now.AddHours(-3) -Now $now | Should Be "3h ago"
    }

    It "reports whole days" {
        Format-RecentAge -When $now.AddDays(-2) -Now $now | Should Be "2d ago"
    }

    It "does not produce a negative age for a clock skewed into the future" {
        Format-RecentAge -When $now.AddMinutes(5) -Now $now | Should Be "just now"
    }
}
