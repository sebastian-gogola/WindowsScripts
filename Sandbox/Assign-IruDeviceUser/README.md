# Assign-IruDeviceUser.ps1

Assigns the logged-in user to this device in Iru using the Iru API. Built for three scenarios where user assignment is missing at scale. Fleets that never used user assignment and now need to backfill it, Jamf or Intune migrations which do not carry user assignment, and Autopilot enrollments which do not currently perform user assignment (support-observed).

Version 2.0.0. Original concept by Craig Hinchliffe, Solutions Engineering, Iru, Inc. Revised for reliability on standard-user devices, hardened environments, and localized Windows builds.

## What changed from v1

The v1 script worked in admin-user English-locale testing but had failure modes that would surface in production.

1. **Result handoff.** v1 detected success by grepping a shared log file for the string SUCCESS. Because the user-session instance re-created a log file owned by SYSTEM, standard users hit access denied, logging died silently, and SYSTEM reported failure even when the assignment succeeded (support-observed behavior of default ProgramData ACLs). v2 uses a structured JSON result file with explicit ACL grants that are revoked on cleanup.
2. **Benign outcomes.** In v1, "already assigned" and "user cancelled" were reported as failures by the SYSTEM instance. v2 maps every outcome to a status and a documented exit code.
3. **GUI stack.** v1 rendered dialogs with mshta.exe, temporary HTA files, and VBScript showModalDialog. mshta is a legacy binary commonly blocked by AppLocker and WDAC baselines and flagged by EDR (support-observed). v2 uses native WinForms with no temporary UI files and no mshta dependency.
4. **Device matching.** v1 paginated the entire device inventory and matched on computer name, which breaks on renames and duplicates and generates heavy API volume during bulk rollouts. v2 matches on the BIOS hardware serial number using the API-side serial_number filter (vendor-documented for the Kandji API v1, which Iru inherits), with name-based pagination retained as a fallback for VMs that report blank or generic serials.
5. **User matching.** v1 paginated the entire user directory. v2 uses the API-side email filter (vendor-documented for the Kandji API v1) with pagination as a fallback.
6. **Task polling.** v1 parsed localized schtasks status text ("Status", "Ready"), which fails on non-English Windows (inferred from schtasks localization behavior). v2 polls for the result file instead.
7. **Token hygiene.** v1 left a copy of the script, including the embedded API token, at C:\ProgramData permanently. v2 deletes the staged copy during cleanup.
8. **Conventions.** Logging moved to %ProgramData%\IruScripts\Logs\, run state recorded in HKLM:\SOFTWARE\IruScripts\UserAssignment, pure ASCII throughout, TLS 1.2 pinned, no external modules, exit codes standardized to 0, 1, and 2.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (tested on Windows 11 24H2)
- Execution as SYSTEM via the Iru agent, with one interactive user session present
- An Iru API token with Device list, Device details, Update device, and List users permissions
- Outbound HTTPS to the Iru API endpoint for your tenant

## Configuration

Edit the CONFIGURATION block at the top of the script before deployment.

| Variable | Purpose | Default |
|---|---|---|
| `IRU_BASE_URL` | Tenant API base URL. US tenants use `https://SubDomain.api.kandji.io` and EU tenants use `https://SubDomain.api.eu.kandji.io` | placeholder |
| `IRU_API_TOKEN` | API token. Scope to the minimum permissions listed above | placeholder |
| `REQUIRE_UPN_CONFIRMATION` | When `$true`, an auto-detected UPN is shown to the user for confirmation instead of being applied silently. Recommended for shared or lab devices | `$false` |
| `USER_TASK_TIMEOUT_SECONDS` | Maximum time SYSTEM waits for the user session to finish. The default allows for a user stepping away mid-prompt | `900` |
| `PAGE_LIMIT` | API pagination page size used by the fallback lookups | `300` |
| `EXCLUDED_ACCOUNTS` | Local accounts never treated as the device user | built-in list |

## How it works

The script runs twice with two contexts and a file-based handoff.

**SYSTEM context** (launched by the Iru agent)

