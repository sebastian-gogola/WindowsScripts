# Manage-WindowsLAPS.ps1

Enables and manages **Windows LAPS** on Iru-managed Windows endpoints by configuring the LAPS CSP policy store, so Entra-joined devices back up their local administrator password to **Microsoft Entra ID** — no Intune, no LAPS licensing, no password custody in Iru.

- **Script:** `Manage-WindowsLAPS.ps1` (v1.0.0)
- **Target OS:** Windows 11 24H2 (build 26100) or later — 24H2, 25H2, and anything newer
- **Runs as:** SYSTEM (Iru Custom Script) or elevated admin shell
- **PowerShell:** 5.1, no external modules

---

## The problem

Iru has no native Windows LAPS feature. Customers migrating from Intune lose the **Endpoint security → Account protection → Local admin password solution** policy, and with it automatic rotation, backup, and audited retrieval of the local administrator password.

Windows LAPS itself is **in the operating system**, not in Intune. Once policy is present, Windows generates the password, rotates it on schedule, backs it up to Entra ID over HTTPS using the device's own identity, blocks anyone else from changing the managed account's password, and enforces post-authentication rotation. None of that traffic goes through an MDM. The only thing Intune supplies is the policy — which is exactly the part a Custom Script can supply instead.

## Why this approach

The obvious route is the [Windows LAPS CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/laps-csp) at `./Device/Vendor/MSFT/LAPS/Policies/...`. Only the MDM that owns the device's MDM enrollment can issue SyncML against an OMA-URI, so a third-party script cannot literally push those nodes. It does not need to.

Microsoft gives **each LAPS policy mechanism its own registry root** and evaluates them in a fixed order:

| Precedence | Policy mechanism | Registry root |
|---|---|---|
| 1 | **LAPS CSP** | `HKLM\SOFTWARE\Microsoft\Policies\LAPS` |
| 2 | LAPS Group Policy | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS` |
| 3 | LAPS Local Configuration | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config` |

Windows walks that list top-down; **the first root holding at least one value becomes the active policy** and every lower root is ignored outright. The script writes root #1 — the CSP's own store — so the resulting policy state is identical to what an Intune LAPS profile produces, at the same precedence, and Windows reports `Policy source: CSP` in its 10022 policy event.

Microsoft documents a fourth root below these — legacy Microsoft LAPS at `HKLM\SOFTWARE\Policies\Microsoft Services\AdmPwd`. It is an Active Directory mechanism, so it is out of scope here and the script does not report on it.

Microsoft documents this path explicitly for this exact scenario: *"If your devices are Microsoft Entra joined but you're not using Microsoft Intune, you can still deploy Windows LAPS for Microsoft Entra ID. In this scenario, you must deploy policy manually (for example, either by using direct registry modification or by using Local Computer Group Policy)."*

**Alternatives considered**

| Alternative | Why not |
|---|---|
| MDM Bridge WMI provider (`root\cimv2\mdm\dmmap`) — write the CSP node "properly" | No documented LAPS class in that namespace. Nothing to call, and inventing a class name would fail silently on real hardware. The registry root reaches the same store with vendor documentation behind it. |
| Write the **GPO** root instead (what most blog write-ups do) | Works, but sits at precedence #2, so it loses to anything that later lands in the CSP root, and it is the root a returning Group Policy deployment expects to own. `$PolicyRoot = 'LocalConfig'` is offered for lab use; the GPO root is deliberately not writable by this script. |
| Rotate the password in-script and store it somewhere the MDM can show it | Puts the plaintext password in a script's hands and in a console field, with no rotation enforcement and no audited retrieval. Windows LAPS keeps the password out of the script entirely, gates retrieval behind Entra RBAC, and rotates on its own schedule and after use. |

---

## Setting map

Every configuration variable is the CSP node name, written verbatim as the registry value name.

