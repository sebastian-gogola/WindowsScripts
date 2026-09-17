# Invoke-IruEnrollment - Iru enrollment inside an existing provisioning flow

**Status: plan and proof-of-concept kit. Nothing here has been executed on Windows yet.** Every script was written against verified documentation and the source of the official migration script, then checked for PowerShell 5.1 syntax, but the first real run happens on the prospect's test hardware. Section 9 is the test plan for exactly that.

## 1. The situation this is for

A prospect already provisions Windows devices with two tools and does not use Microsoft Entra ID or Intune:

- **Windows provisioning packages** (`.ppkg`, built with Windows Configuration Designer) applied during the out-of-box experience or to an installed image.
- **OSDCloud** (David Segura's PowerShell deployment framework) to lay Windows 11 down from WinPE and run post-install automation.

If they buy Iru, they want Iru enrollment to happen inside that flow, not as a separate step a user performs afterwards. Iru's own zero-touch answer for Windows is Windows Autopilot, which needs Entra ID plus an Intune deployment profile, so it is not available to them. What Iru does provide for scripted enrollment is the official migration script, [`mdmmigration.ps1`](../../Iru%20WindowsScripts/mdmmigration.ps1), which enrolls a device through the Windows MDM registration API using the tenant's enrollment code and works unattended as SYSTEM.

This folder turns that script into something a provisioning flow can call, and documents where to call it from.

## 2. Recommendation in one paragraph

Build one small **drop-in bundle**: `Invoke-IruEnrollment.ps1` (this folder) plus an unmodified copy of `mdmmigration.ps1`. Put the bundle wherever the prospect's flow already runs SYSTEM-context scripts. For provisioning packages that is either one extra line in the orchestrator script their package already runs, or a separate Iru-only package built from the template here. For OSDCloud that is the `OSDCloud\Automate\Provisioning` folder, where OSDCloud applies any `.ppkg` to the freshly installed image, so the **same package serves both flows**. The wrapper handles what a provisioning context lacks: it waits for the network, syncs the clock, runs the migration script silently, records the outcome, and, when the device has no network at that moment, hands off to a one-shot retry task at next startup. Because the migration script exits 0 on a device already enrolled in Iru, the step is safe to re-run after any reboot the prospect's own flow performs.

### 2.1 The two USB flows at a glance

Both start from the same built package (`Iru-Enrollment_1.0.ppkg`, section 6.2). Details and alternatives follow in sections 6 and 7.

**Provisioning package on a USB stick, applied at OOBE**

1. Copy the `.ppkg` to the root of a USB drive. Keep it the only package on the drive so Windows applies it without a menu.
2. Boot the device to the first OOBE page (language, region, keyboard) and insert the drive. If nothing happens, press the Windows key five times and choose to install the package.
3. Accept the trust prompt (unsigned package). Windows shows a spinner while the command runs as SYSTEM, then continues OOBE. The device is enrolled before the user creates an account.
4. If the device had no network at that moment, the wrapper's retry task enrolls it at the next startup once network exists.

**OSDCloud USB**

1. On the OSDCloud USB drive the prospect already uses, create `OSDCloud\Automate\Provisioning\` on the data partition and copy the same `.ppkg` there.
2. Deploy as they do today (`Windows 11 24H2 x64` or `25H2`). At the end of deployment OSDCloud adds the package to the offline image with DISM.
3. On first boot the provisioning engine applies the embedded package and the command runs as SYSTEM. No trust prompt applies to embedded packages.
4. Alternative when they prefer scripts over packages: drop `Invoke-IruEnrollment.ps1`, `mdmmigration.ps1` and a `SetupComplete.cmd` into `OSDCloud\Config\Scripts\SetupComplete\` (section 7.2).

## 3. How enrollment behaves at provisioning time

What the official script does, read from its source (v1.2.0, updated 2026-07-27):

1. Validates the five tenant values, then fetches an access token from `https://<TenantName>.gateway.iru.com/main-backend/app/v1/mdm/enroll-ota/<BlueprintId>?code=<EnrollmentCode>&platform=windows` (EU: `gateway.eu.iru.com`).
2. Determines the interactive user from the LogonUI session data in the registry, falling back to a local account name, then a SID, then `NULL`.
3. Enumerates existing MDM enrollments. A device already on Kandji/Iru exits 0 without changes. Foreign enrollments are unenrolled and their artifacts cleaned; a residual state that would block registration stops the run with exit 3 before anything is registered.
4. Calls `RegisterDeviceWithManagement(UPN, https://<TenantId>.web-api.kandji.io/ms/enrollment/discovery, token)` (EU: `web-api.eu.kandji.io`). Microsoft requires the caller to be elevated; the user principal name parameter is descriptive and the script passes whatever it found, including `NULL`.
5. Logs to `C:\ProgramData\Iru\MDMMigration\Logs\MDM-Unenroll_<timestamp>.log`. Exit codes: 0 success or already enrolled, 1 validation or generic failure, 3 residual state blocked registration, any other value is the registration HRESULT.

Consequences for a provisioning context, and how the kit handles each:

| Provisioning reality | Effect on the script | Handling |
|---|---|---|
| Commands run as SYSTEM before any user account exists (vendor-documented for provisioning packages; OSDCloud's SetupComplete likewise). | The identity it attaches to the enrollment will be the temporary OOBE account (`defaultuser0`) or `NULL`. Iru's own guidance for Autopilot warns about exactly this. | Accepted. The enrollment is MDM-only with no directory identity anyway; the device record's user is set later in the Iru console or API (see 3.1). The wrapper logs the identity it sees so the PoC confirms the behavior. |
| Network may not be up yet; Wi-Fi certainly is not unless the package carries a profile. | Token fetch fails, exit 1, and the device is left unenrolled. | Wrapper polls the two tenant hosts on 443 up to `$NetworkWaitSeconds`, then registers a SYSTEM retry task with a network-available condition if they never answer. |
| Clock skew on fresh hardware breaks TLS. | Token fetch fails with a certificate error. | Wrapper starts W32Time and forces a resync before the wait. |
| Provisioning packages allow 30 minutes for all commands together and require complete silence (vendor-documented). | The script already defaults to silent. A hang would consume the budget. | Wrapper passes `-Silent`, runs the script as a hidden child process, and kills it after `$MigrationTimeoutSeconds`. |
| The prospect's flow may reboot after our step. | Second run finds a Kandji/Iru enrollment and exits 0. | Wrapper additionally short-circuits when a Kandji/Iru ProviderID is already present, so no network wait happens on a finished device. |
| Iru supports Windows 11 24H2 and 25H2 only, on Pro, Pro Education, Enterprise, Education (vendor-documented). | Enrollment of an older build would be unsupported. | Wrapper exits 2 below build 26100. OSDCloud must be configured for `Windows 11 24H2 x64` or `25H2`. |

### 3.1 What enrollment does not give them

- **User assignment in Iru.** Nothing in this flow knows who the device is for. Assignment stays a console or API step. The repo's `Assign-IruDeviceUser` script needs an interactive user with a directory identity and will not help on local-account devices.
- **A local user account.** Windows still walks through account creation unless the package creates one (Windows Configuration Designer: Runtime settings > Accounts > Users, optionally with OOBE > Desktop > HideOobe). Microsoft notes a local account created by a package must have its password changed within 42 days or it may lock out. The repo's `Manage-LocalAdmin` script can take over such accounts after enrollment.
- **Require Authentication.** The blueprint behind the enrollment code must have Require Authentication off; the official documentation states the script fails otherwise.

## 4. What is in this folder

| File | Purpose |
|---|---|
| `Invoke-IruEnrollment.ps1` | The wrapper. Modes `Enroll` and `Probe`. Runs `mdmmigration.ps1` as a child process, never modifies it, never dot-sources it. Config block plus optional command-line overrides. |
| `customizations.xml` | Windows Configuration Designer customization template for a standalone `Iru-Enrollment` package: two command files, one command line. Placeholders are filled by the build script. |
| `Build-IruEnrollmentPackage.ps1` | Technician-machine script. Stages the two files, fills the template, calls `ICD.exe /Build-ProvisioningPackage`. Copies `mdmmigration.ps1` from the repo's `Iru WindowsScripts` folder at build time so nothing is duplicated in git. |
| `OSDCloud/SetupComplete.cmd` | Sample entry point for the OSDCloud SetupComplete hook, for a workspace that has none yet. If one exists, the one `powershell.exe` line in it is all that is added. |

`mdmmigration.ps1` is deliberately **not** copied into this folder. The bundle always takes it from `Iru WindowsScripts\` so the version deployed is the version Iru published.

## 5. Prerequisites

**In the Iru tenant** (vendor-documented, docs.iru.com):

- Windows platform enabled for the tenant; a blueprint for Windows configured with the Library Items the prospect wants applied.
- The blueprint's manual enrollment code (Enrollment > Manual Enrollment), with Require Authentication **off** for that blueprint.
- The four other values for the wrapper: TenantName (sign-in URL prefix), BlueprintId (GUID from the blueprint URL), TenantId (prefix of the Device Domain under Organization > Device Domains), TenantLocation (US or EU).

**Devices**:

- Windows 11 24H2 or 25H2, Pro / Pro Education / Enterprise / Education. A serial number is required; virtual machines need one set (Hyper-V exposes a BIOS serial per VM; verify with `Get-CimInstance Win32_BIOS`).
- Outbound HTTPS at provisioning time to, at minimum: `<TenantName>.gateway.iru.com`, `<TenantId>.web-api.kandji.io`, `windows-agent.kandji.io`, `updater.iru.com`, `*.notify.windows.com`, `*.wns.windows.com`, `login.microsoftonline.com`, `login.live.com`, `*.c.lencr.org` (EU variants where applicable). The Iru Agent pins certificates, so TLS inspection must exempt the tenant device domains. A wired connection is the simplest way to guarantee network during OOBE.

**Technician machine**: Windows 11 with Windows Configuration Designer (Microsoft Store app, or the Windows ADK "Imaging and Configuration Designer" component for the `ICD.exe` command line). For OSDCloud, whatever workspace the prospect already maintains.

**Prospect's answers needed before the PoC**:

1. Which OSDCloud do they run: the OSD module (`Start-OSDCloud` / `Start-OSDCloudGUI`, documented on osdcloud.com as "OSDCloud v1") or the newer `OSDCloud` module (`Deploy-OSDCloud`, "v2")? Everything in section 7 was verified against the OSD module's source. The v2 module's hooks could not be source-verified (its repository is not public).
2. Does their existing package already have a `ProvisioningCommands` command line? Windows allows exactly one per package, which decides between 6.1 and 6.2.
3. Do their devices provision on Ethernet or Wi-Fi?
4. Do their devices carry an OEM Windows license in firmware? It decides whether the OSDCloud SetupComplete hook is trustworthy (see 7.2).

## 6. Integration A: provisioning package

### 6.1 Existing package with its own orchestrator (preferred when they have one)

Windows allows one `CommandLine` per package but any number of `CommandFiles`, all copied to one temp folder that becomes the working directory. So:

1. Add `Invoke-IruEnrollment.ps1` and `mdmmigration.ps1` to the package's `ProvisioningCommands > DeviceContext > CommandFiles` (Windows Configuration Designer, Advanced provisioning project). File names must be unique within the package.
2. In the `.cmd` or `.ps1` their command line already runs, add one line. From a batch orchestrator:

```bat
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Invoke-IruEnrollment.ps1" -RunSource PPKG -TenantName contoso -BlueprintId <guid> -EnrollmentCode <code> -TenantId <prefix> -TenantLocation US
```

   From a PowerShell orchestrator, launch it the same way as a child process. Do not dot-source or `&` it: both scripts call `exit`, which would terminate the orchestrator.

3. Place the line after any step that provides network (a Wi-Fi profile, a proxy setting) and before any step that restarts the device. If their orchestrator reboots on its own, the retry task and the already-enrolled short-circuit make a second pass harmless.
4. Rebuild, then apply as they do today.

### 6.2 Standalone Iru-Enrollment package

For a package the prospect has not built yet, or when they want the Iru step separable:

1. On the technician machine, fill the CONFIGURATION block of `Build-IruEnrollmentPackage.ps1` (tenant values, `$WrapperMode = 'Probe'` for the first package, `'Enroll'` afterwards) and run it elevated. It stages the two files under `C:\IruEnrollment\build\files\`, writes a filled `customizations.xml`, and builds `Iru-Enrollment_1.0.ppkg` with `ICD.exe` when found. Without `ICD.exe` it prints the exact command and leaves the staged files for the Windows Configuration Designer UI (Advanced provisioning > File > Import customizations, or recreate the two settings by hand).
2. Do not commit the built package or a filled-in copy of the build script: the enrollment code sits in clear text in the command line.
3. Rebuilds keep the same package ID (persisted in `package-id.txt` in the output folder); bump `$PackageVersion` when a device that already received the package should accept the new one.

Package signing and encryption (vendor-documented): an unsigned package applied from USB at OOBE shows a "from a source you trust?" prompt that must be accepted on the device. Signing with a certificate the device trusts (TrustedProvisioners setting) removes the prompt; encryption removes it too but asks for the password at OOBE, which defeats zero-touch. Packages embedded in the image (6.3.3 and 7.1) are applied regardless of signing.

### 6.3 Applying the package

Vendor-documented paths, all usable with the same file:

1. **At OOBE from USB.** Package at the root of a USB drive. Get the device to the first OOBE page (language, region, keyboard), insert the drive; if nothing happens, press the Windows key five times. A single package on the drive is applied automatically; with several, choose "Install provisioning package". Accept the trust prompt for an unsigned package. Provisioning commands run immediately, before account creation, behind a "please wait" spinner. OOBE then continues to the usual pages.
2. **On an installed device.** Settings > Accounts > Access work or school > Add or remove a provisioning package > Add a package, or from an elevated prompt:

```powershell
Install-ProvisioningPackage -PackagePath C:\path\Iru-Enrollment_1.0.ppkg -QuietInstall
```

   The cmdlets suppress the unsigned-package prompt and are documented for Windows 11 clients. This is the fastest PoC path (test T2).
3. **Embedded in the offline image** with `DISM /Image:<mount> /Add-ProvisioningPackage /PackagePath:<ppkg>`; the provisioning engine applies embedded packages during the OOBE pass whether or not they are signed. This is what OSDCloud does (7.1).
4. **Persisted for reset.** A package copied into `C:\Recovery\Customizations` is applied by the provisioning engine and restored by push-button reset, so a device the prospect resets re-enrolls on its own. Optional; note the folder's ACL requirements in Microsoft's auto-apply documentation.

## 7. Integration B: OSDCloud

Verified against the OSD module source (GitHub master 26.9.8.1, 2026-09-08; PowerShell Gallery 26.8.1.1) and osdcloud.com. All hooks look on every drive except `C:`, so content works from the USB data partition, the WinPE boot partition, or the boot image.

### 7.1 Automate\Provisioning (recommended)

`Invoke-OSDCloud` collects every `*.ppkg` under `<drive>:\OSDCloud\Automate\Provisioning` and, at the end of deployment, runs `dism.exe /Image=C:\ /Add-ProvisioningPackage /PackagePath:<file>` against the offline image. osdcloud.com describes the effect as active when the user first logs in. Nothing in OSDCloud's own configuration changes:

1. Copy `Iru-Enrollment_1.0.ppkg` (from 6.2) to `<OSDCloud USB>\OSDCloud\Automate\Provisioning\` (or the workspace `Media\OSDCloud\Automate\Provisioning\` for ISO/VM testing; osdcloud.com warns large packages may not fit the boot partition).
2. Deploy as usual with `Windows 11 24H2 x64` or `25H2`, Pro or Enterprise as licensed. On restart the image boots to Specialize, then OOBE, and the embedded package's command runs as SYSTEM.

Why preferred: one artifact for both flows, no dependency on SetupComplete semantics, and the package applies even on devices with OEM firmware keys.

Open question for the PoC: whether the command fires in the Specialize pass or the OOBE pass on an embedded package. OSDCloud uses the same mechanism to expand driver packs during Specialize, so the earlier phase is plausible. If MDM registration is not possible that early, set `$RetryOnMigrationFailure = $true` in the wrapper for the PoC so the second attempt runs from the retry task after the first boot completes, and record which phase the log shows.

### 7.2 SetupComplete hook (alternative)

`Invoke-OSDCloud` writes `C:\Windows\Setup\Scripts\SetupComplete.cmd` and a `SetupComplete.ps1` that does the work. If `<drive>:\OSDCloud\Config\Scripts\SetupComplete\` contains files, the folder is copied to `C:\OSDCloud\Scripts\SetupComplete\` and the generated script runs the file named exactly `SetupComplete.cmd` from there (`cmd.exe /c`, SYSTEM, first boot). Afterwards OSDCloud restarts the device (`Restart-Computer -Force`) unless `$Global:OSDCloud.SetupCompleteNoRestart` is set; a reboot after enrollment is what Iru recommends anyway.

1. Copy `Invoke-IruEnrollment.ps1` and `mdmmigration.ps1` into `OSDCloud\Config\Scripts\SetupComplete\` of the workspace or USB.
2. If they already have a `SetupComplete.cmd` there, add the `powershell.exe` line from `OSDCloud/SetupComplete.cmd`. If not, copy the whole sample.
3. Fill the wrapper's CONFIGURATION block or append the tenant parameters to that line.
4. Output lands in the wrapper log and in OSDCloud's transcript `C:\Windows\Temp\osdcloud-logs\SetupComplete.log`.

Caveats, both from the research and to be confirmed in the PoC: Microsoft documents that `SetupComplete.cmd` is disabled when Windows is installed with an OEM product key except on Enterprise editions. OSDCloud applies the image without a key and injects the firmware key from inside SetupComplete, which is presumably why its own SetupComplete works on OEM hardware, but no OSDCloud documentation says so. Also, the generated `SetupComplete.ps1` downloads a module from GitHub before running anything, so the prospect's flow already assumes internet at this point. Startup and Shutdown script folders are not alternatives: both execute inside WinPE.

### 7.3 Zero-touch OSDCloud settings that matter

For the OSD module, either `Edit-OSDCloudWinPE -StartOSDCloud "-OSName 'Windows 11 24H2 x64' -OSEdition Pro -OSLanguage en-us -OSActivation Retail -ZTI -Restart"` in the boot image, or `Start-OSDCloudGUI.json` under `OSDCloud\Automate` with `OSName`, `OSEdition`, `OSActivation`, `restartComputer: true`. `-ZTI` wipes the single fixed disk without confirmation; `-Restart` reboots WinPE into the new image after 30 seconds. Nothing Iru-specific is required here.

## 8. Wrapper reference

Settings (`Invoke-IruEnrollment.ps1`, CONFIGURATION block; the first six can also be passed as parameters, which win over the block):

| Setting | Default | Meaning |
|---|---|---|
| `$ConfigMode` / `-Mode` | `Enroll` | `Enroll` performs the enrollment; `Probe` changes nothing and reports what an enrollment would see, then runs `mdmmigration.ps1 -DiagnoseOnly`. |
| `$ConfigTenantName` .. `$ConfigTenantLocation` | empty / `US` | The five values the migration script needs. Validated the same way the script validates them. |
| `$ConfigRunSource` / `-RunSource` | `PPKG` | Free label written to log and state so runs from different entry points can be told apart (`PPKG`, `OSDCloud`, `Manual`). The retry task records `RetryTask`. |
| `$MigrationScriptName` | `mdmmigration.ps1` | Expected beside the wrapper. Missing file is exit 2. |
| `$MigrationDebug` | `$false` | Passes `-Debug` to the migration script. |
| `$SkipWhenAlreadyEnrolled` | `$true` | Exit 0 immediately when a Kandji/Iru ProviderID is already present. |
| `$NetworkWaitSeconds` / `$NetworkPollSeconds` | 300 / 10 | TCP 443 checks against the gateway and web-api hosts derived from the tenant values. |
| `$MigrationTimeoutSeconds` | 1200 | Child process is killed past this; keep wait + timeout under the package's 30-minute budget. |
| `$ForceTimeSync` | `$true` | Start W32Time and `w32tm /resync` before waiting. Never fatal. |
| `$RequiredOsBuild` | 26100 | Windows 11 24H2. Exit 2 below it. |
| `$RegisterRetryTask` | `$true` | On unreachable endpoints, stage the bundle to `%ProgramData%\IruScripts\Enrollment` and register `IruScripts-EnrollmentRetry` (SYSTEM, at startup + 2 min, network required, up to `$RetryMaxAttempts`). Self-removing after success or exhaustion. |
| `$RetryOnMigrationFailure` | `$false` | Also schedule the retry when the migration script fails. PoC aid, see 7.1. |
| `$ExitCodeWhenRetryScheduled` | 0 | Return value when work was handed to the retry task. Set 1 if the orchestrator must treat "not yet enrolled" as failure. |
| `$ProbeFetchToken` | `$false` | Probe only: request a token from the gateway to prove the tenant values are accepted. Never logs the token. |
| `$LogFile` | `%ProgramData%\IruScripts\Logs\Invoke-IruEnrollment.log` | The migration script's own log stays under `%ProgramData%\Iru\MDMMigration\Logs`; its stdout is also folded into the wrapper log. |

State: `HKLM\SOFTWARE\IruScripts\Enrollment` with `LastRun`, `LastMode`, `LastSource`, `LastResult` (`Enrolled`, `AlreadyEnrolled`, `RetryScheduled`, `RetryPending`, `RetryExhausted`, `BlockedByResidualState`, `TimedOut`, `Failed`, `PreconditionFailed`, `Probe:<verdict>`), `LastDetail`, `LastMigrationExitCode`, `RetryAttempts`.

Exit codes: `0` enrolled, already enrolled, or retry scheduled; `1` migration failed, timed out, endpoints unreachable with no retry possible, or Probe found endpoints unreachable or tenant values rejected; `2` precondition (not elevated, build below 24H2, `mdmmigration.ps1` missing, incomplete tenant values, invalid mode).

## 9. Proof-of-concept test plan

Run in order; each step's evidence is the wrapper log, the migration log, and the Iru console. Use a throwaway blueprint and a dedicated enrollment code so test devices are easy to find and delete.

| # | Test | Setup | Pass criteria |
|---|---|---|---|
| T0 | Static checks (done here) | Pure ASCII, PowerShell 5.1 syntax, bracket balance, disclaimer block identical to other Sandbox scripts. | All pass (see section 12). |
| T1 | Manual Probe | Any Windows 11 24H2 test VM or device, signed in as admin. Bundle in a folder, tenant values filled. `powershell -ExecutionPolicy Bypass -File .\Invoke-IruEnrollment.ps1 -Mode Probe -RunSource Manual`, then again with `$ProbeFetchToken = $true`. | Verdict `ReadyToEnroll`; both hosts reachable; token present; `-DiagnoseOnly` output shows zero enrollments. |
| T2 | Manual Enroll | Same device, `-Mode Enroll`. | Exit 0; "Enrollments after" shows a ProviderID matching Kandji/Iru; device appears in the Iru console within minutes under the test blueprint; Iru Agent checks in within 15 minutes; a Library Item applies. Run again: exit 0 with `AlreadyEnrolled` and no network wait. |
| T3 | Package on installed device | Build the package (`$WrapperMode = 'Probe'` first, then `'Enroll'`). On a fresh VM after OOBE: `Install-ProvisioningPackage -PackagePath ... -QuietInstall`. | Provisioning-Diagnostics-Provider Admin log shows the package applied; wrapper log shows `Source=PPKG`; same console results as T2. `Get-ProvisioningPackage -AllInstalledPackages` lists it. |
| T4 | Package at OOBE, wired | Hyper-V Generation 2 VM (or physical device) with Ethernet, fresh 24H2 install stopped at the first OOBE page. USB with only the Enroll package. Windows key five times if needed, accept the trust prompt. | Spinner, then OOBE continues; after account creation the wrapper log shows `OOBEInProgress=1` in setup state, identity `defaultuser0` (expected), exit 0, device in console. Note the elapsed time against the 30-minute budget. |
| T5 | Package at OOBE, no network | Repeat T4 with the NIC disconnected. | Wrapper exits `RetryScheduled` after `$NetworkWaitSeconds`; task `IruScripts-EnrollmentRetry` exists; reconnect and reboot; retry run enrolls, task and staged bundle are gone, `RetryAttempts` incremented. |
| T6 | OSDCloud + Automate\Provisioning | Prospect's OSDCloud USB or a workspace ISO in a Hyper-V Gen 2 VM (`New-OSDCloudVM` builds one). Package in `OSDCloud\Automate\Provisioning`. Deploy 24H2 Pro, `-Restart`. | `C:\Windows\Temp\osdcloud-logs\*-Deploy-OSDCloud.log` shows the DISM add; after first boot the wrapper log exists with `Source=PPKG`; record the setup state values to learn the phase; device in console. If exit 1 with a registration HRESULT in the early phase, rerun with `$RetryOnMigrationFailure = $true`. |
| T7 | OSDCloud + SetupComplete | Bundle plus `SetupComplete.cmd` in `OSDCloud\Config\Scripts\SetupComplete`. Deploy. | `SetupComplete.log` shows the call; wrapper log `Source=OSDCloud`; device in console. Repeat on a device with an OEM firmware key on Pro edition to test the OEM caveat. |
| T8 | Negative: wrong code | T2 with a wrong enrollment code. | Migration log "No access token found" or HTTP error; wrapper exit 1, `LastResult=Failed`, no enrollment record left behind. |
| T9 | Negative: unsupported build | Any 23H2 VM. | Wrapper exit 2 before any network activity. |
| T10 | Rollback | Section 11 on a T2 device. | Device gone from console and from `HKLM\SOFTWARE\Microsoft\Enrollments`; T2 enrolls it again. |

Evidence to collect per run: `%ProgramData%\IruScripts\Logs\Invoke-IruEnrollment.log`, the newest `%ProgramData%\Iru\MDMMigration\Logs\MDM-Unenroll_*.log`, `mdmdiagnosticstool.exe -area "DeviceEnrollment;DeviceProvisioning" -zip C:\Users\Public\MDMDiag.zip`, and a screenshot of the device record in the Iru console.

## 10. Verification and troubleshooting

On the device:

```powershell
Get-Content "$env:ProgramData\IruScripts\Logs\Invoke-IruEnrollment.log" -Tail 60
Get-ItemProperty HKLM:\SOFTWARE\IruScripts\Enrollment
Get-ChildItem HKLM:\SOFTWARE\Microsoft\Enrollments | ForEach-Object { Get-ItemProperty $_.PSPath } | Select-Object PSChildName, ProviderID, EnrollmentState, DiscoveryServiceFullURL
Get-ScheduledTask -TaskName IruScripts-EnrollmentRetry -ErrorAction SilentlyContinue
Get-WinEvent -LogName 'Microsoft-Windows-Provisioning-Diagnostics-Provider/Admin' -MaxEvents 30
Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin' -MaxEvents 30
```

| Symptom | Likely cause | Where to look |
|---|---|---|
| Wrapper log absent after a package apply | Command never ran: package not applied, or command line malformed. | Provisioning-Diagnostics-Provider Admin log; `Get-ProvisioningPackage -AllInstalledPackages`; for OSDCloud, the Deploy-OSDCloud transcript for the DISM line. |
| `PreconditionFailed` with `mdmmigration.ps1 missing` | Only one file made it into `CommandFiles`, or the OSDCloud folder was copied without it. | Wrapper log "Script directory" line; list that folder. |
| `RetryScheduled` on every device | No network at that phase (Wi-Fi fleet), or the tenant hosts blocked by a proxy. | "Network check" lines; test the two hosts from a working device; consider a WLAN profile in the package (Runtime settings > ConnectivityProfiles > WLAN). |
| Migration log: token request failed with certificate error | Clock skew or TLS inspection. | "System time (UTC)" line; Iru's network requirements on certificate pinning. |
| Migration log: "No access token found" | Wrong enrollment code or blueprint, or Require Authentication on. | Iru console, Enrollment > Manual Enrollment. |
| Migration exit 3 | Residual state from an earlier MDM on a reimaged device that kept its disk. | `mdmmigration.ps1 -DiagnoseOnly`; the official mdmmigration.md. |
| Registration HRESULT 0x8018xxxx | MDM registration rejected. | Microsoft "MDM Registration Error Values"; the DeviceManagement-Enterprise-Diagnostics-Provider log around the timestamp. |
| Enrolled but no Iru Agent | Agent download blocked. | `windows-agent.kandji.io` reachability; agent check-in is every 15 minutes. |
| OSDCloud SetupComplete never ran | OEM key caveat, or folder lacked a file named exactly `SetupComplete.cmd`. | `C:\Windows\Panther\UnattendGC\Setupact.log`; `C:\OSDCloud\Scripts\SetupComplete\` contents. Fall back to 7.1. |

## 11. Rollback

- **Unenroll one device**: delete or unenroll the device in the Iru console; Windows removes the enrollment on the next check-in. Locally, Settings > Accounts > Access work or school > disconnect the Iru account also works. The migration script has no unenroll-only mode.
- **Remove the retry task and staged bundle**: `Unregister-ScheduledTask -TaskName IruScripts-EnrollmentRetry -Confirm:$false` and delete `%ProgramData%\IruScripts\Enrollment`. The wrapper does this itself after success or exhausted attempts.
- **Remove the package record**: `Uninstall-ProvisioningPackage -PackageId <id>` (or Settings > Add or remove a provisioning package). Microsoft documents that removing a package does not undo what device-context commands did, so this does not unenroll.
- **Stop the flow**: remove the `.ppkg` from the USB root, `OSDCloud\Automate\Provisioning`, or the SetupComplete folder; remove the added line from the orchestrator. Nothing else was changed on the technician side.
- **State key**: `HKLM\SOFTWARE\IruScripts\Enrollment` can be deleted freely; it holds evidence only.

## 12. Limitations and open items

- **Untested.** Static checks only (ASCII, PowerShell 5.1 parse, bracket balance, disclaimer). T1 to T10 are the real validation.
- **Identity on the enrollment record** will be `defaultuser0` or `NULL` at OOBE (inferred from how the migration script reads LogonUI session data and how OOBE runs under that temporary account). Cosmetic for an MDM-only enrollment; confirm in T4.
- **Enrollment code in clear text** inside the package command line and, when the retry task is used, in `%ProgramData%\IruScripts\Enrollment\enrollment.json` until cleanup. The code is a shared secret already handed to end users in the portal flow; still, rotate it after the PoC.
- **Phase of execution for embedded packages** (Specialize versus OOBE) is not documented; see 7.1.
- **OSDCloud v2 module** (`Deploy-OSDCloud`) hooks are unverified; the v1 (OSD module) paths are verified from source.
- **SetupComplete and OEM keys**: Microsoft's restriction is documented, OSDCloud's behavior around it is inferred.
- **30-minute package budget** is shared with the prospect's other commands. Defaults here use at most 5 minutes waiting plus the migration run.
- **No user assignment, no local account** (3.1).
- **Wi-Fi devices** need a WLAN profile in the package or will rely on the retry task after the user connects.
- **Iru Autopilot and Entra bulk enrollment** were deliberately excluded: the prospect has neither Entra ID nor Intune.

## 13. Sourcing notes

**Vendor-documented (Iru, docs.iru.com and the repo's official files)**

- [Windows Enrollment](https://docs.iru.com/en/endpoint/getting-started/enrollment/windows-enrollment), [Configuring Windows Enrollment](https://docs.iru.com/en/endpoint/enrollment/windows/configuring-windows-enrollment), [Windows Setup](https://docs.iru.com/en/endpoint/getting-started/platform-setup/windows-setup), [Device Requirements](https://docs.iru.com/en/iru/requirements/device-requirements): supported versions and editions, serial number requirement (VMs need one), MDM framework plus Iru Agent, check-in cadence, enrollment code and blueprint model.
- [Configure Windows Autopilot](https://docs.iru.com/en/endpoint/settings/windows-integrations/configure-windows-autopilot): Entra app registration, custom domain and Intune user-driven deployment profile are required, which is why Autopilot is out of scope here.
- [Using Iru on Enterprise Networks](https://docs.iru.com/en/iru/requirements/using-iru-on-enterprise-networks): domains, ports, certificate pinning.
- `Iru WindowsScripts\mdmmigration.md` and `mdmmigration.ps1` (v1.2.0): parameters, endpoints, exit codes, Require Authentication limitation, the Autopilot note about `defaultuser0`, identity detection order. Read from source; nothing in that folder was modified.

**Vendor-documented (Microsoft Learn)**

- [Provisioning packages: how it works](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-how-it-works): OOBE trigger after the first page, USB at media root, Windows key five times, `%ProgramData%\Microsoft\Provisioning`, `C:\Recovery\Customizations` always applied, embedded packages applied regardless of signing, trust and password prompts.
- [Use a script to install a desktop app in provisioning packages](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-script-to-install-app): system context, runs before user account configuration, 30-minute timeout, silence requirement, one CommandLine, CommandFiles temp folder as working directory, unique file names, no built-in logging.
- [Provision PCs with apps](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provision-pcs-with-apps): return codes 0 and 3010 defaults, restart and continue-on-failure settings, removing a package does not remove what device-context commands installed.
- [Apply a provisioning package](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-apply-package), [Create a provisioning package](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-create-package), [PowerShell cmdlets](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-powershell), [Install-ProvisioningPackage](https://learn.microsoft.com/en-us/powershell/module/provisioning/install-provisioningpackage), [Windows Configuration Designer command line](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-command-line), [multivariant example with customizations.xml skeleton and ICD build command](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-multivariant), [Install Windows Configuration Designer](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provisioning-install-icd), [DISM provisioning package options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-provisioning-package-command-line-options?view=windows-11), [Deploy push-button reset features using auto-apply](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deploy-pbr-features-using-auto-apply?view=windows-11).
- [WCD Accounts](https://learn.microsoft.com/en-us/windows/configuration/wcd/wcd-accounts), [WCD ConnectivityProfiles](https://learn.microsoft.com/en-us/windows/configuration/wcd/wcd-connectivityprofiles), [WCD OOBE](https://learn.microsoft.com/en-us/windows/configuration/wcd/wcd-oobe), [Provision PCs for initial deployment](https://learn.microsoft.com/en-us/windows/configuration/provisioning-packages/provision-pcs-for-initial-deployment) (42-day local account note).
- [RegisterDeviceWithManagement](https://learn.microsoft.com/en-us/windows/win32/api/mdmregistration/nf-mdmregistration-registerdevicewithmanagement): parameters, elevated caller requirement, MS-MDE protocol. [MDM Registration Error Values](https://learn.microsoft.com/en-us/windows/win32/mdmreg/mdm-registration-constants).
- [Add a custom script to Windows Setup](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup): SetupComplete.cmd runs with local system permissions, disabled with OEM product keys except Enterprise, logged in `C:\Windows\Panther\UnattendGC\Setupact.log`.
- [Collect MDM logs](https://learn.microsoft.com/en-us/windows/client-management/mdm-collect-logs): `mdmdiagnosticstool.exe` areas and the Provisioning-Diagnostics-Provider channel.

**Vendor-documented (OSDCloud, osdcloud.com) and source-verified (OSDeploy/OSD on GitHub, master 26.9.8.1)**

- [About OSDCloud](https://www.osdcloud.com/about-osdcloud.md), [Automate: Provisioning](https://www.osdcloud.com/osdcloud-v1/osdcloud-automate/provisioning.md), [PowerShell script in a PPKG](https://www.osdcloud.com/osdcloud-v1/osdcloud-automate/provisioning/powershell-script-ppkg.md), [OSDCloudGUI defaults](https://www.osdcloud.com/osdcloud-v1/osdcloud-automate/osdcloudgui-defaults.md), [Start-OSDCloud ZTI](https://www.osdcloud.com/osdcloud-v1/osdcloud/deployment/winpe/start-osdcloud/zti.md), [First boot](https://www.osdcloud.com/osdcloud-v1/osdcloud/deployment/first-boot.md), [New-OSDCloudVM](https://www.osdcloud.com/osdcloud-v1/osdcloud/setup/osdcloud-vm/new-osdcloudvm.md).
- Source: `Public/OSDCloud.ps1` (Automate\Provisioning collection and `dism.exe /Image=C:\ /Add-ProvisioningPackage`, SetupComplete creation and finish with `Restart-Computer -Force`, Startup/Shutdown scripts executed in WinPE, `-Restart` behavior), `Public/OSDCloudTS/Set-SetupCompleteOSDCloudUSB.ps1` (copy of `OSDCloud\Config\Scripts\SetupComplete` to `C:\OSDCloud\Scripts\SetupComplete` and the fixed `SetupComplete.cmd` name), `Public/OSDCloudTS/Set-SetupCompleteCreateStart.ps1` (generated SetupComplete.ps1 contents, transcript path `C:\Windows\Temp\osdcloud-logs\SetupComplete.log`), `Public/OSDCloudTS/Set-WindowsOEMActivation.ps1`, `Public/OSDCloud/OSDCloudWinPE.ps1` (`Edit-OSDCloudWinPE` parameters), `Public/Start-OSDCloud.ps1` (`-OSName` values, `-ZTI`, `-Restart`), and the module's own [Provisioning\customizations.xml](https://www.powershellgallery.com/packages/OSD/24.9.18.1/Content/Provisioning%5Ccustomizations.xml), the model for the template here.

**Community-observed**

- OOBE runs under the temporary `defaultuser0` account in session 1 (Microsoft Tech Community and Q&A threads; sccmentor.com on Autopilot pre-provisioning). Basis for expecting that identity in the enrollment record.
- `HKLM\SYSTEM\Setup` values `OOBEInProgress`, `SystemSetupInProgress`, `SetupPhase` as OOBE indicators; read for evidence only.
- OSDCloud GitHub issues #268 and #277: SetupComplete scripts execute as SYSTEM with no interactive user at the "Just a moment" stage.
- Hyper-V VMs expose a per-VM BIOS serial number (`Msvm_VirtualSystemSettingData.BIOSSerialNumber`), changeable only while the VM is off.

**Inferred (design reasoning, to be confirmed by the test plan)**

- Network availability at the moment provisioning commands or SetupComplete run (wired yes, Wi-Fi no) and therefore the wait-plus-retry design.
- The phase (Specialize or OOBE) in which an embedded package's command runs, and whether MDM registration succeeds there.
- OSDCloud's SetupComplete surviving the OEM-key restriction because the image is applied without a key.
- Mapping of the migration script's exit codes to the wrapper's 0/1/2 and the decision to return 0 when the retry task takes over.
- The `CommandFile Name` attribute being a label while the file keeps its own name on the device (matches the OSD module's generated XML; confirm by inspecting the temp folder in T3).
