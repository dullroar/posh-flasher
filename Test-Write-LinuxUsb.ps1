$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$scriptPath = "$PSScriptRoot\Write-LinuxUsb.ps1"
. $scriptPath
$script:Passed = 0
function Assert-Equal($actual,$expected,$name) { if($actual -ne $expected){throw "${name}: expected '$expected', got '$actual'"}; $script:Passed++ }
function Assert-True($condition,$name) { if(-not $condition){throw "${name}: expected true"}; $script:Passed++ }
# Runs a block that must throw a LinuxUsbException with the given category and (optionally) message pattern.
function Assert-Fails([scriptblock]$Block,[string]$Category,[string]$Pattern,[string]$Name) {
    $caught = $null
    try { & $Block | Out-Null } catch { $caught = $_ }
    if(-not $caught){ throw "${Name}: expected failure '$Category' but nothing was thrown" }
    $actualCategory = Get-ErrorCategory $caught
    if($actualCategory -ne $Category){ throw "${Name}: expected category '$Category', got '$actualCategory' ($($caught.Exception.Message))" }
    if($Pattern -and $caught.Exception.Message -notmatch $Pattern){ throw "${Name}: message '$($caught.Exception.Message)' did not match '$Pattern'" }
    $script:Passed++
}

# ---- Copy / compare primitives (ordinary memory streams) ----
$bytes = 0..255 | ForEach-Object {[byte]$_}; $payload = New-Object byte[] 2503; for($i=0;$i -lt $payload.Length;$i++){$payload[$i]=$bytes[$i%256]}
$source = New-Object IO.MemoryStream(,$payload); $out = New-Object IO.MemoryStream
$written = Copy-Exact $source {param($b,$n,$o) $out.Write($b,0,$n)} ([uint64]$payload.Length) 257
Assert-Equal $written $payload.Length 'copy byte count'; Assert-Equal $out.Length $payload.Length 'destination length'
$source.Position=0; $out.Position=0; $verified=Compare-Exact $source {param($b,$n,$o) $out.Read($b,0,$n)} ([uint64]$payload.Length) 257; Assert-Equal $verified $payload.Length 'verified byte count'
$out.GetBuffer()[258] = 99; $source.Position=0; $out.Position=0
Assert-Fails { Compare-Exact $source {param($b,$n,$o) $out.Read($b,0,$n)} ([uint64]$payload.Length) 257 } 'VerifyFailure' '258' 'mismatch offset'
$short = New-Object IO.MemoryStream(,[byte[]](1,2))
Assert-Fails { Copy-Exact $short {param($b,$n,$o)} 3 2 } 'InvalidImage' 'ended early' 'short source'
$source.Position=0
try { Copy-Exact $source {param($b,$n,$o) throw 'injected write failure'} ([uint64]$payload.Length) 257; throw 'write callback failure was not surfaced' } catch { if($_.Exception.Message -notmatch 'injected write failure'){throw} }

# ---- Disk eligibility refusals ----
function New-FakeDisk { [pscustomobject]@{Number=7;BusType='USB';IsBoot=$false;IsSystem=$false;IsReadOnly=$false;IsOffline=$false;Size=4096;LogicalSectorSize=512} }
Assert-DiskEligibility (New-FakeDisk)
foreach($change in @(@{BusType='SATA'},@{IsBoot=$true},@{IsReadOnly=$true},@{IsOffline=$true},@{Size=0},@{LogicalSectorSize=0})) {
    $candidate = New-FakeDisk; foreach($key in $change.Keys){ $candidate.$key=$change[$key] }
    Assert-Fails { Assert-DiskEligibility $candidate } 'InvalidTarget' 'not USB|boot or system|read-only or offline|invalid capacity' "refusal $($change.Keys)"
}

# ---- USB device class ----
Assert-UsbDeviceClass ([pscustomobject]@{InterfaceType='USB';MediaType='Removable Media'}) 7
Assert-UsbDeviceClass ([pscustomobject]@{InterfaceType='USB';MediaType='Fixed hard disk media'}) 7
Assert-Fails { Assert-UsbDeviceClass $null 7 } 'InvalidTarget' 'could not be determined' 'unknown device class'
Assert-Fails { Assert-UsbDeviceClass ([pscustomobject]@{InterfaceType='SCSI';MediaType='Removable Media'}) 7 } 'InvalidTarget' 'not a USB mass-storage' 'non-USB interface'
Assert-Fails { Assert-UsbDeviceClass ([pscustomobject]@{InterfaceType='USB';MediaType='Format is unknown'}) 7 } 'InvalidTarget' 'unrecognised media type' 'unknown media type'

