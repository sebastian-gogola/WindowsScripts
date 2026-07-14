# Block-RemovableStorage.ps1

Blocks access to removable storage on Windows endpoints via the machine-level **Removable Storage Access** policies — either everything (`FullBlock`) or writes only (`ReadOnly`). Replicates the Intune Settings Catalog / GPO "Removable Storage Access" category (`RemovableStorage.admx`) for Windows endpoints managed by Iru. This is the **access-layer** control: it governs read/write access to storage that is already installed, across every removable class regardless of bus — the complement to [`Manage-UsbStorageRestrictions/`](../Manage-UsbStorageRestrictions/), which gates device *installation* and supports per-device allowlists.

- **Script:** `Block-RemovableStorage.ps1` (v2.0.0)
- **Target OS:** Windows 10 / Windows 11 (the registry policies themselves are long-standing GPO; see the mapping table for per-node CSP availability)
- **Runs as:** SYSTEM (Iru Custom Script) or elevated admin shell
- **PowerShell:** 5.1, no external modules

---

## Choosing the layer: this script vs. Manage-UsbStorageRestrictions

| | **Block-RemovableStorage** (this script) | **Manage-UsbStorageRestrictions** |
|---|---|---|
| Enforcement layer | **Access**: read/write denies evaluated when anything touches installed removable storage | **Installation**: PnP manager refuses to install matching devices |
| Scope | Every removable storage class regardless of bus — USB sticks, SD readers, CD/DVD (incl. SATA optical), floppy, tape, MTP/WPD | USB mass storage (+ optional WPD class) only |
| Read-only capability | **Yes** (`ReadOnly` posture: writes denied, reads allowed) | No — a device either installs or it doesn't |
| Per-device allowlist | **No.** There is no exclusion mechanism anywhere in these policies | **Yes** — per-unit instance-ID allowlist with documented layered precedence |
| Already-connected devices | Denied at the access layer (reboot/re-logon recommended for in-session devices) | Needs retroactive flags + active device sweep |

**Rule of thumb:** no exceptions needed → this script. "Block everything *except* these sanctioned drives" → Manage-UsbStorageRestrictions.

> **Do not run both mechanisms together.** An access-layer deny has no allowlist and no knowledge of the installation layer's exemptions: a device that Manage-UsbStorageRestrictions deliberately allowlists would install successfully and then be unreadable/unwritable anyway. Both blocking at once is not a *broken* state — the stricter control simply wins — but it silently defeats the allowlist's purpose. This script's Discover/Enforce/Audit modes detect active Device Installation Restrictions values and log a loud warning (see design decisions below). The same warning appears in the other script's README.

---

## Policy mapping: Settings Catalog → CSP/ADMX → registry

Everything the script writes lives under `HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices`. In GPO these are **Computer Configuration > Administrative Templates > System > Removable Storage Access**; the Intune Settings Catalog exposes the same friendly names. Most are ADMX-backed policies surfaced through the Policy CSP's `ADMX_RemovableStorage` area (no dedicated first-class CSP); two have dedicated `Storage` CSP nodes.

| Settings Catalog / GPO name | CSP node (`./Device/Vendor/MSFT/Policy/Config/…`) | Registry value | Written by posture |
|---|---|---|---|
| All Removable Storage classes: Deny all access | `ADMX_RemovableStorage/RemovableStorageClasses_DenyAll_Access_2` | `Deny_All` (DWORD) at the key root | `FullBlock` |
| Removable Disks: Deny write access | `Storage/RemovableDiskDenyWriteAccess` (dedicated node, Win10 1809+) | `{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}\Deny_Write` | `ReadOnly` |
| CD and DVD: Deny write access | `ADMX_RemovableStorage/CDandDVD_DenyWrite_Access_2` | `{53f56308-b6bf-11d0-94f2-00a0c91efb8b}\Deny_Write` | `ReadOnly` |
| Floppy Drives: Deny write access | `ADMX_RemovableStorage/FloppyDrives_DenyWrite_Access_2` | `{53f56311-b6bf-11d0-94f2-00a0c91efb8b}\Deny_Write` | `ReadOnly` |
| Tape Drives: Deny write access | `ADMX_RemovableStorage/TapeDrives_DenyWrite_Access_2` | `{53f5630b-b6bf-11d0-94f2-00a0c91efb8b}\Deny_Write` | `ReadOnly` |
| WPD Devices: Deny write access | `ADMX_RemovableStorage/WPDDevices_DenyWrite_Access_2`, also `Storage/WPDDevicesDenyWriteAccessPerDevice` (Win11 21H2+) | `{6AC27878-A6FA-4155-BA85-F98F491D4F33}\Deny_Write`, plus `{F33FDC04-D1AC-4E8E-9A30-19BBD4B108AE}\Deny_Write` (see note) | `ReadOnly` |

