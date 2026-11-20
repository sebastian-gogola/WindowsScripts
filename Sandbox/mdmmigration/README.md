# MDM Migration Script 1.3.1, experimental (mdmmigration.ps1)

> **Status: experimental.** This is a sandbox alternative to the supported migration script in [`Iru WindowsScripts/mdmmigration.ps1`](../../Iru%20WindowsScripts/mdmmigration.ps1) (documented in [`Iru WindowsScripts/mdmmigration.md`](../../Iru%20WindowsScripts/mdmmigration.md)). It adds Wi-Fi preservation and an RMM hand-off mode on top of the 1.2.0 logic. It has **not** been validated broadly. Test it on a few devices, including at least one Wi-Fi-only device, before using it at scale. If you do not need either addition, use the supported script.

## Overview
`mdmmigration.ps1` automates the process of unenrolling Windows devices from their current management provider and enrolling them into Iru. It gathers enrollment parameters from your Iru gateway, removes existing MDM enrollments (when present), and registers the device with Kandji.

The script is designed to run from an elevated context (Administrator/SYSTEM). It can be executed interactively or fully unattended via the `-Silent` switch. Because it leverages native Windows APIs, it is safe to deploy to devices via your existing MDM solution or other remote execution tools.

Version 1.3.1 keeps the unenrollment, cleanup and registration logic of the supported script and adds the two items below.

## What is different from the supported script

### Wi-Fi preservation (1.3.0, revised in 1.3.1)

**Why.** Unenrolling from Intune (or any MDM that delivered Wi-Fi through the WiFi CSP) removes the Wi-Fi profiles that MDM delivered. A device whose only uplink is one of those networks goes offline before it can register with Iru, and stays unmanaged until someone joins it to Wi-Fi by hand.

**How.** Before the first change to the device, the script:

1. Exports every Wi-Fi profile, keys included, to `C:\ProgramData\Iru\MDMMigration\WifiBackup\<timestamp>\`. The folder is locked to SYSTEM and Administrators (by SID, so localized group names do not matter) before anything is written to it. Key material is never written to the log.
2. Reads the connected network from the Windows network profile (`Get-NetConnectionProfile`) and checks for a wired or cellular adapter that is up and holds a default route.
3. Classifies each backed-up profile from its XML: pre-shared key (WPA2/WPA3-Personal), open network, or 802.1X/enterprise authentication.
4. Decides whether the device can stay online (the **gate**, see `-WifiPreserveMode` below).

After unenrolling, it re-adds whichever backed-up profiles Windows removed as local all-user profiles (`netsh wlan add profile ... user=all`, up to three attempts each), asks Windows to reconnect, and waits up to `-WifiReconnectTimeoutSeconds` for the Iru registration host to answer on TCP 443 before registering. If a direct probe did not work even before unenrolling (for example behind a proxy), it waits for a default route instead. A final restore sweep runs after registration for profiles Windows removed late. The backup folder is deleted on every exit path, unless a profile could not be re-added after three attempts; then it is retained with a warning and a recovery command in the log.

**What is covered.** Password-based networks (WPA2-Personal, WPA3-Personal) and open networks. **802.1X networks** (profiles with `useOneX`, or authentication `WPA`, `WPA2`, `WPA3`, `WPA3ENT`, `WPA3ENT192`) are backed up but never re-added: they depend on certificates or credentials the previous MDM issued, which do not survive unenrollment. A profile whose key Windows did not export in clear text is also treated as not restorable.

**Windows 11 24H2 and later.** `netsh wlan show interfaces` and `netsh wlan connect` are refused unless Location services are on. 1.3.0 therefore reported "not connected" on every 24H2 device. 1.3.1 reads the connected network from `Get-NetConnectionProfile`, which needs no Location permission, and when a `netsh wlan connect` attempt is blocked it stops retrying and relies on Windows auto-connect to rejoin the restored profiles.

**Scope.** The gate and the restore only run when there is an existing enrollment to remove. On a device with no prior MDM the summary reads `skipped (no existing enrollment to remove)`.

### `-Detach` for NinjaOne and other RMM tools (1.3.1)

**Why.** Unenrolling can remove an RMM agent that the previous MDM installed, and with it the PowerShell process the agent launched, so the migration dies halfway. RMM tools also enforce script timeouts that a full migration can exceed.

**What it does.** With `-Detach`, the script:

1. Checks it is elevated, then copies itself to `C:\ProgramData\Iru\MDMMigration\Run\mdmmigration.ps1`. The folder is restricted to SYSTEM and Administrators because the copy may carry baked-in tenant values. If the RMM tool ran the script from memory rather than a file, the script reconstructs its own source.
2. Writes the parameters you passed (everything except `-Detach`) to `parameters.xml` in the same folder, so values with spaces or quotes survive unchanged.
3. Registers the one-time scheduled task `\Iru\Iru MDM Migration` running as SYSTEM with highest privileges, no trigger, a two-hour execution limit, allowed on battery, and starts it immediately.
4. Logs the hand-off and **exits 0**. The RMM tool only learns whether the hand-off succeeded; it never sees the migration result. If the hand-off fails, nothing has been changed and the exit code is 1.

The task's run starts by unregistering the task and deleting both the script copy and `parameters.xml`, then runs the migration silently. Its log is in `C:\ProgramData\Iru\MDMMigration\Logs` like any other run; read the result there.

**Rules.** Do not use `-Detach` with Intune. `-Detach` is ignored when `-DiagnoseOnly` is also given. `-Detach` forces silent mode, because a SYSTEM scheduled task has no desktop to show a dialog on. The script does not check which tool launched it; respecting the Intune rule is up to the operator.

### Pre-flight

`-DiagnoseOnly` now ends with a **Wi-Fi pre-flight** section that runs the same assessment as the gate and prints `Verdict: would proceed` or `Verdict: WOULD BLOCK in Enforce mode`, with the reasons. It exports the profiles to a temporary restricted folder to inspect them and deletes the folder afterwards. Nothing else is changed. As in the supported script, `-DiagnoseOnly` runs before tenant validation, so it works without enrollment details.

The run summary at the end of every log has a new `Wi-Fi preservation` line.

## Configuration Options
You can supply required parameters via:

1. **Editable defaults** near the top of `mdmmigration.ps1`. As shipped, every customer-specific default is `$null`:
   ```powershell
   $TenantNameDefault       = $null
   $BlueprintIdDefault      = $null
   $EnrollmentCodeDefault   = $null
   $TenantIdDefault         = $null
   $TenantLocationDefault   = $null  # "US" or "EU"
   $UninstallAppDefault     = @()    # Example: @("msiexec /x {GUID} /qn /norestart", '"C:\Program Files\agent\Uninstall Agent.exe" /allusers /S')
   $EnableDebugDefault      = $false
   $EnableSilentDefault     = $true
   $WifiPreserveModeDefault = "Enforce"  # "Enforce", "BestEffort" or "Off"
   $WifiReconnectTimeoutSecondsDefault = 180
   $ForceRemigrationDefault = $false
   ```
   Updating these allows admins to "bake in" values without editing the rest of the script. `-Detach` has no editable default; it is a switch only.

   **Where to find these values in the Iru console:**
   - **TenantName**: the first part of your tenant sign-in URL. Example: if your tenant URL is `https://contoso.iru.com`, your tenant name is `contoso`.
   - **BlueprintId**: Iru Console → **Blueprints** → open the target blueprint → copy the GUID from the URL.
     - Example URL: `https://contoso.iru.com/blueprints/maps/447c8874-73f5-4b7a-9d55-18c58e673597/assignments`
     - BlueprintId: `447c8874-73f5-4b7a-9d55-18c58e673597`
   - **EnrollmentCode**: Iru Console → **Enrollment** → **Manual Enrollment** → use the code for the target blueprint.
   - **TenantId**: Iru Console → **Organization** → **Device Domains**.
     - Example Device Domain: `8134cc6c.web-api.kandji.io` → TenantId: `8134cc6c`