# ---- Identity lock: each field change is a hard stop naming the field ----
function New-FakeSnapshot { [pscustomobject]@{Number=7;Bus='USB';Model='M';Serial='S1';UniqueId='U1';Guid='G1';Size=4096;Sector=512;PartitionStyle='MBR';PartitionSummary='1:0:4096:FAT';Identity='S1';IdentityKind='SERIAL'} }
Assert-SameDisk (New-FakeSnapshot) (New-FakeSnapshot)
foreach($change in @(@{Serial='S2'},@{UniqueId='U2'},@{Guid='G2'},@{Size=8192},@{Sector=4096},@{Model='X'},@{Number=8},@{PartitionSummary='2:0:4096:NTFS'},@{PartitionStyle='GPT'},@{Identity='S9'})) {
    $changed = New-FakeSnapshot; $field = @($change.Keys)[0]; $changed.$field = $change[$field]
    Assert-Fails { Assert-SameDisk (New-FakeSnapshot) $changed } 'HardwareMismatch' "changed.*$field" "identity drift $field"
}
$layoutOnly = New-FakeSnapshot; $layoutOnly.PartitionSummary = 'new'
Assert-SameDisk (New-FakeSnapshot) $layoutOnly $script:HardwareFields   # layout may legitimately change after a write

# ---- Confirmation phrase embeds identity ----
Assert-Equal (Get-ConfirmationPhrase (New-FakeSnapshot) 'Write') 'ERASE DISK 7 SERIAL S1' 'write phrase'
Assert-Equal (Get-ConfirmationPhrase (New-FakeSnapshot) 'VerifyOnly') 'VERIFY DISK 7 SERIAL S1' 'verify phrase'

