# Create-LocalAdmin.ps1

A production-ready PowerShell script for creating a local administrator account on Windows 11 endpoints, designed for deployment via MDM platforms (Iru) that support pushing custom PowerShell scripts but lack native CSP support for local user management.

---

## Table of Contents

- [Background & Motivation](#background--motivation)
- [Why PowerShell Over OMA-URI / CSP](#why-powershell-over-oma-uri--csp)
- [What the Script Does](#what-the-script-does)
- [Configuration Reference](#configuration-reference)
  - [Required Settings](#required-settings)
  - [Optional Flags](#optional-flags)
- [Deployment Guide](#deployment-guide)
- [Feature Deep-Dives](#feature-deep-dives)
  - [Idempotency](#idempotency)
  - [Well-Known SID for Group Membership](#well-known-sid-for-group-membership)
  - [Hiding the Account from the Login Screen](#hiding-the-account-from-the-login-screen)
  - [Disabling the Built-In Administrator Account](#disabling-the-built-in-administrator-account)
  - [Local Logging (Optional Backup)](#local-logging-optional-backup)
- [Security Considerations](#security-considerations)
  - [Password Storage](#password-storage)
  - [Why LAPS Is Not Included](#why-laps-is-not-included)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [License](#license)

---

## Background & Motivation

Many organizations enroll Windows devices into an MDM and need a local administrator account available on the endpoint for break-glass scenarios, remote support, or local troubleshooting when the device is offline or the cloud identity provider is unreachable. While Azure AD (Entra ID) joined devices can grant admin rights to cloud accounts, a local admin provides a reliable fallback that works regardless of network connectivity or directory health.

Most MDM platforms expose the ability to push custom PowerShell scripts to managed endpoints. Some also expose OMA-URI policies backed by Windows CSPs (Configuration Service Providers) that can theoretically create local accounts. In practice, however, the CSP approach is unreliable enough that the PowerShell method has become the industry-standard approach recommended by experienced administrators.

---

## Why PowerShell Over OMA-URI / CSP

Windows includes an `Accounts/Users` CSP that MDMs can invoke via OMA-URI to create local user accounts. On paper this seems like the cleaner solution — it is declarative, does not require a script agent, and fits neatly into the MDM policy model. In practice, it has well-documented problems that make it unsuitable for production use.

### Documented Timing and Reliability Issues

The `Accounts/Users` CSP fires during the ESP (Enrollment Status Page) phase of Autopilot provisioning, often before the device has fully completed its setup. This creates a race condition: the CSP attempts to create the user account while the system is still configuring core components, and the operation silently fails. Because the CSP does not reliably return error states to the MDM, the policy appears as "applied" or "pending" in the console even when the account was never created.

Specific problems administrators have reported include the following:

The CSP silently fails during Autopilot OOBE when the device has not yet completed all provisioning steps. The account creation call returns no error, but the account does not exist on the device after setup completes.

On hybrid Azure AD joined devices, the timing issue is compounded by the domain join step. The CSP may fire before or during the domain join, and depending on the order of operations, the local account creation can collide with Active Directory policy application.

There is no retry mechanism built into the CSP pathway. If the first attempt fails, the MDM considers the policy delivered and does not re-attempt. The admin has no visibility into the failure unless they manually inspect the device.

The CSP lacks support for configuring important account properties like group membership, password expiration policy, or login screen visibility. Even if the account is created successfully, the admin still needs a follow-up script to configure these properties, which defeats the purpose of using the CSP in the first place.

Error reporting back to the MDM console is inconsistent. Some MDMs show the policy as "succeeded" based on the delivery acknowledgment rather than the actual outcome on the device, creating a false sense of compliance.

### Why PowerShell Solves These Issues

PowerShell scripts pushed via MDM execute through the management agent (for example, the Intune Management Extension or the Workspace ONE Intelligent Hub). These agents have their own execution queue, retry logic, and reporting pipeline that operates independently of the ESP and CSP timing. The script runs after the agent is fully initialized, which is inherently later in the provisioning sequence — and therefore safer.

The MDM agent captures stdout and stderr from the script execution and reports them back to the console. This gives administrators full visibility into what happened on the device without needing remote access. The exit code is also reported, so a failed script is clearly flagged as failed.

Because the script is imperative rather than declarative, you have full control over error handling, validation, and idempotency. You can check whether the account exists, verify group membership, configure registry keys, and write local logs — all in a single atomic operation.

---

## What the Script Does

The script performs the following operations in order:

1. Checks whether the target account already exists (idempotent — safe on re-runs).
2. Creates the account if it does not exist, or resets its password if it does.
3. Adds the account to the local Administrators group using the well-known SID.
4. Optionally hides the account from the Windows login/lock screen.
5. Optionally disables the built-in Administrator account as a hardening measure.
6. Runs a final validation check and outputs the result.
7. Optionally logs all operations to a local file as a backup.

The script exits with code `0` on success and `1` on failure, which allows the MDM to accurately report the deployment status.

---

## Configuration Reference

All configuration is done through variables at the top of the script. No command-line parameters are used because MDM script execution environments typically do not support passing arguments reliably.

### Required Settings

| Variable | Default | Description |
|---|---|---|
| `$AdminUsername` | `"LocalITAdmin"` | The username for the local admin account. Choose something descriptive but not easily guessable. Avoid generic names like `admin` or `localadmin` that are commonly targeted by brute-force tools. |
| `$AdminPassword` | `"Ch@ngeM3!2026Dep10y"` | The password for the account. Must meet the local password complexity policy (typically: 8+ characters, uppercase, lowercase, number, and symbol). Change this before deploying. |
| `$AdminDescription` | `"MDM-managed local admin"` | A description string attached to the account, visible in `lusrmgr.msc` and `Get-LocalUser`. Useful for identifying the account's purpose during audits. |

### Optional Flags

| Variable | Default | Description |
|---|---|---|
| `$HideFromLogin` | `$true` | When enabled, writes a registry key to hide the account from the Windows login screen and lock screen. The account still exists and can be used via `runas`, Remote Desktop, or by typing the username manually on the login screen. See [Hiding the Account from the Login Screen](#hiding-the-account-from-the-login-screen) for details. |
| `$DisableBuiltIn` | `$true` | When enabled, disables the built-in Administrator account (SID ending in -500). This is a CIS Benchmark recommendation. See [Disabling the Built-In Administrator Account](#disabling-the-built-in-administrator-account) for details. |
| `$EnableLocalLog` | `$false` | When disabled (default), the script only writes to stdout/stderr, which the MDM agent captures and reports. When enabled, the script also writes a log file to the local disk as a backup. See [Local Logging](#local-logging-optional-backup) for details. |
| `$LogPath` | `"$env:ProgramData\MDM-Logs"` | The directory for the local log file. Only used when `$EnableLocalLog` is `$true`. The `ProgramData` path is used because it is accessible to SYSTEM and all administrators, and survives user profile resets. |

---

## Deployment Guide

The following instructions use Intune as the example, but the process is similar for other MDM platforms.

**Step 1: Customize the script.** Open `Create-LocalAdmin.ps1` and update the configuration variables at the top. At a minimum, change `$AdminUsername` and `$AdminPassword`. Review the optional flags and set them according to your requirements.

**Step 2: Upload to your MDM.** In the Intune portal, navigate to Devices > Scripts and remediations > Platform scripts > Add (Windows 10 and later). Upload the `.ps1` file.

**Step 3: Configure execution settings.** Set "Run this script using the logged on credentials" to **No** (this ensures the script runs as SYSTEM). Set "Run script in 64-bit PowerShell host" to **Yes**. Set "Enforce script signature check" according to your organization's policy (if you sign your scripts, enable this).

**Step 4: Assign to a device group.** Assign the script to an Azure AD device group that contains the endpoints you want to target. For Autopilot deployments, assign it to the dynamic group that captures newly enrolled devices.

**Step 5: Monitor.** After deployment, check the script status in the Intune portal under the script's Device Status tab. The MDM will show stdout/stderr output and the exit code for each device. If `$EnableLocalLog` is set to `$true`, you can also check the local log file on the device at the configured path.

---

## Feature Deep-Dives

### Idempotency

The script is designed to be safely re-run on the same device without causing errors or unintended side effects. This is critical because MDM agents may retry script execution due to transient failures, connectivity issues, or agent restarts.

On first run, the script creates the account and configures all settings. On subsequent runs, it detects the existing account, resets the password to the defined value (ensuring consistency if someone changed it locally), verifies group membership, and re-applies the registry and hardening settings. The final validation step confirms the account state regardless of which path was taken.

This means you can safely re-deploy the script to fix configuration drift without worrying about "account already exists" errors causing the deployment to report as failed.

### Well-Known SID for Group Membership

When adding the account to the local Administrators group, the script does not reference the group by its display name (e.g., `"Administrators"`). Instead, it looks up the group using its well-known Security Identifier: `S-1-5-32-544`.

This is important because the Administrators group name is localized on non-English Windows installations. For example, it appears as "Administrateurs" on French systems, "Administratoren" on German systems, and "Administradores" on Spanish systems. A script that hardcodes the English name will fail silently or throw an error on these devices.

The SID `S-1-5-32-544` is a well-known constant defined by Microsoft that always refers to the local Administrators group regardless of the display language. Using it makes the script universally compatible across all Windows language editions without any modification.

The same approach is used when disabling the built-in Administrator account. The built-in Administrator always has a SID that ends in `-500` (the full SID is `S-1-5-21-<machine-specific>-500`). Even if an organization has renamed this account (a common but largely cosmetic hardening step), the script finds it by SID rather than by name.

### Hiding the Account from the Login Screen

When `$HideFromLogin` is set to `$true`, the script creates a registry value under:

```
HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList
```

The value name is the username, and the value data is `0` (DWORD). This tells Windows to exclude the account from the interactive login screen and the lock screen account switcher.

The account is not deleted, disabled, or restricted in any way. It can still be used through the following methods: typing the username directly on the login screen (click "Other user"), using `runas /user:LocalITAdmin cmd` from an elevated prompt, connecting via Remote Desktop with the account credentials, or invoking it through PowerShell with `Start-Process` and a `-Credential` parameter.

Hiding the account is considered a best practice for service and administrative accounts because it prevents end users from being confused by an unfamiliar account tile, reduces the attack surface by not advertising the account's existence to someone with physical access, and keeps the login screen clean in shared-device or kiosk scenarios.

If you set `$HideFromLogin` to `$false`, the registry key is simply not created and the account will appear normally on the login screen.

### Disabling the Built-In Administrator Account

When `$DisableBuiltIn` is set to `$true`, the script locates the built-in Administrator account by its SID (ending in `-500`) and disables it. This is recommended by the CIS (Center for Internet Security) Benchmarks for Windows 10 and 11.

The built-in Administrator account is a well-known target for brute-force attacks because its username is predictable (it is always `Administrator` or a renamed variant that can be enumerated via SID). Disabling it forces attackers to guess both a username and a password, rather than just a password.

Since the script creates a new named admin account, the built-in Administrator is redundant. Disabling it removes a predictable entry point without losing administrative capability.

If your organization has a policy of keeping the built-in Administrator enabled (some disaster recovery procedures depend on it), set `$DisableBuiltIn` to `$false`.

Note that the script handles the case where the built-in Administrator has been renamed. Because it searches by SID rather than by name, it will find and disable the correct account regardless of what it has been renamed to.

### Local Logging (Optional Backup)

By default (`$EnableLocalLog = $false`), the script writes all output to stdout and stderr only. The MDM agent captures this output and reports it back to the management console, so you have full visibility into what happened on each device without needing local log files.

If you set `$EnableLocalLog` to `$true`, the script additionally writes a timestamped log file to the local disk. Each entry includes a timestamp, severity level (INFO, WARN, or ERROR), and a description of the operation performed or the error encountered.

The default log location is `%ProgramData%\MDM-Logs\Create-LocalAdmin.log`. The `ProgramData` folder (`C:\ProgramData` on most systems) is used because it is readable by SYSTEM (the context the script runs in), it is accessible to any local administrator for troubleshooting, it persists across user profile resets and re-imaging (unless the entire drive is wiped), and it does not require creating directories in nonstandard locations.

The local log is intended as a backup for situations where the MDM console data is unavailable, incomplete, or has been purged due to retention policies. For most deployments, the MDM-reported stdout/stderr is sufficient and the local log can be left disabled.

---

## Security Considerations

### Password Storage

The password for the local admin account is stored in cleartext within the script. This is a known and accepted tradeoff in the MDM deployment model for the following reasons.

The script is transmitted from the MDM console to the endpoint over an encrypted channel (TLS). It is not exposed in transit.

The script executes transiently on the endpoint in the SYSTEM context. It is not persisted to a user-accessible location by the MDM agent (though it may be cached temporarily in a protected system directory during execution).

The password is set on the local SAM database, which Windows protects with its own access controls.

That said, anyone with administrative access to the MDM console can read the script and see the password. Treat the MDM console itself as a sensitive system and restrict access appropriately. If your MDM supports encrypted script parameters, environment variable injection, or a secrets vault integration, prefer those mechanisms over hardcoding. Rotate the password periodically using a new script deployment even in the absence of LAPS.

### Why LAPS Is Not Included

LAPS (Local Administrator Password Solution) provides automatic, per-device password rotation with the password stored in Azure AD or Active Directory. It is the gold standard for local admin password management.

This script does not integrate with LAPS because it is designed for MDM environments that do not yet support LAPS. Specifically, the MDM in question does not offer a LAPS CSP or an equivalent secrets management feature. Windows LAPS (the built-in successor to legacy LAPS) requires either Azure AD LAPS or a hybrid join with AD schema extensions, which may not be available in all environments.

When your MDM adds LAPS support, the recommended approach is to enable LAPS via MDM policy for per-device password rotation, then redeploy this script with the static password removed (since LAPS will manage the password), or retire this script entirely and use the LAPS-managed account as your local admin.

Until then, this script provides a reliable, auditable method for establishing a local admin account with a known password across your fleet.

---

## Troubleshooting

**The script shows as "succeeded" in the MDM but the account does not exist.**
This is rare with the PowerShell approach but can happen if the MDM agent reported delivery success before execution completed. Check the local log (if enabled) or re-run the script. The idempotent design means re-running is always safe.

**The script fails with "Access is denied."**
Verify that the script is configured to run as SYSTEM in your MDM, not as the logged-on user. Local user management requires SYSTEM or an elevated administrator context.

**The account exists but is not in the Administrators group.**
This can happen if the group membership step fails due to a transient WMI issue. Re-running the script will detect the existing account and retry the group membership step.

**The account is visible on the login screen despite `$HideFromLogin = $true`.**
Verify the registry key exists at `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList` with the correct username and a DWORD value of `0`. Some third-party credential providers or custom login screen configurations may override this behavior.

**The built-in Administrator is still enabled despite `$DisableBuiltIn = $true`.**
Check the log for a warning on the disable step. Group Policy may be re-enabling the built-in Administrator if there is a conflicting policy (such as a GPO that explicitly enables it). GPO takes precedence over local changes.

---

## FAQ

**Can I use this with Autopilot?**
Yes. Assign the script to a device group that includes your Autopilot devices. The Intune Management Extension will execute the script after the agent is fully installed, which avoids the timing issues that affect CSP-based approaches during the ESP phase.

**Does this work on Azure AD joined, hybrid joined, and on-premises domain-joined devices?**
Yes. The script only interacts with the local SAM database and local group membership. It does not depend on Azure AD or Active Directory.

**Can I deploy this to existing devices, not just newly enrolled ones?**
Yes. The idempotent design means it works correctly whether the account already exists or not. Assign it to a group containing your existing managed devices and it will create or reconcile the account on each one.

**What happens if someone changes the local admin password on the device?**
If the script runs again (for example, after a re-deployment), it will reset the password to the value defined in the script. This enforces consistency across your fleet. If you need per-device unique passwords, you will need LAPS or a custom solution that generates and stores unique passwords.

**Is the password visible in Intune?**
Yes. Anyone with access to the script content in the Intune portal can see the password. Restrict access to the Scripts section of the portal using Intune RBAC roles.

---

## License

This project is provided as-is under the [MIT License](LICENSE). Use at your own risk. Test in a non-production environment before deploying to your fleet.