All node names, GUID subkeys, and value names above are **vendor-documented** on the two Microsoft Learn CSP pages linked in Sourcing notes — with one exception: the second WPD key `{F33FDC04-…}` appears on neither page. It is carried from the shipped `RemovableStorage.admx`, which writes the WPD policies to both GUID keys (**community-observed**; the GPO editor sets both). Writing it alongside the vendor-documented key matches what GPO produces.

The `Deny_All` precedence claim is vendor-documented: *"This policy setting takes precedence over any individual removable storage policy settings."* CSP-node availability dates (e.g. `RemovableStorageClasses_DenyAll_Access_2` requiring Win10 2004 + KB5005101) constrain **MDM SyncML** delivery only — this script writes the registry directly, the same store GPO has populated for far longer, so those gates don't apply to it (inferred from the delivery mechanism; the registry values themselves date back to Vista-era GPO).

---

## Configuration reference

All settings are in the `CONFIGURATION` block at the top of the script — edit nothing below it. Iru Custom Scripts run without parameters, so settings are variables.

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `'Enforce'` | `Enforce` \| `Audit` \| `Discover` \| `Revert` |
| `$Posture` | `'FullBlock'` | `FullBlock` (root `Deny_All=1`, everything denied) \| `ReadOnly` (per-class `Deny_Write=1`, reads allowed) |
| `$LogDirectory` / `$LogFile` | `%ProgramData%\IruScripts\Logs\Block-RemovableStorage.log` | Timestamped log, appended per run, mirrored to stdout |

Machine-local state (last-run metadata) is stamped under `HKLM\SOFTWARE\IruScripts\RemovableStorage` and removed by Revert.

### Modes & exit codes

| Mode | Does | Exit 0 | Exit 1 | Exit 2 |
|---|---|---|---|---|
| `Enforce` | Writes the configured posture's values, **removes the other posture's values** (posture switches converge, never accumulate), verifies every value | Applied & verified | Write/verify failure | Not elevated / invalid `$Posture` |
| `Audit` | Compares live state to `$Posture` — compliant only if the posture's values are exactly present **and** the other posture's values are absent | Compliant | Drift | Not elevated / invalid `$Posture` |
| `Discover` | Reports `Deny_All`, every per-class deny value (incl. foreign `Deny_Read`/`Deny_Execute`), the USBSTOR driver start type, and any active Device Installation Restrictions values | Report produced | Runtime failure | Not elevated |
| `Revert` | Removes `Deny_All`, all six `Deny_Write` values, prunes emptied class subkeys, removes the state key | Removed | Removal failure | Not elevated |

Design decisions, for the record:

- **Detecting active Manage-UsbStorageRestrictions policy during Enforce is a loud WARNING, not exit 2.** Both mechanisms denying at once is a coherent (if redundant) state — the stricter control wins and nothing breaks. What degrades is intent: the other script's allowlisted devices get access-blocked anyway. That's a fleet-configuration decision the admin must resolve, not a machine-level precondition failure — and hard-failing would also block a deliberate belt-and-braces deployment. The warning fires in Enforce and Audit (informational, never drift) and Discover reports the exact values found.
- **`$Posture` validation (exit 2) applies to Enforce and Audit only.** Discover and Revert don't consume `$Posture`, and refusing to revert or report because of a typo in a setting those modes ignore would be unhelpful.

---

## Deploying via Iru

Deploy as a **Custom Script** Library Item using the audit-and-remediate pattern, same as the other `Manage-*`-convention scripts in this repo:

1. **Audit script slot:** the full script with `$Mode = 'Audit'`. Exit 0 = compliant, exit 1 = drift → triggers remediation.
2. **Remediation script slot:** the identical script with `$Mode = 'Enforce'`.
3. `$Posture` set identically in both slots. Runs as `NT AUTHORITY\SYSTEM` (satisfies the elevation gate).

**Intune/GPO overlap during migration.** Intune's Removable Storage Access settings and AD GPO write these same registry values; whichever engine syncs last wins. Retire the old policy before (or when) deploying this item — the audit output makes any tug-of-war visible in the Iru console.

