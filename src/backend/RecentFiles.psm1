# The list shown under the dropzone on Compress, Merge Audio and Trim. Split in two
# deliberately: the *-RecentEntry functions are pure array transforms with no global
# or disk access, which is what the Pester tests exercise, while the *-RecentFile
# wrappers are the thin layer that touches $global:RecentFiles and Save-Settings.

# Three total, not three per panel, and not three per job. Raising this is a one-line
# change here plus nothing else -- the UI loops over whatever it is handed.
$script:RecentLimit = 3

function Add-RecentEntry {
    param(
        [object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Job,
        [datetime]$When = (Get-Date)
    )

    # Case-insensitive because Windows paths are: re-compressing "C:\A.mp4" after
    # picking "c:\a.mp4" must move the existing row, not add a second one for the
    # same file.
    $kept = @($Entries | Where-Object { $_ -and $_.Path -ine $Path })

    $entry = [PSCustomObject]@{
        Path = $Path
        Job  = $Job
        # Sortable round-trip format. ConvertTo-Json would otherwise emit a
        # /Date(...)/ literal for a real [datetime], which does not survive
        # ConvertFrom-Json cleanly.
        When = $When.ToString("s")
    }

    # Unary comma: without it, PowerShell unrolls a single-element array on return,
    # handing the caller a bare PSCustomObject instead of the object[] this
    # function is documented to produce.
    return ,@(@($entry) + $kept | Select-Object -First $script:RecentLimit)
}

function Remove-RecentEntry {
    param(
        [object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Path
    )
    # Same unary-comma reasoning as Add-RecentEntry above.
    return ,@($Entries | Where-Object { $_ -and $_.Path -ine $Path })
}

# Coarse on purpose: the row is a hint about which file this is, not a log entry.
function Format-RecentAge {
    param(
        [Parameter(Mandatory = $true)][datetime]$When,
        [datetime]$Now = (Get-Date)
    )

    $span = $Now - $When
    # A file stamped in the future (clock change, or a file copied from another
    # machine) would otherwise render as "-3m ago".
    if ($span.TotalSeconds -lt 60) { return "just now" }
    if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes)m ago" }
    if ($span.TotalHours -lt 24) { return "$([int]$span.TotalHours)h ago" }
    return "$([int]$span.TotalDays)d ago"
}

function Get-RecentFiles {
    # Absent on first run and in every settings.json written before this feature,
    # same as ToolCheckCache -- a null here is normal rather than a fault.
    # No unary comma here: every caller (Update-RecentList included) wraps this
    # call in @(...) to get array semantics. A `,@(...)` return would emit the
    # whole array as a single pipeline object, which @(...) at the call site
    # then wraps *again* -- a one-element array whose only element is the
    # entire list. Emitting elements normally is what lets @(Get-RecentFiles)
    # do the right thing at every size, including zero and one.
    if (-not $global:RecentFiles) { return @() }
    return @($global:RecentFiles)
}

function Add-RecentFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Job
    )
    $global:RecentFiles = Add-RecentEntry -Entries (Get-RecentFiles) -Path $Path -Job $Job -When (Get-Date)
    Save-Settings
}

function Remove-RecentFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $global:RecentFiles = Remove-RecentEntry -Entries (Get-RecentFiles) -Path $Path
    Save-Settings
}

Export-ModuleMember -Function Add-RecentEntry, Remove-RecentEntry, Format-RecentAge, `
    Get-RecentFiles, Add-RecentFile, Remove-RecentFile
