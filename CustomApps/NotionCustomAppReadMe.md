# Deploying Notion for Windows with Iru

Installing and maintaining the **Notion desktop app** on managed Windows devices using an **Iru Custom App Library Item**.

| | |
|---|---|
| **Platform** | Iru |
| **Target** | Windows x64 |
| **Method** | MSIX, provisioned for all users |

---

## 1. Why this approach is needed

Notion's standard Windows download is a **per-user installer**. It always installs "for the account that runs it" and places the app under that account's profile (`%LocalAppData%\Programs\Notion`).

When any management tool deploys an app, the install runs as the Windows **SYSTEM** account — not the logged-in person. With Notion's per-user installer, the app lands in SYSTEM's own profile, a location no real user can see or launch from. The install genuinely succeeds and detection reports it as present (both run as SYSTEM and look at the same place), but the person at the device never sees Notion. This is the classic "logs say installed, but it's nowhere on the machine" result.

This is a characteristic of Notion's installer, **not** of Iru — any management platform running the per-user `.exe` as SYSTEM hits the same wall.

### The fix

Notion also publishes a **Windows MSIX x64** package. MSIX is Microsoft's modern packaging format built for managed deployment. Deployed as a **provisioned package**, it installs once to a managed machine-wide location (`C:\Program Files\WindowsApps`) and is automatically registered for every current and future user at logon. This sidesteps the SYSTEM-profile problem entirely.

Iru delivers the MSIX through a Custom App Library Item, using a small PowerShell wrapper to provision the package and report status back to Iru.

### Background: why not just script the `.exe`?

The `.exe` route was tested first and abandoned. It is built on **NSIS** wrapped by **electron-builder**, which introduces several traps that make it unsuitable for SYSTEM-context deployment:

- **Silent-switch syntax.** NSIS is case-sensitive and uses `/S` (capital), not `/s`. The MSI-style `/q` / `/quiet` switch is not recognized at all.
- **SYSTEM-profile trap.** With only `/S`, files drop into `C:\Windows\System32\config\systemprofile\AppData\Local\Programs\Notion` — invisible to real users.
- **`/D` space-parsing bug.** electron-builder's `multiUser.nsh` splits the command line at the first space in the `/D` path, so `/D=C:\Program Files\Notion` actually installs to `C:\Program\Notion` and leaves an empty `C:\Program Files\Notion` skeleton. Quoting the path makes the install fail outright. The only workaround is the 8.3 short name (`/D=C:\PROGRA~1\Notion`).
- **Installed-Apps / registry trap.** Under a custom `/D` path in SYSTEM context, the installer writes uninstall keys to the SYSTEM hive's HKCU (`S-1-5-18`) instead of HKLM. The app never appears in "Installed Apps" and is invisible to MDM inventory scanners.

The short-name workaround can get files onto disk, but it cannot fix the registry/inventory problem. **MSIX is the supported path** and is what this repo uses.

---

## 2. Package contents

The Library Item's uploaded `.zip` contains **three files at its root**:

| File | Purpose |
|---|---|
| `Notion-<version>.msix` | The Notion MSIX package, downloaded from Notion's desktop download page (Windows MSIX x64). |
| `install.ps1` | Provisions the MSIX for all users and reports success to Iru. |
| `uninstall.ps1` | Removes the package for all users and clears the detection marker. |

> **Packaging note**
> The three files must sit at the **root** of the zip — not inside a subfolder — so the scripts can locate the `.msix` beside themselves. When zipping on macOS, build the archive from the files directly and exclude the `__MACOSX` metadata folder.

### What each script does

**`install.ps1`**

1. Locates the `.msix` packaged alongside it.
2. Provisions it for all users with `Add-AppxProvisionedPackage`.
3. Confirms the package registered, then writes a machine-wide registry marker (`HKLM\SOFTWARE\Iru\Apps\Notion = <version>`) that Iru uses for detection.
4. Logs every step to `C:\ProgramData\IruLogs\Notion-install.log`.

The marker is written **only after** provisioning is confirmed, so a success status always reflects a genuinely installed app.

**`uninstall.ps1`**

1. Removes the provisioned (all-users) copy so new logins do not re-receive it.
2. Removes the package for any users who already have it registered.
3. Clears the `HKLM\SOFTWARE\Iru\Apps\Notion` marker so Iru reads it as removed.
4. Logs every step to `C:\ProgramData\IruLogs\Notion-uninstall.log`.

Both scripts log the account they ran under. On a real Iru deployment this reads `NT AUTHORITY\SYSTEM`, confirming the agent invoked them in the expected context.

---

## 3. Library Item configuration

Create a **Custom App** Library Item with the following settings.

### Installation

| Field | Value |
|---|---|
| Installation options | Install and continuously enforce |
| Enforcement deadline | Immediately |

### Application details

