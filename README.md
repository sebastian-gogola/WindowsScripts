# Block-RemovableStorage

A PowerShell script for blocking (or unblocking) access to removable storage on Windows endpoints. Built for deployment via MDM, RMM, or configuration-management tooling, with elevation checks, logging, and standard exit codes for deployment reporting.

It uses the machine-level **Removable Storage Access** policies, which cover every removable storage class at once — USB removable disks, CD/DVD, floppy, tape, and Windows Portable Devices (phones, MTP cameras) — rather than only disabling the USB mass-storage driver.

## Features

- **Full block** of all removable storage read/write/execute access
- **Read-only mode** that denies writes only (useful for preventing data exfiltration while still allowing vendor media to be read)
- **Optional USBSTOR driver disable** for defense in depth
- **Clean revert** that removes all policies and restores defaults
- Administrator/elevation check
- Logging to `%ProgramData%\EndpointSecurity\`
- Standard exit codes for deployment-status reporting
- Automatic group policy refresh

## Requirements

- Windows with PowerShell 5.1 or later
- Administrator privileges (most MDM/RMM tools run scripts as `SYSTEM`, which satisfies this)

## Usage

```powershell
# Full block — all read/write access denied to all removable storage classes
.\Block-RemovableStorage.ps1

# Read-only — block writes but still allow reads
.\Block-RemovableStorage.ps1 -ReadOnly

# Full block AND disable the USB mass-storage driver
.\Block-RemovableStorage.ps1 -DisableUSBSTOR

# Revert — remove all blocking and restore normal access
.\Block-RemovableStorage.ps1 -Revert
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-Revert` | Removes the blocking policies and restores the USBSTOR driver to its default state. |
| `-DisableUSBSTOR` | Also disables the USB mass-storage driver service (`Start = 4`). Ignored when `-Revert` is used. |
| `-ReadOnly` | Denies write access only; reads remain permitted. Cannot be combined with `-Revert`. |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Not running elevated |
| `2` | One or more registry operations failed |

These let your MDM/RMM platform report deployment success or failure per device.

## How it works

The script writes to two locations in the registry:

- **`HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices`** — the Removable Storage Access policy root. Setting `Deny_All = 1` blocks every removable class. Read-only mode instead sets `Deny_Write = 1` per device class.
- **`HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR`** — the USB mass-storage driver service, set to disabled (`4`) when `-DisableUSBSTOR` is passed and restored to default (`3`) on revert.

After applying changes, the script runs `gpupdate /target:computer /force` so currently connected devices are re-evaluated promptly.

## Logging

Actions are logged to:

```
%ProgramData%\EndpointSecurity\Block-RemovableStorage.log
```

Each entry is timestamped and tagged `INFO`, `WARN`, or `ERROR`.

## Deployment notes

- **Reboot / re-logon recommended.** The policy applies immediately to *newly connected* devices, but a reboot or user logoff/logon ensures it fully applies to devices already in session.
- **Test against a pilot group first.** `Deny_All` is machine-wide and will also block USB optical drives and phone storage/tethering. Roll out in rings.
- **`SYSTEM` context.** Many MDM/RMM platforms execute scripts as `SYSTEM`, which is already elevated, so the admin check passes cleanly.
- **Allow-listing approved devices.** This script blocks broadly. If you need to permit specific approved devices (e.g. encrypted corporate USB drives) while blocking everything else, that requires an allow-list by device instance/hardware ID — best handled through your MDM's native device-control feature where available.

## Reverting

```powershell
.\Block-RemovableStorage.ps1 -Revert
```

This removes all `Deny_All` / `Deny_Write` / `Deny_Read` / `Deny_Execute` values, and restores the USBSTOR driver to its default manual-start state.

## License

Add your license of choice (e.g. MIT) here.