---

## Verification & troubleshooting

**What a blocked user sees (FullBlock).** The device may mount, but opening it in Explorer is denied ("Location is not available" / access-denied class errors). **ReadOnly:** browsing and copying *from* the media works; copying *to* it fails with a write-protect/access-denied error. (Community-observed presentation; exact dialogs vary by Windows build and application.)

**Timing.** New device connections are evaluated against the policy immediately. For devices already mounted and in use when the policy lands, a reboot or user logoff/logon is recommended for full effect (community-observed behavior, carried from the original script's guidance; the policies are re-read at device arrival and session start).

**Check the live state.** Run `$Mode = 'Discover'` in an elevated shell — it prints every relevant value, plus the two conditions that most often confuse troubleshooting: a disabled USBSTOR driver (`Start = 4`, from tooling outside this script) and active Device Installation Restrictions values (the other mechanism).

**MTP/WPD caveat (vendor-documented).** Microsoft notes WPD policy "isn't a reliable policy for removable storage. You can't use WPD policy to entirely block removable storage… the policy may block PTP or MTP, but the user can still browse the drive in Windows Explorer." In the ReadOnly posture, treat the WPD write-denies as best-effort against phones/cameras; FullBlock's `Deny_All` covers the mass-storage path regardless.

### Behavior matrix (recommended acceptance tests)

| Test | Expected |
|---|---|
| FullBlock: USB flash drive, newly connected | No usable access (read and write denied) |
| FullBlock: SATA/USB DVD drive | Media access denied |
| FullBlock: already-mounted stick at policy time | Denied after reboot/re-logon at the latest |
| ReadOnly: copy a file *from* a USB stick | Succeeds |
| ReadOnly: copy a file *to* a USB stick | Fails (write denied) |
| ReadOnly: burn/write to CD/DVD, floppy, tape | Fails (per-class `Deny_Write`) |
| ReadOnly: phone via MTP, write attempt | Best-effort deny (see WPD caveat) |
| Switch posture FullBlock → ReadOnly, run Enforce | `Deny_All` removed, six `Deny_Write` written — no leftovers; Audit compliant |
| Switch posture ReadOnly → FullBlock, run Enforce | Six `Deny_Write` removed (emptied subkeys pruned), `Deny_All=1`; Audit compliant |
| Audit with the *other* posture's values present | Exit 1 (drift) — compliance requires the other posture absent |
| Enforce/Audit with `$Posture = 'Banana'` | Exit 2, nothing written |
| Non-storage USB peripherals (keyboard, headset) in any posture | Unaffected (policies address storage classes only) |
| USB heads-up: internal USB-attached SD readers | Blocked like any removable disk (expected; no exemption exists at this layer) |
| `Revert` mode | All managed values removed, foreign `Deny_Read`/`Deny_Execute` left with a WARN, state key removed |

---

## Limitations & security notes

- **No allowlist, by design of the policy itself.** These policies have no per-device exclusion mechanism. If the requirement includes sanctioned exceptions, use [`Manage-UsbStorageRestrictions/`](../Manage-UsbStorageRestrictions/) instead — not both (see Choosing the layer).
- **Access control, not device control.** FullBlock stops file access through the mounted-volume path; it does not prevent a device from installing, drawing power, or presenting non-storage interfaces. ReadOnly does not deny execute — running a program *from* removable media still works in that posture (only `Deny_Write` is written).
- **Sole-manager assumption, narrowly scoped.** The script owns `Deny_All` at the key root and `Deny_Write` under its six class subkeys. Foreign values in the same space (`Deny_Read`, `Deny_Execute`, custom-class entries from other tooling) are reported and never touched, in every mode including Revert.
- **User-scope variants exist.** All these policies also exist under User Configuration (HKCU). This script is machine-level only; a conflicting HKCU policy from other tooling is out of its sight.

## History

**v2.0.0 (2026-07-14) — modernized from the parameter-based v1.** The v1 script used `-ReadOnly`/`-Revert`/`-DisableUSBSTOR` switches; Iru Custom Scripts run without parameters, so under Iru only the default full-block path was ever reachable — the other paths were dead code. v1 was never deployed to any fleet, so v2 required no migration logic. Three substantive changes beyond the convention work (modes, exit codes, `IruScripts` log/state paths — the old `%ProgramData%\EndpointSecurity` log location is retired):

- **USBSTOR driver disable removed entirely.** v1's `-DisableUSBSTOR` set `HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR\Start = 4`. Dropped because: it has no policy backing (a raw service-start value, invisible to GPO/Intune/CSP reporting), it is redundant under `Deny_All` (which already denies all access), and it has the riskiest failure mode of anything in the old script — a machine left with `Start = 4` has USB mass storage dead in a way no policy console shows. Manual recovery on any machine found in that state: set `Start` back to `3` (the service's default, community-observed as the shipped value) under `HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR`, then replug the device. Discover mode reports the current `Start` value and warns if it is 4.
- **Removable Disks class GUID corrected.** v1 wrote `Deny_Write` under `{53f56307-b6bf-11d0-94f2-00a0c91efb8b}`; Microsoft's CSP references consistently document the Removable Disks access policies at **`{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}`** (five separate policy entries across the two Learn pages in Sourcing notes). With the v1 GUID, the ReadOnly posture would not have write-blocked USB flash drives at all. Vendor-documented correction; since v1 was never deployed, no endpoint carries the wrong key.
- **`gpupdate /force` call dropped.** v1 ran it after every change; this script writes the policy store directly, and a Group Policy refresh neither creates nor consumes these values (inferred). The reboot/re-logon guidance for in-session devices is retained instead.

