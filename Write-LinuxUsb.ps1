#requires -Version 5.1
<#
.SYNOPSIS
Writes a publisher-provided Linux hybrid ISO to a USB disk. DESTRUCTIVE.

.DESCRIPTION
UNSAFE OPERATION: this script opens \\.\PhysicalDriveN for raw writing and DESTROYS all data and the
partition layout on the selected USB disk. Run it only from an elevated Windows PowerShell 5.1 session,
only with a disposable USB disk, and only with an ISO its publisher documents as suitable for direct USB writing.

The selected disk is snapshotted (number, bus, model, serial, unique ID, GUID, size, sector size, partition
layout) and re-checked after confirmation and before every raw handle is opened. Any difference aborts.
The confirmation phrase includes the disk's identity, e.g. "ERASE DISK 3 SERIAL 1234XYZ".

Failures carry a category in $_.Exception.Category: InvalidTarget, InvalidImage, HardwareMismatch,
LockFailure, WriteFailure, VerifyFailure, CleanupFailure, UserDeclined.

.PARAMETER ListDisks   List eligible USB disks and exit.
.PARAMETER ImageFile   Local .iso path. Prompted for when omitted.
.PARAMETER DiskNumber  Target disk number. Interactive selection when omitted.
.PARAMETER Verify      Read every written byte back and compare.
.PARAMETER VerifyOnly  Compare an existing disk with the image; writes nothing.
.PARAMETER WhatIf      Validate and display everything, but open no raw handles and write nothing.
.PARAMETER ShowHash    Print the image SHA-256.
.PARAMETER LogPath     Append structured JSON-lines audit records to this file. Use -Verbose for a trace.

