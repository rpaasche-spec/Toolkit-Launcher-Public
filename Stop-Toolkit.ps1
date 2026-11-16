
#Requires -Version 5.1

<#
.SYNOPSIS
    Finds and removes temporary PowerShell-Toolkit downloads.
#>

# Find our temporary Toolkit folders
$ToolkitFolders = @(
    Get-ChildItem -LiteralPath $env:TEMP -Directory |
        Where-Object {
            $_.Name -match '^PowerShell-Toolkit-[0-9a-f]{32}$'
        }
)

if ($ToolkitFolders.Count -eq 0) {
    Write-Host 'No temporary Toolkit folders found.'
    return
}

Write-Host "`nFound Toolkit folders:" -ForegroundColor Cyan

$ToolkitFolders | Select-Object FullName

# Ask before deleting
$Confirm = Read-Host "`nDelete these folders? Type JA"

if ($Confirm -cne 'JA') {
    Write-Host 'Cleanup cancelled.'
    return
}

foreach ($Folder in $ToolkitFolders) {

    # Verify that this is a Toolkit download
    $Init = Get-ChildItem -LiteralPath $Folder.FullName `
        -Filter 'Initialize-Toolkit.ps1' `
        -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $Init) {
        Write-Warning "Skipping unverified folder: $($Folder.FullName)"
        continue
    }

    # Remove Toolkit paths from current session
    foreach ($VariableName in @('PATH', 'PSModulePath')) {

        $CurrentValue = [Environment]::GetEnvironmentVariable(
            $VariableName, 'Process'
        )

        $Paths = $CurrentValue -split [regex]::Escape(
            [string][IO.Path]::PathSeparator
        )

        $Paths = $Paths | Where-Object {
            -not $_.StartsWith(
                "$($Folder.FullName)\",
                [StringComparison]::OrdinalIgnoreCase
            )
        }

        [Environment]::SetEnvironmentVariable(
            $VariableName,
            ($Paths -join [IO.Path]::PathSeparator),
            'Process'
        )
    }

    Remove-Item -LiteralPath $Folder.FullName `
        -Recurse -Force -ErrorAction Stop

    Write-Host "Removed: $($Folder.Name)" -ForegroundColor Green
}

Remove-Variable ToolkitSessionRoot -Scope Global `
    -ErrorAction SilentlyContinue

Write-Host "`nCleanup completed." -ForegroundColor Green
