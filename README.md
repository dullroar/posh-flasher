# posh-flasher

> ## ⚠ WARNING: THIS TOOL DESTROYS DATA
> - It **erases the selected USB disk** and its partition layout by writing raw bytes to `\\.\PhysicalDriveN`. There is no undo.
> - It must run **as Administrator** in **Windows PowerShell 5.1**.
> - Use **only publisher-approved Linux hybrid ISO images**, checked against the publisher's checksum (`-ShowHash`).
> - It does **not** do arbitrary partitioning, persistence, or bootloader repair.
> - Use a disposable USB disk. Unplug other USB storage first.

`posh-flasher` is a small, inspectable Windows PowerShell 5.1 utility for writing a publisher-provided Linux hybrid ISO to a USB disk. It is intentionally not a general partition editor, bootloader installer, downloader, or persistence tool.

The goal is simple: make the dangerous part visible. The script is one PowerShell file, uses a short C# interop block compiled in memory, writes through one reviewed path, and can read every written byte back for comparison.

## Supported environments

| Item | Supported |
|---|---|
| OS | Windows 10 and Windows 11 (developed on Windows 11 Pro) |
| PowerShell | Windows PowerShell 5.1 only. PowerShell 7 is not supported or tested. |
| Privileges | Elevated (Administrator) |
| Target | A disk whose Win32 interface is `USB` and whose media type is `Removable Media`, `External hard disk media`, or `Fixed hard disk media` |
| Image | Local `.iso` on a non-network path with an ISO 9660 signature, a whole number of logical sectors, no larger than the target |

Not supported: non-USB disks, boot/system disks, SD readers that do not present as USB, USB devices that report an unknown media type, network or reparse-point images, and non-hybrid ISOs.

USB controller families: the author has only the sample evidence listed under *Hardware validation record*. Treat everything else as unverified.

## Quick start

Run the script without image or disk parameters. It asks for the ISO path, lists eligible USB disks, and requires an explicit `Y` before selecting the only eligible disk. If no USB disk is present, insert one and press Enter to rescan.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Write-LinuxUsb.ps1 -Verify -ShowHash
```

The default image path is `C:\ISO\linux-installer.iso`. Press Enter to accept it or type another path.

For automation or a known target:

```powershell
.\Write-LinuxUsb.ps1 -ImageFile 'C:\ISO\linux-installer.iso' -DiskNumber 3 -Verify -LogPath .\flash.jsonl
.\Write-LinuxUsb.ps1 -ListDisks
.\Write-LinuxUsb.ps1 -ImageFile 'C:\ISO\linux-installer.iso' -WhatIf -ShowHash
```

`-WhatIf` validates and displays the source and selected target but opens no raw handles and writes nothing. `-ShowHash` prints the source SHA-256. `-Verify` performs a bounded byte-for-byte read-back check. `-VerifyOnly` compares an existing disk with the image without writing. `-LogPath` appends JSON-lines audit records; `-Verbose` adds a selection/volume/cleanup trace.

### Confirmation

Before any raw handle is opened you see the mode, image path and size, and the full target identity, then must type a phrase that includes the disk's identity:

```
ERASE DISK 3 SERIAL 1234XYZ
```

(`VERIFY DISK ...` for `-VerifyOnly`; `ID` replaces `SERIAL` for disks with no serial number.) Disk number alone is not accepted, and this applies even when `-DiskNumber` is given.

## What it does while writing

1. Validates the image, selects the target, and snapshots its identity (number, bus, model, serial, unique ID, GUID, size, sector size, partition layout).
2. After confirmation, re-queries the disk and aborts if **any** field changed, naming the field.
3. Temporarily disables Windows automount, then locks and dismounts the target's volumes. Re-checks identity again.
4. Opens the physical disk (one code path only), writes from byte zero, flushes, and optionally reads back and compares.
5. Re-queries the disk for identity drift and unexpected newly mounted partitions.
6. Cleans up in a fixed order (raw handle, volume handles, image file, automount). If anything fails to release or restore, it prints recovery steps.

A failure after writing starts can leave a partial image. The script does not retry, repair, clear disk tail data, or edit partitions.

## Errors

Failures throw with a category in `$_.Exception.Category`, so callers need not parse messages: `InvalidTarget`, `InvalidImage`, `HardwareMismatch`, `LockFailure`, `WriteFailure`, `VerifyFailure`, `CleanupFailure`, `UserDeclined`.

## Known failure modes

- **Image rejected**: zero-byte, sparse, hidden/system, extra alternate data streams (the normal `Zone.Identifier` is allowed), executable header, no ISO 9660 signature, or not a multiple of the sector size. Some UDF-only images lack the signature and are refused.
- **Device rejected as unknown class**: a few USB bridges report an empty or unusual media type. The script fails closed.
- **Lock failure**: another program (Explorer window, antivirus, backup tool) holds a volume on the target. Close it and retry.
- **Disk metadata changed**: the device re-enumerated or was swapped. Nothing is written; start over.
- **Mid-write failure** (unplug, bad sector, USB reset): the disk holds a partial image and must be rewritten.
- **Cleanup failure**: if automount could not be restored, run `mountvol /E` in an elevated prompt; close the PowerShell session to release stray handles, then unplug and reinsert the disk.
- **Image changed during write**: reported as an error; treat the disk as invalid.

## Script map

Every major section begins with a searchable marker in this exact form: `# 'Step x - Do y'`.

