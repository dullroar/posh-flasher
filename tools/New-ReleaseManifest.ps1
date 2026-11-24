#requires -Version 5.1
<#
.SYNOPSIS
Writes SHA256SUMS for the release files and optionally Authenticode-signs the script.
.PARAMETER CertThumbprint  Thumbprint of a code-signing certificate in Cert:\CurrentUser\My. Omit to skip signing.
#>
[CmdletBinding()]
param([string] $CertThumbprint)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'Write-LinuxUsb.ps1'
if ($CertThumbprint) {
    $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertThumbprint"
    $sig = Set-AuthenticodeSignature -FilePath $script -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
    if ($sig.Status -ne 'Valid') { throw "Signing failed: $($sig.Status) $($sig.StatusMessage)" }
}
# Hash AFTER signing so the checksum matches the shipped bytes.
$files = 'Write-LinuxUsb.ps1', 'Test-Write-LinuxUsb.ps1', 'README.md', 'CHANGELOG.md', 'LICENSE'
$lines = foreach ($f in $files) { '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $root $f) -Algorithm SHA256).Hash.ToLower(), $f }
Set-Content -LiteralPath (Join-Path $root 'SHA256SUMS') -Value $lines -Encoding ASCII
$lines
