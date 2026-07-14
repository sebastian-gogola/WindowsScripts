# WindowsScripts

PowerShell scripts for Windows device management and automation on the [Iru](https://www.iru.com) MDM platform (formerly Kandji).

## Repository layout — two tiers

| Folder | What it is |
|---|---|
| [`Iru WindowsScripts/`](./Iru%20WindowsScripts/) | **Official scripts** from Iru engineers. |
| [`Sandbox/`](./Sandbox/) | **Experimental helper scripts**, provided as-is without warranty or official Iru support. Review and validate in a lab before any production use. |

## Official scripts (`Iru WindowsScripts/`)

| Script | Purpose |
|---|---|
| [`AppInstall.ps1`](./Iru%20WindowsScripts/AppInstall.ps1) | Downloads and installs MSI/EXE applications from public URLs (OneDrive, Google Drive, etc.), with download verification and optional uninstall of existing versions. See [`AppInstall.md`](./Iru%20WindowsScripts/AppInstall.md). |
| [`DeviceLock.ps1`](./Iru%20WindowsScripts/DeviceLock.ps1) | Quarantines (locks) a device by blocking all interactive and RDP logons via LSA policy, with a scheduled task that re-applies the lock to prevent drift. |
| [`DeviceUnlock.ps1`](./Iru%20WindowsScripts/DeviceUnlock.ps1) | Reverses the Iru device lock: removes the enforcement scheduled task and restores the baseline local security policy saved during the lock. |
| [`mdmmigration.ps1`](./Iru%20WindowsScripts/mdmmigration.ps1) | Unenrolls a device from its current MDM provider and enrolls it into Iru (Kandji), interactively or fully unattended. See [`mdmmigration.md`](./Iru%20WindowsScripts/mdmmigration.md). |

## Sandbox

Experimental helper scripts for common Windows management tasks (printers, USB restrictions, device naming, local admin management, and more). See the full index at [`Sandbox/README.md`](./Sandbox/README.md).