| Field | Value |
|---|---|
| Publisher | Notion |
| Name | Notion |
| Version | `7.21.0` |
| App icon | Notion logo (`.png`) |
| Upload app | The Notion MSIX zip (the three files above) |
| Architecture | x64 |
| Executables for open app detection | `Notion.exe` |

### Install / uninstall commands

| Field | Value |
|---|---|
| Install command | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File install.ps1` |
| Uninstall command | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File uninstall.ps1` |

> **Use the full path to `powershell.exe`**
> Iru treats the first token of the command as a file to launch from the package folder. A bare `powershell.exe` is not present there and fails with "the system cannot find the file specified." The fully-qualified path resolves correctly; `-File install.ps1` then loads from the package folder, which is the working directory at runtime.

### Detection logic rules

| Field | Value |
|---|---|
| Type | Registry |
| Key path | `HKLM\SOFTWARE\Iru\Apps` |
| Value | `Notion` |
| Detection method | String comparison |
| Comparison | equals |
| String | `7.21.0.0` |

> **On the detection string**
> The MSIX reports a **four-part** version (e.g. `7.21.0.0`), which is the value the install script writes to the marker and the value the detection rule must match. This differs from the **three-part** display version (`7.21.0`) shown on Notion's download page and in the Version field above.

Assign the Library Item to the target blueprint, then let the agent enforce.

---

## 4. Verifying a deployment

After the agent runs, confirm the result on the device with **elevated PowerShell**.

```powershell
# 1. Script log — should end with "provisioned", the marker, and exit code 0
Get-Content C:\ProgramData\IruLogs\Notion-install.log -Tail 30

# 2. The detection marker Iru reads
Get-ItemProperty "HKLM:\SOFTWARE\Iru\Apps" -Name Notion | Select-Object Notion

# 3. The provisioned package and its install location
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "*Notion*" | Select-Object DisplayName, Version
(Get-AppxPackage -Name *Notion*).InstallLocation
```

A healthy deployment shows:

- The log ending with `Exit code: 0` and `Marker written: ...Notion = 7.21.0.0`.
- The marker holding `7.21.0.0`.
- The package present under `C:\Program Files\WindowsApps\com.notion.app.desktop.notion_...` — a managed machine-wide location, not a SYSTEM profile path.
- The Library Item reporting **Pass / Installed** in the Iru console on its next detection cycle.

> **Timing**
> A provisioned package installs for an already-logged-in user at their next sign-in. New users receive it automatically at first login.

---

## 5. Updating Notion to a new release

Provisioned MSIX packages do not update themselves from this deployment method, so new releases are pushed via Iru. MSIX performs an **in-place upgrade** as long as the package identity is unchanged and the version increases — which it is, for each official Notion release.

### Steps

1. **Download the new MSIX.** From Notion's desktop download page, get the new Windows MSIX x64 build (e.g. `Notion-7.22.0.msix`).
2. **Confirm the new version string** — provision the new MSIX once on a test device and read the exact four-part version the detection rule will need:

   ```powershell
   Add-AppxProvisionedPackage -Online -PackagePath "C:\path\Notion-7.22.0.msix" -SkipLicense
   (Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "*Notion*").Version
   ```

3. **Build the new zip.** Package the new `.msix` with the same `install.ps1` and `uninstall.ps1` — the scripts are version-independent and need no edits.
4. **Update the Library Item:**

   | Field | New value |
   |---|---|
   | Upload app | The new MSIX zip |
   | Version | The new display version (e.g. `7.22.0`) |
   | Detection → String | The new four-part version (e.g. `7.22.0.0`) |

5. **Save and let enforcement run.** Because the device's existing marker (`7.21.0.0`) no longer matches the updated detection rule (`7.22.0.0`), Iru runs the install command again. The script provisions the new package (an in-place upgrade), updates the marker, and detection then matches.

> **If an update does not appear to take**
> Increment the Library Item's **Version** field so the agent recognizes the payload as new and re-downloads it. A payload that reuses the prior version can be served from the agent's local cache instead of the updated upload.

---

## 6. Troubleshooting quick reference

| Symptom | Where to look | Likely cause |
|---|---|---|
| Iru shows "failed," no script log at `C:\ProgramData\IruLogs` | Agent log under the Iru agent's logs folder | The install command could not launch, so the script never ran. Most common cause: a bare `powershell.exe` instead of the full path. |
| Install log ends without "provisioned" | `Notion-install.log` | MSIX provisioning error — the logged exception names the cause (signing, sideload policy). |
| Installs but Iru still shows "not installed" | Marker value vs. detection string | The detection string does not match the four-part version the script wrote. |
| App opens to a blank window | Per-user app cache | Clear `%LocalAppData%\Notion` and `%AppData%\Notion`, then relaunch. |
| Update not applying | Library Item Version field | Cached payload — bump the Version field to force a fresh download. |
