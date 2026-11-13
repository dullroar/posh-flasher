$ErrorActionPreference='Stop'
. "$PSScriptRoot\Write-LinuxUsb.ps1"
function Assert-Equal($actual,$expected,$name) { if($actual -ne $expected){throw "${name}: expected '$expected', got '$actual'"} }
$bytes = 0..255 | ForEach-Object {[byte]$_}; $payload = New-Object byte[] 2503; for($i=0;$i -lt $payload.Length;$i++){$payload[$i]=$bytes[$i%256]}
$source = New-Object IO.MemoryStream(,$payload); $out = New-Object IO.MemoryStream
$written = Copy-Exact $source {param($b,$n,$o) $out.Write($b,0,$n)} ([uint64]$payload.Length) 257
Assert-Equal $written $payload.Length 'copy byte count'; Assert-Equal $out.Length $payload.Length 'destination length'
$source.Position=0; $out.Position=0; $verified=Compare-Exact $source {param($b,$n,$o) $out.Read($b,0,$n)} ([uint64]$payload.Length) 257; Assert-Equal $verified $payload.Length 'verified byte count'
$out.GetBuffer()[258] = 99; $source.Position=0; $out.Position=0
try { Compare-Exact $source {param($b,$n,$o) $out.Read($b,0,$n)} ([uint64]$payload.Length) 257; throw 'mismatch was not detected' } catch { if($_.Exception.Message -notmatch '258'){throw} }
$short = New-Object IO.MemoryStream(,[byte[]](1,2)); try { Copy-Exact $short {param($b,$n,$o)} 3 2; throw 'short source was not detected' } catch { if($_.Exception.Message -notmatch 'ended early'){throw} }
try { $fake=[pscustomobject]@{Identity='a';Size=1;Sector=512;Bus='USB'}; $changed=[pscustomobject]@{Identity='b';Size=1;Sector=512;Bus='USB'}; Assert-SameDisk $fake $changed; throw 'identity change was not detected' } catch { if($_.Exception.Message -notmatch 'changed'){throw} }
$disk = [pscustomobject]@{Number=7;BusType='USB';IsBoot=$false;IsSystem=$false;IsReadOnly=$false;IsOffline=$false;Size=4096;LogicalSectorSize=512}
Assert-DiskEligibility $disk
foreach($change in @(@{BusType='SATA'},@{IsBoot=$true},@{IsReadOnly=$true},@{IsOffline=$true},@{Size=0},@{LogicalSectorSize=0})) {
    $candidate = [pscustomobject]@{Number=7;BusType='USB';IsBoot=$false;IsSystem=$false;IsReadOnly=$false;IsOffline=$false;Size=4096;LogicalSectorSize=512}
    foreach($key in $change.Keys){ $candidate.$key=$change[$key] }
    try { Assert-DiskEligibility $candidate; throw "disk refusal for $($change.Keys) was not detected" } catch { if($_.Exception.Message -notmatch 'not USB|boot or system|read-only or offline|invalid capacity'){throw} }
}
try { $source.Position=0; Copy-Exact $source {param($b,$n,$o) throw 'injected write failure'} ([uint64]$payload.Length) 257; throw 'write callback failure was not surfaced' } catch { if($_.Exception.Message -notmatch 'injected write failure'){throw} }
$script:LinuxUsbInputBound = @{}
function Get-Disk { [CmdletBinding()] param([int]$Number) [pscustomobject]@{Number=7;BusType='USB';IsBoot=$false;IsSystem=$false;IsReadOnly=$false;IsOffline=$false;Size=4096;LogicalSectorSize=512;SerialNumber='test-serial';UniqueId='test-id';FriendlyName='Test USB'} }
function Read-Host { param([string]$Prompt) 'Y' }
$selected = @(Select-UsbTarget)
Assert-Equal $selected.Count 1 'interactive selection result count'; Assert-Equal $selected[0].Number 7 'interactive selection disk number'
'All ordinary-file copy, compare, and identity refusal tests passed.'