.NOTES
Version 1.0.0. See README.md for supported environments and known failure modes.
#>
[CmdletBinding(DefaultParameterSetName = 'Write', SupportsShouldProcess = $false)]
param(
    [Parameter(ParameterSetName = 'List')]
    [switch] $ListDisks,
    [Parameter(ParameterSetName = 'Write')]
    [string] $ImageFile,
    [Parameter(ParameterSetName = 'Write')]
    [int] $DiskNumber,
    [Parameter(ParameterSetName = 'Write')]
    [switch] $Verify,
    [Parameter(ParameterSetName = 'Write')]
    [switch] $VerifyOnly,
    [Parameter(ParameterSetName = 'Write')]
    [switch] $WhatIf,
    [Parameter(ParameterSetName = 'Write')]
    [switch] $ShowHash,
    [Parameter(ParameterSetName = 'Write')]
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolVersion = '1.0.0'

# 'Step 1 - Load the small, visible Win32 interop layer'
if (-not ('LinuxUsb.NativeV4' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace LinuxUsb {
  // Carries an error category so callers can tell failure classes apart without parsing message text.
  public class LinuxUsbException : InvalidOperationException {
    public string Category { get; private set; }
    public LinuxUsbException(string message, string category) : base(message) { Category = category; }
  }
  public static class NativeV4 {
    // --- File access ---
    public const uint GENERIC_READ=0x80000000, GENERIC_WRITE=0x40000000, OPEN_EXISTING=3;
    // SAFETY-SENSITIVE: write-through bypasses the cache for raw disk writes.
    public const uint FILE_FLAG_WRITE_THROUGH=0x80000000;
    // --- Volume management ---
    // SAFETY-SENSITIVE: lock fails if anything has the volume open; dismount invalidates open handles.
    public const uint FSCTL_LOCK_VOLUME=0x00090018, FSCTL_DISMOUNT_VOLUME=0x00090020;
    // Maps a volume to the physical disk(s) it lives on (volume -> disk number).
    public const uint IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS=0x00560000;
    // --- Device queries ---
    // Used to prove an opened PhysicalDriveN handle really is the selected disk.
    public const uint IOCTL_STORAGE_GET_DEVICE_NUMBER=0x002D1080, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX=0x000700A0;
    // --- Mount manager control ---
    // SAFETY-SENSITIVE: SET_AUTO_MOUNT changes system-wide state and must always be restored.
    public const uint IOCTL_MOUNTMGR_QUERY_AUTO_MOUNT=0x006D003C, IOCTL_MOUNTMGR_SET_AUTO_MOUNT=0x006DC040;
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern SafeFileHandle CreateFile(string n,uint a,uint s,IntPtr x,uint d,uint f,IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadFile(SafeFileHandle h, byte[] b, uint n, out uint r, IntPtr o);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteFile(SafeFileHandle h, byte[] b, uint n, out uint w, IntPtr o);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FlushFileBuffers(SafeFileHandle h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool DeviceIoControl(SafeFileHandle h,uint c,IntPtr i,uint il,IntPtr o,uint ol,out uint r,IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool DeviceIoControl(SafeFileHandle h,uint c,IntPtr i,uint il,byte[] o,uint ol,out uint r,IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool DeviceIoControl(SafeFileHandle h,uint c,byte[] i,uint il,IntPtr o,uint ol,out uint r,IntPtr ov);
  }
}
'@
}

function Fail {
    param([string] $Message, [string] $Category = 'InvalidTarget')
    throw [LinuxUsb.LinuxUsbException]::new($Message, $Category)
}
function Get-ErrorCategory($ErrorRecord) {
    $p = $ErrorRecord.Exception.PSObject.Properties['Category']
    if ($p) { return [string]$p.Value }
    return 'Unclassified'
}
function Format-Win32Error([int] $Code) { "Win32 error ${Code}: $([ComponentModel.Win32Exception]::new($Code).Message)" }
function Get-Win32Message { Format-Win32Error ([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
function Get-OptionalProperty($Object, [string] $Name) {
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# 'Step 1b - Run state, audit log, and cleanup state (no hidden script-level state)'
function New-CleanupState {
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{
        WasAutoMountDisabled = $false
        OpenedVolumeHandles  = (New-Object System.Collections.ArrayList)
        OpenedRawHandle      = $null
        SourceStream         = $null
        Failures             = (New-Object System.Collections.ArrayList)
    }
}

function New-LinuxUsbState {
    [OutputType([pscustomobject])]
    param(
        [System.Collections.IDictionary] $Bound = @{},
        [string] $ImageFile, [int] $DiskNumber,
        [bool] $Verify, [bool] $VerifyOnly, [bool] $WhatIf, [bool] $ShowHash, [bool] $ListDisks,
        [string] $LogPath
    )
    # PSBoundParametersDictionary does not expose a usable Contains() on all PowerShell versions;
    # copy into a plain hashtable so .Contains(key) always works.
    $boundCopy = @{}
    foreach ($key in $Bound.Keys) { $boundCopy[$key] = $Bound[$key] }
    [pscustomobject]@{
        Bound = $boundCopy; ImageFile = $ImageFile; DiskNumber = $DiskNumber
        Verify = $Verify; VerifyOnly = $VerifyOnly; WhatIf = $WhatIf; ShowHash = $ShowHash; ListDisks = $ListDisks
        LogPath = $LogPath
        DefaultImagePath = 'C:\ISO\linux-installer.iso'
        Image = $null; Before = $null; After = $null
        Outcome = 'NotStarted'; ErrorCategory = $null
        Cleanup = (New-CleanupState)
        Log = (New-Object System.Collections.ArrayList)
    }
}

function Write-AuditLog {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][string] $Name, $Data)
    $entry = [pscustomobject]@{ Timestamp = (Get-Date).ToUniversalTime().ToString('o'); Name = $Name; Data = $Data }
    [void]$State.Log.Add($entry)
    $json = $entry | ConvertTo-Json -Compress -Depth 6
    Write-Verbose $json
    if ($State.LogPath) {
        try { Add-Content -LiteralPath $State.LogPath -Value $json -Encoding UTF8 }
        catch { Write-Warning "Could not write audit log '$($State.LogPath)': $($_.Exception.Message)" }
    }
}

# 'Step 2 - Inspect and select a safe USB target'
# Seams: all hardware/OS queries go through these small wrappers so tests can simulate devices.
function Get-DiskInfo { param([int] $Number) @(Get-Disk -Number $Number -ErrorAction SilentlyContinue) }

function Get-DiskPartitionSummary {
    param([int] $Number)
    try {
        $parts = @(Get-Partition -DiskNumber $Number -ErrorAction Stop | Sort-Object Offset)
        if ($parts.Count -eq 0) { return 'none' }
        return (($parts | ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.PartitionNumber, $_.Offset, $_.Size, $_.Type }) -join ';')
    } catch { return 'unavailable' }
}

function Get-DiskDeviceClass {
    param([int] $Number)
    $d = @(Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index=$Number" -ErrorAction SilentlyContinue)
    if ($d.Count -ne 1) { return $null }
    [pscustomobject]@{ InterfaceType = [string]$d[0].InterfaceType; MediaType = [string]$d[0].MediaType }
}

function Get-MountedDriveLetters {
    param([int] $Number)
    @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and [int][char]$_.DriveLetter -ne 0 } |
        ForEach-Object { [string]$_.DriveLetter })
}

function Assert-DiskEligibility {
    param($disk)
    if ([string]$disk.BusType -ne 'USB') { Fail "Disk $($disk.Number) is not USB (bus: $($disk.BusType))." }
    if ($disk.IsBoot -or $disk.IsSystem) { Fail "Disk $($disk.Number) is a boot or system disk." }
    if ($disk.IsReadOnly -or $disk.IsOffline) { Fail "Disk $($disk.Number) is read-only or offline." }
    if (-not $disk.Size -or -not $disk.LogicalSectorSize -or $disk.LogicalSectorSize -lt 512) { Fail "Disk $($disk.Number) has invalid capacity or logical sector size." }
}

function Assert-UsbDeviceClass {
    param($Class, [int] $Number)
    if (-not $Class) { Fail "Disk $Number device class could not be determined. Refusing raw write." }
    if ($Class.InterfaceType -ne 'USB') { Fail "Disk $Number is not a USB mass-storage device (interface: '$($Class.InterfaceType)')." }
    # Flash drives report any of these; anything else (empty, 'Unknown', 'Format is unknown') is refused.
    if (@('Removable Media', 'External hard disk media', 'Fixed hard disk media') -notcontains $Class.MediaType) { Fail "Disk $Number has an unrecognised media type '$($Class.MediaType)'." }
}

function New-TargetSnapshot {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Disk)
    $serial = if ($Disk.SerialNumber) { ([string]$Disk.SerialNumber).Trim() } else { '' }
    $uniqueId = if ($Disk.UniqueId) { ([string]$Disk.UniqueId).Trim() } else { '' }
    $guid = Get-OptionalProperty $Disk 'Guid'; $guid = if ($guid) { [string]$guid } else { '' }
    if ($serial) { $kind = 'SERIAL'; $identity = $serial } elseif ($uniqueId) { $kind = 'ID'; $identity = $uniqueId } elseif ($guid) { $kind = 'ID'; $identity = $guid } else { Fail "Disk $($Disk.Number) has no stable identity. Refusing raw write." }
    [pscustomobject]@{
        Number = [int]$Disk.Number; Model = [string]$Disk.FriendlyName; Size = [UInt64]$Disk.Size; Bus = [string]$Disk.BusType
        Serial = $serial; UniqueId = $uniqueId; Guid = $guid; Sector = [UInt32]$Disk.LogicalSectorSize
        PartitionStyle = [string](Get-OptionalProperty $Disk 'PartitionStyle')
        PartitionSummary = (Get-DiskPartitionSummary ([int]$Disk.Number))
        Identity = $identity; IdentityKind = $kind
    }
}

function Get-EligibleDisk {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][int] $Number)
    $items = @(Get-DiskInfo $Number)
    if ($items.Count -ne 1) { Fail "Disk $Number was not found or is ambiguous." }
    Assert-DiskEligibility $items[0]
    Assert-UsbDeviceClass (Get-DiskDeviceClass $Number) $Number
    New-TargetSnapshot $items[0]
}

function Get-EligibleUsbDisks {
    $results = @()
    foreach($disk in @(Get-Disk -ErrorAction Stop | Where-Object BusType -eq USB)) {
        try { $results += Get-EligibleDisk $disk.Number } catch { Write-Warning $_.Exception.Message }
    }
    return $results
}

function Show-Disk($d) { "Disk $($d.Number): model='$($d.Model)', size=$($d.Size), bus=$($d.Bus), serial='$($d.Serial)', identity='$($d.Identity)'" }

function Select-UsbTarget {
    param([Parameter(Mandatory)] $State)
    if ($State.Bound.Contains('DiskNumber')) { return Get-EligibleDisk $State.DiskNumber }
    while ($true) {
        $choices = @(Get-EligibleUsbDisks)
        if ($choices.Count -eq 0) {
            [void](Read-Host 'No eligible USB disk found. Insert an expendable USB disk, then press Enter to rescan')
            continue
        }
        Write-Host 'Eligible USB disks:'
        foreach($choice in $choices) { Write-Host (Show-Disk $choice) }
        if ($choices.Count -eq 1) {
            $answer = Read-Host "Use Disk $($choices[0].Number), model '$($choices[0].Model)', serial '$($choices[0].Serial)'? Type Y to select it; press Enter to rescan"
            if ($answer -ceq 'Y') { return $choices[0] }
            continue
        }
        $answer = Read-Host 'Type the disk number to select it, or press Enter to rescan'
        if ([string]::IsNullOrWhiteSpace($answer)) { continue }
        [int]$number = 0
        if (-not [int]::TryParse($answer, [ref]$number)) { Write-Warning 'Enter a numeric disk number.'; continue }
        $selected = @($choices | Where-Object Number -eq $number)
        if ($selected.Count -eq 1) { return $selected[0] }
        Write-Warning "Disk $number is not an eligible USB target."
    }
}

# Target identity lock: every field must match exactly. Any difference is a hard stop with a precise reason.
$script:IdentityFields = @('Number', 'Bus', 'Model', 'Serial', 'UniqueId', 'Guid', 'Size', 'Sector', 'PartitionStyle', 'PartitionSummary', 'Identity')
# After a write the partition layout legitimately changes, so post-write checks skip layout fields.
$script:HardwareFields = @('Number', 'Bus', 'Model', 'Serial', 'UniqueId', 'Guid', 'Size', 'Sector', 'Identity')

function Assert-SameDisk {
    param([Parameter(Mandatory)] $Before, [Parameter(Mandatory)] $After, [string[]] $Fields = $script:IdentityFields)
    $diffs = @()
    foreach($f in $Fields) {
        $a = [string](Get-OptionalProperty $Before $f); $b = [string](Get-OptionalProperty $After $f)
        if ($a -cne $b) { $diffs += "$f '$a' -> '$b'" }
    }
    if ($diffs.Count -gt 0) { Fail "Disk metadata changed after confirmation ($($diffs -join '; ')). Refusing." 'HardwareMismatch' }
}

# 'Step 3 - Resolve and validate the ISO source'
function Resolve-ImageFileInput {
    param([Parameter(Mandatory)] $State)
    if ($State.Bound.Contains('ImageFile')) { return $State.ImageFile }
    $answer = Read-Host "ISO path [$($State.DefaultImagePath)] (press Enter to use this default)"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $State.DefaultImagePath }
    return $answer
}

function Read-StreamBytes {
    param([IO.Stream] $Stream, [long] $Offset, [int] $Count)
    $buffer = New-Object byte[] $Count
    $Stream.Position = $Offset; $got = 0
    while ($got -lt $Count) { $r = $Stream.Read($buffer, $got, $Count - $got); if ($r -le 0) { Fail 'Image is too short to be an ISO 9660 image.' 'InvalidImage' }; $got += $r }
    return $buffer
}

function Get-ImageStream {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path)
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { Fail "Image path could not be resolved: $Path" 'InvalidImage' }
    $resolved = $item.FullName
    if ($resolved -match '^(\\\\|//)' -or (Get-PSDrive -Name ([IO.Path]::GetPathRoot($resolved).TrimEnd(':','\')) -ErrorAction SilentlyContinue).DisplayRoot) { Fail 'Network and mapped-network image paths are not allowed.' 'InvalidImage' }
    if ($item.PSIsContainer -or $item.Extension -ine '.iso') { Fail 'Image must be a non-empty local .iso file.' 'InvalidImage' }
    if ($item.Length -le 0) { Fail 'Image is zero bytes.' 'InvalidImage' }
    $attrs = [int]$item.Attributes
    if ($attrs -band [int][IO.FileAttributes]::ReparsePoint) { Fail 'Image reparse points are not allowed.' 'InvalidImage' }
    if ($attrs -band [int][IO.FileAttributes]::SparseFile) { Fail 'Sparse image files are not allowed.' 'InvalidImage' }
    if ($attrs -band ([int][IO.FileAttributes]::Hidden -bor [int][IO.FileAttributes]::System -bor [int][IO.FileAttributes]::Offline)) { Fail 'Hidden, system, or offline image files are not allowed.' 'InvalidImage' }
    # Zone.Identifier is the normal "downloaded from the internet" marker and is tolerated; any other stream is not.
    $extra = @(Get-Item -LiteralPath $resolved -Stream * -ErrorAction Stop | Where-Object { $_.Stream -ne ':$DATA' -and $_.Stream -ne 'Zone.Identifier' })
    if ($extra.Count -gt 0) { Fail "Image has alternate data streams ($($extra.Stream -join ', ')); refusing." 'InvalidImage' }
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 0x8006) { Fail 'Image is too small to be an ISO 9660 image.' 'InvalidImage' }
        $head = Read-StreamBytes $stream 0 4
        if (($head[0] -eq 0x4D -and $head[1] -eq 0x5A) -or ($head[0] -eq 0x7F -and $head[1] -eq 0x45 -and $head[2] -eq 0x4C -and $head[3] -eq 0x46)) { Fail 'File has an executable header; it is not an ISO image.' 'InvalidImage' }
        if ([Text.Encoding]::ASCII.GetString((Read-StreamBytes $stream 0x8001 5)) -cne 'CD001') { Fail 'File lacks the ISO 9660 signature; it is not an ISO image.' 'InvalidImage' }
        $stream.Position = 0
    } catch { $stream.Dispose(); throw }
    [pscustomobject]@{ Stream = $stream; Path = $resolved; Name = $item.Name; Length = [UInt64]$stream.Length; LastWriteTimeUtc = $item.LastWriteTimeUtc }
}

function Assert-ImageFitsTarget {
    param([Parameter(Mandatory)] $Image, [Parameter(Mandatory)] $Target)
    if ($Image.Length -gt $Target.Size) { Fail 'Image is larger than the target disk.' 'InvalidImage' }
    if (($Image.Length % $Target.Sector) -ne 0) { Fail "Image length must be a multiple of logical sector size $($Target.Sector)." 'InvalidImage' }
}

function Assert-ImageUnchanged {
    param([Parameter(Mandatory)] $Image)
    $now = Get-Item -LiteralPath $Image.Path -Force -ErrorAction Stop
    if ([UInt64]$now.Length -ne $Image.Length -or $now.LastWriteTimeUtc -ne $Image.LastWriteTimeUtc -or [UInt64]$Image.Stream.Length -ne $Image.Length) { Fail 'Image file changed while it was being written. Treat the USB disk as invalid.' 'InvalidImage' }
}

# 'Step 4 - Copy and compare bounded byte buffers'
function Copy-Exact {
    param([IO.Stream]$Source, [scriptblock]$WriteChunk, [UInt64]$Length, [int]$BufferSize = 1048576)
    $buffer = New-Object byte[] $BufferSize; [UInt64]$done = 0
    while ($done -lt $Length) {
        $need = [Math]::Min([UInt64]$buffer.Length, $Length - $done); $got = 0
        while ($got -lt $need) { $r = $Source.Read($buffer, $got, [int]($need - $got)); if ($r -le 0) { Fail "Source ended early at byte $($done + $got)." 'InvalidImage' }; $got += $r }
        & $WriteChunk $buffer $got $done
        $done += $got
        Write-Progress -Activity 'Writing Linux USB image' -Status "$done / $Length bytes" -PercentComplete ([int](100 * $done / $Length))
    }
    Write-Progress -Activity 'Writing Linux USB image' -Completed
    return $done
}

function Compare-Exact {
    param([IO.Stream]$Source, [scriptblock]$ReadChunk, [UInt64]$Length, [int]$BufferSize = 1048576)
    $expected = New-Object byte[] $BufferSize; $actual = New-Object byte[] $BufferSize; [UInt64]$done = 0
    while ($done -lt $Length) {
        $need = [int][Math]::Min([UInt64]$BufferSize, $Length - $done); $a = $Source.Read($expected,0,$need); if ($a -ne $need) { Fail "Source ended early at byte $($done + [Math]::Max($a,0))." 'InvalidImage' }
        $r = & $ReadChunk $actual $need $done; if ($r -ne $need) { Fail "Destination ended early at byte $($done + [Math]::Max($r,0))." 'VerifyFailure' }
        for($i=0; $i -lt $need; $i++) { if($expected[$i] -ne $actual[$i]) { Fail "Verification mismatch at zero-based byte offset $($done + $i)." 'VerifyFailure' } }
        $done += $need
        Write-Progress -Activity 'Verifying Linux USB image' -Status "$done / $Length bytes" -PercentComplete ([int](100 * $done / $Length))
    }
    Write-Progress -Activity 'Verifying Linux USB image' -Completed
    return $done
}

# 'Step 5 - Open the confirmed physical disk and control automount'
# Open-RawDisk is the ONLY place PhysicalDriveN is opened. Call it only via Invoke-RawDiskOperation.
function Open-RawDisk {
    param([Parameter(Mandatory)][int] $Number, [Parameter(Mandatory)][bool] $Write)
    $access = [LinuxUsb.NativeV4]::GENERIC_READ; $flags = 0
    if ($Write) { $access = $access -bor [LinuxUsb.NativeV4]::GENERIC_WRITE; $flags = [LinuxUsb.NativeV4]::FILE_FLAG_WRITE_THROUGH }
    $h = [LinuxUsb.NativeV4]::CreateFile("\\.\PhysicalDrive$Number", $access, 0, [IntPtr]::Zero, [LinuxUsb.NativeV4]::OPEN_EXISTING, $flags, [IntPtr]::Zero)
    if ($h.IsInvalid) { $h.Dispose(); Fail "Could not open PhysicalDrive$Number exclusively: $(Get-Win32Message)" 'LockFailure' }
    return $h
}

function Get-MountManagerAutoMount {
    $h = [LinuxUsb.NativeV4]::CreateFile('\\.\MountPointManager', [LinuxUsb.NativeV4]::GENERIC_READ, 3, [IntPtr]::Zero, [LinuxUsb.NativeV4]::OPEN_EXISTING, 0, [IntPtr]::Zero)
    if($h.IsInvalid) { $h.Dispose(); Fail "Could not open Windows Mount Manager: $(Get-Win32Message)" 'LockFailure' }
    try {
        $data = New-Object byte[] 4; [uint32]$returned=0
        if(-not [LinuxUsb.NativeV4]::DeviceIoControl($h,[LinuxUsb.NativeV4]::IOCTL_MOUNTMGR_QUERY_AUTO_MOUNT,[IntPtr]::Zero,0,$data,4,[ref]$returned,[IntPtr]::Zero) -or $returned -lt 4) { Fail "Could not query Windows automount state: $(Get-Win32Message)" 'LockFailure' }
        return ([BitConverter]::ToUInt32($data,0) -eq 1)
    } finally { $h.Dispose() }
}

function Set-MountManagerAutoMount([bool] $Enabled) {
    $h = [LinuxUsb.NativeV4]::CreateFile('\\.\MountPointManager', [LinuxUsb.NativeV4]::GENERIC_READ -bor [LinuxUsb.NativeV4]::GENERIC_WRITE, 3, [IntPtr]::Zero, [LinuxUsb.NativeV4]::OPEN_EXISTING, 0, [IntPtr]::Zero)
    if($h.IsInvalid) { $h.Dispose(); Fail "Could not open Windows Mount Manager for update: $(Get-Win32Message)" 'LockFailure' }
    try {
        $data = [BitConverter]::GetBytes([uint32]$(if($Enabled){1}else{0})); [uint32]$returned=0
        if(-not [LinuxUsb.NativeV4]::DeviceIoControl($h,[LinuxUsb.NativeV4]::IOCTL_MOUNTMGR_SET_AUTO_MOUNT,$data,4,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) { Fail "Could not set Windows automount state: $(Get-Win32Message)" 'LockFailure' }
    } finally { $h.Dispose() }
}

function Assert-OpenedDisk {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle] $Handle, $Expected)
    $data = New-Object byte[] 12; [uint32]$returned = 0
    if (-not [LinuxUsb.NativeV4]::DeviceIoControl($Handle,[LinuxUsb.NativeV4]::IOCTL_STORAGE_GET_DEVICE_NUMBER,[IntPtr]::Zero,0,$data,[uint32]$data.Length,[ref]$returned,[IntPtr]::Zero) -or $returned -lt 12) { Fail "Could not identify opened raw disk: $(Get-Win32Message)" 'HardwareMismatch' }
    if ([BitConverter]::ToUInt32($data,4) -ne $Expected.Number) { Fail "Opened raw disk number does not match selected disk $($Expected.Number)." 'HardwareMismatch' }
    $geometry = New-Object byte[] 64; $returned = 0
    if (-not [LinuxUsb.NativeV4]::DeviceIoControl($Handle,[LinuxUsb.NativeV4]::IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,[IntPtr]::Zero,0,$geometry,[uint32]$geometry.Length,[ref]$returned,[IntPtr]::Zero) -or $returned -lt 32) { Fail "Could not read opened raw disk geometry: $(Get-Win32Message)" 'HardwareMismatch' }
    if ([BitConverter]::ToUInt32($geometry,20) -ne $Expected.Sector -or [UInt64][BitConverter]::ToInt64($geometry,24) -ne $Expected.Size) { Fail 'Opened raw disk geometry does not match the confirmed target.' 'HardwareMismatch' }
}

function Get-TransferBufferSize([uint32] $Sector) {
    # 64 KiB avoids large USB mass-storage requests while remaining a fixed,
    # sector-aligned transfer size. Some removable-device bridges are less
    # reliable with multi-megabyte raw requests.
    return [int]([Math]::Ceiling(65536.0 / $Sector) * $Sector)
}

# Every gate that must pass before a raw handle may exist. Set each flag only after its check succeeds.
function New-WriteAuthorization {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Target)
    [pscustomobject]@{ PSTypeName = 'LinuxUsb.WriteAuthorization'; TargetNumber = $Target.Number; NotDryRun = $false; PhraseMatched = $false; IdentityVerified = $false; VolumesLocked = $false }
}

function Assert-WriteAuthorization {
    param($Authorization, $Target)
    if (-not $Authorization -or $Authorization.TargetNumber -ne $Target.Number) { Fail 'Raw disk access requested without a matching authorization.' 'InvalidTarget' }
    foreach($gate in 'NotDryRun', 'PhraseMatched', 'IdentityVerified', 'VolumesLocked') {
        if (-not $Authorization.$gate) { Fail "Raw disk access refused: safety gate '$gate' has not passed." 'InvalidTarget' }
    }
}

# The single unsafe stage: raw open, write/read, flush, close. Accepts only a validated target plus authorization.
function Invoke-RawDiskOperation {
    param(
        [Parameter(Mandatory)] $Target, $Authorization,
        [Parameter(Mandatory)][ValidateSet('Write', 'Read')][string] $Mode,
        [Parameter(Mandatory)][IO.Stream] $Source, [Parameter(Mandatory)][UInt64] $Length, [Parameter(Mandatory)] $Cleanup
    )
    Assert-WriteAuthorization $Authorization $Target
    $raw = $null
    try {
        $raw = Open-RawDisk $Target.Number ($Mode -eq 'Write'); $Cleanup.OpenedRawHandle = $raw
        Assert-OpenedDisk $raw $Target
        $Source.Position = 0
        $size = Get-TransferBufferSize $Target.Sector
        if ($Mode -eq 'Write') {
            $write = {
                param($b,$n,$offset)
                [uint32]$written=0
                $ok = [LinuxUsb.NativeV4]::WriteFile($raw,$b,[uint32]$n,[ref]$written,[IntPtr]::Zero)
                $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                if(-not $ok) { Fail "WriteFile failed at byte ${offset}: $(Format-Win32Error $lastError)" 'WriteFailure' }
                if($written -ne $n) { Fail "WriteFile made a short write at byte ${offset}: requested $n bytes, reported $written bytes." 'WriteFailure' }
            }
            $count = Copy-Exact $Source $write $Length $size
            if (-not [LinuxUsb.NativeV4]::FlushFileBuffers($raw)) { Fail "Flush failed: $(Get-Win32Message)" 'WriteFailure' }
            return $count
        }
        $read = { param($b,$n,$offset) [uint32]$got=0; if(-not [LinuxUsb.NativeV4]::ReadFile($raw,$b,[uint32]$n,[ref]$got,[IntPtr]::Zero)) { Fail "Read failed at byte ${offset}: $(Get-Win32Message)" 'VerifyFailure' }; return [int]$got }
        return (Compare-Exact $Source $read $Length $size)
    } finally {
        if ($raw) { $raw.Dispose() }
        $Cleanup.OpenedRawHandle = $null
    }
}

# 'Step 6 - Lock and dismount target volumes before raw access'
function Get-OpenedVolumeExtents {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle] $Handle, [string] $Path)
    # VOLUME_DISK_EXTENTS is variable length.  The first DISK_EXTENT starts at offset 8 on 64-bit Windows.
    $size = 1024
    while ($true) {
        $buffer = New-Object byte[] $size; [uint32]$returned = 0
        if ([LinuxUsb.NativeV4]::DeviceIoControl($Handle,[LinuxUsb.NativeV4]::IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,[IntPtr]::Zero,0,$buffer,[uint32]$buffer.Length,[ref]$returned,[IntPtr]::Zero)) { break }
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($lastError -ne 234 -or $size -ge 65536) {
            # Volumes with no disk extents (virtual/network/optical/etc.) fail here; let the caller decide.
            $script:LastExtentError = Format-Win32Error $lastError
            return $null
        }
        $size *= 2
    }
    if ($returned -lt 4) { Fail "Volume $Path returned invalid disk extents." 'HardwareMismatch' }
    $count = [BitConverter]::ToUInt32($buffer,0); $needed = 8 + (24 * [UInt64]$count)
    if ($needed -gt $returned) { Fail "Volume $Path returned incomplete disk extents." 'HardwareMismatch' }
    $result = @()
    for($i=0; $i -lt $count; $i++) { $result += [BitConverter]::ToUInt32($buffer,8 + (24*$i)) }
    return $result
}