| Intune setting (Account protection / LAPS) | CSP node under `./Device/Vendor/MSFT/LAPS/Policies/` | Registry value under the CSP root | Type |
|---|---|---|---|
| Backup Directory | `BackupDirectory` | `BackupDirectory` | REG_DWORD |
| Administrator Account Name | `AdministratorAccountName` | `AdministratorAccountName` | REG_SZ |
| Password Age Days | `PasswordAgeDays` | `PasswordAgeDays` | REG_DWORD |
| Password Complexity | `PasswordComplexity` | `PasswordComplexity` | REG_DWORD |
| Password Length | `PasswordLength` | `PasswordLength` | REG_DWORD |
| Passphrase Length | `PassphraseLength` | `PassphraseLength` | REG_DWORD |
| Post Authentication Reset Delay | `PostAuthenticationResetDelay` | `PostAuthenticationResetDelay` | REG_DWORD |
| Post Authentication Actions | `PostAuthenticationActions` | `PostAuthenticationActions` | REG_DWORD |
| Automatic Account Management Enabled | `AutomaticAccountManagementEnabled` | `AutomaticAccountManagementEnabled` | REG_DWORD |
| Automatic Account Management Target | `AutomaticAccountManagementTarget` | `AutomaticAccountManagementTarget` | REG_DWORD |
| Automatic Account Management Name Or Prefix | `AutomaticAccountManagementNameOrPrefix` | `AutomaticAccountManagementNameOrPrefix` | REG_SZ |
| Automatic Account Management Enable Account | `AutomaticAccountManagementEnableAccount` | `AutomaticAccountManagementEnableAccount` | REG_DWORD |
| Automatic Account Management Randomize Name | `AutomaticAccountManagementRandomizeName` | `AutomaticAccountManagementRandomizeName` | REG_DWORD |

That is the complete set of LAPS CSP nodes that apply when backing up to Microsoft Entra ID. Every one of them is available on Windows 11 24H2 and later, so there is no per-setting OS gate — the whole surface is usable across the supported fleet, including the passphrase complexities, `PassphraseLength`, post-authentication action 11, and automatic account management.

**`BackupDirectory` is fixed at `1` (Entra ID) and is not a configuration variable.** It is still written and still audited, so tampering on the device is caught, but there is nothing to choose: `2` is Active Directory, and `0` (disabled) is what `Revert` achieves properly.

**The CSP's Active Directory nodes are deliberately not implemented** — `PasswordExpirationProtectionEnabled`, `ADPasswordEncryptionEnabled`, `ADPasswordEncryptionPrincipal`, and `ADEncryptedPasswordHistorySize`. Microsoft's own applicability table marks all four as *not applicable* when `BackupDirectory` is Entra ID, so on this fleet they would be inert values in the registry and dead branches in the script.

The CSP's `Actions/ResetPassword` and `Actions/ResetPasswordStatus` nodes have no registry equivalent. Their local equivalents are the in-box `Reset-LapsPassword` cmdlet (exposed here as `$RotateNow`) and the LAPS event log.

Registry value **names** and **semantics** are vendor-documented; the DWORD/SZ **types** follow from each node's documented CSP format (`int`/`bool` → REG_DWORD, `chr` → REG_SZ) — see [Sourcing notes](#sourcing-notes).

---

## Prerequisites

**1. Enable LAPS in the Entra tenant.** By default Entra ID rejects password backups. In the Microsoft Entra admin center: **Identity → Devices → Overview → Device settings → Enable Microsoft Entra Local Administrator Password Solution (LAPS) → Yes → Save**. Requires Cloud Device Administrator or higher.

**2. Devices must be Entra joined.** `dsregcmd /status` must report `AzureAdJoined : YES`. Entra *registered* (workplace-joined, BYOD) devices do not qualify — the script blocks these with exit 2 rather than writing a policy that can never succeed.

**3. Windows 11 24H2 or later.** The script gates on build ≥ 26100 and exits 2 below it. That matches Iru's own supported-OS floor, so nothing in a supported fleet is excluded, and it means every LAPS setting is available on every targeted device. There is deliberately no support for older releases: Windows LAPS behaves differently there (several settings silently fall back to Windows defaults rather than erroring), and reasoning about those fallbacks is not worth carrying for devices Iru does not manage anyway.

**4. Decide who may read passwords.** Retrieval from Entra ID is RBAC-gated and audited. Review the built-in roles that can read LAPS passwords before rollout, and for Graph/PowerShell retrieval register an app with `Device.Read.All` plus `DeviceLocalCredential.ReadBasic.All` (metadata only) or `DeviceLocalCredential.Read.All` (clear-text passwords).

**5. If managing a custom account, create it first** — Windows LAPS never creates accounts. The script verifies the account exists and exits 2 if it does not. Leaving `$AdministratorAccountName = $null` targets the built-in administrator by its well-known RID, which is correct even where that account has been renamed or is localized.

---

