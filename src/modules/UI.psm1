function Show-AsciiBanner {
    $bannerLines = @(
        "########  ########  ##      ## #######  ########  ######        ##      ##  ######   ######  #########   ########  ",
        "##        ##        ###    ### ##    ## ##       ##    ##       ###    ### ##    ## ##    ##    ##     ##         ",
        "##        ##        ####  #### ##    ## ##       ##             ####  #### ##    ## ##          ##     ##       ",
        "########  ########  ## #### ## ####### ########  ##  ####       ## #### ## ######## ##  ####    ##     ##       ",
        "##        ##        ##  ##  ## ##       ##       ##    ##       ##  ##  ## ##    ## ##    ##    ##     ##       ",
        "##        ##        ##      ## ##       ##       ##    ##       ##      ## ##    ## ##    ##    ##     ##         ",
        "##        ##        ##      ## ##       ########  ######        ##      ## ##    ##  ######  #########   ######## "
    )

    $host.UI.RawUI.BackgroundColor = "Black"
    $host.UI.RawUI.ForegroundColor = "Cyan"
    Clear-Host

    for ($i = 0; $i -lt $bannerLines.Length; $i++) {
        $line = $bannerLines[$i]
        
        for ($j = 0; $j -lt 60 -and $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Blue"
            Start-Sleep -Milliseconds 0.5
        }
        
        for ($j = 60; $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Yellow"
            Start-Sleep -Milliseconds 0.5
        }
        
        Write-Host ""
    }
}

function Show-RotatingFFmpegLogo {
    $frames = @(
        @(
            "  #####   #######  ##   ##  #####   #######  ##   ##",
            "    ##    ##   ##   ## ##   ##  ##  ##   ##   ## ## ",
            "    ##    ##   ##    ###    #####   ##   ##    ###  ",
            "##  ##    ##   ##     #     ##  ##  ##   ##     #   ",
            " #####    #######     #     #####   #######     #   "
        ),
        @(
            "  #####   #####    ##   ##  #####   #####    ##   ##",
            "   ##    ##   ##    ## ##   ##  ## ##   ##    ## ## ",
            "   ##    ##   ##     ###    #####  ##   ##     ###  ",
            "## ##    ##   ##      #     ##  ## ##   ##      #   ",
            " ###      #####       #     #####   #####       #   "
        ),
        @(
            "  #####   #######  ##   ##  #####   #######  ##   ##",
            "    ##    ##   ##   ## ##   ##  ##  ##   ##   ## ## ",
            "    ##    ##   ##    ###    #####   ##   ##    ###  ",
            "##  ##    ##   ##     #     ##  ##  ##   ##     #   ",
            " #####    #######     #     #####   #######     #   "
        )
    )

    $colors = @("Yellow", "Blue", "Cyan", "Magenta")
    $originalCursorPosition = $host.UI.RawUI.CursorPosition
    $consoleWidth = $host.UI.RawUI.WindowSize.Width
    $logoWidth = 54
    $padding = [Math]::Max(0, [Math]::Floor(($consoleWidth - $logoWidth) / 2))
    $paddingSpaces = " " * $padding

    for ($i = 0; $i -lt 12; $i++) {
        $frameIndex = $i % $frames.Count
        $colorIndex = $frameIndex % $colors.Count
        $frame = $frames[$frameIndex]
        $color = $colors[$colorIndex]

        if ($i -eq 11) {
            $color = "Magenta"
        }

        $host.UI.RawUI.CursorPosition = $originalCursorPosition

        foreach ($line in $frame) {
            Write-Host "$paddingSpaces$line" -ForegroundColor $color
        }

        Start-Sleep -Milliseconds 85
    }

    Write-Host ""
}

function Show-AnimatedIcon {
    param (
        [string]$iconType,
        [string]$message,
        [double]$duration = 0.8
    )
    
    try {
        $spinnerFrames = @("⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏")
        $iterations = [math]::Ceiling($duration * 20)
        
        for ($i = 0; $i -lt $iterations; $i++) {
            $frame = $spinnerFrames[$i % $spinnerFrames.Length]
            Write-Host "`r$frame $message" -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 50
        }
        Write-Host "`r" -NoNewline
    }
    catch {
        Write-Host "$message" -ForegroundColor Cyan
    }
}

