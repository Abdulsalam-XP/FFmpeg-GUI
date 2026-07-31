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

Describe "Get-RecentFiles" {
    # Save/restore so these tests cannot leak $global:RecentFiles state into
    # the other Describe blocks (or into a real session running the suite).
    $originalRecentFiles = $global:RecentFiles

    AfterEach {
        $global:RecentFiles = $originalRecentFiles
    }

    # These assert the caller idiom @(Get-RecentFiles) rather than the bare
    # call, because that is the contract every consumer (Update-RecentList
    # included) actually depends on. Get-RecentFiles emits its elements
    # normally rather than as one pre-wrapped object -- wrapping the bare
    # call a second time here would defeat exactly the case (two-plus
    # entries) that a `,@(...)` return breaks: @(Get-RecentFiles) on such
    # a return double-wraps into a one-element array holding the whole list.

    It "returns an empty array when the global is unset" {
        $global:RecentFiles = $null
        @(Get-RecentFiles).Count | Should Be 0
    }

    It "returns a one-element array for a single-entry global" {
        $global:RecentFiles = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        $result = @(Get-RecentFiles)
        $result.Count | Should Be 1
        $result[0].Path | Should Be "C:\a.mp4"
    }

    It "returns a distinct entry per item for a two-entry global, not one merged row" {
        $list = Add-RecentEntry -Entries @() -Path "C:\a.mp4" -Job "Trim" -When $when
        $global:RecentFiles = Add-RecentEntry -Entries $list -Path "C:\b.mp4" -Job "Compress" -When $when
        $result = @(Get-RecentFiles)
        $result.Count | Should Be 2
        $result[0].Job | Should Be "Compress"
        $result[1].Job | Should Be "Trim"
    }
}

Describe "Add-RecentFile and Remove-RecentFile" {
    # Save/restore so these tests cannot leak $global:RecentFiles state into the
    # other Describe blocks (or into a real session running the suite).
    $originalRecentFiles = $global:RecentFiles

    AfterEach {
        $global:RecentFiles = $originalRecentFiles
    }

    # Both functions call Save-Settings, which writes the developer's real
    # settings.json. Mocking it inside RecentFiles' module scope stops that
    # write from ever happening while still letting us assert it was (or was
    # not) called.
    Mock -ModuleName RecentFiles -CommandName Save-Settings -MockWith { }

    It "puts the entry in `$global:RecentFiles" {
        $global:RecentFiles = @()
        Add-RecentFile -Path "C:\a.mp4" -Job "Trim"
        $global:RecentFiles.Count | Should Be 1
        $global:RecentFiles[0].Path | Should Be "C:\a.mp4"
    }

    It "moves an existing path to the top instead of duplicating it on a second add" {
        $global:RecentFiles = @()
        Add-RecentFile -Path "C:\a.mp4" -Job "Trim"
        Add-RecentFile -Path "C:\b.mp4" -Job "Trim"
        Add-RecentFile -Path "C:\a.mp4" -Job "Compress"
        $global:RecentFiles.Count | Should Be 2
        $global:RecentFiles[0].Path | Should Be "C:\a.mp4"
        $global:RecentFiles[0].Job | Should Be "Compress"
    }

    It "drops the named entry on Remove-RecentFile" {
        $global:RecentFiles = @()
        Add-RecentFile -Path "C:\a.mp4" -Job "Trim"
        Add-RecentFile -Path "C:\b.mp4" -Job "Trim"
        Remove-RecentFile -Path "C:\a.mp4"
        $global:RecentFiles.Count | Should Be 1
        $global:RecentFiles[0].Path | Should Be "C:\b.mp4"
    }

    It "does not call Save-Settings when -NoSave is passed" {
        $global:RecentFiles = @()
        Add-RecentFile -Path "C:\a.mp4" -Job "Trim" -NoSave
        # -Scope It: without it, Assert-MockCalled counts every call made anywhere
        # in this Describe block, including the plain (non -NoSave) adds in the
        # earlier It blocks above.
        Assert-MockCalled -ModuleName RecentFiles -CommandName Save-Settings -Times 0 -Scope It
    }

    It "calls Save-Settings when -NoSave is not passed" {
        $global:RecentFiles = @()
        Add-RecentFile -Path "C:\a.mp4" -Job "Trim"
        Assert-MockCalled -ModuleName RecentFiles -CommandName Save-Settings -Times 1 -Scope It
    }
}