# Target-volume handles are registered in $Cleanup the moment they are opened, so a failure at any later
# step still releases them via Invoke-Cleanup. Returns the number of volumes locked.
function Lock-TargetVolumes {
    [OutputType([int])]
    param([Parameter(Mandatory)] $Target, [Parameter(Mandatory)] $Cleanup)
    # Win32_Volume exposes drive-letter-less and hidden Volume GUID paths. The Storage
    # query is retained as a cross-check and also detects a changed partition table.
    $storagePaths = @((Get-Partition -DiskNumber $Target.Number -ErrorAction Stop | Get-Volume -ErrorAction SilentlyContinue | ForEach-Object { $_.UniqueId }))
    $volumes = @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | Where-Object { $_.DeviceID })
    $locked = 0
    foreach($v in $volumes) {
        $path = [string]$v.DeviceID
        $openPath = $path.TrimEnd('\')
        $h = [LinuxUsb.NativeV4]::CreateFile($openPath, [LinuxUsb.NativeV4]::GENERIC_READ -bor [LinuxUsb.NativeV4]::GENERIC_WRITE, 3, [IntPtr]::Zero, [LinuxUsb.NativeV4]::OPEN_EXISTING, 0, [IntPtr]::Zero)
        if ($h.IsInvalid) { $h.Dispose(); Fail "Could not open volume $path while resolving target mapping: $(Get-Win32Message)" 'LockFailure' }
        try { $rawExtents = Get-OpenedVolumeExtents $h $path } catch { $h.Dispose(); throw }
        if ($null -eq $rawExtents) {
            # Cannot map this volume to a disk. Refuse only if the Storage module says it belongs to the target.
            $h.Dispose()
            if ($storagePaths -contains $path) { Fail "Could not read disk extents for target volume ${path}: $script:LastExtentError" 'HardwareMismatch' }
            Write-Verbose "Skipping volume $path (no disk extents: $script:LastExtentError); not on target disk."
            continue
        }
        $extents = @($rawExtents)
        Write-Verbose "Volume $path maps to disk(s): $($extents -join ',')"
        if ($extents -notcontains $Target.Number) { $h.Dispose(); continue }
        [void]$Cleanup.OpenedVolumeHandles.Add($h)
        if ($extents.Count -ne 1) { Fail "Volume $path spans more than one disk; refusing write." 'HardwareMismatch' }
        if ($storagePaths.Count -gt 0 -and $storagePaths -notcontains $path) { Fail "Volume $path maps to Disk $($Target.Number) but Storage module did not confirm it." 'HardwareMismatch' }
        [uint32]$returned = 0
        if (-not [LinuxUsb.NativeV4]::DeviceIoControl($h,[LinuxUsb.NativeV4]::FSCTL_LOCK_VOLUME,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) { Fail "Could not lock volume ${path}: $(Get-Win32Message)" 'LockFailure' }
        # A successful lock proves no application has the volume open. Dismount it
        # before raw writing so a stale or newly discovered ISO partition cannot
        # keep an online volume device in the I/O path.
        if (-not [LinuxUsb.NativeV4]::DeviceIoControl($h,[LinuxUsb.NativeV4]::FSCTL_DISMOUNT_VOLUME,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) { Fail "Could not dismount locked volume ${path}: $(Get-Win32Message)" 'LockFailure' }
        $locked++
        Write-Host "Locked and dismounted target volume $path."
    }
    return $locked
}

# Cleanup runs in a fixed order and every step is attempted even if an earlier one fails:
# raw handle -> volume handles -> image stream -> automount. Returns $true only if nothing failed.
function Invoke-Cleanup {
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Cleanup)
    if ($Cleanup.OpenedRawHandle) {
        try { $Cleanup.OpenedRawHandle.Dispose() } catch { [void]$Cleanup.Failures.Add("Could not close the raw disk handle: $($_.Exception.Message)") }
        $Cleanup.OpenedRawHandle = $null
    }
    foreach($h in @($Cleanup.OpenedVolumeHandles)) {
        try { $h.Dispose() } catch { [void]$Cleanup.Failures.Add("Could not close a volume handle: $($_.Exception.Message)") }
    }
    $Cleanup.OpenedVolumeHandles.Clear()
    if ($Cleanup.SourceStream) {
        try { $Cleanup.SourceStream.Dispose() } catch { [void]$Cleanup.Failures.Add("Could not close the image file: $($_.Exception.Message)") }
        $Cleanup.SourceStream = $null
    }
    if ($Cleanup.WasAutoMountDisabled) {
        try { Set-MountManagerAutoMount $true; $Cleanup.WasAutoMountDisabled = $false; Write-Host 'Restored Windows automount.' }
        catch { [void]$Cleanup.Failures.Add("Could not restore Windows automount: $($_.Exception.Message)") }
    }
    if ($Cleanup.Failures.Count -gt 0) {
        foreach($f in $Cleanup.Failures) { Write-Warning $f }
        $steps = 'RECOVERY: close this PowerShell session to release any leftover handles, then unplug and reinsert the USB disk.'
        if ($Cleanup.WasAutoMountDisabled) { $steps += ' Windows automount is STILL DISABLED: run "mountvol /E" in an elevated prompt to re-enable it.' }
        Write-Warning $steps
        return $false
    }
    return $true
}

# 'Step 7 - Confirm, write, verify, and clean up'
function Get-ConfirmationPhrase {
    [OutputType([string])]
    param([Parameter(Mandatory)] $Target, [Parameter(Mandatory)][string] $Mode)
    $verb = if ($Mode -eq 'VerifyOnly') { 'VERIFY' } else { 'ERASE' }
    "$verb DISK $($Target.Number) $($Target.IdentityKind) $($Target.Identity)"
}

# Re-queries the disk after the operation: no identity drift, and no partition newly mounted behind our back.
function Assert-PostOperationState {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)] $Target, [string[]] $LettersBefore = @())
    $items = @(Get-DiskInfo $Target.Number)
    if ($items.Count -ne 1) { Fail "Disk $($Target.Number) disappeared during the operation." 'HardwareMismatch' }
    $State.After = New-TargetSnapshot $items[0]
    Assert-SameDisk $Target $State.After $script:HardwareFields
    $new = @(Get-MountedDriveLetters $Target.Number | Where-Object { $LettersBefore -notcontains $_ })
    if ($new.Count -gt 0) { Fail "Partitions were mounted on Disk $($Target.Number) during the operation (drive letters: $($new -join ', '))." 'HardwareMismatch' }
}

