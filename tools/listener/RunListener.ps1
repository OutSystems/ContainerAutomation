Param (
    $Port
)

[Console]::OutputEncoding = New-Object -typename System.Text.UTF8Encoding

Import-Module $(Join-Path -Path "$PSScriptRoot" -ChildPath "AutomationHookListener.psm1") -Force

if (-not $Port) {
    $Port = 8080
}

AutomationHookListener -Port $Port
