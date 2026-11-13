# posh-flasher

`posh-flasher` is a small, inspectable Windows PowerShell 5.1 utility for writing a publisher-provided Linux hybrid ISO to a USB disk. It is intentionally not a general partition editor, bootloader installer, downloader, or persistence tool.

The goal is simple: make the dangerous part visible. The script is one PowerShell file, uses a short C# interop block compiled in memory, writes through one reviewed path, and can read every written byte back for comparison.

## Requirements

- Windows PowerShell 5.1, run as Administrator.
- A disposable USB disk. All data and its current layout will be destroyed.
- A Linux ISO that its publisher documents as suitable for direct USB writing.

The script rejects non-USB disks, boot/system disks, read-only or offline disks, remote image paths, reparse points, unaligned images, uncertain device identities, and disks that are too small.

## Quick start

Run the script without image or disk parameters. It proposes a default ISO path, asks for the actual path, lists eligible USB disks, and requires an explicit `Y` before selecting the only eligible disk. If no USB disk is present, insert one and press Enter to rescan.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Write-LinuxUsb.ps1 -Verify -ShowHash
```

The default image path is `C:\ISO\linux-installer.iso`. Press Enter to accept it or type another local `.iso` path. The script then requires the exact phrase `ERASE DISK N` before it opens raw handles.

For automation or a known target, pass either or both values explicitly:

```powershell
.\Write-LinuxUsb.ps1 -ImageFile 'C:\ISO\linux-installer.iso' -DiskNumber 3 -Verify
.\Write-LinuxUsb.ps1 -ListDisks
.\Write-LinuxUsb.ps1 -ImageFile 'C:\ISO\linux-installer.iso' -WhatIf -ShowHash
```

`-WhatIf` validates and displays the source and selected target but opens no raw handles and writes nothing. `-ShowHash` prints the source SHA-256 for comparison with the publisher checksum. `-Verify` performs a bounded byte-for-byte read-back check. `-VerifyOnly` checks an existing image without writing it.

## What it does while writing

The script temporarily disables Windows automount, locks and dismounts target volumes, writes the ISO from byte zero, flushes the disk, and optionally verifies the same byte length. It restores automount during cleanup. A failure after writing starts can leave a partial image. The script does not retry, repair, clear disk tail data, or edit partitions automatically.

## Script map

Every major section begins with a searchable marker in this exact form: `# 'Step x - Do y'`.

| Marker | Why it exists |
|---|---|
| Step 1 – Load the small, visible Win32 interop layer | Declares only the Windows calls needed for handles, raw I/O, volume controls, and Mount Manager. |
| Step 2 – Inspect and select a safe USB target | Filters to eligible USB disks and provides the interactive rescan/select loop. |
| Step 3 – Resolve and validate the ISO source | Prompts for an ISO when needed and rejects unsafe source paths. |
| Step 4 – Copy and compare bounded byte buffers | Contains the production copy and verification loops used by tests. |
| Step 5 – Open the confirmed physical disk and control automount | Opens `PhysicalDriveN` exclusively and prevents newly written ISO partitions from mounting mid-write. |
| Step 6 – Lock and dismount target volumes before raw access | Maps volumes to physical disks, then locks and dismounts only the selected target’s volumes. |
| Step 7 – Confirm, write, verify, and clean up | Rechecks identity, asks for the destructive phrase, writes, verifies, and releases every handle. |

## Tests

The ordinary-file test suite needs no elevation, USB disk, download, or external module:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Write-LinuxUsb.ps1
```

It exercises bounded copying, final partial buffers, comparison, mismatch offsets, short input, injected write errors, changed identities, and refusal metadata. It does not test raw hardware I/O.

## Hardware validation record

Linux Mint 22.3 Xfce was successfully written and verified byte-for-byte for `3,033,710,592` bytes on these USB devices:

- SanDisk Ultra, serial ending `1473` — UEFI boot confirmed.
- SanDisk Ultra, serial ending `1450` — UEFI boot confirmed.
- JetFlash Transcend 4GB, serial `AA00000000000485` — UEFI boot confirmed.

Hardware results do not guarantee every image, port, controller, or computer will behave the same way.

## License

MIT © Jim Lehmer. See [LICENSE](LICENSE).
