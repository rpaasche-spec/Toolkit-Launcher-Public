
#Requires -Version 5.1

<#
.SYNOPSIS
    Removes the temporary PowerShell-Toolkit.

.DESCRIPTION
    Removes %TEMP%\Toolkit and its paths from
    the current PowerShell session.
#>

$ErrorActionPreference = 'Stop'

$ToolkitRoot = Join-Path $env:TEMP 'Toolkit'
$Marker = Join-Path $ToolkitRoot '.toolkit-launcher-managed'

# Check if Toolkit exists
if (-not (Test-Path -LiteralPath $ToolkitRoot)) {
    Write-Host 'No temporary Toolkit installation found.'
    return
}

# Safety checks
$Item = Get-Item -LiteralPath $ToolkitRoot -Force

if (-not $Item.PSIsContainer -or
    ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Unsafe Toolkit folder. Cleanup cancelled.'
}

if (-not (Test-Path -LiteralPath $Marker)) {
    throw 'Toolkit folder is not managed by launcher.'
}

$Initializer = Join-Path $ToolkitRoot 'Initialize-Toolkit.ps1'

if (-not (Test-Path -LiteralPath $Initializer)) {
    throw 'Toolkit installation could not be verified.'
}

Write-Host "`nToolkit location: $ToolkitRoot" -ForegroundColor Cyan

$Confirm = Read-Host 'Remove PowerShell-Toolkit? Type JA'

if ($Confirm -cne 'JA') {
    Write-Host 'Cleanup cancelled.'
    return
}

# Remove downloaded files
Remove-Item -LiteralPath $ToolkitRoot `
    -Recurse -Force -ErrorAction Stop

# Remove paths from current PowerShell session
$Separator = [IO.Path]::PathSeparator
$Pattern = [regex]::Escape([string]$Separator)

foreach ($VariableName in @('PATH', 'PSModulePath')) {

    $CurrentValue = [Environment]::GetEnvironmentVariable(
        $VariableName,
        'Process'
    )

    $Remaining = @(
        ($CurrentValue -split $Pattern) |
            Where-Object {
                $_ -and
                -not $_.StartsWith(
                    "$ToolkitRoot\",
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )

    [Environment]::SetEnvironmentVariable(
        $VariableName,
        ($Remaining -join $Separator),
        'Process'
    )
}

Remove-Variable ToolkitSessionRoot -Scope Global `
    -ErrorAction SilentlyContinue

Write-Host "`nPowerShell-Toolkit removed." -ForegroundColor Green