# ---- Image validation ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("posh-flasher-test-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    function New-TestIso([string]$Name,[int]$Size=65536,[bool]$Signature=$true,[byte[]]$Head=$null) {
        $b = New-Object byte[] $Size
        if($Signature -and $Size -gt 0x8006){ [Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($b,0x8001) }
        if($Head){ $Head.CopyTo($b,0) }
        $p = Join-Path $tmp $Name; [IO.File]::WriteAllBytes($p,$b); $p
    }
    $good = New-TestIso 'good.iso'
    $img = Get-ImageStream $good; Assert-Equal $img.Length 65536 'image length'; Assert-Equal $img.Path $good 'canonical path'; $img.Stream.Dispose()
    Assert-Fails { Get-ImageStream (New-TestIso 'zero.iso' 0) } 'InvalidImage' 'zero bytes' 'zero-byte image'
    Assert-Fails { Get-ImageStream (New-TestIso 'tiny.iso' 100) } 'InvalidImage' 'too small' 'tiny image'
    Assert-Fails { $p = New-TestIso 'file.img'; Get-ImageStream $p } 'InvalidImage' 'non-empty local .iso' 'wrong extension'
    Assert-Fails { Get-ImageStream (New-TestIso 'exe.iso' 65536 $true ([byte[]](0x4D,0x5A,0,0))) } 'InvalidImage' 'executable header' 'MZ disguised as iso'
    Assert-Fails { Get-ImageStream (New-TestIso 'elf.iso' 65536 $true ([byte[]](0x7F,0x45,0x4C,0x46))) } 'InvalidImage' 'executable header' 'ELF disguised as iso'
    Assert-Fails { Get-ImageStream (New-TestIso 'nosig.iso' 65536 $false) } 'InvalidImage' 'ISO 9660 signature' 'missing CD001'
    Assert-Fails { Get-ImageStream (Join-Path $tmp 'missing.iso') } 'InvalidImage' 'could not be resolved' 'missing file'
    $hidden = New-TestIso 'hidden.iso'; (Get-Item $hidden).Attributes = 'Hidden'
    Assert-Fails { Get-ImageStream $hidden } 'InvalidImage' 'Hidden, system' 'hidden image'
    $ads = New-TestIso 'ads.iso'; Set-Content -LiteralPath $ads -Stream 'payload' -Value 'x'
    Assert-Fails { Get-ImageStream $ads } 'InvalidImage' 'alternate data streams' 'alternate data stream'
    $zone = New-TestIso 'zone.iso'; Set-Content -LiteralPath $zone -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3"
    $z = Get-ImageStream $zone; $z.Stream.Dispose(); $script:Passed++   # downloaded-file marker is tolerated

    $img = Get-ImageStream $good
    Assert-ImageUnchanged $img
    $t = [pscustomobject]@{Size=65535;Sector=512}
    Assert-Fails { Assert-ImageFitsTarget $img $t } 'InvalidImage' 'larger than the target' 'image too big'
    Assert-Fails { Assert-ImageFitsTarget $img ([pscustomobject]@{Size=1MB;Sector=4096*3}) } 'InvalidImage' 'multiple of logical sector' 'unaligned image'
    $img.Stream.Dispose()
    # Mutation after validation must be detected (share-read lock is released first so the test can mutate).
    $img = Get-ImageStream $good; $img.Stream.Dispose(); (Get-Item $good).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-5)
    $img.Stream = [IO.File]::OpenRead($good)
    Assert-Fails { Assert-ImageUnchanged $img } 'InvalidImage' 'changed while' 'image mutated during write'
    $img.Stream.Dispose()

    # ---- Raw-write containment ----
    $text = Get-Content -LiteralPath $scriptPath -Raw
    Assert-Equal ([regex]::Matches($text,'CreateFile\([^\r\n]*PhysicalDrive').Count) 1 'single PhysicalDrive open site'
    Assert-True ((Get-Command Open-RawDisk).ScriptBlock.ToString() -match 'PhysicalDrive') 'PhysicalDrive open lives in Open-RawDisk'
    # Authorization gates: a raw handle must never be opened if any gate is missing.
    $script:RealOpenRawDisk = ${function:Open-RawDisk}
    $script:RawOpened = $false
    function Open-RawDisk { $script:RawOpened = $true; throw 'must not open' }
    $tgt = New-FakeSnapshot; $cl = New-CleanupState; $ms = New-Object IO.MemoryStream
    foreach($gate in 'NotDryRun','PhraseMatched','IdentityVerified','VolumesLocked') {
        $auth = New-WriteAuthorization $tgt; foreach($g in 'NotDryRun','PhraseMatched','IdentityVerified','VolumesLocked'){ $auth.$g = ($g -ne $gate) }
        Assert-Fails { Invoke-RawDiskOperation -Target $tgt -Authorization $auth -Mode Write -Source $ms -Length 0 -Cleanup $cl } 'InvalidTarget' $gate "gate $gate"
    }
    Assert-Fails { Invoke-RawDiskOperation -Target $tgt -Authorization $null -Mode Write -Source $ms -Length 0 -Cleanup $cl } 'InvalidTarget' 'authorization' 'no authorization'
    Assert-True (-not $script:RawOpened) 'no raw handle opened without authorization'

    # ---- Cleanup guarantees ----
    $script:AutoMountCalls = @(); $script:FailRestore = $false
    function Set-MountManagerAutoMount([bool]$Enabled) { $script:AutoMountCalls += $Enabled; if($script:FailRestore -and $Enabled){ throw 'mount manager busy' } }
    $c = New-CleanupState; $h1 = New-Object IO.MemoryStream; $h2 = New-Object IO.MemoryStream; $raw = New-Object IO.MemoryStream; $src = New-Object IO.MemoryStream
    [void]$c.OpenedVolumeHandles.Add($h1); [void]$c.OpenedVolumeHandles.Add($h2); $c.OpenedRawHandle = $raw; $c.SourceStream = $src; $c.WasAutoMountDisabled = $true
    Assert-True (Invoke-Cleanup $c 3>$null 6>$null) 'clean cleanup succeeds'
    Assert-True (-not $h1.CanRead -and -not $h2.CanRead -and -not $raw.CanRead -and -not $src.CanRead) 'all handles disposed'
    Assert-Equal ($script:AutoMountCalls -join ',') 'True' 'automount restored'; Assert-True (-not $c.WasAutoMountDisabled) 'state cleared'
    $script:FailRestore = $true
    $c = New-CleanupState; $h1 = New-Object IO.MemoryStream; [void]$c.OpenedVolumeHandles.Add($h1); $c.WasAutoMountDisabled = $true
    $warnings = @(); [void](Invoke-Cleanup $c 3>&1 6>$null | ForEach-Object { if($_ -is [Management.Automation.WarningRecord]){ $warnings += $_.Message } else { $_ } })
    Assert-True (-not $h1.CanRead) 'handles still disposed when automount restore fails'
    Assert-True (@($c.Failures).Count -eq 1 -and $c.WasAutoMountDisabled) 'restore failure recorded and state retained'
    Assert-True (($warnings -join ' ') -match 'mountvol /E') 'recovery guidance names mountvol /E'
    $script:FailRestore = $false

    # ---- Failure-path integration (simulated hardware, no real disk) ----
    $script:DiskSerials = @('S1'); $script:DiskCalls = 0; $script:DeviceClass = [pscustomobject]@{InterfaceType='USB';MediaType='Removable Media'}
    $script:Answer = 'ERASE DISK 7 SERIAL S1'; $script:FailLock = $false; $script:LetterCalls = 0; $script:LettersLater = @()
    $script:RawModes = @(); $script:AutoMountState = $true; $script:DiskSize = 1MB
    function Get-Disk { [CmdletBinding()] param([int]$Number) $i=[Math]::Min($script:DiskCalls,$script:DiskSerials.Count-1); $script:DiskCalls++
        [pscustomobject]@{Number=7;BusType='USB';IsBoot=$false;IsSystem=$false;IsReadOnly=$false;IsOffline=$false;Size=$script:DiskSize;LogicalSectorSize=512;SerialNumber=$script:DiskSerials[$i];UniqueId='test-id';FriendlyName='Test USB'} }
    function Get-DiskDeviceClass { param([int]$Number) $script:DeviceClass }
    function Get-DiskPartitionSummary { param([int]$Number) 'p1' }
    function Get-MountedDriveLetters { param([int]$Number) $script:LetterCalls++; if($script:LetterCalls -gt 1){ @($script:LettersLater) } else { @() } }
    function Get-MountManagerAutoMount { $script:AutoMountState }
    function Read-Host { param([string]$Prompt) if($Prompt -match 'Type exactly'){ $script:Answer } else { 'Y' } }
    function Lock-TargetVolumes { param($Target,$Cleanup) if($script:FailLock){ Fail 'Could not lock volume X: Win32 error 5' 'LockFailure' }; [void]$Cleanup.OpenedVolumeHandles.Add((New-Object IO.MemoryStream)); 1 }
    function Invoke-RawDiskOperation { param($Target,$Authorization,$Mode,$Source,$Length,$Cleanup) Assert-WriteAuthorization $Authorization $Target; $script:RawModes += $Mode; $Length }
    function Invoke-Flow([hashtable]$Overrides=@{}) {
        $script:DiskCalls = 0; $script:LetterCalls = 0; $script:RawModes = @(); $script:AutoMountCalls = @()
        $o = @{ImageFile=$good;DiskNumber=7;Verify=$false;VerifyOnly=$false;WhatIf=$false;LogPath=$null}
        foreach($k in $Overrides.Keys){ $o[$k] = $Overrides[$k] }
        $bound = @{ImageFile=1;DiskNumber=1}
        $state = New-LinuxUsbState -Bound $bound -ImageFile $o.ImageFile -DiskNumber $o.DiskNumber -Verify $o.Verify -VerifyOnly $o.VerifyOnly -WhatIf $o.WhatIf -ShowHash $false -ListDisks $false -LogPath $o.LogPath
        $err = $null
        try { Invoke-LinuxUsb $state 6>$null 3>$null | Out-Null } catch { $err = $_ }
        [pscustomobject]@{ State=$state; Error=$err; Category=$(if($err){ Get-ErrorCategory $err } else { $null }) }
    }

    $r = Invoke-Flow @{Verify=$true}
    Assert-True (-not $r.Error) "happy path ($($r.Error))"; Assert-Equal $r.State.Outcome 'Success' 'happy outcome'; Assert-Equal ($script:RawModes -join ',') 'Write,Read' 'write then verify'
    Assert-Equal ($script:AutoMountCalls -join ',') 'False,True' 'automount disabled then restored'
    Assert-True ($r.State.Log.Name -contains 'RunSummary') 'audit summary recorded'
    Assert-True (-not $r.State.Image.Stream.CanRead) 'image stream closed'

    $r = Invoke-Flow @{WhatIf=$true}
    Assert-Equal $r.State.Outcome 'DryRun' 'dry run outcome'; Assert-Equal $script:RawModes.Count 0 'dry run opens nothing'; Assert-Equal $script:AutoMountCalls.Count 0 'dry run leaves automount alone'

    $script:Answer = 'ERASE DISK 7'
    $r = Invoke-Flow; Assert-Equal $r.Category 'UserDeclined' 'number-only phrase refused'; Assert-Equal $r.State.Outcome 'Declined' 'declined outcome'; Assert-Equal $script:RawModes.Count 0 'declined opens nothing'
    $script:Answer = 'ERASE DISK 7 SERIAL S1'

    $script:DiskSerials = @('S1','S2')
    $r = Invoke-Flow; Assert-Equal $r.Category 'HardwareMismatch' 'serial swap after confirmation'; Assert-True ($r.Error.Exception.Message -match "Serial 'S1' -> 'S2'") 'mismatch reason names the field'; Assert-Equal $script:RawModes.Count 0 'swap: nothing written'
    $script:DiskSerials = @('S1','S1','S2')
    $r = Invoke-Flow; Assert-Equal $r.Category 'HardwareMismatch' 'serial swap after locking'; Assert-Equal $script:RawModes.Count 0 'swap after lock: nothing written'
    $script:DiskSerials = @('S1','S1','S1','S2')
    $r = Invoke-Flow; Assert-Equal $r.Category 'HardwareMismatch' 'identity drift after write'; Assert-Equal $r.State.Outcome 'Failed' 'drift outcome'
    $script:DiskSerials = @('S1')

    $script:DeviceClass = $null
    $r = Invoke-Flow; Assert-Equal $r.Category 'InvalidTarget' 'unknown device class refused'; Assert-Equal $script:RawModes.Count 0 'unknown class: nothing written'
    $script:DeviceClass = [pscustomobject]@{InterfaceType='USB';MediaType='Removable Media'}

    $script:FailLock = $true
    $r = Invoke-Flow; Assert-Equal $r.Category 'LockFailure' 'lock failure'; Assert-Equal $script:RawModes.Count 0 'lock failure: nothing written'
    Assert-Equal ($script:AutoMountCalls -join ',') 'False,True' 'lock failure still restores automount'
    $script:FailLock = $false

    $script:LettersLater = @('E')
    $r = Invoke-Flow; Assert-Equal $r.Category 'HardwareMismatch' 'unexpected remount detected'; Assert-True ($r.Error.Exception.Message -match 'mounted') 'remount message'
    $script:LettersLater = @()

    $script:FailRestore = $true
    $r = Invoke-Flow; Assert-Equal $r.Category 'CleanupFailure' 'cleanup failure classified'; Assert-Equal $r.State.Outcome 'CleanupFailure' 'cleanup failure outcome'
    $script:FailRestore = $false

    $logFile = Join-Path $tmp 'audit.jsonl'
    $r = Invoke-Flow @{LogPath=$logFile}
    $lines = @(Get-Content -LiteralPath $logFile); Assert-True ($lines.Count -ge 4) 'log file written'
    $summary = ($lines | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Equal $summary.Name 'RunSummary' 'last log line is the summary'; Assert-Equal $summary.Data.TargetDisk 7 'summary target disk'
    $r = Invoke-Flow @{LogPath=(Join-Path $tmp 'nodir\x.jsonl')}; Assert-Equal $r.Category 'InvalidTarget' 'bad LogPath directory refused'

    # ---- Interactive selection ----
    $state = New-LinuxUsbState -Bound @{}
    $selected = @(Select-UsbTarget $state)
    Assert-Equal $selected.Count 1 'interactive selection result count'; Assert-Equal $selected[0].Number 7 'interactive selection disk number'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"All $($script:Passed) tests passed."