1. Detects the interactive user by reading the owner of explorer.exe.
2. Stages a copy of itself in `%ProgramData%\IruScripts\UserAssignment\` and grants that user Modify on the working and log directories so a standard user can write results.
3. Creates and runs a one-shot interactive scheduled task (`IruAssignUser`) as the detected user.
4. Polls for the JSON result file rather than parsing schtasks output.
5. Reads the result, records state to the registry, cleans up the task, the staged script copy, the result file, and the ACL grants, then exits with the mapped exit code.

**User session context** (launched by the scheduled task)

1. Attempts UPN auto-detection from `LogonUI\LastLoggedOnUPN`, then from the Entra IdentityStore cache. Both keys are populated on Entra joined devices (support-observed).
2. If a UPN is found and `REQUIRE_UPN_CONFIRMATION` is `$false`, the flow runs silently. Otherwise a WinForms dialog collects and confirms the email address, prefilled with the detected UPN when available.
3. Looks up the device by BIOS serial number, falling back to computer name pagination.
4. Exits without changes if the device already has an assigned user.
5. Looks up the Iru user by email and applies the assignment with `PATCH /api/v1/devices/{device_id}/` and body `{"user": "<user_id>"}` (vendor-documented for the Kandji API v1).
6. Writes the JSON result file for the SYSTEM instance to read.

A success dialog is shown only when the user typed or confirmed the email. Silent auto-detected runs complete without interrupting the user.

## Deployment in Iru

Deploy as a Custom Script Library Item scoped to the target Blueprint. Paste the identical script into the Audit slot. The script is a one-shot action rather than an Audit and Remediation pair, so a Remediation slot entry is not required. Execution frequency of "Run once per device" fits the backfill and migration use cases. Because the script requires an interactive session, devices sitting at the lock screen with no logged-in user will exit 2 and can be retried by re-running the Library Item.

For ad hoc testing, run the script manually in an elevated SYSTEM shell (for example via `psexec -s -i powershell.exe`) or directly in a user session. When run directly as a user, the script performs the full flow, writes the result file, and exits with the mapped code without the scheduled-task relaunch.

## Exit codes

| Code | Meaning | Statuses |
|---|---|---|
| 0 | Success or benign no-op | `assigned`, `already_assigned` |
| 1 | User-recoverable outcome, safe to re-run | `cancelled`, `user_not_found` |
| 2 | Fatal error requiring admin attention | `api_error`, `device_not_found`, `no_user_session`, `timeout`, `stage_failed`, `result_parse_error` |

## Logging and state

- SYSTEM log at `%ProgramData%\IruScripts\Logs\Assign-IruDeviceUser_SYSTEM.log`
- User-session log at `%ProgramData%\IruScripts\Logs\Assign-IruDeviceUser_User_<username>.log`
- Run state at `HKLM:\SOFTWARE\IruScripts\UserAssignment` with values `LastRunTimestamp`, `LastRunStatus`, `AssignedUserEmail`, `DeviceName`, and `ScriptVersion`

Separate log files per context eliminate the file contention and ACL conflicts that broke v1 logging on standard-user devices.

## Security notes

- The API token is embedded in the script. This is unavoidable in this architecture because the user session must call the API directly, so scope the token to the minimum permissions and rotate it after the rollout completes. The interactive user can read the staged script copy while the task runs (inferred, since the task executes as that user).
- The staged script copy is deleted and the directory ACL grants are revoked during SYSTEM cleanup on every run, including failures.
- Silent UPN auto-detection trusts `LastLoggedOnUPN`, which reflects the most recent logon and may not be the intended device owner on shared devices (support-observed). Set `REQUIRE_UPN_CONFIRMATION` to `$true` for those fleets.
- No external modules are used and TLS 1.2 is enforced explicitly for Windows PowerShell 5.1 compatibility.

## Known limitations

- Exactly one interactive session is assumed. With multiple sessions (for example RDP), the first explorer.exe process found determines the target user (inferred).
- Virtual machines that report blank or generic BIOS serial numbers fall back to computer name matching, which requires the Iru device name to match `$env:COMPUTERNAME`.
- The `[char]38` ampersand construction in query strings is preserved from the original script as a precaution against character handling in the Iru script editor. Whether the editor actually mangles literal ampersands has not been verified (inferred).
- The API-side `serial_number` and `email` filters are documented for the Kandji API v1. Iru inherits this API, but if a filter is ignored by a future API revision the script degrades gracefully to pagination (vendor-documented, with inferred continuity for Iru).