## Configuration reference

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `'Enforce'` | `Enforce` \| `Audit` \| `Discover` \| `Revert` |
| `$PolicyRoot` | `'CSP'` | `CSP` (production) or `LocalConfig` (lab only, lowest precedence) |
| `$AdministratorAccountName` | `$null` | `$null` = built-in administrator by well-known RID |
| `$PasswordAgeDays` | `30` | 7–365 (7 is the Entra ID minimum) |
| `$PasswordComplexity` | `4` | `1`–`4` character classes · `5` improved readability · `6`–`8` passphrase |
| `$PasswordLength` | `20` | 8–64; ignored for passphrase complexities |
| `$PassphraseLength` | `$null` | 3–10 words; only with complexity 6–8 |
| `$PostAuthenticationResetDelay` | `8` | Hours 0–24; `0` disables post-auth actions entirely |
| `$PostAuthenticationActions` | `3` | `1` reset · `3` reset + sign out · `5` reset + reboot · `11` reset + sign out + kill processes |
| `$AutomaticAccountManagement*` | `$null` | LAPS creates and owns the managed account itself |
| `$ApplyPolicyImmediately` | `$true` | Runs `Invoke-LapsPolicyProcessing` after writing, instead of waiting for the hourly cycle |
| `$VerifyBackupSeconds` | `45` | How long to wait before reading the LAPS event log for the outcome; `0` skips |
| `$RotateNow` | `$false` | Forces `Reset-LapsPassword` every run — leave `$false`, Microsoft throttles frequent calls |
| `$LogDirectory` / `$LogFile` | `%ProgramData%\IruScripts\Logs\Manage-WindowsLAPS.log` | Timestamped log, appended per run |

**Three states per setting**, exactly like targeting/un-targeting in Intune:

- a value → enforced, written to the policy root
- `$null` → **Not Configured**; the value is *removed* if present and Windows applies its documented default
- there is no "leave whatever is there" state — that is the point of an audit/remediate pair

### Capturing environment-specific values

Run once with `$Mode = 'Discover'` on a representative device before rollout. It prints the OS build and whether it clears the supported floor, whether the LAPS PowerShell module is present, whether the device is Entra joined, **every LAPS policy root that currently holds values** (with the winning one called out), which values this script owns, and the last 15 LAPS events. That output is what tells you whether a LAPS GPO, an old Intune profile, or a leftover CSP policy is already in play.

There are no per-tenant identifiers to capture — nothing in the configuration is environment-specific. The one decision worth making up front is `$AdministratorAccountName`: leave it `$null` unless a named local admin account is already standardized across the fleet, in which case that account must already exist on every targeted device.

---

## Deploying via Iru

Deploy as a **Custom Script** Library Item using the audit-and-remediate pattern:

1. **Audit slot:** the full script with `$Mode = 'Audit'`. Exit 0 = compliant, exit 1 = drift → triggers remediation. Audit never writes and never triggers policy processing.
2. **Remediation slot:** the identical script with `$Mode = 'Enforce'`. **Keep the configuration block byte-identical in both slots** — the audit compares the live policy against *its own* config, so any difference means the pair oscillates.
3. **Execute in:** 64-bit. Runs as `NT AUTHORITY\SYSTEM`.
4. Per Iru's current documentation, Windows Custom Scripts execute **once per device**, unlike the macOS check-in/daily options — so treat this as a provisioning-time item and re-scope the Library Item when the policy changes, rather than relying on a recurring cycle to converge drift.
5. **Retire the Intune profile first.** If the tenant still has an Intune LAPS policy assigned, it writes the same CSP root and the two will overwrite each other. Unassign it before enabling this item.

---

## Verification & troubleshooting

**The authoritative signal is the LAPS event log**, at *Applications and Services Logs → Microsoft → Windows → LAPS → Operational*. `Enforce` reads it for you after policy processing and mirrors the events into the script log.

| Event | Meaning |
|---|---|
| 10003 / 10004 / 10005 | Policy processing started / succeeded / failed (with error code) |
| **10022** | The policy LAPS is actually using. **Confirm `Policy source: CSP` and `Backup directory: Azure AD` here** — this is the proof the script's policy took effect at the right precedence |
| **10029** | Password successfully backed up to Microsoft Entra ID |
| 10020 | The local account was updated with the new password (logs the account name and RID) |
| 10027 | No compatible password could be generated — `PasswordLength`/`PasswordComplexity` conflict with the device's local password policy |
| 10031 | Something other than LAPS tried to change the managed account's password and was blocked |
| 10041 / 10042 / 10043 / 10044 | Post-authentication: detected, grace expired, rotation failed, rotation succeeded |