function Show-Banner {
    Write-Host ""
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "|                ADVANCED VIDEO PROCESSING TOOL                   |" -ForegroundColor Yellow
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                       SELECT AN OPTION                         |" -ForegroundColor Yellow
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "|  [1] Analyze Video & Compress                                  |" -ForegroundColor White
    Write-Host "|  [2] Extract & Merge Audio Streams                             |" -ForegroundColor White
    Write-Host "|  [3] Download YouTube MP3                                      |" -ForegroundColor White
    Write-Host "|  [4] Download YouTube MP4                                      |" -ForegroundColor White
    Write-Host "|  [B] Exit                                                      |" -ForegroundColor White
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
}

function Write-AnimatedLine {
    param (
        [string]$text,
        [string]$color = "White",
        [int]$delayMs = 3
    )
    
    Write-Host -NoNewline "  "
    foreach ($char in $text.ToCharArray()) {
        Write-Host -NoNewline $char -ForegroundColor $color
        Start-Sleep -Milliseconds $delayMs
    }
    Write-Host ""
}

function Show-CompletionAnimation {
    $frames = "/", "-", "\", "|"
    $colors = "Yellow", "Green", "Cyan", "Magenta"
    
    for ($i = 0; $i -lt 20; $i++) {
        $frame = $frames[$i % $frames.Length]
        $color = $colors[$i % $colors.Length]
        Write-Host "`r$frame Processing... " -NoNewline -ForegroundColor $color
        Start-Sleep -Milliseconds 100
    }
    
    Write-Host "`r* Completed!               " -ForegroundColor Green
}

Export-ModuleMember -Function * 
function Show-AsciiBanner {
    $bannerLines = @(
        "########  ########  ##      ## #######  ########  ######        ##      ##  ######   ######  #########   ########  ",
        "##        ##        ###    ### ##    ## ##       ##    ##       ###    ### ##    ## ##    ##    ##     ##         ",
        "##        ##        ####  #### ##    ## ##       ##             ####  #### ##    ## ##          ##     ##       ",
        "########  ########  ## #### ## ####### ########  ##  ####       ## #### ## ######## ##  ####    ##     ##       ",
        "##        ##        ##  ##  ## ##       ##       ##    ##       ##  ##  ## ##    ## ##    ##    ##     ##       ",
        "##        ##        ##      ## ##       ##       ##    ##       ##      ## ##    ## ##    ##    ##     ##         ",
        "##        ##        ##      ## ##       ########  ######        ##      ## ##    ##  ######  #########   ######## "
    )

    $host.UI.RawUI.BackgroundColor = "Black"
    $host.UI.RawUI.ForegroundColor = "Cyan"
    Clear-Host

    for ($i = 0; $i -lt $bannerLines.Length; $i++) {
        $line = $bannerLines[$i]
        
        for ($j = 0; $j -lt 60 -and $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Blue"
            Start-Sleep -Milliseconds 0.5
        }
        
        for ($j = 60; $j -lt $line.Length; $j++) {
            Write-Host -NoNewline ($line[$j]) -ForegroundColor "Yellow"
            Start-Sleep -Milliseconds 0.5
        }
        
        Write-Host ""
    }
}

function Show-RotatingFFmpegLogo {
    $frames = @(
        @(
            "  #####   #######  ##   ##  #####   #######  ##   ##",
            "    ##    ##   ##   ## ##   ##  ##  ##   ##   ## ## ",
            "    ##    ##   ##    ###    #####   ##   ##    ###  ",
            "##  ##    ##   ##     #     ##  ##  ##   ##     #   ",
            " #####    #######     #     #####   #######     #   "
        ),
        @(
            "  #####   #####    ##   ##  #####   #####    ##   ##",
            "   ##    ##   ##    ## ##   ##  ## ##   ##    ## ## ",
            "   ##    ##   ##     ###    #####  ##   ##     ###  ",
            "## ##    ##   ##      #     ##  ## ##   ##      #   ",
            " ###      #####       #     #####   #####       #   "
        ),
        @(
            "  #####   #######  ##   ##  #####   #######  ##   ##",
            "    ##    ##   ##   ## ##   ##  ##  ##   ##   ## ## ",
            "    ##    ##   ##    ###    #####   ##   ##    ###  ",
            "##  ##    ##   ##     #     ##  ##  ##   ##     #   ",
            " #####    #######     #     #####   #######     #   "
        )
    )

    $colors = @("Yellow", "Blue", "Cyan", "Magenta")
    $originalCursorPosition = $host.UI.RawUI.CursorPosition
    $consoleWidth = $host.UI.RawUI.WindowSize.Width
    $logoWidth = 54
    $padding = [Math]::Max(0, [Math]::Floor(($consoleWidth - $logoWidth) / 2))
    $paddingSpaces = " " * $padding

    for ($i = 0; $i -lt 12; $i++) {
        $frameIndex = $i % $frames.Count
        $colorIndex = $frameIndex % $colors.Count
        $frame = $frames[$frameIndex]
        $color = $colors[$colorIndex]

        if ($i -eq 11) {
            $color = "Magenta"
        }

        $host.UI.RawUI.CursorPosition = $originalCursorPosition

        foreach ($line in $frame) {
            Write-Host "$paddingSpaces$line" -ForegroundColor $color
        }

        Start-Sleep -Milliseconds 85
    }

    Write-Host ""
}

