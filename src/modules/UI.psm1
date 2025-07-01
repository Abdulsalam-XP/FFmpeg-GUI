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

function Show-FilmStripBorder {
    param (
        [string]$message,
        [int]$frameCount = 20,
        [int]$width = 60
    )
    
    try {
        $topBorder = "+" + ("=O=" * [math]::Floor($width/3)) + "+"
        $bottomBorder = "+" + ("=O=" * [math]::Floor($width/3)) + "+"
        
        Write-Host $topBorder -ForegroundColor Cyan
        Write-Host "|" -NoNewline -ForegroundColor Cyan
        Write-Host (" " * ([math]::Floor(($width - $message.Length) / 2)) + $message + (" " * [math]::Ceiling(($width - $message.Length) / 2))) -NoNewline -ForegroundColor Yellow
        Write-Host "|" -ForegroundColor Cyan
        Write-Host $bottomBorder -ForegroundColor Cyan
        
        for ($i = 0; $i -lt 5; $i++) {
            Write-Host "Processing..." -ForegroundColor Cyan
            Start-Sleep -Milliseconds 200
        }
    }
    catch {
        Write-Host "`n$message`n" -ForegroundColor Yellow
    }
}

function Show-ProgressBar {
    param (
        [int]$PercentComplete,
        [string]$Status
    )
    
    $progressBarWidth = 50
    $completedWidth = [math]::Floor($progressBarWidth * $PercentComplete / 100)
    $remainingWidth = $progressBarWidth - $completedWidth
    
    Write-Host "`r[" -NoNewline
    
    for ($i = 0; $i -lt $completedWidth; $i++) {
        if ($i -lt ($progressBarWidth * 0.33)) {
            Write-Host "#" -NoNewline -ForegroundColor Red
        } 
        elseif ($i -lt ($progressBarWidth * 0.66)) {
            Write-Host "#" -NoNewline -ForegroundColor Yellow
        } 
        else {
            Write-Host "#" -NoNewline -ForegroundColor Green
        }
    }
    
    Write-Host ("-" * $remainingWidth) -NoNewline -ForegroundColor DarkGray
    
    Write-Host "] $PercentComplete% Complete: $Status                     " -NoNewline -ForegroundColor White
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

function Show-FilmStripBorder {
    param (
        [string]$message,
        [int]$frameCount = 20,
        [int]$width = 60
    )
    
    try {
        $topBorder = "+" + ("=O=" * [math]::Floor($width/3)) + "+"
        $bottomBorder = "+" + ("=O=" * [math]::Floor($width/3)) + "+"
        
        Write-Host $topBorder -ForegroundColor Cyan
        Write-Host "|" -NoNewline -ForegroundColor Cyan
        Write-Host (" " * ([math]::Floor(($width - $message.Length) / 2)) + $message + (" " * [math]::Ceiling(($width - $message.Length) / 2))) -NoNewline -ForegroundColor Yellow
        Write-Host "|" -ForegroundColor Cyan
        Write-Host $bottomBorder -ForegroundColor Cyan
        
        for ($i = 0; $i -lt 5; $i++) {
            Write-Host "Processing..." -ForegroundColor Cyan
            Start-Sleep -Milliseconds 200
        }
    }
    catch {
        Write-Host "`n$message`n" -ForegroundColor Yellow
    }
}

function Show-ProgressBar {
    param (
        [int]$PercentComplete,
        [string]$Status
    )
    
    $progressBarWidth = 50
    $completedWidth = [math]::Floor($progressBarWidth * $PercentComplete / 100)
    $remainingWidth = $progressBarWidth - $completedWidth
    
    Write-Host "`r[" -NoNewline
    
    for ($i = 0; $i -lt $completedWidth; $i++) {
        if ($i -lt ($progressBarWidth * 0.33)) {
            Write-Host "#" -NoNewline -ForegroundColor Red
        } 
        elseif ($i -lt ($progressBarWidth * 0.66)) {
            Write-Host "#" -NoNewline -ForegroundColor Yellow
        } 
        else {
            Write-Host "#" -NoNewline -ForegroundColor Green
        }
    }
    
    Write-Host ("-" * $remainingWidth) -NoNewline -ForegroundColor DarkGray
    
    Write-Host "] $PercentComplete% Complete: $Status                     " -NoNewline -ForegroundColor White
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