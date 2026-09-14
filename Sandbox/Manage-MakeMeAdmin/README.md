# Deploying Make Me Admin for Windows with Iru

Installing, configuring, and maintaining **[Make Me Admin](https://github.com/pseymour/MakeMeAdmin)** on managed Windows devices using an **Iru Custom App Library Item**.

| | |
|---|---|
| **Platform** | Iru ([iru.com](https://iru.com)) |
| **Target** | Windows x64 |
| **Method** | MSI (WiX, `ALLUSERS=1` / per-machine), installed and configured via a PowerShell wrapper |
| **App version referenced** | 2.4.1 — the current release (published 2025-11-14; still latest as of 2026-09-14). It adds the German localization on top of 2.4.0. |
| **License** | GPL-3.0 |
| **Vendor docs** | [Repo](https://github.com/pseymour/MakeMeAdmin) · [Wiki](https://github.com/pseymour/MakeMeAdmin/wiki) · [Registry settings](https://github.com/pseymour/MakeMeAdmin/wiki/Registry-Settings) |

> **Status: untested.** These wrapper scripts and Library Item settings have not been validated on a real device or tenant. Treat everything here as a starting point to test, not a proven runbook.

---

## 1. What Make Me Admin is, and why it deploys cleanly

Make Me Admin lets a **standard** user temporarily elevate themselves into the local **Administrators** group. A background **Windows service** does the actual group-membership change; a small **user application** is what the person clicks. The user launches the app, clicks **Grant Me Administrator Rights**, the service adds them to Administrators, and after a configurable timeout (default **10 minutes**) the service removes them again.

### Why MSI + SYSTEM is the right fit here

Make Me Admin distributes a **Windows Installer MSI** built with WiX. The package sets `ALLUSERS=1`, so it installs **per-machine** into `Program Files`, registers a service, and writes its uninstall entry to the machine-wide `HKLM` Add/Remove Programs hive.

That matters because the usual trap for MDM app deployment is a per-user `.exe` installer: run as `NT AUTHORITY\SYSTEM` it installs into the SYSTEM profile and writes its uninstall keys under the SYSTEM account's hive, so the app is invisible to the signed-in user and to inventory. An `ALLUSERS=1` MSI has no such problem — SYSTEM is exactly the context it expects. Files land in `Program Files`, the service installs machine-wide, and the app appears in "Installed Apps" natively. No short-name tricks, no `/D` directory juggling.

The only thing the MSI does *not* do on its own is apply your **org policy** (who may elevate, for how long, whether to prompt for a reason, etc.). Those are registry settings. The wrapper below installs the MSI **and** stamps that configuration in one shot, so a freshly imaged device is both installed and policied without a second deployment.

---

## 2. Package contents

The Library Item's uploaded `.zip` contains these files **at its root**:

| File | Purpose |
|---|---|
| `MakeMeAdmin-2.4.1-x64-en-us.msi` | The Make Me Admin MSI, downloaded from the project's [GitHub Releases](https://github.com/pseymour/MakeMeAdmin/releases). |
| `Install-MakeMeAdmin.ps1` | From this folder. Installs the MSI silently, writes your org policy to the registry, confirms install, and writes a detection marker. |
| `Uninstall-MakeMeAdmin.ps1` | From this folder. Removes the MSI, clears the policy keys, and clears the detection marker. |

> **Packaging note**
> The three files must sit at the **root** of the zip — not in a subfolder — so the scripts can find the `.msi` beside themselves. When zipping on macOS, build the archive from the files directly and exclude the `__MACOSX` metadata folder.

### Picking the right MSI

Releases ship **one MSI per language**, not one universal package. The 2.4.1 assets are:

```
MakeMeAdmin-2.4.1-x64-da.msi      Danish
MakeMeAdmin-2.4.1-x64-de.msi      German
MakeMeAdmin-2.4.1-x64-en-us.msi   English (US)
MakeMeAdmin-2.4.1-x64-fr.msi      French
sha256sum.txt                     Checksums for the above
```

> **Put exactly one MSI in the zip.** Both wrappers locate the installer by pattern (`*x64*.msi`) and take the **first match**, so a zip containing two language variants installs an arbitrary one. Pick the language your fleet needs and bundle only that file. Multi-language fleets need one Library Item per language, each scoped to the right blueprint.
>
> Note the asset naming changed between releases — 2.4.0 used dots (`MakeMeAdmin.2.4.0.x64.en-us.msi`), 2.4.1 uses hyphens (`MakeMeAdmin-2.4.1-x64-en-us.msi`). The `*x64*.msi` pattern matches both, which is why the wrappers glob rather than hardcode a filename.

**Verify the download** against the release's `sha256sum.txt` before packaging:

```powershell
Get-FileHash .\MakeMeAdmin-2.4.1-x64-en-us.msi -Algorithm SHA256 | Select-Object -ExpandProperty Hash
```

---

## 3. The wrapper scripts

Both scripts live in this folder and are what you zip alongside the MSI:

| File | Role |
|---|---|
| [`Install-MakeMeAdmin.ps1`](./Install-MakeMeAdmin.ps1) | Locates the single x64 MSI beside itself, installs it silently, confirms the product registered in Add/Remove Programs, writes the organization policy to the enforced registry key, then writes the detection marker — in that order, so the marker only exists once policy is in place. |
| [`Uninstall-MakeMeAdmin.ps1`](./Uninstall-MakeMeAdmin.ps1) | Hands the same MSI to `msiexec /x`, treats 1605 (not installed) as already removed, then deletes both Make Me Admin registry keys and the marker. |

Both are Windows PowerShell 5.1, run as SYSTEM, log to `C:\ProgramData\IruScripts\Logs\` (`Install-MakeMeAdmin.log`, `Install-MakeMeAdmin-msi.log` for the verbose MSI log, `Uninstall-MakeMeAdmin.log`) with every line mirrored to stdout so the Iru agent captures it, and use the repo's standard exit codes (§12).

> **Edit the CONFIGURATION block** at the top of `Install-MakeMeAdmin.ps1` before packaging. It is the single place you define who may elevate and the timeout/prompt policy; nothing below it needs editing.

| Variable | Default | Writes registry value | Purpose |
|---|---|---|---|
| `$AppVersion` | `'2.4.1.0'` *(placeholder)* | *(detection marker)* | Four-part string written to `HKLM\SOFTWARE\Iru\Apps\MakeMeAdmin`; must equal the Library Item's Detection → String. Read the real value off a test install (§8). |
| `$AllowedEntities` | `@('S-1-5-4')` | `Allowed Entities` | SIDs or `DOMAIN\Name` users/groups who may elevate. The default is the well-known INTERACTIVE SID — every signed-in user. Prefer SIDs; see the entity-naming note in §6. |
| `$AdminRightsTimeout` | `15` | `Admin Rights Timeout` | Minutes of elevation per grant (Make Me Admin's own default is 10). |
| `$PromptForReason` | `1` | `Prompt For Reason` | `0` none · `1` optional · `2` required. |
| `$RequireAuthentication` | `1` | `Require Authentication For Privileges` | Re-enter Windows credentials before elevating. |
| `$RenewalsAllowed` | `1` | `Renewals Allowed` | Times a user may extend a grant before it must lapse. |
| `$RemoveAdminRightsOnLogout` | `1` | `Remove Admin Rights On Logout` | Drop rights immediately at sign-out. |
| `$LogDirectory` / `$LogFile` / `$MsiLog` | `%ProgramData%\IruScripts\Logs\…` | — | Log locations. |

Anything in the §6 settings table not listed here takes Make Me Admin's default. To manage an additional setting, add one more `New-ItemProperty` line in step 3 of the install script, using the value name and type from that table.

---

## 4. Library Item configuration

Create a **Custom App** Library Item with the following settings.

### Installation

| Field | Value |
|---|---|
| Installation options | Install and continuously enforce |
| Enforcement deadline | Immediately |

### Application details

| Field | Value |
|---|---|
| Publisher | Sinclair Community College |
| Name | Make Me Admin |
| Version | `2.4.1` |
| App icon | Make Me Admin lock icon (`.png`) |
| Upload app | The MakeMeAdmin zip (the three files above) |
| Architecture | x64 |
| Executables for open app detection | `MakeMeAdminUI.exe` |

### Install / uninstall commands

| Field | Value |
|---|---|
| Install command | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File Install-MakeMeAdmin.ps1` |
| Uninstall command | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File Uninstall-MakeMeAdmin.ps1` |

> **Use the full path to the executable.** Iru treats the first token of the command as a file to launch from the package folder. A bare `powershell.exe` (or `msiexec.exe`) is not present there and fails with "the system cannot find the file specified." The fully-qualified path resolves correctly; `-File Install-MakeMeAdmin.ps1` then loads from the package folder, which is the working directory at runtime. This is why the wrapper calls `msiexec.exe` with its full `System32` path internally, too.

### Detection logic rules

| Field | Value |
|---|---|
| Type | Registry |
| Key path | `HKLM\SOFTWARE\Iru\Apps` |
| Value | `MakeMeAdmin` |
| Detection method | String comparison |
| Comparison | equals |
| String | `2.4.1.0` *(placeholder — use the real `DisplayVersion`, see §8)* |

> **Match the marker to `$AppVersion`.** The string here must equal the four-part `$AppVersion` the wrapper writes. Bump both together on every release.
>
> *Alternative:* because the MSI registers natively in Add/Remove Programs, you can instead detect on the `Make Me Admin` uninstall entry under `HKLM\...\Uninstall`. The marker approach is preferred here because it only goes green after policy is applied, not merely after files land.

Assign the Library Item to the target blueprint, then let the agent enforce.

---

## 5. Prerequisite: User Account Control

Make Me Admin relies on UAC being **at least partially enabled**. If UAC is fully disabled, elevation fails with access-denied. Confirm (or enforce, via a separate Iru profile / script) these values under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`:

| Value | Required setting |
|---|---|
| `EnableLUA` | `1` (UAC on) |
| `ConsentPromptBehaviorUser` | `1` (prompt for credentials on the secure desktop — the effective default on client editions) **or** `3` (prompt for credentials). **Not** `0` (automatically deny elevation requests), which causes access-denied for standard users. |

These are not set by the MSI or the wrapper; they are an environment prerequisite. On managed devices they are typically already compliant.

---

## 6. Configuration reference

The wrapper writes a sensible subset to the **policy** key. The full set of supported settings is below, for when you want to tune the deployment. Settings live in either:

- `HKLM\SOFTWARE\Sinclair Community College\Make Me Admin` — plain settings, or
- `HKLM\SOFTWARE\Policies\Sinclair Community College\Make Me Admin` — **enforced** policy (takes precedence; this is what the wrapper uses).

| Setting | Default | Format | Notes |
|---|---|---|---|
| Allowed Entities | *empty* | `REG_MULTI_SZ` | SIDs or `DOMAIN\Name` users/groups allowed to elevate. |
| Denied Entities | *empty* | `REG_MULTI_SZ` | Denials win over allows. |
| Automatic Add Allowed | *empty* | `REG_MULTI_SZ` | Auto-added to Administrators at logon — **not** subject to a timeout. |
| Automatic Add Denied | *empty* | `REG_MULTI_SZ` | Denials win over allows. |
| Remote Allowed Entities | *empty* | `REG_MULTI_SZ` | Allowed to elevate from a remote computer. |
| Remote Denied Entities | *empty* | `REG_MULTI_SZ` | Denials win over allows. |
| syslog servers | *empty* | `REG_MULTI_SZ` | See the wiki's syslog configuration page. |
| Admin Rights Timeout | 10 | `REG_DWORD` | Default minutes of elevation. |
| Timeout Overrides | *empty* | `REG_SZ` per entity | One value per user/group (name = SID/name, data = minutes). Highest applicable wins. |
| Renewals Allowed | 0 | `REG_DWORD` | Times a user may renew. |
| Remove Admin Rights On Logout | 0 | `REG_DWORD` | Drop rights on logoff. |
| Log Off After Expiration | 0 | `REG_DWORD` | Seconds after expiry before forced logoff (`0` disables). |
| Log Off Message | *(default text)* | `REG_MULTI_SZ` | Shown before forced logoff. |
| Override Removal By Outside Process | 0 | `REG_DWORD` | Re-add the user if something other than Make Me Admin (another management script or tool rewriting the Administrators group) removes them before their timeout. |
| Require Authentication For Privileges | 0 | `REG_DWORD` | Require credentials before granting. |
| Allow Remote Requests | 0 | `REG_DWORD` | Accept elevation requests from remote computers. |
| End Remote Sessions Upon Expiration | 1 | `REG_DWORD` | Terminate remote sessions at expiry. |
| Close Application Upon Expiration | 1 | `REG_DWORD` | Exit the user app at expiry. |
| Prompt For Reason | 0 (None) | `REG_DWORD` | `0` None, `1` Optional, `2` Required. |
| Allow Free-Form Reason | 1 | `REG_DWORD` | Allow a typed reason. |
| Canned Reasons | *empty* | `REG_MULTI_SZ` | Drop-down reason choices. |
| Maximum Reason Length | 333 | `REG_DWORD` | Max free-form reason length. |
| Log Elevated Processes | 0 (Never) | `REG_DWORD` | `0` Never, `1` OnlyWhenAdmin, `2` Always. |
| TCP Service Port | — | `REG_DWORD` | Service port (remote scenarios). |

> **Entity naming.** Use the **SID** for Entra-joined or sometimes-offline devices — it always resolves without a network/domain connection. If you use a name, the group must be **local** (resolvable always) or the device needs a live Active Directory connection. Names must be `DOMAIN\Name`; UPNs (`user@domain.com`) do not work. For a local group, `DOMAIN` is `.`, the computer name (not recommended), or `%COMPUTERNAME%`.

---

## 7. Verifying a deployment

Run from elevated PowerShell after the agent enforces:

```powershell
# 1. Wrapper log — should end with the marker line and "Exit code: 0"
Get-Content C:\ProgramData\IruScripts\Logs\Install-MakeMeAdmin.log -Tail 30

# 2. The detection marker Iru reads
Get-ItemProperty "HKLM:\SOFTWARE\Iru\Apps" -Name MakeMeAdmin | Select-Object MakeMeAdmin

# 3. The product is registered machine-wide (Add/Remove Programs)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                 -ErrorAction SilentlyContinue |
  Where-Object DisplayName -like '*Make Me Admin*' |
  Select-Object DisplayName, DisplayVersion, Publisher

# 4. The background service exists (service name MakeMeAdmin, display name "Make Me Admin")
Get-Service -Name MakeMeAdmin

# 5. Applied policy
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Sinclair Community College\Make Me Admin"
```

A healthy deployment shows the log ending in `Exit code: 0`, the marker holding the four-part version you configured, a `Make Me Admin` uninstall entry from publisher *Sinclair Community College*, the service present, and the Library Item reporting **Pass / Installed** on its next detection cycle.

### Behavior matrix (recommended acceptance tests)

None of these have been run yet — this is the test plan, not a result set.

| Test | Expected |
|---|---|
| Clean device, first enforce | MSI installs, policy key populated, marker written, Library Item **Installed** |
| Re-run on an already-installed device | Marker already matches, so Iru does not re-run the install command |
| Standard user clicks **Grant Me Administrator Rights** | Added to local Administrators; removed again after `$AdminRightsTimeout` minutes |
| Elevation attempt by a user outside `$AllowedEntities` | Grant refused / button unavailable |
| Device offline, SID-based `$AllowedEntities` | Elevation still works (SIDs resolve without a directory) |
| Device offline, name-based `$AllowedEntities` with a domain group | Elevation fails to resolve — the reason to prefer SIDs |
| UAC disabled (`EnableLUA=0`) | Elevation fails access-denied; install itself still succeeds |
| Uninstall command | Product removed, policy + settings keys gone, marker cleared, Library Item **Not installed** |
| Uninstall run twice | Second run logs 1605 "already removed" and still exits 0 |
| Zip containing two language MSIs | Arbitrary language installed — the reason to bundle exactly one |
| Version bump without changing the Library Item Version field | Cached payload may be served; bump Version to force re-download |

---

## 8. Updating to a new release

1. **Download the new MSI** from [GitHub Releases](https://github.com/pseymour/MakeMeAdmin/releases) — the x64 asset for your language — and check it against the release's `sha256sum.txt`.
2. **Confirm the four-part version** the detection rule will need. `$AppVersion` in this doc is a placeholder; the only reliable source is the installed product. Install once on a test device and read it back:
   ```powershell
   (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' `
     -ErrorAction SilentlyContinue |
     Where-Object DisplayName -like '*Make Me Admin*').DisplayVersion
   ```
   The MSI's own `ProductVersion` works too, if you would rather not install first:
   ```powershell
   # OpenDatabase does not honour PowerShell's current directory - pass a full path.
   $path = (Resolve-Path '.\MakeMeAdmin-2.4.1-x64-en-us.msi').ProviderPath
   $i  = New-Object -ComObject WindowsInstaller.Installer
   $db = $i.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$i,@($path,0))
   $v  = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,
         @("SELECT Value FROM Property WHERE Property='ProductVersion'"))
   $v.GetType().InvokeMember('Execute','InvokeMethod',$null,$v,$null)
   $r  = $v.GetType().InvokeMember('Fetch','InvokeMethod',$null,$v,$null)
   $r.GetType().InvokeMember('StringData','GetProperty',$null,$r,1)
   ```
   Note that `ProductVersion` may be three-part (`2.4.1`) while `DisplayVersion` reads four-part. Whatever the device actually reports is what the detection rule must match.
3. **Update `$AppVersion`** at the top of `Install-MakeMeAdmin.ps1` to that value.
4. **Rebuild the zip** with the new `.msi` and the updated `Install-MakeMeAdmin.ps1` (plus the unchanged `Uninstall-MakeMeAdmin.ps1`). Remove the previous MSI — only one may be present.
5. **Update the Library Item:** upload the new zip, set **Version** to the new display version, and set **Detection → String** to the value from step 2.
6. **Save and enforce.** Because the device's marker no longer matches the detection rule, Iru re-runs the install command. The MSI performs an in-place upgrade (WiX downgrade-detection blocks installing an older build over a newer one), the wrapper updates the marker, and detection matches again.

> **Uninstall follows the package, not the device.** Because `Uninstall-MakeMeAdmin.ps1` derives the ProductCode from the bundled MSI, the Library Item can only uninstall the version it currently ships. After an upgrade, a device still on the old build (one that failed to upgrade, say) will not be removed by the new package's uninstall command — it returns 1605. Remove those manually, or keep the old package available until the fleet has converged.

> **If an update doesn't take:** increment the Library Item's **Version** field so the agent treats the payload as new and re-downloads it, rather than serving a cached copy.

---

## 9. Troubleshooting quick reference

| Symptom | Where to look | Likely cause |
|---|---|---|
| Iru shows "failed," no wrapper log at `C:\ProgramData\IruScripts\Logs` | Iru agent log | The install command couldn't launch, so the script never ran. Most common cause: a bare `powershell.exe` instead of the full path. |
| Wrapper log ends before "Confirmed installed" | `Install-MakeMeAdmin-msi.log` | MSI error — the verbose MSI log names the cause (signing, downgrade block, locked service). |
| Installs but Iru shows "not installed" | Marker value vs. detection string | The detection string doesn't match the four-part `$AppVersion` the wrapper wrote. |
| Installs, but users still can't elevate | UAC values | `EnableLUA=0` or `ConsentPromptBehaviorUser=0`. Re-enable UAC (see §5). |
| "Grant" button greyed out for a user | `Allowed Entities` | The user/group isn't allowed, the name didn't resolve (offline + name instead of SID), or they're already an admin. |
| Update not applying | Library Item Version field | Cached payload — bump the Version field to force a fresh download. |
| Uninstall returns 1605 | `Uninstall-MakeMeAdmin.log` | The installed build's ProductCode differs from the bundled MSI's — the package can only remove the version it ships (see §8). |
| Wrong UI language after install | The MSI in the zip | Releases are per-language; the wrapper installs the first `*x64*.msi` it finds. Bundle exactly one. |

---

## 10. Limitations

**Policy is applied at install time only.** The wrapper writes the policy key during install, and detection is marker-based. Once the marker matches, Iru considers the item satisfied and does not re-run the install command — so if someone edits or deletes the Make Me Admin policy values afterwards, **nothing puts them back**. "Install and continuously enforce" enforces *installation*, not *configuration*. If policy drift matters in your environment, pair this with a separate Iru Custom Script that audits and re-applies the policy key on a schedule; that is the tool designed for enforcing settings.

**One language per Library Item.** Releases ship per-language MSIs and the wrapper installs the first one it finds, so a multi-language fleet needs one Library Item per language, each scoped to the right blueprint.

**Uninstall is tied to the shipped MSI.** See the note in §8 — the package removes only the version it currently bundles.

**UAC is an external prerequisite.** Neither the MSI nor the wrapper configures UAC. If `EnableLUA=0` or `ConsentPromptBehaviorUser=0`, the install still succeeds and the app still appears, but elevation fails at the moment a user tries it. Verify §5 separately.

**This grants real local administrator rights.** Every allowed user can become a local admin on demand for the configured window, which is the whole point, but it is a genuine expansion of privilege. `Automatic Add Allowed` in particular is **not** subject to any timeout — entities listed there are made admin at logon and stay admin. Scope `$AllowedEntities` deliberately, prefer `Prompt For Reason = 2` plus `Log Elevated Processes` where you need an audit trail, and keep the timeout short.

**Untested.** Nothing here has been validated on a device or in a tenant.

## 11. Rollback

Trigger the Library Item's uninstall command (or run `Uninstall-MakeMeAdmin.ps1` from the staged package folder). It removes the product, deletes both configuration keys — `HKLM\SOFTWARE\Policies\Sinclair Community College\Make Me Admin` and `HKLM\SOFTWARE\Sinclair Community College\Make Me Admin` — and clears the `HKLM\SOFTWARE\Iru\Apps\MakeMeAdmin` marker so Iru reads the device as not installed.

Two things it deliberately does not do:

- **It does not demote anyone.** A user who is elevated at the moment of uninstall keeps their Administrators membership — the service that would have removed them is gone. Check `Get-LocalGroupMember Administrators` on removal and clean up by hand if needed.
- **It does not remove log files** under `C:\ProgramData\IruScripts\Logs\`. Delete them separately if the device is being reassigned.

To roll back to an earlier release, rebuild the package around the older MSI and bump the Library Item **Version** field — but note that WiX downgrade detection blocks installing an older build over a newer one, so the newer version must be uninstalled first.

## 12. Exit codes

Both wrappers use the repo's standard scheme:

| Code | Meaning |
|---|---|
| 0 | Success — product installed/removed, policy written/cleared, marker updated |
| 1 | Runtime failure — MSI returned a non-success code, the product did not register after install, or a registry write failed |
| 2 | Precondition failure — not elevated, or no x64 MSI found beside the script (nothing is changed in that case) |

MSI reboot codes `3010` (reboot required) and `1641` (reboot initiated) count as success; the wrappers never reboot the device. On uninstall, `1605` (product not installed) also counts as success because the goal state is already met. The raw `msiexec` exit code is always logged before it is translated. On an install failure the marker is deliberately not written, so the Library Item stays "not installed" and Iru retries on its next cycle.

---

## Sourcing notes

**Vendor-documented (repo, wiki, release artifacts):** the service-plus-user-app model and timeout behavior; the settings key `HKLM\SOFTWARE\Sinclair Community College\Make Me Admin` and the enforced policy key `HKLM\SOFTWARE\Policies\Sinclair Community College\Make Me Admin`, plus every value name, type, and default in the §6 table — all verified against the wiki's [Registry Settings](https://github.com/pseymour/MakeMeAdmin/wiki/Registry-Settings) page; UAC requirements (`EnableLUA`, `ConsentPromptBehaviorUser`); that the installer is a WiX **MSI** with publisher *Sinclair Community College* and `ALLUSERS=1`; and — verified in the WiX source (`Setup/Components.wxs`, `Setup/Folders.wxs`) and `UserRequestApp/LocalUI.csproj` — that the user app is `MakeMeAdminUI.exe` and the service is installed with name `MakeMeAdmin` and display name `Make Me Admin`. Release data verified against the GitHub Releases API on 2026-09-14: **2.4.1** (published 2025-11-14) is current, shipping per-language x64 assets `MakeMeAdmin-2.4.1-x64-{da,de,en-us,fr}.msi` plus `sha256sum.txt`; 2.4.0 used the older dotted naming (`MakeMeAdmin.2.4.0.x64.en-us.msi`).

**Standard Windows behavior:** for `ConsentPromptBehaviorUser`, Microsoft's policy reference names the three options (automatically deny / prompt for credentials on the secure desktop / prompt for credentials) and gives "prompt for credentials on the secure desktop" as the effective client default; the numeric mapping `0` / `1` / `3` used in §5 is the long-standing registry encoding for those options and is not spelled out on that page. Silent args `/qn /norestart`; success codes `0`, `3010` (reboot required), `1641` (reboot initiated); `1605` meaning the product is not installed; that `msiexec /x <path.msi>` reads the ProductCode from that file, so the package can only uninstall the version it bundles; and that WiX downgrade detection blocks installing an older build over a newer one.

**Inferred / unverified (check before you rely on it):** the Iru Custom App field layout, the full-path-to-executable requirement, and the detection-marker pattern (`HKLM\SOFTWARE\Iru\Apps`) are carried over from the established Iru Custom App approach in this repo rather than from Iru or MakeMeAdmin documentation. The `$AppVersion` value `2.4.1.0` is a **placeholder** — the four-part `DisplayVersion` a given MSI writes has not been confirmed; read it off a test install (§8) and match the detection rule to it. Nothing in this document has been executed on a device or in a tenant.