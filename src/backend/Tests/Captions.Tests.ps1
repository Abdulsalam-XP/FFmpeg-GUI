$modulePath = Join-Path $PSScriptRoot "..\Captions.psm1"
Import-Module $modulePath -Force

Describe "New-Caption" {
    It "creates a caption with the spec defaults" {
        $c = New-Caption -Start 12.4 -End 14.1 -Text "nice shot"
        $c.Start | Should Be 12.4
        $c.End | Should Be 14.1
        $c.Text | Should Be "nice shot"
        $c.X | Should Be 0.5
        $c.Y | Should Be 0.78
        $c.FontSizeFrac | Should Be 0.055
        $c.FontFamily | Should Be "Arial"
        $c.Bold | Should Be $true
        $c.FillColor | Should Be "#FFFFFF"
        $c.OutlineColor | Should Be "#000000"
        $c.OutlineWidth | Should Be 3
        $c.BounceIn | Should Be $true
    }
    It "gives every caption a distinct id" {
        (New-Caption -Start 0 -End 1).Id | Should Not Be (New-Caption -Start 0 -End 1).Id
    }
}

Describe "ConvertTo-AssColor" {
    It "converts RGB hex to ASS BGR" {
        ConvertTo-AssColor -Hex "#FFAA33" | Should Be "&H0033AAFF"
    }
    It "handles white and black" {
        ConvertTo-AssColor -Hex "#FFFFFF" | Should Be "&H00FFFFFF"
        ConvertTo-AssColor -Hex "#000000" | Should Be "&H00000000"
    }
}

Describe "ConvertTo-AssTime" {
    It "formats zero" { ConvertTo-AssTime -Seconds 0 | Should Be "0:00:00.00" }
    It "formats minutes and centiseconds" {
        ConvertTo-AssTime -Seconds 74.35 | Should Be "0:01:14.35"
    }
    It "formats hours" { ConvertTo-AssTime -Seconds 3723.5 | Should Be "1:02:03.50" }
}

Describe "ConvertTo-AssText" {
    It "escapes braces so user text cannot inject override tags" {
        ConvertTo-AssText -Text "a{b}c" | Should Be "a\{b\}c"
    }
    It "turns newlines into ASS line breaks" {
        ConvertTo-AssText -Text "line1`r`nline2" | Should Be "line1\Nline2"
        ConvertTo-AssText -Text "line1`nline2" | Should Be "line1\Nline2"
    }
    It "passes plain text through, emoji included" {
        ConvertTo-AssText -Text "gg wp" | Should Be "gg wp"
    }
}