Revert compatibility with v1: v1's reachable path wrote only root `Deny_All` (plus the optional USBSTOR value). v2's Revert removes `Deny_All` and all six `Deny_Write` values — a superset of everything v1's reachable path wrote to the policy key — so a hypothetical v1 machine would be fully cleaned, except a `Start = 4` left by `-DisableUSBSTOR`, which v2 deliberately no longer touches (see above; moot in practice, v1 was never deployed).

## Rollback

Set `$Mode = 'Revert'` and run once (or push as a one-time Iru script). It removes exactly the values in the mapping table plus the state key `HKLM\SOFTWARE\IruScripts\RemovableStorage`, prunes class subkeys it emptied, and leaves any foreign `Deny_Read`/`Deny_Execute` values in place with a warning. Reboot or re-logon to restore access for in-session devices.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (Enforce/Revert/Discover) or compliant (Audit) |
| 1 | Drift detected (Audit) or one or more runtime operations failed |
| 2 | Precondition failure: not elevated, invalid `$Posture` (Enforce/Audit), or invalid `$Mode` |

---

## Sourcing notes

**Vendor-documented** (Microsoft Learn — the basis for every CSP node, GUID subkey, and value name in the mapping table):

- [Policy CSP – ADMX_RemovableStorage](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-removablestorage) — `RemovableStorageClasses_DenyAll_Access_2` → `RemovableStorageDevices` / `Deny_All` and its precedence statement; the machine-scope per-class `Deny_Write` mappings for CD/DVD `{53f56308}`, Floppy `{53f56311}`, Tape `{53f5630b}`, WPD `{6AC27878}`; the Removable Disks key `{53f5630d}` (via its read/execute policy entries); ADMX file name `RemovableStorage.admx`; per-node CSP availability (Win10 2004 + KB5005101 / Win11 for the `_2` DenyAll node).
- [Policy CSP – Storage](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-storage) — dedicated nodes `Storage/RemovableDiskDenyWriteAccess` (Win10 1809+, maps to GPO "Removable Disks: Deny write access", key `{53f5630d}`) and `Storage/WPDDevicesDenyWriteAccessPerDevice` (Win11 21H2+, key `{6AC27878}`); the WPD-unreliability note quoted in Verification & troubleshooting.

**Community-observed** (widely reported field behavior, verify in your environment):

- The second WPD GUID key `{F33FDC04-D1AC-4E8E-9A30-19BBD4B108AE}` — written by the shipped `RemovableStorage.admx` alongside `{6AC27878}`, but absent from both Learn mapping tables.
- The reboot / re-logon recommendation for devices already in session when the policy lands, and the exact end-user error presentation per posture.
- USBSTOR's default `Start = 3` (manual start) as the shipped service configuration.

**Inferred** (design reasoning, flagged in the text):

- CSP availability gates constrain MDM SyncML delivery, not direct registry writes (the GPO has written these values since long before the CSP nodes existed).
- Dropping `gpupdate /force` as a no-op for direct policy-store writes.
- The v1 GUID `{53f56307}` (the disk *interface* class) being inert for these policies — it appears in no vendor mapping for Removable Storage Access; flagged here because v1 used it.
