#requires -Version 5.1
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
    [switch] $ShowHash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LinuxUsbInputBound = $PSBoundParameters
$script:DefaultImagePath = 'C:\ISO\linux-installer.iso'

# 'Step 1 - Load the small, visible Win32 interop layer'
if (-not ('LinuxUsb.NativeV3' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace LinuxUsb {
  public static class NativeV3 {
    public const uint GENERIC_READ=0x80000000, GENERIC_WRITE=0x40000000, OPEN_EXISTING=3;
    public const uint FILE_FLAG_WRITE_THROUGH=0x80000000, FSCTL_LOCK_VOLUME=0x00090018, FSCTL_DISMOUNT_VOLUME=0x00090020, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS=0x00560000, IOCTL_STORAGE_GET_DEVICE_NUMBER=0x002D1080, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX=0x000700A0, IOCTL_MOUNTMGR_QUERY_AUTO_MOUNT=0x006D003C, IOCTL_MOUNTMGR_SET_AUTO_MOUNT=0x006DC040;
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

function Fail([string] $Message) { throw [System.InvalidOperationException]::new($Message) }
function Format-Win32Error([int] $Error) { "Win32 error ${Error}: $([ComponentModel.Win32Exception]::new($Error).Message)" }
function Get-Win32Message { Format-Win32Error ([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }

# 'Step 2 - Inspect and select a safe USB target'
function Get-EligibleDisk {
    param([int] $Number)
    $items = @(Get-Disk -Number $Number -ErrorAction SilentlyContinue)
    if ($items.Count -ne 1) { Fail "Disk $Number was not found or is ambiguous." }
    $disk = $items[0]
    Assert-DiskEligibility $disk
    $identity = if ($disk.SerialNumber) { $disk.SerialNumber.Trim() } elseif ($disk.UniqueId) { $disk.UniqueId } elseif ($disk.Guid) { $disk.Guid.ToString() } else { $null }
    if (-not $identity) { Fail "Disk $Number has no stable identity. Refusing raw write." }
    [pscustomobject]@{ Disk=$disk; Number=$disk.Number; Model=$disk.FriendlyName; Size=[UInt64]$disk.Size; Bus=[string]$disk.BusType; Serial=$disk.SerialNumber; Identity=$identity; Sector=[UInt32]$disk.LogicalSectorSize }
}

function Get-EligibleUsbDisks {
    $results = @()
    foreach($disk in @(Get-Disk -ErrorAction Stop | Where-Object BusType -eq USB)) {
        try { $results += Get-EligibleDisk $disk.Number } catch { Write-Warning $_.Exception.Message }
    }
    return $results
}

function Select-UsbTarget {
    if ($script:LinuxUsbInputBound.ContainsKey('DiskNumber')) { return Get-EligibleDisk $DiskNumber }
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

function Assert-DiskEligibility {
    param($disk)
    if ([string]$disk.BusType -ne 'USB') { Fail "Disk $($disk.Number) is not USB (bus: $($disk.BusType))." }
    if ($disk.IsBoot -or $disk.IsSystem) { Fail "Disk $($disk.Number) is a boot or system disk." }
    if ($disk.IsReadOnly -or $disk.IsOffline) { Fail "Disk $($disk.Number) is read-only or offline." }
    if (-not $disk.Size -or -not $disk.LogicalSectorSize -or $disk.LogicalSectorSize -lt 512) { Fail "Disk $($disk.Number) has invalid capacity or logical sector size." }
}

# 'Step 3 - Resolve and validate the ISO source'
function Resolve-ImageFileInput {
    if ($script:LinuxUsbInputBound.ContainsKey('ImageFile')) { return $ImageFile }
    $answer = Read-Host "ISO path [$($script:DefaultImagePath)] (press Enter to use this default)"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $script:DefaultImagePath }
    return $answer
}

function Get-ImageStream {
    param([string] $Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ($resolved -match '^(\\\\|//)' -or (Get-PSDrive -Name ([IO.Path]::GetPathRoot($resolved).TrimEnd(':','\')) -ErrorAction SilentlyContinue).DisplayRoot) { Fail 'Network and mapped-network image paths are not allowed.' }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.PSIsContainer -or $item.Extension -ine '.iso' -or $item.Length -le 0) { Fail 'Image must be a non-empty local .iso file.' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Image reparse points are not allowed.' }
    [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

# 'Step 4 - Copy and compare bounded byte buffers'
function Copy-Exact {
    param([IO.Stream]$Source, [scriptblock]$WriteChunk, [UInt64]$Length, [int]$BufferSize = 1048576)
    $buffer = New-Object byte[] $BufferSize; [UInt64]$done = 0
    while ($done -lt $Length) {
        $need = [Math]::Min([UInt64]$buffer.Length, $Length - $done); $got = 0
        while ($got -lt $need) { $r = $Source.Read($buffer, $got, [int]($need - $got)); if ($r -le 0) { Fail "Source ended early at byte $($done + $got)." }; $got += $r }
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
        $need = [int][Math]::Min([UInt64]$BufferSize, $Length - $done); $a = $Source.Read($expected,0,$need); if ($a -ne $need) { Fail "Source ended early at byte $($done + [Math]::Max($a,0))." }
        $r = & $ReadChunk $actual $need $done; if ($r -ne $need) { Fail "Destination ended early at byte $($done + [Math]::Max($r,0))." }
        for($i=0; $i -lt $need; $i++) { if($expected[$i] -ne $actual[$i]) { Fail "Verification mismatch at zero-based byte offset $($done + $i)." } }
        $done += $need
        Write-Progress -Activity 'Verifying Linux USB image' -Status "$done / $Length bytes" -PercentComplete ([int](100 * $done / $Length))
    }
    Write-Progress -Activity 'Verifying Linux USB image' -Completed
    return $done
}

# 'Step 5 - Open the confirmed physical disk and control automount'
function Open-RawDisk([int]$Number, [bool]$Write) {
    $access = [LinuxUsb.NativeV3]::GENERIC_READ; $flags = 0
    if ($Write) { $access = $access -bor [LinuxUsb.NativeV3]::GENERIC_WRITE; $flags = [LinuxUsb.NativeV3]::FILE_FLAG_WRITE_THROUGH }
    $h = [LinuxUsb.NativeV3]::CreateFile("\\.\PhysicalDrive$Number", $access, 0, [IntPtr]::Zero, [LinuxUsb.NativeV3]::OPEN_EXISTING, $flags, [IntPtr]::Zero)
    if ($h.IsInvalid) { $h.Dispose(); Fail "Could not open PhysicalDrive$Number exclusively: $(Get-Win32Message)" }
    return $h
}

function Get-MountManagerAutoMount {
    $h = [LinuxUsb.NativeV3]::CreateFile('\\.\MountPointManager', [LinuxUsb.NativeV3]::GENERIC_READ, 3, [IntPtr]::Zero, [LinuxUsb.NativeV3]::OPEN_EXISTING, 0, [IntPtr]::Zero)
    if($h.IsInvalid) { $h.Dispose(); Fail "Could not open Windows Mount Manager: $(Get-Win32Message)" }
    try {
        $data = New-Object byte[] 4; [uint32]$returned=0
        if(-not [LinuxUsb.NativeV3]::DeviceIoControl($h,[LinuxUsb.NativeV3]::IOCTL_MOUNTMGR_QUERY_AUTO_MOUNT,[IntPtr]::Zero,0,$data,4,[ref]$returned,[IntPtr]::Zero) -or $returned -lt 4) { Fail "Could not query Windows automount state: $(Get-Win32Message)" }
        return ([BitConverter]::ToUInt32($data,0) -eq 1)
    } finally { $h.Dispose() }
}

function Set-MountManagerAutoMount([bool] $Enabled) {
    $h = [LinuxUsb.NativeV3]::CreateFile('\\.\MountPointManager', [LinuxUsb.NativeV3]::GENERIC_READ -bor [LinuxUsb.NativeV3]::GENERIC_WRITE, 3, [IntPtr]::Zero, [LinuxUsb.NativeV3]::OPEN_EXISTING, 0, [IntPtr]::Zero)
    if($h.IsInvalid) { $h.Dispose(); Fail "Could not open Windows Mount Manager for update: $(Get-Win32Message)" }
    try {
        $data = [BitConverter]::GetBytes([uint32]$(if($Enabled){1}else{0})); [uint32]$returned=0
        if(-not [LinuxUsb.NativeV3]::DeviceIoControl($h,[LinuxUsb.NativeV3]::IOCTL_MOUNTMGR_SET_AUTO_MOUNT,$data,4,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) { Fail "Could not set Windows automount state: $(Get-Win32Message)" }
    } finally { $h.Dispose() }
}

function Assert-OpenedDisk {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle] $Handle, $Expected)
    $data = New-Object byte[] 12; [uint32]$returned = 0
    if (-not [LinuxUsb.NativeV3]::DeviceIoControl($Handle,[LinuxUsb.NativeV3]::IOCTL_STORAGE_GET_DEVICE_NUMBER,[IntPtr]::Zero,0,$data,[uint32]$data.Length,[ref]$returned,[IntPtr]::Zero) -or $returned -lt 12) { Fail "Could not identify opened raw disk: $(Get-Win32Message)" }
    if ([BitConverter]::ToUInt32($data,4) -ne $Expected.Number) { Fail "Opened raw disk number does not match selected disk $($Expected.Number)." }
    $geometry = New-Object byte[] 64; $returned = 0
    if (-not [LinuxUsb.NativeV3]::DeviceIoControl($Handle,[LinuxUsb.NativeV3]::IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,[IntPtr]::Zero,0,$geometry,[uint32]$geometry.Length,[ref]$returned,[IntPtr]::Zero) -or $returned -lt 32) { Fail "Could not read opened raw disk geometry: $(Get-Win32Message)" }
    if ([BitConverter]::ToUInt32($geometry,20) -ne $Expected.Sector -or [UInt64][BitConverter]::ToInt64($geometry,24) -ne $Expected.Size) { Fail 'Opened raw disk geometry does not match the confirmed target.' }
}

function Get-TransferBufferSize([uint32] $Sector) {
    # 64 KiB avoids large USB mass-storage requests while remaining a fixed,
    # sector-aligned transfer size. Some removable-device bridges are less
    # reliable with multi-megabyte raw requests.
    return [int]([Math]::Ceiling(65536.0 / $Sector) * $Sector)
}

function Assert-SameDisk($Before, $After) {
    if ($Before.Identity -ne $After.Identity -or $Before.Size -ne $After.Size -or $Before.Sector -ne $After.Sector -or $Before.Bus -ne $After.Bus) { Fail 'Disk metadata changed after confirmation. Refusing write.' }
}

# 'Step 6 - Lock and dismount target volumes before raw access'
function Get-OpenedVolumeExtents {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle] $Handle, [string] $Path)
    # VOLUME_DISK_EXTENTS is variable length.  The first DISK_EXTENT starts at offset 8 on 64-bit Windows.
    $size = 1024
    while ($true) {
        $buffer = New-Object byte[] $size; [uint32]$returned = 0
        if ([LinuxUsb.NativeV3]::DeviceIoControl($Handle,[LinuxUsb.NativeV3]::IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,[IntPtr]::Zero,0,$buffer,[uint32]$buffer.Length,[ref]$returned,[IntPtr]::Zero)) { break }
        $error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($error -ne 234 -or $size -ge 65536) { Fail "Could not read disk extents for volume ${Path}: $(Get-Win32Message)" }
        $size *= 2
    }
    if ($returned -lt 4) { Fail "Volume $Path returned invalid disk extents." }
    $count = [BitConverter]::ToUInt32($buffer,0); $needed = 8 + (24 * [UInt64]$count)
    if ($needed -gt $returned) { Fail "Volume $Path returned incomplete disk extents." }
    $result = @()
    for($i=0; $i -lt $count; $i++) { $result += [BitConverter]::ToUInt32($buffer,8 + (24*$i)) }
    return $result
}

function Lock-TargetVolumes { param($Target)
    # Win32_Volume exposes drive-letter-less and hidden Volume GUID paths. The Storage
    # query is retained as a cross-check and also detects a changed partition table.
    $storagePaths = @((Get-Partition -DiskNumber $Target.Number -ErrorAction Stop | Get-Volume -ErrorAction SilentlyContinue | ForEach-Object { $_.UniqueId }))
    $volumes = @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | Where-Object { $_.DeviceID })
    $handles = @()
    try {
        foreach($v in $volumes) {
            $path = [string]$v.DeviceID
            $openPath = $path.TrimEnd('\')
            $h = [LinuxUsb.NativeV3]::CreateFile($openPath, [LinuxUsb.NativeV3]::GENERIC_READ -bor [LinuxUsb.NativeV3]::GENERIC_WRITE, 3, [IntPtr]::Zero, [LinuxUsb.NativeV3]::OPEN_EXISTING, 0, [IntPtr]::Zero)
            if ($h.IsInvalid) { $h.Dispose(); Fail "Could not open volume $path while resolving target mapping: $(Get-Win32Message)" }
            $extents = @(Get-OpenedVolumeExtents $h $path)
            if ($extents -notcontains $Target.Number) { $h.Dispose(); continue }
            if ($extents.Count -ne 1) { $h.Dispose(); Fail "Volume $path spans more than one disk; refusing write." }
            if ($storagePaths.Count -gt 0 -and $storagePaths -notcontains $path) { $h.Dispose(); Fail "Volume $path maps to Disk $($Target.Number) but Storage module did not confirm it." }
            [uint32]$returned = 0
            if (-not [LinuxUsb.NativeV3]::DeviceIoControl($h,[LinuxUsb.NativeV3]::FSCTL_LOCK_VOLUME,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) { $h.Dispose(); Fail "Could not lock volume ${path}: $(Get-Win32Message)" }
            # A successful lock proves no application has the volume open. Dismount it
            # before raw writing so a stale or newly discovered ISO partition cannot
            # keep an online volume device in the I/O path.
            if (-not [LinuxUsb.NativeV3]::DeviceIoControl($h,[LinuxUsb.NativeV3]::FSCTL_DISMOUNT_VOLUME,[IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$returned,[IntPtr]::Zero)) { $h.Dispose(); Fail "Could not dismount locked volume ${path}: $(Get-Win32Message)" }
            $handles += $h
            Write-Host "Locked and dismounted target volume $path."
        }
        return $handles
    } catch { foreach($h in $handles) { $h.Dispose() }; throw }
}

function Show-Disk($d) { "Disk $($d.Number): model='$($d.Model)', size=$($d.Size), bus=$($d.Bus), serial='$($d.Serial)', identity='$($d.Identity)'" }

# 'Step 7 - Confirm, write, verify, and clean up'
function Invoke-LinuxUsb {
    if ($ListDisks) { Get-EligibleUsbDisks | ForEach-Object { Show-Disk $_ }; return }
    $selectedImage = Resolve-ImageFileInput
    $source = Get-ImageStream $selectedImage
    $raw = $null; $locks = @(); $restoreAutoMount = $false
    try {
        $length = [UInt64]$source.Length; $target = Select-UsbTarget; $selectedDiskNumber = $target.Number
        if ($length -gt $target.Size) { Fail 'Image is larger than the target disk.' }; if (($length % $target.Sector) -ne 0) { Fail "Image length must be a multiple of logical sector size $($target.Sector)." }
        if ($ShowHash) { $source.Position=0; "SHA256: $((Get-FileHash -LiteralPath $source.Name -Algorithm SHA256).Hash)" }
        Show-Disk $target; "Image: '$($source.Name)' ($length bytes)"
        if ($WhatIf) { 'Dry run: no handles opened, volumes locked, or bytes written.'; return }
        $prompt = if ($VerifyOnly) { "Read-only verification. Type ERASE DISK $selectedDiskNumber to confirm the selected target" } else { "WARNING: this destroys the existing layout. Type ERASE DISK $selectedDiskNumber to continue" }
        $answer = Read-Host $prompt
        if ($answer -cne "ERASE DISK $selectedDiskNumber") { Fail 'Confirmation declined.' }
        $again = Get-EligibleDisk $selectedDiskNumber; Assert-SameDisk $target $again
        if (-not $VerifyOnly -and (Get-MountManagerAutoMount)) { Set-MountManagerAutoMount $false; $restoreAutoMount = $true; 'Temporarily disabled Windows automount.' }
        $locks = @(Lock-TargetVolumes $again); $again = Get-EligibleDisk $selectedDiskNumber; Assert-SameDisk $target $again
        if (-not $VerifyOnly) {
            $raw = Open-RawDisk $selectedDiskNumber $true; Assert-OpenedDisk $raw $again; $source.Position=0
            $write = {
                param($b,$n,$offset)
                [uint32]$written=0
                $ok = [LinuxUsb.NativeV3]::WriteFile($raw,$b,[uint32]$n,[ref]$written,[IntPtr]::Zero)
                $error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                if(-not $ok) { Fail "WriteFile failed at byte ${offset}: $(Format-Win32Error $error)" }
                if($written -ne $n) { Fail "WriteFile made a short write at byte ${offset}: requested $n bytes, reported $written bytes." }
            }
            $count = Copy-Exact $source $write $length (Get-TransferBufferSize $again.Sector)
            if (-not [LinuxUsb.NativeV3]::FlushFileBuffers($raw)) { Fail "Flush failed: $(Get-Win32Message)" }; $raw.Dispose(); $raw=$null
        }
        if ($Verify -or $VerifyOnly) { if($raw){$raw.Dispose();$raw=$null}; $raw = Open-RawDisk $selectedDiskNumber $false; Assert-OpenedDisk $raw $again; $source.Position=0; $read = { param($b,$n,$offset) [uint32]$got=0; if(-not [LinuxUsb.NativeV3]::ReadFile($raw,$b,[uint32]$n,[ref]$got,[IntPtr]::Zero)) { Fail "Read failed at byte ${offset}: $(Get-Win32Message)" }; return [int]$got }; $verified = Compare-Exact $source $read $length (Get-TransferBufferSize $again.Sector); "Verified $verified bytes." }
        if (-not $VerifyOnly) { "Successfully wrote $count bytes." }
    } finally {
        if($raw){$raw.Dispose()}; foreach($h in $locks){ if($h -is [IDisposable]){$h.Dispose()} }; if($source){$source.Dispose()}
        if($restoreAutoMount) { try { Set-MountManagerAutoMount $true; 'Restored Windows automount.' } catch { Write-Warning "Could not restore Windows automount. Run: mountvol /E. Error: $($_.Exception.Message)" } }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-LinuxUsb }
