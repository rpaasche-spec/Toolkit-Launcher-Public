
#Requires -Version 5.1

<#
.SYNOPSIS
    Downloads and initializes PowerShell-Toolkit from GitHub.
#>

$ErrorActionPreference = 'Stop'

$TokenFile = Join-Path $PSScriptRoot 'token.enc'
$Url = 'https://api.github.com/repos/rpaasche-spec/PowerShell-Toolkit/zipball/main'

if (-not (Test-Path -LiteralPath $TokenFile)) {
    throw 'token.enc ble ikke funnet.'
}

# Read encrypted token configuration
$Config = Get-Content -LiteralPath $TokenFile -Raw |
    ConvertFrom-Json

if ($Config.Version -ne 1 -or $Config.Iterations -ne 250000) {
    throw 'Ukjent krypteringsformat.'
}

# Ask for your password
$Passphrase = Read-Host 'Toolkit password' -AsSecureString

$PassPtr = [IntPtr]::Zero
$TokenPtr = [IntPtr]::Zero
$Key = $null
$Kdf = $null
$SecureToken = $null

$Destination = Join-Path $env:TEMP (
    'PowerShell-Toolkit-' + [guid]::NewGuid().ToString('N')
)
$ZipFile = "$Destination.zip"

try {
    # Derive the same encryption key
    $PassPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($PassPtr)

    $Salt = [Convert]::FromBase64String($Config.Salt)

    $Kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password,
        $Salt,
        [int]$Config.Iterations,
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )

    $Key = $Kdf.GetBytes(32)

    # Unlock GitHub token
    $SecureToken = ConvertTo-SecureString `
        -String $Config.Ciphertext `
        -Key $Key `
        -ErrorAction Stop

    $TokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
    $PlainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($TokenPtr)

    Write-Host 'Downloading PowerShell-Toolkit...' -ForegroundColor Cyan

    # Download private repository
    Invoke-WebRequest `
        -Uri $Url `
        -Headers @{
            Authorization = "Bearer $PlainToken"
            Accept = 'application/vnd.github+json'
        } `
        -OutFile $ZipFile `
        -UseBasicParsing `
        -ErrorAction Stop

    # Extract Toolkit
    Expand-Archive -LiteralPath $ZipFile `
        -DestinationPath $Destination `
        -ErrorAction Stop

    $Init = Get-ChildItem -LiteralPath $Destination `
        -Filter 'Initialize-Toolkit.ps1' `
        -File -Recurse |
        Select-Object -First 1

    if (-not $Init) {
        throw 'Initialize-Toolkit.ps1 ble ikke funnet.'
    }

    # Initialize the downloaded Toolkit
    & $Init.FullName

    # Prefer the downloaded scripts over existing local copies
    $ScriptsRoot = Join-Path $Init.DirectoryName 'Scripts'

    $Folders = @($ScriptsRoot) + @(
        Get-ChildItem -LiteralPath $ScriptsRoot -Directory -Recurse |
            Select-Object -ExpandProperty FullName
    )

    $Separator = [IO.Path]::PathSeparator

    $env:PATH = ($Folders -join $Separator) + $Separator + $env:PATH

    Write-Host "`nPowerShell-Toolkit is ready!" -ForegroundColor Green
    Write-Host "Location: $($Init.DirectoryName)"
}
finally {
    # Remove temporary ZIP, but keep the extracted tools
    Remove-Item -LiteralPath $ZipFile -Force -ErrorAction SilentlyContinue

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