**Retrieve the password** from the Entra admin center on the device object (Local administrator password recovery), or:

```powershell
Connect-MgGraph -Environment Global -TenantId <tenant-id> -ClientId <app-id>
Get-LapsAADPassword -DeviceIds <device-name> -IncludePasswords -AsPlainText
```

**Force an immediate cycle** on a test device: `Invoke-LapsPolicyProcessing`, then re-check for a 10029. To rotate deliberately: `Reset-LapsPassword`.

| Symptom | Cause |
|---|---|
| Policy written, no 10029, 10005 with an access error | Tenant setting not enabled — Entra ID rejects the backup by default |
| 10022 shows `Policy source: GPO` | A higher-precedence root won. `Discover` names it; clear it or accept it |
| Settings you configured are missing from the 10022 event | Expected — the winning root supplies *all* settings, and anything absent from it takes the Windows default. Nothing is inherited from a lower root |
| Nothing at all in the LAPS log | The channel does not exist until LAPS first runs |
| 10027 | `PasswordLength` or `PasswordComplexity` conflicts with the local password policy |
| Password rotates constantly | `PostAuthenticationResetDelay` is short and someone is using the account; that is the feature working |
| Device is Entra registered, not joined | Exit 2 by design — LAPS to Entra ID needs a true Entra join |

**Behavior matrix (recommended acceptance tests)**

| Test | Expected |
|---|---|
| Entra-joined device, first `Enforce` | Values written, `Invoke-LapsPolicyProcessing` runs, 10022 shows `Policy source: CSP`, 10029 follows, exit 0 |
| `Audit` immediately after | Compliant, exit 0, nothing written |
| Audit after someone edits a value in regedit | Drift on exactly that value, exit 1 |
| Second `Enforce` | All `OK`, no writes, exit 0 |
| Set a setting to `$null` and re-enforce | That value removed, Windows default applies, exit 0 |
| Passphrase config (`PasswordComplexity = 7`, `PassphraseLength = 5`) | Written, `PasswordLength` flagged as ignored, exit 0 |
| Entra *registered* (not joined) device | Exit 2, nothing written |
| `PasswordAgeDays = 3` | Exit 2 naming the 7-day Entra minimum |
| `AdministratorAccountName` pointing at a nonexistent account | Exit 2, nothing written |
| Existing LAPS GPO present, then `Enforce` | Warning that the GPO root will be ignored; CSP root wins |
| `Revert` | Only script-owned values removed, key removed if empty, state key gone, exit 0 |
| Non-elevated shell | Exit 2 |

---

## Limitations & operational notes

**Iru never sees the password.** Retrieval is entirely an Entra ID / Graph story. There is no Iru console view, no Iru API call, and nothing in device notes. Helpdesk workflows have to move to Entra (or Graph) before this can replace whatever local-admin password process is in place today.

**One password manager per account.** Once Windows LAPS manages an account it blocks every external password change and logs event 10031. Anything else that sets that account's password — a provisioning script, a helpdesk tool, another rotation mechanism — will start failing, and any copy of the password it holds goes stale. Point them at different accounts, or retire the other mechanism.

**Policy roots do not merge.** Writing the CSP root switches Windows to it wholesale. A device carrying a LAPS GPO loses those settings the moment this runs — not to their old values, but to *Windows defaults*. `Discover` exists to surface this before you find out the hard way.

**Sole-manager assumption.** The script assumes it alone manages these settings. A returning Intune LAPS profile writes the same root and will fight it.

**Entra ID backup only.** `BackupDirectory` is fixed at `1` and the CSP's Active Directory settings are not implemented, matching Iru's cloud-only model. A fleet that needs passwords in on-premises AD needs a different tool — adding it back here would mean the AD-side prerequisites too (schema extension, OU permissions, domain functional level for encryption), none of which a Custom Script can arrange.

**Rotation is the OS's job.** The script does not schedule, track, or report rotation beyond reading the event log at enforce time. Ongoing rotation reporting belongs in Entra.

**Windows LAPS does not create accounts.** `AdministratorAccountName` must point at an account that already exists, and enabling `AutomaticAccountManagementEnabled` hands account creation to Windows and makes `AdministratorAccountName` irrelevant.

**Not tested against Iru's script signing requirement.** Iru recommends uploading signed `.ps1` files; sign per your own process before production use.

## Rollback

