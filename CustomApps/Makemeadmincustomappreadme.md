# Deploying Make Me Admin for Windows with Iru

Installing, configuring, and maintaining **[Make Me Admin](https://github.com/pseymour/MakeMeAdmin)** on managed Windows devices using an **Iru Custom App Library Item**.

| | |
|---|---|
| **Platform** | Iru ([iru.com](https://iru.com)) |
| **Target** | Windows x64 |
| **Method** | MSI (WiX, `ALLUSERS=1` / per-machine), installed and configured via a PowerShell wrapper |
| **App version referenced** | 2.4 (latest mainline). `2.4.1` exists only to add the German localization. |
| **License** | GPL-3.0 |
| **Vendor docs** | [Repo](https://github.com/pseymour/MakeMeAdmin) · [Wiki](https://github.com/pseymour/MakeMeAdmin/wiki) |

---

## 1. What Make Me Admin is, and why it deploys cleanly

Make Me Admin lets a **standard** user temporarily elevate themselves into the local **Administrators** group. A background **Windows service** does the actual group-membership change; a small **user application** is what the person clicks. The user launches the app, clicks **Grant Me Administrator Rights**, the service adds them to Administrators, and after a configurable timeout (default **10 minutes**) the service removes them again.

### Why MSI + SYSTEM is the right fit here

Unlike Notion's per-user `.exe`, Make Me Admin distributes a **Windows Installer MSI** built with WiX. The package sets `ALLUSERS=1`, so it installs **per-machine** into `Program Files`, registers a service, and writes its uninstall entry to the machine-wide `HKLM` Add/Remove Programs hive.

This means the SYSTEM-profile trap that bites per-user `.exe` installers **does not apply**. When Iru runs the install as `NT AUTHORITY\SYSTEM`, that is exactly the context an `ALLUSERS=1` MSI expects — files land in `Program Files`, the service installs machine-wide, and the app appears in "Installed Apps" natively. No short-name tricks, no `/D` directory juggling.

The only thing the MSI does *not* do on its own is apply your **org policy** (who may elevate, for how long, whether to prompt for a reason, etc.). Those are registry settings. The wrapper below installs the MSI **and** stamps that configuration in one shot, so a freshly imaged device is both installed and policied without a second deployment.

---

## 2. Package contents

The Library Item's uploaded `.zip` contains these files **at its root**:

| File | Purpose |
|---|---|
| `MakeMeAdmin 2.4 x64.msi` | The Make Me Admin MSI, downloaded from the project's [GitHub Releases](https://github.com/pseymour/MakeMeAdmin/releases). |
| `install.ps1` | Installs the MSI silently, writes your org policy to the registry, confirms install, and writes a detection marker. |
| `uninstall.ps1` | Removes the MSI, clears the policy keys, and clears the detection marker. |

> **Packaging note**
> The three files must sit at the **root** of the zip — not in a subfolder — so the scripts can find the `.msix`/`.msi` beside themselves. When zipping on macOS, build the archive from the files directly and exclude the `__MACOSX` metadata folder.

> **The MSI filename has spaces.** The official asset is named like `MakeMeAdmin 2.4 x64.msi`. The wrapper locates it by pattern (`*x64*.msi`) rather than a hardcoded name, so you don't have to rename it — but if you reference it directly anywhere, quote the path.

---

## 3. The wrapper scripts

Both scripts are Windows PowerShell 5.1 compatible, log to `C:\ProgramData\Iru\Logs\`, and return MDM-friendly exit codes (`0` = success; MSI reboot codes `3010`/`1641` are treated as success).

> **Edit the CONFIG block** at the top of `install.ps1` before packaging. That block is the single place you define who may elevate and your timeout/prompt policy.

### `install.ps1`

```powershell
#requires -Version 5.1
<#
    Make Me Admin — Iru Custom App install wrapper
    Installs the bundled MSI (ALLUSERS=1) and applies org policy, then writes a
    detection marker Iru reads for Pass/Installed status.
#>

# ----------------------------- CONFIG -----------------------------
# Four-part version string written to the detection marker. Must match the
# Iru detection rule's String value. Update this for each new release.
$AppVersion = '2.4.0.0'

# Who may elevate. Use SIDs for Entra-joined / sometimes-offline devices so the
# entity resolves without a domain connection. Names must be DOMAIN\Name format
# (UPNs do NOT work); for a LOCAL group use '.' or %COMPUTERNAME% as DOMAIN.
# Example below allows all interactive users (well-known SID S-1-5-4).
$AllowedEntities = @('S-1-5-4')

# Default elevation window, in MINUTES.
$AdminRightsTimeout = 15

# Prompt for a reason: 0 = None, 1 = Optional, 2 = Required
$PromptForReason = 1

# Require the user to (re)enter Windows credentials before elevating: 0/1
$RequireAuthentication = 1

# How many times a user may renew their elevation before it must lapse.
$RenewalsAllowed = 1

# Remove admin rights immediately if the user logs off: 0/1
$RemoveAdminRightsOnLogout = 1
# ------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$PolicyKey   = 'HKLM:\SOFTWARE\Policies\Sinclair Community College\Make Me Admin'
$MarkerKey   = 'HKLM:\SOFTWARE\Iru\Apps'
$MarkerName  = 'MakeMeAdmin'
$LogDir      = 'C:\ProgramData\Iru\Logs'
$LogFile     = Join-Path $LogDir 'MakeMeAdmin-install.log'
$MsiLog      = Join-Path $LogDir 'MakeMeAdmin-msi.log'

function Write-Log {
    param([string]$Message)
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" | Tee-Object -FilePath $LogFile -Append | Out-Null
}

try {
    Write-Log "=== Make Me Admin install started ==="
    Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    # 1. Locate the bundled MSI beside this script.
    $msi = Get-ChildItem -Path $PSScriptRoot -Filter '*x64*.msi' | Select-Object -First 1
    if (-not $msi) { throw "No x64 MSI found beside install.ps1 in $PSScriptRoot" }
    Write-Log "Found MSI: $($msi.Name)"

    # 2. Install silently, per-machine. ALLUSERS=1 is set by the package itself.
    $args = @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart', '/l*v', "`"$MsiLog`"")
    Write-Log "Running: msiexec.exe $($args -join ' ')"
    $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $args -Wait -PassThru
    Write-Log "msiexec exit code: $($p.ExitCode)"
    if ($p.ExitCode -notin 0,3010,1641) { throw "MSI install failed with exit code $($p.ExitCode)" }

    # 3. Confirm the product registered in the machine-wide uninstall hive.
    $installed = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like '*Make Me Admin*' }
    if (-not $installed) { throw "MSI reported success but no 'Make Me Admin' uninstall entry was found." }
    Write-Log "Confirmed installed: $($installed.DisplayName) $($installed.DisplayVersion)"

    # 4. Apply org policy to the enforced (Policies) key. These override the
    #    plain settings key and are the right place for managed deployment.
    if (-not (Test-Path $PolicyKey)) { New-Item -Path $PolicyKey -Force | Out-Null }
    New-ItemProperty -Path $PolicyKey -Name 'Allowed Entities'                      -Value $AllowedEntities          -PropertyType MultiString -Force | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Admin Rights Timeout'                  -Value $AdminRightsTimeout       -PropertyType DWord       -Force | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Prompt For Reason'                     -Value $PromptForReason          -PropertyType DWord       -Force | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Require Authentication For Privileges' -Value $RequireAuthentication    -PropertyType DWord       -Force | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Renewals Allowed'                      -Value $RenewalsAllowed          -PropertyType DWord       -Force | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Remove Admin Rights On Logout'         -Value $RemoveAdminRightsOnLogout -PropertyType DWord      -Force | Out-Null
    Write-Log "Policy written to $PolicyKey"

    # 5. Write the detection marker AFTER everything else succeeds.
    if (-not (Test-Path $MarkerKey)) { New-Item -Path $MarkerKey -Force | Out-Null }
    New-ItemProperty -Path $MarkerKey -Name $MarkerName -Value $AppVersion -PropertyType String -Force | Out-Null
    Write-Log "Marker written: $MarkerKey\$MarkerName = $AppVersion"

    Write-Log "=== Completed. Exit code: 0 ==="
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "=== Failed. Exit code: 1 ==="
    exit 1
}
```

### `uninstall.ps1`

```powershell
#requires -Version 5.1
<#
    Make Me Admin — Iru Custom App uninstall wrapper
    Removes the MSI, clears the policy keys, and clears the detection marker.
#>

$ErrorActionPreference = 'Stop'
$PolicyKey   = 'HKLM:\SOFTWARE\Policies\Sinclair Community College\Make Me Admin'
$SettingsKey = 'HKLM:\SOFTWARE\Sinclair Community College\Make Me Admin'
$MarkerKey   = 'HKLM:\SOFTWARE\Iru\Apps'
$MarkerName  = 'MakeMeAdmin'
$LogDir      = 'C:\ProgramData\Iru\Logs'
$LogFile     = Join-Path $LogDir 'MakeMeAdmin-uninstall.log'

function Write-Log {
    param([string]$Message)
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" | Tee-Object -FilePath $LogFile -Append | Out-Null
}

try {
    Write-Log "=== Make Me Admin uninstall started ==="
    Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    # Uninstall by passing the bundled MSI to msiexec /x (matches by product code,
    # so no hardcoded GUID is needed and it stays version-independent).
    $msi = Get-ChildItem -Path $PSScriptRoot -Filter '*x64*.msi' | Select-Object -First 1
    if ($msi) {
        $args = @('/x', "`"$($msi.FullName)`"", '/qn', '/norestart')
        Write-Log "Running: msiexec.exe $($args -join ' ')"
        $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $args -Wait -PassThru
        Write-Log "msiexec exit code: $($p.ExitCode)"
        if ($p.ExitCode -notin 0,3010,1641) { throw "MSI uninstall failed with exit code $($p.ExitCode)" }
    } else {
        Write-Log "No MSI found beside script; skipping product removal."
    }

    # Clear configuration and the detection marker.
    Remove-Item -Path $PolicyKey   -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $SettingsKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $MarkerKey -Name $MarkerName -Force -ErrorAction SilentlyContinue
    Write-Log "Cleared policy keys and detection marker."

    Write-Log "=== Completed. Exit code: 0 ==="
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "=== Failed. Exit code: 1 ==="
    exit 1
}
```

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
| Version | `2.4` |
| App icon | Make Me Admin lock icon (`.png`) |
| Upload app | The MakeMeAdmin zip (the three files above) |
| Architecture | x64 |
| Executables for open app detection | `MakeMeAdmin.exe` |

### Install / uninstall commands

| Field | Value |
|---|---|
| Install command | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File install.ps1` |
| Uninstall command | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File uninstall.ps1` |

> **Use the full path to the executable.** Iru treats the first token of the command as a file to launch from the package folder. A bare `powershell.exe` (or `msiexec.exe`) is not present there and fails with "the system cannot find the file specified." The fully-qualified path resolves correctly; `-File install.ps1` then loads from the package folder, which is the working directory at runtime. This is why the wrapper calls `msiexec.exe` with its full `System32` path internally, too.

### Detection logic rules

| Field | Value |
|---|---|
| Type | Registry |
| Key path | `HKLM\SOFTWARE\Iru\Apps` |
| Value | `MakeMeAdmin` |
| Detection method | String comparison |
| Comparison | equals |
| String | `2.4.0.0` |

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
| `ConsentPromptBehaviorUser` | `1` (prompt for credentials) **or** `3` (prompt on secure desktop — the default). **Not** `0`, which causes access-denied for standard users. |

These are not set by the MSI or the wrapper; they are an environment prerequisite. On managed devices they are typically already compliant.

---

## 6. Configuration reference

The wrapper writes a sensible subset to the **policy** key. The full set of supported settings is below, for when you want to tune the deployment. Settings live in either:

- `HKLM\SOFTWARE\Sinclair Community College\Make Me Admin` — plain settings, or
- `HKLM\SOFTWARE\Policies\Sinclair Community College\Make Me Admin` — **enforced** policy (takes precedence; this is what the wrapper uses). ADMX/ADML Group Policy templates also ship inside the install directory.

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
| Override Removal By Outside Process | 0 | `REG_DWORD` | Re-add user if another process (e.g. GPO refresh) removes them. |
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
Get-Content C:\ProgramData\Iru\Logs\MakeMeAdmin-install.log -Tail 30

# 2. The detection marker Iru reads
Get-ItemProperty "HKLM:\SOFTWARE\Iru\Apps" -Name MakeMeAdmin | Select-Object MakeMeAdmin

# 3. The product is registered machine-wide (Add/Remove Programs)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object DisplayName -like '*Make Me Admin*' |
  Select-Object DisplayName, DisplayVersion, Publisher

# 4. The background service exists
Get-Service -DisplayName '*Make Me Admin*'

# 5. Applied policy
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Sinclair Community College\Make Me Admin"
```

A healthy deployment shows the log ending in `Exit code: 0`, the marker holding `2.4.0.0`, a `Make Me Admin` uninstall entry from publisher *Sinclair Community College*, the service present, and the Library Item reporting **Pass / Installed** on its next detection cycle.

---

## 8. Updating to a new release

1. **Download the new MSI** from [GitHub Releases](https://github.com/pseymour/MakeMeAdmin/releases) (x64).
2. **Confirm the four-part version** the detection rule will need — install once on a test device and read it back:
   ```powershell
   (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
     Where-Object DisplayName -like '*Make Me Admin*').DisplayVersion
   ```
3. **Update `$AppVersion`** at the top of `install.ps1` to that four-part value.
4. **Rebuild the zip** with the new `.msi` and the updated `install.ps1` (plus the unchanged `uninstall.ps1`).
5. **Update the Library Item:** upload the new zip, set **Version** to the new display version (e.g. `2.5`), and set **Detection → String** to the new four-part value.
6. **Save and enforce.** Because the device's marker no longer matches the detection rule, Iru re-runs the install command. The MSI performs an in-place upgrade (WiX downgrade-detection blocks installing an older build over a newer one), the wrapper updates the marker, and detection matches again.

> **If an update doesn't take:** increment the Library Item's **Version** field so the agent treats the payload as new and re-downloads it, rather than serving a cached copy.

---

## 9. Troubleshooting quick reference

| Symptom | Where to look | Likely cause |
|---|---|---|
| Iru shows "failed," no wrapper log at `C:\ProgramData\Iru\Logs` | Iru agent log | The install command couldn't launch, so the script never ran. Most common cause: a bare `powershell.exe` instead of the full path. |
| Wrapper log ends before "Confirmed installed" | `MakeMeAdmin-msi.log` | MSI error — the verbose MSI log names the cause (signing, downgrade block, locked service). |
| Installs but Iru shows "not installed" | Marker value vs. detection string | The detection string doesn't match the four-part `$AppVersion` the wrapper wrote. |
| Installs, but users still can't elevate | UAC values | `EnableLUA=0` or `ConsentPromptBehaviorUser=0`. Re-enable UAC (see §5). |
| "Grant" button greyed out for a user | `Allowed Entities` | The user/group isn't allowed, the name didn't resolve (offline + name instead of SID), or they're already an admin. |
| Update not applying | Library Item Version field | Cached payload — bump the Version field to force a fresh download. |

---

## Sourcing notes

**Directly from the vendor (repo, wiki, release artifacts):** the service-plus-user-app model and timeout behavior; the settings/policy registry keys and the full settings table; UAC requirements (`EnableLUA`, `ConsentPromptBehaviorUser`); that the installer is a WiX **MSI** in x64/x86 with publisher *Sinclair Community College* and `ALLUSERS=1`; standard silent args `/qn /norestart` with success codes `0, 3010, 1641`; and that GPO ADMX/ADML templates ship in the package. Latest release is **2.4.1** (Nov 2025), noted by the author as needed only for German localization.

**Inferred / standard behavior (verify in your tenant):** the Iru Custom App field layout, the full-path-to-executable requirement, and the detection-marker pattern are carried over from the established Iru Custom App approach rather than from MakeMeAdmin's own docs. The `$AppVersion` value `2.4.0.0` is a placeholder — read the real four-part `DisplayVersion` off your chosen MSI and match the detection rule to it. MSI **ProductCode** GUIDs are version-specific, which is why the uninstall wrapper passes the MSI to `msiexec /x` rather than hardcoding a GUID.ß