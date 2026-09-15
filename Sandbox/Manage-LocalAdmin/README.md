# Manage-LocalAdmin.ps1

Declarative local user management for Iru-managed Windows endpoints — create or take over local accounts, set Administrators membership, enabled state, sign-in screen visibility, and a per-account password strategy — standing in for the **user-to-device binding** that MDMs such as JumpCloud provide and Iru does not.

- **Script:** `Manage-LocalAdmin.ps1` (v1.0.0) — supersedes `CreateLocalAdmin.ps1` and `SetLocalAdminPassword.ps1`
- **Target OS:** Windows 11 24H2 or later
- **Runs as:** SYSTEM (Iru Custom Script, **64-bit** host) or elevated admin shell
- **PowerShell:** 5.1, in-box modules only (`Microsoft.PowerShell.LocalAccounts`, `ScheduledTasks`)

> **Status: untested.** Nothing here has been executed on a device or tenant yet. Run `Discover`, then a single `Enforce` with one account, on a lab machine first.

---

## What this replaces

JumpCloud manages local accounts by *binding* a user to a device: the agent provisions a local account if none exists or takes over an existing one, the binding carries an admin-or-standard flag, a password is required to provision, and unbinding is the removal path. Iru has no equivalent — no CSP for local users is exposed, and no console feature creates accounts or sets their passwords. This script provides the same outcomes from a declared list.