Set `$Mode = 'Revert'` and run once (or push as a one-off Iru script). It removes **only the value names recorded in `HKLM\SOFTWARE\IruScripts\WindowsLaps`** — the ones this script actually wrote — then removes the policy key if nothing else is left under it, then removes the state key. Values placed there by anything else are left alone, and the policy key is left in place if it still holds them. If the recorded root differs from the currently configured `$PolicyRoot` (someone changed the config after enforcing), Revert follows the recorded one and says so.

Reverting stops future management at the next LAPS cycle. It does **not** delete the password already stored in Entra ID, and it does **not** change the managed account's current password — that account remains usable with whatever LAPS last set. Reset or disable it separately if it should not be.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / compliant |
| 1 | Drift detected (Audit) or a runtime failure during Enforce/Revert |
| 2 | Precondition failure: not elevated, OS build below Windows 11 24H2, device not Entra joined, invalid configuration, or a managed account that does not exist |

---

## Sourcing notes

**Vendor-documented (Microsoft Learn):**

- [LAPS CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/laps-csp) — every node name under `./Device/Vendor/MSFT/LAPS`, its format (`int`/`bool`/`chr`), allowed values, ranges, defaults, dependencies, and the device-scope applicability table. Source for every range the script validates.
- [Configure policy settings for Windows LAPS](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-management-policy-settings) — the policy registry roots and their names, the top-down precedence rule, the statement that settings are never shared or inherited across roots, per-setting semantics, and the default-value table. Its applicability-by-`BackupDirectory` table is the source for which settings this script implements: the four marked *not applicable* under Entra ID backup are the four deliberately left out. Also the source for which settings arrived in Windows 11 24H2 — all of which are therefore available across this script's supported range.
- [Get started with Windows LAPS and Microsoft Entra ID](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-azure-active-directory) — the tenant-level enablement requirement, the explicit statement that non-Intune Entra-joined devices deploy policy by direct registry modification, the settings that apply in Entra mode, `Invoke-LapsPolicyProcessing` / `Reset-LapsPassword` / `Get-LapsAADPassword` usage, the Graph permissions, and the Reset-LapsPassword throttling warning.
- [Use Windows LAPS event logs](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-management-event-log) — the `Microsoft-Windows-LAPS/Operational` channel, its Event Viewer path, and the meaning of events 10003/10004/10005, 10020, 10022, 10027, 10029, 10031, and 10041–10044, including the `Policy source:` line in the 10022 event. (The doc also covers AD-backup and legacy-LAPS events, which this script does not surface.)
- [LAPS PowerShell module](https://learn.microsoft.com/en-us/powershell/module/laps/) — the in-box cmdlet set the script relies on.
- [Iru — Custom Scripts overview](https://docs.iru.com/en/endpoint/library/library-items-profiles/custom-scripts-overview#windows) — Windows audit/remediation semantics (non-zero audit exit = non-compliant, remediation runs only then), the 64-bit execution choice, the signing recommendation, and the once-per-device execution statement.

**Community-observed:**

- Configuring Windows LAPS for Entra ID by writing the policy values directly, with `BackupDirectory` and the numeric settings as `REG_DWORD` and account names as `REG_SZ`, is a widely reproduced field pattern — including the write-up that prompted this script ([bitstechnologyservices.com](https://bitstechnologyservices.com/windows-laps-with-microsoft-entra-id-azure-ad/)). Note that published walkthroughs generally target the **Group Policy** root (`…\CurrentVersion\Policies\LAPS`); this script targets the **CSP** root by default, which is a different key at higher precedence.

**Inferred (own reasoning — verify in your environment):**

- The REG_DWORD / REG_SZ mapping is inferred from each node's documented CSP format (`int` and `bool` → DWORD, `chr` → SZ) plus the community observation above. Microsoft documents the value names and semantics per root but not the types.
- That writing the CSP root makes event 10022 report `Policy source: CSP` follows from Microsoft documenting that root as the LAPS CSP's root and that the winning root determines the active policy. It is the script's headline verification step precisely because it is cheap to confirm on first deployment — check it before trusting a fleet rollout.
- The absence of a LAPS class in the MDM Bridge WMI provider (`root\cimv2\mdm\dmmap`) is based on finding no documentation for one; it is the reason that route was not taken, not a claim that one can never exist.
- Treating a missing password-backup event after a policy cycle as informational rather than a failure reflects that LAPS only backs up when a password is actually due — not a documented behavior of the cmdlet.
