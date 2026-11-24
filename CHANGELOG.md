# Changelog

> **UNSAFE OPERATION:** every release of this tool writes raw bytes to a physical disk and destroys its contents. Read the README warning before running.

## 1.0.0

Hardening and release-readiness pass (see `plans/productionify.md`). Validated on real hardware: SanDisk Ultra USB, Xubuntu 26.10, 2026-11-24 (see README).

Safety
- Full target identity lock (number, bus, model, serial, unique ID, GUID, size, sector size, partition layout) re-checked after confirmation, after volume lock, and (hardware fields) after the write. Any difference aborts with the changed field named.
- Confirmation phrase now includes the disk identity: `ERASE DISK 3 SERIAL 1234XYZ` (`VERIFY DISK ...` for `-VerifyOnly`). The number-only phrase is no longer accepted.
- Single raw-disk path: `Open-RawDisk` is the only `PhysicalDriveN` open site and is reachable only through `Invoke-RawDiskOperation`, which requires every safety gate to have passed.
- Stronger device-class checks (USB interface and a recognised media type); unknown classes are refused.
- Stronger image checks: zero-byte, sparse, hidden/system, alternate data streams (Zone.Identifier tolerated), executable headers, missing ISO 9660 signature, and change-during-write detection.
- Cleanup is a fixed-order, always-attempted step with recovery guidance printed on failure; a cleanup failure after a successful write is reported as an error.
- Post-operation re-query for identity drift and unexpected newly mounted partitions.

Maintainability
- Explicit run-state object instead of `$script:` state; typed/validated helper signatures; named, grouped Win32 constants.
- Error categories on `$_.Exception.Category`: `InvalidTarget`, `InvalidImage`, `HardwareMismatch`, `LockFailure`, `WriteFailure`, `VerifyFailure`, `CleanupFailure`, `UserDeclined`.
- Mockable hardware seams; failure-path tests that need no USB disk.
- PSScriptAnalyzer + tests in CI.

Supportability
- `-LogPath` JSON-lines audit log, a final `AUDIT:` summary record, and `-Verbose` tracing.

Release
- `tools/New-ReleaseManifest.ps1` produces `SHA256SUMS` and can Authenticode-sign the script.
- Not done: packaging as a module (kept as one auditable file on purpose).