2. **Named command-line parameters**, which take precedence over the defaults. All parameters of the supported script are unchanged:
   - `-TenantName` (string, required if no default)
   - `-BlueprintId` (string, required if no default)
   - `-EnrollmentCode` (string, required if no default)
   - `-TenantId` (string, required if no default; prefix used to build the management URL)
   - `-TenantLocation` (`US` or `EU`, required if no default; selects the Kandji/Iru region endpoints)
   - `-UninstallApp` (string array, optional); array of full command lines for uninstalling applications after enrollment
   - `-Debug` (switch) enables verbose logging
   - `-Silent` (switch) suppresses the intro and completion dialogs
   - `-ForceRemigration` (switch) unenrolls and re-enrolls even when the device already reports a Kandji/Iru provider
   - `-DiagnoseOnly` (switch) prints a read-only inventory of MDM state (and, in 1.3.1, the Wi-Fi pre-flight) and changes nothing

   New in 1.3.x:
   - `-WifiPreserveMode` (`Enforce` (default), `BestEffort`, `Off`)
     - `Enforce`: abort before unenrolling, with exit code 4, when the device is on Wi-Fi, the connected network cannot be restored, and no other uplink is available. Also aborts with exit code 4 if the Wi-Fi check itself fails. The device stays on its current MDM.
     - `BestEffort`: back up and restore what is possible, warn about the rest, never abort.
     - `Off`: Wi-Fi is not touched; identical to the supported script.
     - An unrecognized value falls back to `Enforce` with a warning.
   - `-WifiReconnectTimeoutSeconds` (int, default 180): how long to wait after unenrolling for the network to return before attempting registration. Values of 0 or less fall back to the default. When the time runs out the script logs a warning and attempts registration anyway.
   - `-Detach` (switch): hand the migration to a one-time SYSTEM scheduled task and exit 0 (see above).
   - `-DetachedRun` (switch): internal; set by the scheduled task that `-Detach` starts. Do not pass it yourself.

   When you specify `-TenantLocation EU`, the script automatically targets the Kandji/Iru EU endpoints (`*.gateway.eu.iru.com` and `*.web-api.eu.kandji.io`). Leaving it at `US` keeps the existing US URLs.

The script validates every required input (regardless of whether it came from a default or CLI) *before* displaying any UI. Missing or invalid values cause the script to log errors and exit with code `1`.

### Application Uninstall Parameters

Unchanged from the supported script: `-UninstallApp` (or `$UninstallAppDefault`) takes an array of full command lines, each run sequentially with a 30-minute timeout. In this version, as in 1.2.0, the uninstalls run **after a successful registration with Iru**; a failed registration skips them, and an uninstall failure is logged but does not change the exit code. See the supported script's documentation for the command format and examples.

## Usage Examples

Standard unattended run (same as the supported script):
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\mdmmigration.ps1 `
    -TenantName "contoso" `
    -BlueprintId "447c8874-73f5-4b7a-9d55-18c58e673597" `
    -EnrollmentCode "571537" `
    -TenantId "8134cc6c" `
    -TenantLocation "US" `
    -Silent
```

From an RMM tool such as NinjaOne, where the agent may be removed by the unenrollment:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\mdmmigration.ps1 `
    -TenantName "contoso" -BlueprintId "447c8874-73f5-4b7a-9d55-18c58e673597" `
    -EnrollmentCode "571537" -TenantId "8134cc6c" -TenantLocation "US" `
    -Detach
```
The RMM job finishes within seconds with exit code 0 once the task is started. Check `C:\ProgramData\Iru\MDMMigration\Logs` for the migration result.

Fleet where some devices sit on an 802.1X Wi-Fi and you accept the risk of a device dropping offline:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\mdmmigration.ps1 ... -Silent -WifiPreserveMode BestEffort
```

