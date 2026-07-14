# Sandbox

Experimental helper scripts, provided as-is, without warranty or official Iru support. Sandbox scripts have not gone through the review and validation applied to the official [Iru WindowsScripts](../Iru%20WindowsScripts/). Review the code and validate on test hardware before any production use.

## Script index

| Folder | Purpose |
|---|---|
| [`Add-CUPS-IPP-Printer/`](./Add-CUPS-IPP-Printer/) | Adds a driverless (IPP Everywhere) printer pointing at an onsite CUPS print server, using the in-box Microsoft IPP Class Driver. Idempotent, audit-and-remediate pattern. |
| [`Block-RemovableStorage/`](./Block-RemovableStorage/) | Blocks access to all removable storage classes at the access layer via the machine-level "Removable Storage Access" policies — FullBlock (deny everything) or ReadOnly (deny writes) postures, Audit/Enforce/Discover/Revert. The no-allowlist complement to `Manage-UsbStorageRestrictions`. |
| [`BrowserShortcuts/`](./BrowserShortcuts/) | Pushes browser shortcuts to the all-users desktop. An Audit + Remediate script **pair** — `Audit-BrowserShortcuts.ps1` checks the expected shortcuts, `Remediate-BrowserShortcuts.ps1` creates, repairs, or removes them — matching the Iru Custom Script audit/remediation fields. |
| [`CreateLocalAdmin/`](./CreateLocalAdmin/) | Creates a local administrator account on a Windows endpoint, idempotently, using the well-known Administrators SID for language-neutral compatibility. Designed for MDM deployment. |
| [`Grant-OktaSCEPPrivateKeyAccess/`](./Grant-OktaSCEPPrivateKeyAccess/) | Companion to a full Okta Device Trust via Iru SCEP guide: grants the logged-in user read access to the SCEP certificate's private key when the certificate lands in the Local Machine store. |
| [`Manage-ChromeCBCMEnrollment/`](./Manage-ChromeCBCMEnrollment/) | Enrolls Chrome on Windows into Chrome Browser Cloud Management by writing the Chrome Enterprise Core enrollment token to the machine-level Chrome policy key, so Chrome policy is managed centrally from Google Admin until native ADMX support lands in Iru. |
| [`Manage-DeviceName/`](./Manage-DeviceName/) | Renames devices to match a configurable token-based naming template (serial, asset tag, chassis, random digits), replicating the Intune Autopilot device name template and Rename device action. |
| [`Manage-UsbStorageRestrictions/`](./Manage-UsbStorageRestrictions/) | Blocks USB mass storage while keeping non-storage USB peripherals functional, with a device-instance-ID allowlist. Replicates the Intune Device Installation restriction policies. |
| [`Manage-WindowsHelloforBusiness/`](./Manage-WindowsHelloforBusiness/) | Manages Windows Hello for Business policy via GPO-equivalent registry keys, replicating the Intune WHfB settings catalog category. Audit and Enforce modes. |
| [`SetLocalAdminPassword/`](./SetLocalAdminPassword/) | LAPS-style local admin password rotation: generates a random password, sets it on the local admin account, and stores it in the device's notes via the Iru API. |

## Documentation only — `CustomApps/`

No scripts here — these are Iru **Custom App** packaging guides:

| Guide | Purpose |
|---|---|
| [`CustomApps/MakeMeAdmin/`](./CustomApps/MakeMeAdmin/Makemeadmincustomappreadme.md) | Installing, configuring, and maintaining Make Me Admin on managed Windows devices via an Iru Custom App Library Item. |
| [`CustomApps/Notion/`](./CustomApps/Notion/Notioncustomappreadme.md) | Installing and maintaining the Notion desktop app on managed Windows devices via an Iru Custom App Library Item. |