function Invoke-ConfirmedOperation {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)] $Target)
    $image = $State.Image; $cleanup = $State.Cleanup
    $mode = if ($State.VerifyOnly) { 'VerifyOnly' } else { 'Write' }
    $phrase = Get-ConfirmationPhrase $Target $mode
    $action = if ($State.VerifyOnly) { 'READ-ONLY VERIFY (nothing is erased)' } else { 'WRITE - THIS DESTROYS ALL DATA ON THE TARGET' }
    $auth = New-WriteAuthorization $Target
    $auth.NotDryRun = (-not $State.WhatIf)
    $prompt = "`n==== CONFIRM ====`nMode  : $action`nImage : $($image.Path) ($($image.Length) bytes)`nTarget: $(Show-Disk $Target)`nType exactly: $phrase`n> "
    $answer = Read-Host $prompt
    if ($answer -cne $phrase) { Fail 'Confirmation declined.' 'UserDeclined' }
    $auth.PhraseMatched = $true
    Write-AuditLog $State 'Confirmed' @{ Phrase = $phrase }
    $again = Get-EligibleDisk $Target.Number; Assert-SameDisk $Target $again
    $auth.IdentityVerified = $true
    if (-not $State.VerifyOnly -and (Get-MountManagerAutoMount)) { Set-MountManagerAutoMount $false; $cleanup.WasAutoMountDisabled = $true; 'Temporarily disabled Windows automount.' }
    $lettersBefore = @(Get-MountedDriveLetters $Target.Number)
    $lockedCount = Lock-TargetVolumes $again $cleanup
    Write-AuditLog $State 'VolumesLocked' @{ Count = $lockedCount }
    $again = Get-EligibleDisk $Target.Number; Assert-SameDisk $Target $again
    $auth.VolumesLocked = $true
    $count = $null
    if (-not $State.VerifyOnly) {
        $count = Invoke-RawDiskOperation -Target $again -Authorization $auth -Mode Write -Source $image.Stream -Length $image.Length -Cleanup $cleanup
        Write-AuditLog $State 'Written' @{ Bytes = $count }
    }
    if ($State.Verify -or $State.VerifyOnly) {
        $verified = Invoke-RawDiskOperation -Target $again -Authorization $auth -Mode Read -Source $image.Stream -Length $image.Length -Cleanup $cleanup
        "Verified $verified bytes."
        Write-AuditLog $State 'Verified' @{ Bytes = $verified }
    }
    Assert-ImageUnchanged $image
    Assert-PostOperationState $State $Target $lettersBefore
    if (-not $State.VerifyOnly) { "Successfully wrote $count bytes." }
}

