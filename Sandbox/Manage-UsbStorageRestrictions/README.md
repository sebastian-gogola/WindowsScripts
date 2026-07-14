# Manage-UsbStorageRestrictions.ps1

Blocks USB mass storage devices (flash drives, external HDD/SSD, card readers) while leaving non-storage USB peripherals — headsets, keyboards, mice, webcams, docks — fully functional, with an allowlist for sanctioned storage devices. Replicates the Intune Settings Catalog **Device Installation** restriction policies for Windows endpoints managed by Iru, where no GUI CSP configuration exists.

- **Script:** `Manage-UsbStorageRestrictions.ps1` (v1.0.0)
- **Target OS:** Windows 10 2004+ / Windows 11 (Iru-managed 24H2/25H2 fleets satisfy every build gate below)
- **Runs as:** SYSTEM (Iru Custom Script) or elevated admin shell
- **PowerShell:** 5.1, no external modules

---

## Why this CSP and not ADMX_RemovableStorage

The question that prompted this solution: is [Policy CSP – ADMX_RemovableStorage](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-removablestorage) the right documentation for a script that blocks USB storage but supports hardware-identifier exclusions?

**No — it covers the wrong control for the exclusion requirement.** Windows has two separate mechanisms here, and they are frequently conflated:

| | Removable Storage Access (`ADMX_RemovableStorage`) | Device Installation Restrictions (`DeviceInstallation`) |
|---|---|---|
| What it controls | Read/Write/Execute **access** to already-installed removable storage, per storage *class* (Removable Disks, CD/DVD, WPD, Tape, Floppy) | Whether a device's driver may **install** at all, evaluated by the PnP manager per device identifier |
| Granularity | Class-level only (`Deny_Read`, `Deny_Write`, `Deny_Execute` per class GUID) | Setup class GUIDs, hardware/compatible IDs, and per-unit device **instance IDs** |
| Per-device exclusions | **None.** There is no allowlist mechanism anywhere in this CSP | **Yes** — Allow lists at every tier, with a documented layered precedence model |
| Registry store | `HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{classGUID}` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions` |
| Non-storage peripherals | Unaffected (it only addresses storage classes) | Unaffected by this design (see below) |

`ADMX_RemovableStorage` is the right tool for a blunt, no-exceptions "nobody reads/writes removable disks" posture — that's what the earlier `Block-RemovableStorage.ps1` in this repo implements. The moment the requirement includes *"…except these sanctioned devices,"* the correct documentation is:

- [Policy CSP – DeviceInstallation](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-deviceinstallation) — the policy reference this script implements
- [Manage Device Installation with Group Policy](https://learn.microsoft.com/en-us/windows/client-management/client-tools/manage-device-installation-with-group-policy) — Microsoft's scenario guide, including the block-all/allow-one-thumb-drive pattern

> **Do not run both mechanisms together.** A `RemovableStorageDevices` class deny (or Intune's "Removable storage: Block") sits at the access layer and has no exclusion mechanism — it will block your allowlisted drives even though their installation succeeds. If migrating a tenant that used the Intune removable-storage block, retire that policy before (or when) deploying this one.

---

## How enforcement works

Device Installation Restrictions are evaluated by the PnP manager directly from the GPO policy store in the registry. Writing those values with a script is functionally equivalent to setting them via GPO or Intune — all three populate the same key, and enforcement does not depend on a Group Policy client or MDM sync.

The design uses two tiers of the documented evaluation hierarchy:

```
Device instance IDs  >  Device IDs  >  Device setup class  >  Removable devices
        ▲ Allow             ▲ Deny            ▲ Deny (optional)
   (sanctioned units)  (USB\Class_08)        (WPD GUID)