| JumpCloud capability | Here |
|---|---|
| Bind a user → local account provisioned | `$Users` entry → account created (`Password = Static` or `Rotate` supplies the initial password) |
| Bind to an existing local account (take-over) | Entry for an account that already exists; `Password = Keep` leaves its password alone |
| Administrator vs standard binding | `Admin = $true / $false` — membership in the local Administrators group is added **or removed** to match |
| Password set / changed by the platform | `Static` (declared value) or `Rotate` (random per device, escrowed to the device's Iru notes) |
| Unbind → account removed | Drop the entry; `$UnlistedCreatedAccounts = 'Disable'` or `'Delete'` handles accounts the script itself created |
| Multiple users per device | Any number of `$Users` entries |
| "Device may lock if no accounts remain" warning | Enforced: any action that would leave **no enabled administrator** (local or cloud/domain) is refused with exit 2 |

Two things this does *not* replicate: JumpCloud's password is the user's own identity password synced down; here passwords are either declared or random. And there is no user-facing self-service — this is an administrator-defined account list.

## Why this approach

**LocalAccounts cmdlets, addressed by SID.** `New-LocalUser` / `Set-LocalUser` / `Add-LocalGroupMember` are in-box on every supported Windows build. The Administrators group is located by its well-known SID `S-1-5-32-544` and the built-in Administrator by RID `500`, so the script works on any Windows display language and survives a renamed Administrator account. Where `Get-LocalGroupMember` fails — it does on some Entra-joined devices when the group contains members it cannot resolve — membership is enumerated through ADSI instead, and "already a member" / "not a member" responses are treated as success rather than failure.

**One declared list, three password strategies.** The two scripts this replaces each half-implemented the other: one created accounts with a static password, the other rotated passwords and created the account as a side effect (with the English group name, no visibility control, and no take-over). Putting the account lifecycle in one place and making the password a per-account *strategy* removes that overlap and adds the case neither had — managing an account without ever touching its password.

**Note before password.** In `Rotate`, the new password is posted to the device's Iru notes **before** `Set-LocalUser` runs. The common failure (no network, wrong token, device not found in Iru) therefore happens before any local change. The rare failure (`Set-LocalUser` rejects the password) is followed by a correction note saying the posted password was *not* applied and the previous one still works. The predecessor did it the other way round and could leave a device with a password recorded nowhere.

**A lockout guard, because JumpCloud warns about it and scripts don't.** Before disabling an administrator, removing one from the group, disabling the built-in Administrator, or deleting an account, the script counts what would remain in Administrators: enabled local users plus any non-local principal (Entra or domain identities). If nothing would remain, it refuses and exits 2.

**Why not the Accounts CSP.** Windows has an `Accounts/Users` CSP, but Iru does not expose OMA-URI, and the CSP cannot set group membership beyond creation, visibility, or password policy anyway.

---

## Configuration reference

### Top-level

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `'Enforce'` | `Enforce` \| `Audit` \| `Discover` \| `Revert` |
| `$Users` | one example entry | The declared accounts — see the per-account keys below |
| `$UnlistedCreatedAccounts` | `'Leave'` | What happens to accounts **this script created** that are no longer in `$Users`: `Leave` \| `Disable` \| `Delete`. Taken-over accounts are never touched by this |
| `$BuiltInAdministrator` | `'Leave'` | `Leave` \| `Disable` \| `Enable` — the RID-500 account, found by SID. Its prior state is recorded so Revert can restore it |
| `$IruSubdomain` / `$IruRegion` / `$IruApiToken` | empty / `'us'` / empty | Required only when any account uses `Rotate`. Scope the token to **Device list** and **Device notes (create)** — nothing more |
| `$PasswordLength` | `24` | 8–64, `Rotate` only |
| `$RotationDays` | `30` | 1–365; rotate when the last rotation is older than this |
| `$InstallRotationTask` | `$false` | Opt-in scheduled task so `Rotate` keeps rotating between Iru runs. **Copies this script, API token included, to `%ProgramData%\IruScripts\LocalAdmin\`** — readable by local admins. Installed from `Enforce` only |
| `$RevertRemovesAccounts` | `$false` | Revert deletes the accounts the script created only when `$true` |
| `$LogDirectory` / `$LogFile` | `%ProgramData%\IruScripts\Logs\Manage-LocalAdmin.log` | Timestamped log, appended per run, mirrored to stdout |

### Per-account keys in `$Users`

| Key | Default | Meaning |
|---|---|---|
| `Name` | *required* | 1–20 characters; none of `" / \ [ ] : ; | = , + * ? < > @` |
| `Description` | *(none)* | Set on creation; corrected on take-over if it differs |
| `Admin` | `$false` | `$true` adds to Administrators; `$false` removes if present |
| `Enabled` | `$true` | Enabled or disabled account |
| `HideFromLogin` | `$false` | Hides the tile on the sign-in and lock screens via `Winlogon\SpecialAccounts\UserList`. The account still works through "Other user", RDP, and `runas` |
| `Password` | `'Keep'` | `Static` \| `Rotate` \| `Keep` |
| `StaticPassword` | *(none)* | Required for `Static`. Must satisfy the device's local password policy. The shipped placeholder is rejected at validation — change it |

`Keep` on an account that does not exist yet is a configuration error: a new account needs a password from somewhere. Accounts the script creates get `PasswordNeverExpires`, since the script (not Windows) manages their passwords; `Keep` accounts are not modified in that respect.

### Capturing environment-specific values

Run `Discover` first on a representative device. It lists every local account with `ADMIN` / `BUILT-IN` / `HIDDEN` / `CREATED-BY-SCRIPT` / `LISTED` flags, how many **non-local** principals sit in Administrators (the cloud identities that keep the lockout guard satisfied on Entra-joined devices), the built-in Administrator's prior state if the script changed it, last rotation dates, whether the rotation task or the legacy `IruLAPS` task is present, and — when any account uses `Rotate` — whether the device resolves in Iru by serial number. Nothing is changed.

The values that are genuinely per-tenant are the Iru API settings. Create the token in Iru under **Settings → Access → API Tokens** with only the two permissions above. `$IruSubdomain` is the `acme` in `acme.api.kandji.io`; EU tenants set `$IruRegion = 'eu'`.

---

## Deploying via Iru

Deploy as a **Custom Script** Library Item with the audit-and-remediate pattern:

1. **Audit slot:** the script with `$Mode = 'Audit'`. Exit 0 = every declared account matches, exit 1 = drift → remediation.
2. **Remediation slot:** the identical script with `$Mode = 'Enforce'`. **Keep `$Users` byte-identical in both slots**; the audit compares the device against *its own* list.
3. **Execute in: 64-bit.** The LocalAccounts module is not available to 32-bit PowerShell on 64-bit Windows; the script exits 2 with a clear message if it finds itself there.
4. Per Iru's documentation, Windows Custom Scripts execute **once per device**. That is fine for creation and take-over, which are one-time by nature. For `Rotate` it means the password rotates once — on that run — unless you either re-scope the Library Item when rotation is due or opt into `$InstallRotationTask`, accepting the token-on-disk trade-off.
5. The first `Enforce` also removes the predecessor's `IruLAPS-PasswordRotation` task and `%ProgramData%\IruLAPS\` folder if present — both held a copy of an API token.

---

## Verification & troubleshooting

```powershell
# Log
Get-Content "$env:ProgramData\IruScripts\Logs\Manage-LocalAdmin.log" -Tail 40

# State: accounts the script created, accounts it hid, prior built-in state, rotation dates
Get-ItemProperty 'HKLM:\SOFTWARE\IruScripts\LocalAdmin'

# Membership by SID, independent of the script
Get-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-544').Name

# Hidden accounts
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' -ErrorAction SilentlyContinue
```

For `Rotate`, the password itself is in the device's **Notes** tab in Iru, newest note first, in the form `[Manage-LocalAdmin] HOSTNAME | Account: name | Password: … | Rotated: <UTC>`. A `ROTATION FAILED` note means the password in the note immediately above it was **not** applied and the one before that still works.

| Symptom | Cause |
|---|---|
| Exit 2, `StaticPassword is still the placeholder` | The shipped example password was not changed. Deliberate: it is rejected so it can never reach a fleet |
| Exit 2, `REFUSED … last enabled administrator` | The requested change would have left nobody able to administer the device. Add another admin first, or reconsider the change |
| Exit 1, `Set-LocalUser` error mentioning password requirements | `StaticPassword` (or the generated one) does not satisfy the local password policy — length, complexity, or history |
| `Get-LocalGroupMember failed … enumerating via ADSI instead` | Expected on some Entra-joined devices; the fallback is authoritative. Informational |
| `Rotate` account exists but `Iru API check: FAILED` in Discover | Token, subdomain, region, or the device is not in Iru under this serial number. Enforce would fail *before* touching the password |
| Audit reports `password does not match` for a `Static` account | Someone changed it locally, or the declared value changed. Enforce resets it |
| `Keep` account does not exist | Configuration error by design — pick `Static` or `Rotate` for the first run, then switch to `Keep` |
| Account is hidden but still shows a tile | Some credential providers ignore `SpecialAccounts\UserList` |

**Behavior matrix (recommended acceptance tests)** — none run yet; this is the plan.

| Test | Expected |
|---|---|
| `Discover` on a lab device | Inventory printed, nothing changed, exit 0 |
| `Enforce`, one `Static` admin, clean device | Account created, in Administrators, hidden, exit 0 |
| `Audit` immediately after | Compliant, exit 0 |
| Change the account's password by hand, then `Audit` | `password does not match` drift, exit 1; `Enforce` resets it |
| Remove the account from Administrators by hand, then `Enforce` | Re-added, exit 0 |
| Entry for an existing account with `Password = Keep`, `Admin = $true` | Taken over: membership and visibility applied, password untouched |
| `Admin = $false` on the only enabled local admin, no cloud admins present | `REFUSED`, exit 2, membership unchanged |
| Same, but an Entra admin is in Administrators | Removed, exit 0 (non-local principal satisfies the guard) |
| `Rotate` with a wrong token | Fails at device lookup, exit 1, password unchanged, no note posted |
| `Rotate` healthy | Note posted, password set, `LastRotation_<name>` written, exit 0; second run within `RotationDays` is `OK` |
| Entry removed from `$Users`, `$UnlistedCreatedAccounts = 'Disable'` | Created account disabled; a taken-over account is untouched |
| `$BuiltInAdministrator = 'Disable'` | Disabled, prior state recorded; `Revert` re-enables it |
| `Revert` (default) | Visibility restored, built-in state restored, tasks and legacy folder gone, state gone, accounts and passwords untouched |
| `Revert` with `$RevertRemovesAccounts = $true` | Created accounts deleted unless doing so would orphan Administrators |
| Placeholder password left in place | Exit 2 before any change |
| 32-bit PowerShell host | Exit 2 with the 64-bit instruction |

---

## Limitations & operational notes

**`Static` is a shared secret.** The same password on every device, in cleartext in the Library Item. It exists because a fleet without Entra ID or another escrow has no other way to *know* the password — but treat it as the fallback it is, keep the account hidden and rotate it by redeploying with a new value.

**`Rotate` passwords are plaintext in Iru notes**, and every historical note stays visible. Restrict who can read device notes. The log never contains passwords.

**The rotation task puts the API token on disk.** Off by default for that reason. If enabled, the copy under `%ProgramData%\IruScripts\LocalAdmin\` is readable by every local administrator — including the accounts this script creates. Scope the token to the two permissions it needs so a leak is bounded to listing devices and creating notes.

**Once-per-device execution** means `Audit`/`Enforce` converge on the day they run and not afterwards unless re-scoped. Drift correction is not continuous.

**Static password verification is a logon attempt.** `Audit` checks a `Static` password with `ValidateCredentials`, which counts as a failed logon when it is wrong. With an account-lockout policy of very few attempts, repeated audits against a mismatched password could lock the account until Enforce resets it. Disabled accounts are not verified.

**Deleting an account leaves its profile folder.** `Remove-LocalUser` does not remove `C:\Users\<name>`; clean it separately if disk space or data residue matters.

**Cloud identities are not managed.** Entra or domain principals in Administrators are counted for the lockout guard and reported by `Discover`, never added or removed.

**Migrating from the predecessors.** `SetLocalAdminPassword`'s task and folder are removed automatically on the first `Enforce`. `CreateLocalAdmin` kept no state, so an account it hid is not in this script's `HiddenAccounts` list — declare it in `$Users` with `HideFromLogin = $true` to adopt it, or `$false` to unhide it; `Revert` alone will not touch it.

## Rollback

Set `$Mode = 'Revert'` and run once. It unhides the accounts this script hid, restores the built-in Administrator to the state recorded before the script changed it (refusing if that would orphan Administrators), removes the rotation task and its script copy, removes the legacy `IruLAPS` task and folder, and deletes the state key `HKLM\SOFTWARE\IruScripts\LocalAdmin`. Accounts the script created are deleted **only** when `$RevertRemovesAccounts = $true`, and never if doing so would leave no enabled administrator. **Passwords are never reset by Revert** — a `Static` or `Rotate` password stays whatever it last was, and the last `Rotate` note in Iru remains the way to retrieve it.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / compliant |
| 1 | Drift detected (Audit) or a runtime failure during Enforce/Revert |
| 2 | Precondition failure — not elevated, 32-bit host, invalid configuration (including the unchanged placeholder password) — or a **refused action** that would have left the device with no enabled administrator |

---

## Sourcing notes

**Vendor-documented:**

- [Security identifiers](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-security-identifiers) (Microsoft Learn) — `S-1-5-32-544` is the built-in Administrators group on every Windows computer; the built-in Administrator account has RID `500` and *can be renamed*, which is why both are located by SID rather than name.
- [Microsoft.PowerShell.LocalAccounts](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.localaccounts/) — `New-LocalUser`, `Set-LocalUser`, `Enable-/Disable-/Remove-LocalUser`, `Get-LocalGroup -SID`, `Add-/Remove-/Get-LocalGroupMember`, including SID-based addressing.
- [Bind Users to Devices](https://jumpcloud.com/support/bind-users-to-devices) (JumpCloud) — the feature this substitutes for: provision-or-take-over on bind, single user or group of users per device, and the warning that a device with no accounts left can become locked.
- [Iru — Custom Scripts overview](https://docs.iru.com/en/endpoint/library/library-items-profiles/custom-scripts-overview#windows) — audit/remediation semantics, 64-bit execution, and the once-per-device execution statement.
- [Iru Endpoint Management API](https://api-docs.iru.com) — the API reference for the token, base URL, and endpoints used by `Rotate`.

**Carried over from this repository's existing scripts (verify against the API reference before relying on them):**

- The API base URL pattern (`https://<subdomain>.api.kandji.io/api/v1`, `.api.eu.kandji.io` for EU), `GET /devices?serial_number=`, and `POST /devices/{device_id}/notes` with `{ "content": … }` are the calls the superseded `SetLocalAdminPassword.ps1` and the sibling `Assign-IruDeviceUser.ps1` already use. They were not re-verified against the API documentation for this rewrite.

**Community-observed:**

- Hiding an account from the sign-in screen via a `DWORD 0` named for the account under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList` is long-standing, widely used behavior that Microsoft does not document as a supported setting.
- `Get-LocalGroupMember` failing on Entra-joined devices whose Administrators group contains unresolvable members is widely reported; the ADSI fallback is the usual workaround.
- JumpCloud's exact unbind behavior on Windows (disable vs delete) is not spelled out in the pages consulted; `$UnlistedCreatedAccounts` offers both.

**Inferred (own design — verify in your environment):**

- The note-then-password ordering, the correction note on `Set-LocalUser` failure, the lockout guard counting non-local principals as "someone can still administer", and treating `MemberExistsException` / `MemberNotFoundException` as success are this script's design choices.
- `ValidateCredentials` against the `Machine` context as a non-destructive check of a static password, and its interaction with account-lockout policy, is reasoning about the API's behavior, not something tested here.
- Nothing in this folder has been executed on a device.