function Invoke-LinuxUsb {
    param([Parameter(Mandatory)] $State)
    if ($State.ListDisks) { Get-EligibleUsbDisks | ForEach-Object { Show-Disk $_ }; return }
    if ($State.LogPath) {
        $logDir = Split-Path -Parent $State.LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir -PathType Container)) { Fail "LogPath directory does not exist: $logDir" 'InvalidTarget' }
    }
    $State.Outcome = 'Started'
    try {
        $State.Image = Get-ImageStream (Resolve-ImageFileInput $State)
        $State.Cleanup.SourceStream = $State.Image.Stream
        $target = Select-UsbTarget $State; $State.Before = $target
        Write-AuditLog $State 'TargetSelected' $target
        Assert-ImageFitsTarget $State.Image $target
        if ($State.ShowHash) { "SHA256: $((Get-FileHash -LiteralPath $State.Image.Path -Algorithm SHA256).Hash)" }
        Show-Disk $target; "Image: '$($State.Image.Path)' ($($State.Image.Length) bytes)"
        if ($State.WhatIf) { 'Dry run: no handles opened, volumes locked, or bytes written.'; $State.Outcome = 'DryRun' }
        else { Invoke-ConfirmedOperation $State $target; $State.Outcome = 'Success' }
    } catch {
        $State.ErrorCategory = Get-ErrorCategory $_
        $State.Outcome = if ($State.ErrorCategory -eq 'UserDeclined') { 'Declined' } else { 'Failed' }
        Write-AuditLog $State 'Error' @{ Category = $State.ErrorCategory; Message = $_.Exception.Message }
        throw
    } finally {
        $cleanupOk = Invoke-Cleanup $State.Cleanup
        if (-not $cleanupOk -and $State.Outcome -eq 'Success') { $State.Outcome = 'CleanupFailure'; $State.ErrorCategory = 'CleanupFailure' }
        $summary = [pscustomobject]@{
            Timestamp = (Get-Date).ToUniversalTime().ToString('o'); ToolVersion = $script:ToolVersion
            Outcome = $State.Outcome; ErrorCategory = $State.ErrorCategory
            ImagePath = if ($State.Image) { $State.Image.Path } else { $null }
            ImageSize = if ($State.Image) { $State.Image.Length } else { $null }
            TargetDisk = if ($State.Before) { $State.Before.Number } else { $null }
            Identity = if ($State.Before) { $State.Before.Identity } else { $null }
            Before = $State.Before; After = $State.After
            Cleanup = [pscustomobject]@{ Succeeded = $cleanupOk; Failures = @($State.Cleanup.Failures) }
        }
        Write-AuditLog $State 'RunSummary' $summary
        Write-Host ('AUDIT: ' + ($summary | ConvertTo-Json -Compress -Depth 6))
    }
    if ($State.Outcome -eq 'CleanupFailure') { Fail 'The operation finished but cleanup failed; see the recovery steps above.' 'CleanupFailure' }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-LinuxUsb (New-LinuxUsbState -Bound $PSBoundParameters -ImageFile $ImageFile -DiskNumber $DiskNumber `
        -Verify $Verify.IsPresent -VerifyOnly $VerifyOnly.IsPresent -WhatIf $WhatIf.IsPresent -ShowHash $ShowHash.IsPresent `
        -ListDisks $ListDisks.IsPresent -LogPath $LogPath)
}