| Marker | Why it exists |
|---|---|
| Step 1 – Load the small, visible Win32 interop layer | Declares only the Windows calls needed for handles, raw I/O, volume controls, and Mount Manager, with grouped, commented constants. |
| Step 1b – Run state, audit log, and cleanup state | Explicit state objects; no hidden script-level state. |
| Step 2 – Inspect and select a safe USB target | Hardware seams, eligibility checks, identity snapshot/lock, interactive selection. |
| Step 3 – Resolve and validate the ISO source | Prompts for an ISO when needed and rejects unsafe source paths and files. |
| Step 4 – Copy and compare bounded byte buffers | Production copy and verification loops used by tests. |
| Step 5 – Open the confirmed physical disk and control automount | The only `PhysicalDriveN` open site, authorization gates, and `Invoke-RawDiskOperation`. |
| Step 6 – Lock and dismount target volumes before raw access | Maps volumes to physical disks, locks and dismounts only the target's volumes, and the always-attempted cleanup. |
| Step 7 – Confirm, write, verify, and clean up | Confirmation, post-write checks, orchestration, audit summary. |

## Tests and CI

No elevation, USB disk, download, or external module is needed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Write-LinuxUsb.ps1
```

Beyond copy/compare primitives, the suite uses simulated hardware to assert each failure path: identity changes at selection, after confirmation, after locking and after the write; unknown device class; lock failure; unexpected remount; automount-restore failure; declined confirmation; image rejections; and that no raw handle is opened without every safety gate. It does **not** touch real raw hardware. CI (`.github/workflows/ci.yml`) also runs PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1`.

## Releases

`tools/New-ReleaseManifest.ps1` writes `SHA256SUMS` for the release files and can Authenticode-sign the script (`-CertThumbprint`). Verify a download with `Get-FileHash` against `SHA256SUMS`. See [CHANGELOG.md](CHANGELOG.md).

## Hardware validation record

This is **sample evidence from the author's own hardware, not a certification.** Hardware results do not guarantee every image, port, controller, or computer will behave the same way.

| Image | Device | Controller / port | OS | Result |
|---|---|---|---|---|
| Linux Mint 22.3 Xfce (`3,033,710,592` bytes) | SanDisk Ultra, serial ending `1473` | Not recorded | Windows 11 | Written and verified byte-for-byte; booted on an ASUS UX331U laptop (UEFI) (pre-1.0.0) |
| Linux Mint 22.3 Xfce (`3,033,710,592` bytes) | SanDisk Ultra, serial ending `1450` | Not recorded | Windows 11 | Written and verified byte-for-byte; booted on an ASUS UX331U laptop (pre-1.0.0) |
| Xubuntu 26.10 desktop (`5,282,123,776` bytes) | SanDisk Ultra (15.7 GB, USB), serial ending `1473` | Not recorded | Windows 11 | **1.0.0:** audit outcome `Success`; identity unchanged before and after; cleanup succeeded with no failures; booted an ASUS UX331U laptop |

The first two rows predate the 1.0.0 hardening pass. The third row is the first recorded real-hardware run of 1.0.0 (2026-11-24). It covers one device and one image, all boot tests were on the same ASUS UX331U laptop. No failures were noted in these runs.

## License

MIT © Jim Lehmer. See [LICENSE](LICENSE).
