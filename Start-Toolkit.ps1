
#Requires -Version 5.1

<#
.SYNOPSIS
    Downloads and initializes PowerShell-Toolkit.

.DESCRIPTION
    Decrypts the GitHub token using a personal passphrase.
    Downloads the latest Toolkit from GitHub main.
    Installs it temporarily to %TEMP%\Toolkit.

    Supports Windows PowerShell 5.1 and PowerShell 7.
    No permanent PowerShell profile changes.
#>

$ErrorActionPreference = 'Stop'

# Configuration
$TokenFile = Join-Path $PSScriptRoot 'token.enc'
$Url = 'https://api.github.com/repos/rpaasche-spec/PowerShell-Toolkit/zipball/main'

$ToolkitRoot = Join-Path $env:TEMP 'Toolkit'
$WorkRoot = Join-Path $env:TEMP (
    'Toolkit-Staging-' + [guid]::NewGuid().ToString('N')
)
$BackupRoot = Join-Path $env:TEMP (
    'Toolkit-Backup-' + [guid]::NewGuid().ToString('N')
)

$ZipFile = Join-Path $WorkRoot 'Toolkit.zip'
$ExtractRoot = Join-Path $WorkRoot 'Extracted'
$MarkerName = '.toolkit-launcher-managed'

# Remember current environment for rollback
$OriginalPath = $env:PATH
$OriginalModulePath = $env:PSModulePath

$Passphrase = $null
$SecureToken = $null
$PassPtr = [IntPtr]::Zero
$TokenPtr = [IntPtr]::Zero
$Key = $null
$Kdf = $null

$BackupCreated = $false
$Installed = $false