```

1. **Deny at the Device IDs tier — compatible ID `USB\Class_08`.** Every USB mass-storage *function* device — BOT flash drives, UASP enclosures, USB card readers, and the storage interface (`MI_xx`) of composite devices — carries `USB\Class_08` in its compatible ID list. This is a single choke point that:
   - never matches internal SATA/NVMe/RAID disks (they aren't USB-enumerated), which makes the retroactive flag **safe** here — unlike a Disk Drives class deny, where Microsoft explicitly warns a retroactive apply can prevent the machine from starting;
   - never matches audio (`Class_01`), HID (`Class_03`), or video (`Class_0E`) interfaces, so headsets and other peripherals are untouched;
   - is far narrower than the "Prevent installation of removable devices" policy, whose documentation states drivers report *all* USB-connected devices as removable — that policy would block a USB headset's first installation.

2. **Allow at the Device instance IDs tier — sanctioned units.** Instance IDs (`USB\VID_xxxx&PID_xxxx\<serial>`) identify one physical device. Per the CSP documentation for `PreventInstallationOfMatchingDeviceIDs`, the *only* Allow policy that can supersede a device-ID deny is the instance-ID Allow, and only when layering is enabled.

3. **`AllowDenyLayered = 1`, always.** Without layered evaluation, the documented default is that every Prevent policy takes precedence over every Allow policy — the allowlist would be dead weight. The script refuses to apply an allowlist on builds that predate layering support rather than silently shipping a config that blocks sanctioned devices.

4. **Optional WPD class deny.** MTP/PTP (phones, cameras) is the classic bypass for a storage-only block: a phone mounts as a Portable Device, not mass storage. `$BlockPortableDevices = $true` denies the Windows Portable Devices setup class `{eec5ad98-8080-425f-922a-dabf3de3f69a}`. Because this deny sits at the *class* tier, both instance-ID **and** model-level hardware-ID allows can supersede it. Phone charging is unaffected.

5. **Retroactive + active sweep.** Installation restrictions only gate *new* installations by default. `$ApplyToExistingDevices = $true` sets the documented retroactive flags **and** immediately removes currently attached, non-allowlisted matches via `pnputil /remove-device` (falling back to `Disable-PnpDevice`), so enforcement doesn't wait for the next replug. A reboot guarantees full retroactive coverage of anything installed before the policy landed.

### Why Microsoft's Scenario 5 was not used

The scenario guide's "prevent all USB devices, allow one thumb drive" pattern denies the entire USB setup class and then requires allowlisting the machine's hubs and controllers (`PCI\CC_0C03`, `USB\ROOT_HUB30`, `USB\USB20_HUB`, …) to keep the bus alive. That is fragile (hub IDs vary by hardware), and any omission takes out every USB peripheral — the exact opposite of the "headsets keep working" requirement. Denying only `USB\Class_08` makes the hub/controller allowlist unnecessary because the bus infrastructure is never in scope.

---

## Policy mapping: Settings Catalog → CSP → registry

Everything the script writes lives under `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions`. List policies use a subkey of the same name holding numbered `REG_SZ` values (`1`, `2`, …). GPO equivalents are under **Computer Configuration > Administrative Templates > System > Device Installation > Device Installation Restrictions**; Intune Settings Catalog exposes the same friendly names under the **Device Installation** category.

| Settings Catalog / GPO name | CSP node (`./Device/Vendor/MSFT/Policy/Config/DeviceInstallation/…`) | Registry value | Min. OS |
|---|---|---|---|
| Apply layered order of evaluation for Allow and Prevent device installation policies across all device match criteria | `EnableInstallationPolicyLayering` | `AllowDenyLayered` (DWORD) | 17763.2145 / 18362.1714 / 19041.1151 / 20348.256 / 22000+ |
| Prevent installation of devices that match any of these device IDs | `PreventInstallationOfMatchingDeviceIDs` | `DenyDeviceIDs` (DWORD) + `DenyDeviceIDs\` subkey | 10.0.15063 |
| — "Also apply to matching devices that are already installed" | (element `DeviceInstall_IDs_Deny_Retroactive`) | `DenyDeviceIDsRetroactive` (DWORD) | — |
| Prevent installation of devices using drivers that match these device setup classes | `PreventInstallationOfMatchingDeviceSetupClasses` | `DenyDeviceClasses` (DWORD) + `DenyDeviceClasses\` subkey | 10.0.15063 |
| — retroactive checkbox | (element `DeviceInstall_Classes_Deny_Retroactive`) | `DenyDeviceClassesRetroactive` (DWORD) | — |
| Allow installation of devices that match any of these device instance IDs | `AllowInstallationOfMatchingDeviceInstanceIDs` | `AllowInstanceIDs` (DWORD) + `AllowInstanceIDs\` subkey | 10.0.19041 |
| Allow installation of devices that match any of these device IDs | `AllowInstallationOfMatchingDeviceIDs` | `AllowDeviceIDs` (DWORD) + `AllowDeviceIDs\` subkey | 10.0.17763 |
| Allow administrators to override Device Installation Restriction policies | *(ADMX/GPO + Settings Catalog only — no node on the DeviceInstallation CSP reference page)* | `AllowAdminInstall` (DWORD) | Vista+ (GPO) |

The script never touches `DenyInstanceIDs`, `DenyUnspecified`, or `DenyRemovableDevices`, so it can coexist with (and its Revert will not disturb) other tooling that manages those.

---

## Configuration reference

All settings are in the `CONFIGURATION` block at the top of the script — edit nothing below it.

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `'Enforce'` | `Enforce` \| `Audit` \| `Discover` \| `Revert` |
| `$BlockUsbMassStorage` | `$true` | The core control: deny compatible ID `USB\Class_08` |
| `$ApplyToExistingDevices` | `$true` | Set retroactive flags + sweep attached non-allowlisted matches |
| `$BlockPortableDevices` | `$false` | Also deny the WPD setup class (MTP/PTP phones, cameras) |
| `$AllowedInstanceIds` | `@()` | Per-unit exemptions — **the only allow type that beats the mass-storage deny** |
| `$AllowedHardwareIds` | `@()` | Model-level (VID&PID) exemptions — effective against the WPD class deny **only** (see precedence below) |
| `$AllowAdminOverride` | `$false` | Local Administrators may install any device despite restrictions |
| `$LogDirectory` / `$LogFile` | `%ProgramData%\IruScripts\Logs\…` | Timestamped log, appended per run |

### Precedence rules you must respect when populating the allowlists

Straight from the documented model — this is the part that silently breaks naive configurations:

- **Instance-ID Allow → beats the `USB\Class_08` deny** (higher tier, layering on). This is the supported exemption path for storage.
- **Hardware-ID Allow (e.g. `USB\VID_0781&PID_5575`) → does NOT beat the `USB\Class_08` deny.** Both live in the same *Device IDs* tier, and within a tier Prevent wins. The CSP text for the device-ID deny names only the instance-ID Allow as capable of superseding it. The script logs a WARN if you configure `$AllowedHardwareIds` alongside the mass-storage block so this can't fail silently.
- **Hardware-ID Allow → DOES beat the WPD class deny** (device-ID tier > class tier). Use this to allow, say, all corporate iPhones through `$BlockPortableDevices` without enumerating serials.
- **Without layering, no Allow beats any Prevent.** The script hard-fails (exit 2) if an allowlist is configured on a build that can't do layered evaluation, rather than blocking sanctioned devices.

---

## Capturing device identifiers

1. Plug the device to sanction into any managed test machine (before enforcement, or an exempt machine).
2. Run the script with `$Mode = 'Discover'` in an elevated shell. It enumerates every present device carrying `USB\Class_08` (plus WPD devices) and prints a paste-ready `$AllowedInstanceIds = @(...)` block.
3. Alternatives: `pnputil /enum-devices /ids`, or Device Manager → device → **Details** tab → *Device instance path* / *Hardware Ids* properties.

Rules of thumb, all consequential:

- **Allowlist the USB parent (function) device**, e.g. `USB\VID_0781&PID_5575\4C53000123…` — not the child `USBSTOR\Disk…` node. The deny fires at the parent; if only the child is allowed, the parent never installs and the child never exists. For composite devices, the storage *interface* (`…&MI_00\…`) is the node to allow.
- **Serial-less drives get port-generated instance paths** (recognizable by an `&`-prefixed segment after the final `\`, e.g. `…\7&2f4a1b3c&0&0000`). These change when the drive moves to another port or machine. Discover mode flags them; standardize on serialized drives (most reputable business-line sticks) for the sanctioned pool.
- **Test multiple physical units** of the same model before rollout — Microsoft's own guidance in the CSP reference. Two "identical" SKUs can present different identifiers across firmware revisions.

---

## Deploying via Iru

Deploy as a **Custom Script** Library Item using the audit-and-remediate pattern, same as the other `Manage-*.ps1` scripts in this repo:

1. **Audit script slot:** the full script with `$Mode = 'Audit'`. Exit 0 = compliant, exit 1 = drift → triggers remediation.
2. **Remediation script slot:** the identical script with `$Mode = 'Enforce'`.
3. Runs as `NT AUTHORITY\SYSTEM` (satisfies the elevation gate). Schedule per blueprint — daily is a sensible default for a security control.
4. Populate `$AllowedInstanceIds` identically in both slots (the audit compares the live registry against *its own* config).

**Intune/GPO overlap during migration.** Intune's Device Installation policies and AD GPO write these same registry values; whichever engine syncs last wins. During a migration window where a device is still Intune-enrolled or domain-GPO-managed, expect churn — the recurring Iru execution self-heals on the next audit/remediation cycle, but the clean sequence is: remove the Intune/GPO device-installation policies (or unenroll), then let this item converge. The audit output makes any tug-of-war visible in the Iru console.

---

## Verification & troubleshooting

**Confirm the policy engine is evaluating restrictions.** After a device-installation attempt, `C:\Windows\INF\setupapi.dev.log` contains a `[Device Installation Restrictions Policy Check]` section near the relevant install transaction — the documented verification for every policy in this CSP.

**What a blocked user sees.** Plugging an unapproved stick yields no drive letter; Device Manager shows the device with an error, classically *"The installation of this device is forbidden by system policy. Contact your system administrator."*

**Re-allowing a device after the fact.** Add its instance ID to `$AllowedInstanceIds` in both Library Item slots → let remediation run (or run Enforce manually) → replug the device or run `pnputil /scan-devices`. The retroactive deny does not fight the allow: with layering, the instance-tier Allow supersedes, and Microsoft's own scenarios show an allowed device surviving a retroactive class deny.

**Timing.** New installation attempts are evaluated the moment the registry values exist — no gpupdate, no MDM sync. Retroactive application to devices installed *before* the policy is guaranteed complete after a reboot; the script's active sweep covers currently attached devices immediately.

**Internal SD readers.** Some laptop card readers are internally USB-attached and legitimately match `USB\Class_08`. That is technically correct for "block USB storage," but if a fleet needs them, capture their instance IDs with Discover mode and allowlist them.

### Behavior matrix (recommended acceptance tests)

| Test | Expected |
|---|---|
| Unapproved USB flash drive (BOT) | Blocked: no volume, policy error in Device Manager, setupapi.dev.log shows restriction check |
| Unapproved UASP enclosure / NVMe bridge | Blocked (Class_08 covers UASP) |
| Allowlisted drive (instance ID present) | Installs and mounts normally, survives re-runs and reboots |
| Allowlisted drive on a *different* unit of same model | Blocked — instance IDs are per-unit (expected; use hardware-ID allow only where the tier permits) |
| USB headset / keyboard / mouse / webcam | Unaffected, including first-time installation |
| Phone via MTP, `$BlockPortableDevices = $false` | Unaffected |
| Phone via MTP, `$BlockPortableDevices = $true` | Blocked unless instance-ID or hardware-ID allowlisted |
| Internal SATA/NVMe disk | Untouched in every configuration, including retroactive |
| `Revert` mode | All managed values/subkeys removed, devices reinstall on rescan/replug |

---

## Limitations & security notes

**This is installation control, not DLP.** It governs whether a devnode may install/start — not what an already-authorized device may read or write. It cannot do read-only-except-encrypted, file-type filtering, or audit-with-evidence.

**Instance IDs are asserted by the device.** A programmable (BadUSB-class) device can present a sanctioned VID/PID/serial. This control raises the bar for casual exfiltration and honest-user policy compliance; it does not defeat a capable attacker with physical access. Where serial-verified enforcement with auditing is a hard requirement, the native step up is Microsoft Defender for Endpoint **Device Control** (licensed, policy-XML based) or a dedicated device-control product — positioning this script as the zero-additional-license baseline is the honest pre-sales framing.

**Sole-manager assumption.** Enforce rewrites the numbered entries of the four managed lists to match its config (foreign non-numeric values are preserved and flagged). Revert removes only the eight values and four subkeys it owns. If another tool actively manages the same lists, coordinate — last writer wins.

**Installation vs. usage edge:** a device that was installed *and remains attached* through the policy landing keeps working until the retroactive pass (sweep or reboot) removes it. Plan the rollout with `$ApplyToExistingDevices = $true` unless a grace period is intentional.

---

## Rollback

Set `$Mode = 'Revert'` and run once (or push as a one-time Iru script). It deletes exactly the values and subkeys listed in the mapping table, removes the state stamp at `HKLM\SOFTWARE\IruScripts\UsbStorageRestrictions`, then runs `pnputil /scan-devices` so previously removed devices reinstall. Devices removed by the sweep also reinstall on physical replug.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (Enforce/Revert/Discover) or compliant (Audit) |
| 1 | Drift detected (Audit) or one or more runtime operations failed |
| 2 | Precondition failure: not elevated, or the OS build cannot honor a configured allowlist (missing instance-ID policy or layering support) |

---

## Sourcing notes

Vendor-documented (Microsoft Learn), and the basis for every registry value name, CSP node, OS gate, and precedence claim above:

- [Policy CSP – DeviceInstallation](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-deviceinstallation) — ADMX mappings (registry value names incl. `AllowDenyLayered`, `AllowInstanceIDs`), per-policy OS availability incl. the layering backport builds (17763.2145 / 18362.1714 / 19041.1151 / 20348.256 / 22000), the layered hierarchy definition, which Allow policies may supersede which Prevent policies, SyncML retroactive elements, and the `setupapi.dev.log` verification.
- [Manage Device Installation with Group Policy](https://learn.microsoft.com/en-us/windows/client-management/client-tools/manage-device-installation-with-group-policy) — scenario patterns (incl. Scenario 5's hub/controller allowlist requirement, which this design avoids), the warning that a retroactive Disk Drives class deny can prevent boot, the note that "Prevent installation of removable devices" treats all USB-connected devices as removable, and allowed-device survival under retroactive class denies.
- [Policy CSP – ADMX_RemovableStorage](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-removablestorage) — confirms that CSP is class-level access denies (`Deny_Read`/`Deny_Write`/`Deny_Execute` under `RemovableStorageDevices\{classGUID}`) with no exclusion mechanism.
- [Device instance IDs](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/device-instance-ids) and [Device identifier formats](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/device-identifier-formats) — identifier structure referenced by the CSP.

Field-observed / inferred (flagged as such, verify in your environment):

- `DenyDeviceIDsRetroactive` / `DenyDeviceClassesRetroactive` as the registry value names behind the retroactive checkboxes: consistent across ADMX reference listings and community documentation; the CSP page shows the SyncML element (`DeviceInstall_IDs_Deny_Retroactive`) rather than the registry value name.
- `AllowAdminInstall` (admin override) is documented in the GPO/ADMX space and Settings Catalog but has no entry on the DeviceInstallation CSP reference page.
- The exact wording of the end-user "forbidden by system policy" error and the port-generated instance-path heuristic (`\<digit>&…` suffix) are field observations, not spec.
