# Manage-ManualMdmUnenrollment

Blocks the **Disconnect** action for an MDM enrollment in *Settings > Accounts > Access work or school* by applying the Policy CSP setting `Experience/AllowManualMDMUnenrollment = 0` locally. Built for environments where the MDM does not expose this node natively, or where a script-based guardrail that can be re-applied on a schedule is wanted.

Part of [WindowsScripts](https://github.com/sebastian-gogola/WindowsScripts) and follows the repo conventions: ASCII only, no external modules, config block instead of parameters, SYSTEM execution, exit codes `0/1/2`, logging to `%ProgramData%\IruScripts\Logs\`, state under `HKLM:\SOFTWARE\IruScripts\`.

## Read this before deploying

Three facts decide whether this control does anything useful on a given fleet.

1. **Entra joined devices.** Microsoft states that if the device is Microsoft Entra joined and MDM enrolled (for example auto-enrolled), disabling manual unenrollment has no effect. *(Vendor-documented.)* Whether that also holds for an Entra joined device whose MDM enrollment came from a third-party enrollment flow rather than Entra auto-enrollment is not spelled out. Treat it as unverified until tested on your enrollment type. `Discover` mode prints the join state and enrollment details needed for that test.
2. **This is a UI guardrail, not a security boundary.** The policy removes the Disconnect path in Settings. A user with local admin rights can still set the value back to `1`, delete the enrollment keys and scheduled tasks by hand, or run the MDM vendor's own removal tooling. *(Inferred from how the policy works; not a documented claim either way.)* Hardening against admins means not giving end users local admin and re-applying this script on a schedule so drift is corrected.
3. **The MDM server can always remove the enrollment remotely.** *(Vendor-documented.)* This does not lock you out of your own tenant.

## Policy reference

| Item | Value | Basis |
|---|---|---|
| OMA-URI | `./Device/Vendor/MSFT/Policy/Config/Experience/AllowManualMDMUnenrollment` | Documented |
| Format | `int` | Documented |
| Default | `1` (Allowed) | Documented |
| Allowed values | `0` Not allowed, `1` Allowed | Documented |
| Scope | Device only | Documented |
| Editions | Pro, Enterprise, Education, IoT Enterprise / IoT Enterprise LTSC | Documented |
| Minimum OS | Windows 10 1507 (10.0.10240) | Documented |
| Group Policy equivalent | None listed | Documented (absence) |
| Conflict resolution | Most restricted value is `0` | Documented |
| WMI Bridge class | `MDM_Policy_Config01_Experience02`, property `AllowManualMDMUnenrollment` (`sint32`) | Documented |
| Effective value location | `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Experience\AllowManualMDMUnenrollment`, `REG_DWORD` | Observed |

## How the script applies the setting

`Enforce` and `Revert` try two methods in order:

1. **MDM Bridge WMI Provider** (`root\cimv2\mdm\dmmap`, class `MDM_Policy_Config01_Experience02`). This is Microsoft's documented route for applying CSP settings on a device without going through an MDM server. The write goes through PolicyManager, so provider bookkeeping and conflict resolution behave the way they do for a server-pushed policy. Requires the SYSTEM context; when run as an elevated user the script skips it and logs a warning.
2. **Direct registry write** to `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Experience\AllowManualMDMUnenrollment` as `REG_DWORD`. This is where PolicyManager materializes the effective device value and the Settings app reads it from here. *(Observed.)* Microsoft does not document this layout, and PolicyManager can recompute the key on its next policy merge, so this is the fallback rather than the preferred path.

After writing, the script re-reads the effective value up to `$VerifyRetries` times. If the bridge write succeeds but never shows up in `PolicyManager\current`, the script also applies the registry write before giving up. It exits `0` only when the registry reflects the desired state as a `REG_DWORD`.

## Modes

Set `$Mode` in the CONFIG block at the top of the script.

| Mode | Action | Exit 0 | Exit 1 | Exit 2 |
|---|---|---|---|---|
| `Audit` | Read only | Value is `0` (`REG_DWORD`) | Missing, `1`, or wrong type | Privilege, edition, or script error |
| `Enforce` | Set to `0`, verify | Verified `0` | Write succeeded, verification failed | No write method succeeded |
| `Discover` | Report join state, enrollments, effective value, winning provider, bridge result | Always | n/a | Privilege, edition, or script error |
| `Revert` | Set to `1` (documented default), verify | Verified `1` or absent | Write succeeded, verification failed | No write method succeeded |

`Audit` treats a `REG_SZ` value of `"0"` as non-compliant on purpose. The CSP format is `int` and PolicyManager stores it as `REG_DWORD`; a string value indicates an earlier script wrote the wrong type. `Enforce` removes the mis-typed value and recreates it as a `DWORD`.

`Revert` sets the value to `1` rather than deleting it. `1` is the documented default, and because the most restricted value wins, an explicit `1` cannot override a `0` pushed later by your MDM.

### CONFIG values

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `Enforce` | `Audit`, `Enforce`, `Discover`, or `Revert` |
| `$TryWmiBridge` | `$true` | Attempt the MDM Bridge WMI Provider first (SYSTEM only) |
| `$TryRegistry` | `$true` | Fall back to the direct PolicyManager registry write |
| `$VerifyRetries` | `3` | Re-read attempts after a write |
| `$VerifyDelaySec` | `2` | Seconds between verification attempts |
| `$LogFile` | `%ProgramData%\IruScripts\Logs\Manage-ManualMdmUnenrollment.log` | Log path; rotates at 1 MB |
| `$StateKey` | `HKLM:\SOFTWARE\IruScripts\ManualMdmUnenrollment` | Last run, mode, method, result, effective value, version |

## Requirements

- Windows 10 1507 or later: Pro, Enterprise, Education, or IoT Enterprise. Home editions exit `2` because they are outside the documented applicability list.
- Windows PowerShell 5.1 or PowerShell 7. No modules.
- Elevated context. SYSTEM for the preferred WMI Bridge path; local admin is enough for the registry fallback.
- 64-bit process on 64-bit Windows. If launched from a 32-bit host the script relaunches itself through `sysnative` so HKLM writes are not redirected to `WOW6432Node`.

## Deployment

Any tool that runs PowerShell as SYSTEM works.

**MDM custom script.** For example an Iru Custom Script Library Item or an Intune platform script. Set `$Mode = 'Enforce'` and run at enrollment plus on a recurring schedule so drift is corrected.

**Detection and remediation pair.** Deploy one copy with `$Mode = 'Audit'` as detection (exit `1` means non-compliant) and one with `$Mode = 'Enforce'` as remediation.

**Manual test as SYSTEM.**

```
psexec -i -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-ManualMdmUnenrollment.ps1
```

**Manual test as admin.** Runs the registry fallback only; expect the "Skipping MDM Bridge" warning in the log.

If your MDM can push the Policy CSP directly (custom OMA-URI or SyncML), prefer that. It is the fully supported path, and because the most restricted value wins the two can coexist without conflict. *(The conflict rule is documented; coexistence is inferred from it.)*

## Verification

Registry:

```
reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Experience" /v AllowManualMDMUnenrollment
```

Expected: `REG_DWORD 0x0`.

Settings app: open *Settings > Accounts > Access work or school* and select the MDM account. The Disconnect action should be unavailable, with a message that the account cannot be removed by system policy. *(Observed; wording varies by build.)* Reopen the page after enforcing.

Log: `%ProgramData%\IruScripts\Logs\Manage-ManualMdmUnenrollment.log`

State: `HKLM:\SOFTWARE\IruScripts\ManualMdmUnenrollment`

## Test matrix

Run `Discover` first to confirm join state and enrollment type, then fill in results for your environment before treating the control as effective.

| Join state | Enrollment | Context | Expected | Result |
|---|---|---|---|---|
| Not joined (workgroup) | Third-party MDM via work account | SYSTEM | Disconnect blocked | |
| Entra joined | Third-party MDM, separate enrollment | SYSTEM | Unverified; Microsoft says no effect for Entra joined + MDM enrolled | |
| Entra joined | Entra auto-enrollment | SYSTEM | No effect (documented) | |
| Any | Any | Elevated user, not SYSTEM | Registry fallback applied, value `0` | |
| Any | Any | Existing `REG_SZ "0"` from an older script | Replaced with `REG_DWORD 0` | |

## Documented vs observed

| Claim | Basis |
|---|---|
| Policy path, format, default, allowed values, scope, editions, minimum OS | Microsoft Learn, Policy CSP - Experience |
| No effect on Entra joined + MDM enrolled devices | Microsoft Learn, Policy CSP - Experience |
| MDM server can always remove the enrollment; most restricted value is `0` | Microsoft Learn, Policy CSP - Experience |
| WMI Bridge class and property names; SYSTEM requirement | Microsoft Learn, MDM Bridge WMI Provider reference |
| `PolicyManager\current\device\Experience` holds the effective value as `REG_DWORD`, with `_ProviderSet` and `_WinningProvider` companions | Observed on Windows 10/11; layout not documented |
| Settings app honors a value written directly to `PolicyManager\current` | Observed; may be recomputed on the next policy merge |
| `HKLM\SOFTWARE\Microsoft\Enrollments\<GUID>` structure used by `Discover` | Observed; not documented |
| Local admin can reverse the setting or remove the enrollment by other means | Inferred |

## Changelog

**1.0.0**
- Initial release. Replaces a one-off snippet that wrote `REG_SZ "0"` with no exit codes or verification.

## References

- Policy CSP - Experience: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience
- MDM_Policy_Config01_Experience02 class: https://learn.microsoft.com/en-us/windows/win32/dmwmibridgeprov/mdm-policy-config01-experience02
- Using PowerShell scripting with the WMI Bridge Provider: https://learn.microsoft.com/en-us/windows/client-management/mdm/using-powershell-scripting-with-the-wmi-bridge-provider