try {
    # Verify encrypted token
    if (-not (Test-Path -LiteralPath $TokenFile)) {
        throw 'token.enc ble ikke funnet.'
    }

    $Config = Get-Content -LiteralPath $TokenFile -Raw |
        ConvertFrom-Json

    if ($Config.Version -ne 1 -or $Config.Iterations -ne 250000) {
        throw 'Ukjent krypteringsformat.'
    }

    # Ask for personal passphrase
    $Passphrase = Read-Host 'Toolkit password' -AsSecureString

    # Derive AES key from passphrase
    $PassPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $Passphrase
    )

    $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        $PassPtr
    )

    $Salt = [Convert]::FromBase64String($Config.Salt)

    $Kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password,
        $Salt,
        [int]$Config.Iterations,
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )

    $Key = $Kdf.GetBytes(32)

    # Decrypt GitHub token
    $SecureToken = ConvertTo-SecureString `
        -String $Config.Ciphertext `
        -Key $Key `
        -ErrorAction Stop

    $TokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $SecureToken
    )

    $PlainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        $TokenPtr
    )

    # Prepare temporary download folder
    New-Item -Path $WorkRoot -ItemType Directory |
        Out-Null

    Write-Host "`nDownloading PowerShell-Toolkit..." -ForegroundColor Cyan

    # Download private GitHub repository
    Invoke-WebRequest `
        -Uri $Url `
        -Headers @{
            Authorization = "Bearer $PlainToken"
            Accept = 'application/vnd.github+json'
        } `
        -OutFile $ZipFile `
        -UseBasicParsing `
        -ErrorAction Stop

    # Extract archive
    Expand-Archive `
        -LiteralPath $ZipFile `
        -DestinationPath $ExtractRoot `
        -ErrorAction Stop

    # GitHub creates one folder with a long commit name
    $Folders = @(
        Get-ChildItem -LiteralPath $ExtractRoot -Directory
    )

    if ($Folders.Count -ne 1) {
        throw 'Unexpected GitHub archive structure.'
    }

    $ExtractedToolkit = $Folders[0].FullName
    $Initializer = Join-Path $ExtractedToolkit 'Initialize-Toolkit.ps1'

    if (-not (Test-Path -LiteralPath $Initializer)) {
        throw 'Initialize-Toolkit.ps1 ble ikke funnet.'
    }

    # Mark this folder as managed by our launcher
    'Managed by Toolkit-Launcher' |
        Set-Content -LiteralPath (
            Join-Path $ExtractedToolkit $MarkerName
        ) -Encoding ASCII

    # Handle previously downloaded Toolkit
    if (Test-Path -LiteralPath $ToolkitRoot) {

        $Existing = Get-Item -LiteralPath $ToolkitRoot -Force

        if ($Existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Toolkit destination is a symbolic link. Aborting.'
        }

        $ExistingMarker = Join-Path $ToolkitRoot $MarkerName

        if (-not (Test-Path -LiteralPath $ExistingMarker)) {
            throw "Existing Toolkit folder is not managed by launcher: $ToolkitRoot"
        }

        Write-Host 'Previous Toolkit found. Updating...' -ForegroundColor Yellow

        # Keep old version temporarily in case something fails
        Move-Item -LiteralPath $ToolkitRoot `
            -Destination $BackupRoot -ErrorAction Stop

        $BackupCreated = $true
    }

    # Move extracted Toolkit to the fixed folder
    Move-Item -LiteralPath $ExtractedToolkit `
        -Destination $ToolkitRoot -ErrorAction Stop

    $Installed = $true

    # Initialize Toolkit
    $Initializer = Join-Path $ToolkitRoot 'Initialize-Toolkit.ps1'
    & $Initializer

    # Ensure downloaded scripts have PATH priority
    $ScriptsRoot = Join-Path $ToolkitRoot 'Scripts'
    $Separator = [IO.Path]::PathSeparator

    $ScriptFolders = @($ScriptsRoot) + @(
        Get-ChildItem -LiteralPath $ScriptsRoot -Directory -Recurse |
            Select-Object -ExpandProperty FullName
    )

    $OtherPaths = @(
        ($env:PATH -split [regex]::Escape([string]$Separator)) |
            Where-Object {
                $_ -and
                -not $_.StartsWith(
                    "$ToolkitRoot\",
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )

    $env:PATH = (@($ScriptFolders) + $OtherPaths) -join $Separator

    # Make Toolkit modules available
    $ModulesRoot = Join-Path $ToolkitRoot 'Modules'

    if (Test-Path -LiteralPath $ModulesRoot) {

        $OtherModules = @(
            ($env:PSModulePath -split [regex]::Escape([string]$Separator)) |
                Where-Object {
                    $_ -and
                    -not $_.StartsWith(
                        "$ToolkitRoot\",
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
        )

        $env:PSModulePath = (@($ModulesRoot) + $OtherModules) -join $Separator
    }

    # Remove previous version after successful installation
    if ($BackupCreated) {
        try {
            Remove-Item -LiteralPath $BackupRoot `
                -Recurse -Force -ErrorAction Stop

            $BackupCreated = $false
        }
        catch {
            Write-Warning "Could not remove old Toolkit backup: $BackupRoot"
        }
    }

    $global:ToolkitSessionRoot = $ToolkitRoot

    Write-Host "`nPowerShell-Toolkit is ready!" -ForegroundColor Green
    Write-Host "Location: $ToolkitRoot"
}
catch {
    # Restore environment variables
    $env:PATH = $OriginalPath
    $env:PSModulePath = $OriginalModulePath

    # Roll back incomplete installation
    if ($Installed -and (Test-Path -LiteralPath $ToolkitRoot)) {
        try {
            Remove-Item -LiteralPath $ToolkitRoot -Recurse -Force
        }
        catch {
            Write-Warning "Could not remove incomplete Toolkit: $ToolkitRoot"
        }
    }

    if ($BackupCreated -and
        (Test-Path -LiteralPath $BackupRoot) -and
        -not (Test-Path -LiteralPath $ToolkitRoot)) {

        Move-Item -LiteralPath $BackupRoot -Destination $ToolkitRoot
    }

    throw
}
finally {
    # Remove temporary download files
    if (Test-Path -LiteralPath $WorkRoot) {
        Remove-Item -LiteralPath $WorkRoot `
            -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Clear sensitive data as far as possible
    if ($Kdf) { $Kdf.Dispose() }
    if ($Key) { [Array]::Clear($Key, 0, $Key.Length) }

    if ($PassPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PassPtr)
    }

    if ($TokenPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($TokenPtr)
    }

    if ($SecureToken) { $SecureToken.Dispose() }
    if ($Passphrase) { $Passphrase.Dispose() }

    Remove-Variable Password, PlainToken -ErrorAction SilentlyContinue
}