Read-only pre-flight, including the Wi-Fi verdict, before touching a device:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\mdmmigration.ps1 -DiagnoseOnly
```

## Deployment Guidance
- **Context**: run as an elevated user or, preferably, as SYSTEM when deploying via your current MDM/remote management stack.
- **Reboots**: not required, though a reboot after migration is recommended to ensure device policies are refreshed.
- **User Interaction**: for mass deployments use `-Silent` (or keep `$EnableSilentDefault = $true`) so no dialogs are shown. `-Detach` is always silent.
- **Logging**: output is written both to the console and to `C:\ProgramData\Iru\MDMMigration\Logs\MDM-Unenroll_<timestamp>.log`. Run with `-Debug` to capture verbose API responses for troubleshooting. The run summary at the end of the log now includes the Wi-Fi outcome.
- **Require Authentication to Blueprint**: the script will fail if Require Authentication is set on the blueprint.
- **Wi-Fi-only fleets**: run `-DiagnoseOnly` on a sample of devices first. A `WOULD BLOCK` verdict means those devices need Ethernet, a manually joined Wi-Fi network, or `-WifiPreserveMode BestEffort` with the understanding that they may go offline.
- **802.1X Wi-Fi**: certificates and credentials issued by the previous MDM do not survive unenrollment, and the script cannot recreate them. Plan those devices on a wired connection or a temporary PSK network, and deliver the new 802.1X profile from Iru after registration.
- **Proxies**: the post-unenroll wait probes the registration host on TCP 443 directly. If that probe already fails before unenrolling, the script waits for a default route instead and says so in the log.
- **Location services on 24H2+**: not required. The script no longer depends on `netsh wlan show interfaces`, and a blocked `netsh wlan connect` is handled by letting Windows auto-connect.
- **RMM tools**: use `-Detach` when the agent that launches the script was installed by the MDM you are leaving, or when the tool's script timeout is shorter than a migration. Do not use `-Detach` with Intune.
- **Files left on the device**: the Wi-Fi backup folder is removed on every exit path unless a profile failed to re-add after three attempts (the log then names the folder and the `netsh wlan add profile` command to recover it). The `-Detach` run folder is emptied as the task starts. Registry backups from the unenrollment cleanup are kept; the run summary prints their location.

### Autopilot Deployment Requirements
When running this script as part of an Autopilot deployment, the following Intune configuration is required:

1. **Disable Enrollment Status Page (ESP)**: The Enrollment Status Page must be disabled in the Autopilot Deployment Profile. If ESP is enabled, the script may run before the user profile is fully created, which can cause the script to incorrectly identify the user (e.g., picking up `defaultuser0` instead of the actual Azure AD UPN).

2. **User-Driven Deployment**: The Autopilot Deployment Profile must be configured as **User-Driven** (not Self-Deploying or Pre-Provisioned). This ensures the user signs in before the script runs, allowing the script to correctly identify the logged-in user's UPN.

These settings ensure the script runs after the user has signed in and their profile is fully created, allowing for accurate user identification during the MDM migration process.

## Script Flow Summary
1. Validate required parameters (defaults/CLI combined). With `-Detach`, hand off to the scheduled task here and exit 0.
2. (Optional) Show intro dialog unless `-Silent` is set. User cancellations exit with code `0`.
3. Confirm elevation and initialize logging.
4. Find the UPN of the user.
5. Retrieve the enrollment token from your Iru gateway.
6. **Wi-Fi gate** (only when an enrollment exists): back up all Wi-Fi profiles, assess whether the connected network can be restored, abort with exit code `4` in `Enforce` mode if it cannot and no other uplink exists.
7. Enumerate existing enrollments and attempt unenrollment when present.
8. **Wi-Fi restore**: re-add the profiles Windows removed, reconnect.
9. Artifact cleanup and the residual-state check (exit code `3` if registration would be blocked).
10. **Wait for the network** (up to `-WifiReconnectTimeoutSeconds`) before registering.
11. Register the device with Kandji using `RegisterDeviceWithManagement`.
12. Final Wi-Fi restore sweep, then execute configured application uninstall commands.
13. Remove the Wi-Fi backup, write the run summary to the log and (when not silent) display the completion dialog.

## Exit Codes
- `0` – Success (or the user cancelled from the intro dialog, or `-Detach` handed off to the scheduled task)
- `1` – Validation failure, token retrieval failure, failed `-Detach` hand-off, unenroll/register failures without explicit HRESULTs
- `3` – Stopped before registration because residual state from the previous MDM would block it; the device stays on its original MDM
- `4` – **New.** Stopped before unenrolling because the device would lose its network (`-WifiPreserveMode Enforce`). The device is unchanged and still enrolled in its current MDM.
- `>1` (other) – Specific HRESULT returned by the Windows registration API

Use these exit codes in your deployment tooling to detect success/failure conditions. With `-Detach`, the exit code of the launching process only reflects the hand-off; the migration's own exit code is in its log.

## Changelog
- **1.3.1** (2026-11-10): Wi-Fi detection without Location services (`Get-NetConnectionProfile` instead of `netsh wlan show interfaces`); network profile name matching with the Windows " 2" suffix; stop retrying a `netsh wlan connect` that Windows blocks and rely on auto-connect; `-Detach` for RMM tools.
- **1.3.0**: Wi-Fi backup, restore and pre-unenroll gate (`-WifiPreserveMode`, `-WifiReconnectTimeoutSeconds`); exit code 4.
- **1.2.0**: the supported script in `Iru WindowsScripts/`.