function Show-AnimatedIcon {
    param (
        [string]$iconType,
        [string]$message,
        [double]$duration = 0.8
    )
    
    try {
        $spinnerFrames = @("⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏")
        $iterations = [math]::Ceiling($duration * 20)
        
        for ($i = 0; $i -lt $iterations; $i++) {
            $frame = $spinnerFrames[$i % $spinnerFrames.Length]
            Write-Host "`r$frame $message" -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 50
        }
        Write-Host "`r" -NoNewline
    }
    catch {
        Write-Host "$message" -ForegroundColor Cyan
    }
}

function Show-Banner {
    Write-Host ""
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "|                ADVANCED VIDEO PROCESSING TOOL                   |" -ForegroundColor Yellow
    Write-Host "|                                                                 |" -ForegroundColor Magenta
    Write-Host "+-----------------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                       SELECT AN OPTION                         |" -ForegroundColor Yellow
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "|  [1] Analyze Video & Compress                                  |" -ForegroundColor White
    Write-Host "|  [2] Extract & Merge Audio Streams                             |" -ForegroundColor White
    Write-Host "|  [3] Download YouTube MP3                                      |" -ForegroundColor White
    Write-Host "|  [4] Download YouTube MP4                                      |" -ForegroundColor White
    Write-Host "|  [B] Exit                                                      |" -ForegroundColor White
    Write-Host "|                                                                |" -ForegroundColor Blue
    Write-Host "+----------------------------------------------------------------+" -ForegroundColor Blue
}

function Write-AnimatedLine {
    param (
        [string]$text,
        [string]$color = "White",
        [int]$delayMs = 3
    )
    
    Write-Host -NoNewline "  "
    foreach ($char in $text.ToCharArray()) {
        Write-Host -NoNewline $char -ForegroundColor $color
        Start-Sleep -Milliseconds $delayMs
    }
    Write-Host ""
}

function Update-ProgressBar {
    param(
        [string]$Activity,   
        [double]$Percent,   
        [string]$ETA = "--:--:--",
        [string]$StatusInfo = "" 
    )

    $width = 30
    $filled = [math]::Round(($Percent / 100) * $width)
    if ($filled -gt $width) { $filled = $width }
    $empty = $width - $filled
    
    $charFilled = "=" 
    $charEmpty  = "-" 

    Write-Host "`r" -NoNewline
    
    Write-Host "$Activity " -NoNewline -ForegroundColor Yellow
    
    Write-Host "[" -NoNewline -ForegroundColor White
    
    if ($filled -gt 0) { Write-Host ($charFilled * $filled) -NoNewline -ForegroundColor Green }
    if ($empty -gt 0)  { Write-Host ($charEmpty * $empty) -NoNewline -ForegroundColor Gray }
    
    Write-Host "] " -NoNewline -ForegroundColor White
    
    $percentStr = "{0,5:N1}" -f $Percent
    Write-Host "$percentStr%" -NoNewline -ForegroundColor Cyan
    
    Write-Host " | ETA: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$ETA   " -NoNewline -ForegroundColor White
    
    if ($StatusInfo) {
        Write-Host "| $StatusInfo" -NoNewline -ForegroundColor DarkGray
    }
    
    Write-Host "    " -NoNewline
}

function Show-CompletionAnimation {
    $frames = "/", "-", "\", "|"
    $colors = "Yellow", "Green", "Cyan", "Magenta"
    
    for ($i = 0; $i -lt 20; $i++) {
        $frame = $frames[$i % $frames.Length]
        $color = $colors[$i % $colors.Length]
        Write-Host "`r$frame Processing... " -NoNewline -ForegroundColor $color
        Start-Sleep -Milliseconds 100
    }
    
    Write-Host "`r* Completed!               " -ForegroundColor Green
}

Export-ModuleMember -Function * 