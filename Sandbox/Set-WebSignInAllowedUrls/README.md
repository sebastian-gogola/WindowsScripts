# Set-WebSignInAllowedUrls

Delivers the Windows policy `Authentication/ConfigureWebSignInAllowedUrls` through an Iru Windows Custom Script Library Item, replicating the Intune Settings Catalog setting **Authentication > Configure Web Sign In Allowed Urls**. Restores the lock screen **I forgot my PIN** flow (and Web sign-in in general) on Entra-joined devices federated to a third-party identity provider after a migration off Intune.

Two scripts, one per Library Item field, nothing to edit at paste time:

- **`Audit-WebSignInAllowedUrls.ps1`** goes in the Audit Script field. Reports the device state and exits 1 when the policy is missing or different.
- **`Remediate-WebSignInAllowedUrls.ps1`** goes in the Remediation Script field. Writes the policy and states which method it used.
- Both read the tenant's host list from the Library Item's **Command line parameters** field (`-AllowedUrls "host1;host2"`), which Iru passes to both scripts.

Facts:

- **Version:** 1.1.0
- **Target OS:** Windows 11 24H2 (build 26100) or later by default; the policy itself exists since Windows 10 1803
- **Runs as:** SYSTEM (Iru Custom Script) or elevated admin shell
- **PowerShell:** 5.1, no external modules
- **Status:** Untested. Refactored from a customer-delivered audit/remediation pair; the additions (host list validation, method reporting, state key, discovery output) have not been lab-validated yet. See Validation.

---

## The problem

On an Entra-joined device whose tenant federates to AD FS or a non-Microsoft IdP, the lock screen uses Web sign-in to authenticate the user during PIN reset. Web sign-in only navigates to hosts on an allow list; anything else shows *We can't open that page right now*, and in the field the flow often just sits on *Just a moment...*. Microsoft requires the allow list in federated environments as the mitigation for CVE-2021-27092.

Intune delivers the list through the Policy CSP. When the device is unenrolled from Intune, that policy is removed and the flow breaks. The setting has **no ADMX or Group Policy equivalent**, and Iru has, at the time of writing, no OMA-URI or custom CSP profile Library Item for Windows. A Custom Script is the only vehicle left, and that is what this is.

The scripts ship with **no host list**. The list is tenant-specific (which IdP, which regional hosts), so both scripts refuse to run until `-AllowedUrls` is supplied. Examples for common IdPs are in the Configuration reference; the first deployment was a Google Workspace federated tenant and its list appears there as one of them.

## Why this approach

The Policy CSP node is `./Device/Vendor/MSFT/Policy/Config/Authentication/ConfigureWebSignInAllowedUrls`. Only the enrolled MDM can push SyncML at an OMA-URI, so the remediation script reaches the same state locally, in two tiers, and states which one it used:

| Tier | Path | Standing |
|---|---|---|
| 1 | **MDM Bridge WMI provider**: namespace `root\cimv2\mdm\dmmap`, class `MDM_Policy_Config01_Authentication02`, keys `ParentID='./Vendor/MSFT/Policy/Config'`, `InstanceID='Authentication'` | Microsoft-documented as the local, SYSTEM-context way to drive Policy CSP. **Microsoft's published class definition lists only `AllowAadPasswordReset`, `AllowFastReconnect`, `AllowFidoDeviceSignon` and `AllowSecondaryAuthenticationDevice`; it does not list `ConfigureWebSignInAllowedUrls`.** Both scripts inspect the class at runtime and use this tier only when the property is exposed on the build. |
| 2 | **PolicyManager effective-value key**: `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication`, `REG_SZ ConfigureWebSignInAllowedUrls` plus `REG_DWORD ConfigureWebSignInAllowedUrls_ProviderSet = 1` | Community-observed. `current\device` is where PolicyManager stores the effective (winning) value of each policy, and it is what the Web sign-in component reads. Writing it directly is not Microsoft-supported. With no MDM contending for this node, the value persists. **This is the expected path on current builds** until the WMI property is verified on hardware. |

Why two scripts rather than one script with a mode switch: the Library Item has one Command line parameters field that feeds both slots, so a mode parameter cannot differ between them, and a single file would have to be edited at paste time. Two single-purpose files avoid that.

Alternatives considered:

| Alternative | Why not |
|---|---|
| Wait for an Iru custom profile / OMA-URI Library Item for Windows | Nothing to deploy today; the customer's PIN reset is broken now. Retire these scripts when such an item exists. |
| Group Policy or ADMX | Microsoft lists no Group Policy mapping for this node. |
| Provisioning package (`Policies/Authentication/ConfigureWebSignInAllowedUrls`) | Microsoft documents this route, but it is a one-time apply with no audit and no remediation, and it does not fit the Iru Library Item model. Reasonable for a device being reimaged; see `Invoke-IruEnrollment` for provisioning-time patterns. |
| Write `HKLM\SOFTWARE\Microsoft\PolicyManager\Providers\...` to imitate a provider | Provider GUID subkeys are owned by enrollments and their structure is undocumented; inventing one is fragile. The effective-value key is simpler and observable. |

## Setting map

| Intune setting | CSP node | WMI class / property (tier 1) | Registry value (tier 2) |
|---|---|---|---|
| Authentication > Configure Web Sign In Allowed Urls | `./Device/Vendor/MSFT/Policy/Config/Authentication/ConfigureWebSignInAllowedUrls`, format `chr`, list with delimiter `;`, device scope | `MDM_Policy_Config01_Authentication02.ConfigureWebSignInAllowedUrls` (not in the published definition; runtime-checked) | `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication\ConfigureWebSignInAllowedUrls` (`REG_SZ`) and `..._ProviderSet` (`REG_DWORD 1`) |

Related settings the audit script lists but neither script manages: `EnableWebSignIn` and `PreferredAadTenantDomainName` live under the same Authentication key and show up in the audit output when present.

## How it works

Both scripts share the same preflight and validation:

1. **Preflight.** Elevation (exit 2 otherwise) and OS build against `$MinimumBuild` (26100 by default, the floor Iru supports).
2. **Validation.** `-AllowedUrls` is required (exit 2 with a pointer to the examples when missing). The list is split on `;`, trimmed, and every entry must be a bare hostname: anything containing a scheme (`https://`), a path (`/`), or whitespace is rejected with exit 2 before anything else happens.
3. **Comparison.** Both sides are normalized (lower-case, unique, sorted, `;`-joined) so order and case on the device never count as drift.
4. **Effective value.** WMI if the class exposes the property and holds a value, else the PolicyManager key, else not set.

**Audit** then prints a discovery report (OS, join state, WMI class availability and its property list, the registry key contents including `_ProviderSet` and `_WinningProvider`, the effective value and its source, the state key) and exits 0 on match, 1 on drift. It never writes.

**Remediate** writes only when the effective value differs: tier 1 when the property is exposed, tier 2 otherwise or when tier 1 does not read back. The value written is the entries as given, de-duplicated and sorted. Method and value are recorded under `HKLM\SOFTWARE\IruScripts\WebSignInAllowedUrls`, the output names the method, and the script asks for a sign-out or reboot. `-WhatIf` reports what would be written and changes nothing.

## Prerequisites

- Windows 11 24H2 or later, Pro / Enterprise / Education (Iru's supported floor; the policy applies to those editions plus IoT Enterprise).
- **Microsoft Entra joined.** Web sign-in is not supported on Entra hybrid joined or domain-joined devices, so the setting does nothing useful there. The audit output reports join state.
- The tenant is federated to a non-Microsoft IdP (or AD FS). Cloud-only tenants do not need this policy for PIN reset.
- The host list from the former Intune profile (see Capturing environment-specific values).
- Device-side reachability of the listed hosts from the lock screen, which uses the device's network, not the user's.

## Configuration reference

Parameter (both scripts, set once in the Library Item's **Command line parameters** field):

| Parameter | Default | Meaning |
|---|---|---|
| `-AllowedUrls` | none | Semicolon-delimited bare hostnames. **Required**; both scripts exit 2 without it. Iru applies the field to both scripts, so the audit and the remediation always compare against the same list. |

CONFIGURATION block (edit in each file; keep the two files identical):

| Variable | Default | Meaning |
|---|---|---|
| `$UseWmiWhenAvailable` | `$true` | Read/write the MDM Bridge first. `$false` forces the registry tier, useful to reproduce the original customer pilot exactly. |
| `$MinimumBuild` | `26100` | Windows 11 24H2. Lower only for lab devices. |
| `$LogFile` | `%ProgramData%\IruScripts\Logs\Audit-WebSignInAllowedUrls.log` and `Remediate-WebSignInAllowedUrls.log` | Appended per run and mirrored to stdout, which Iru captures. |

### Examples

Placeholders to start from, not recommendations. Every tenant's redirect chain differs; capture the real one (next section) before deploying.

| Federation | Example `-AllowedUrls` | Note |
|---|---|---|
| Google Workspace | `accounts.google.com;accounts.youtube.com` | A field deployment (Intune export of a migrated tenant) also carried `accounts.google.ca`, `accounts.google.ae` and `mysignins.microsoft.com`. Regional hosts depend on where users sign in. |
| Okta | `yourorg.okta.com` | Or the Okta custom domain if one is configured. |
| AD FS | `adfs.contoso.com` | The federation service FQDN. |
| Microsoft's documentation example | `accounts.contoso.com;signin.contoso.com` | From the Policy CSP reference. |
| Azure US Government | add `login.microsoftonline.us` | Microsoft's PIN reset documentation calls this out as the workaround for the *We can't open that page right now* error on Entra joined devices in that cloud. |

In the Iru console the field value looks like:

```
-AllowedUrls "accounts.google.com;accounts.youtube.com"
```

### Capturing environment-specific values

Take the list from the tenant's former Intune configuration profile (Settings Catalog export, or `MDMDiagReport.html` from a still-enrolled device, under the Authentication area). Reduce every entry to a hostname:

- A field export listed `mysignins.microsoft.com/api/post/registrationinterrupt`. The policy takes hostnames, not paths, so it becomes `mysignins.microsoft.com`. Both scripts reject the un-reduced form.
- Include every IdP host the sign-in journey visits, including regional variants (the Google example above is why `accounts.google.ca` showed up in one deployment).
- For Azure US Government tenants Microsoft says to include `login.microsoftonline.us`.
- If the flow still fails after deployment, open the same IdP sign-in in Edge with developer tools on a desktop and note every host the redirect chain touches; add the missing ones.

## Deploying via Iru

1. Library > Add Library Item > **Windows Custom Script**.
2. **Audit Script:** paste `Audit-WebSignInAllowedUrls.ps1`.
3. **Remediation Script:** paste `Remediate-WebSignInAllowedUrls.ps1`.
4. **Command line parameters:** `-AllowedUrls "host1;host2"` with the tenant's list. Leaving it empty makes both scripts exit 2 with a message pointing here.
5. **Execute in:** 64 bit. Runs as `NT AUTHORITY\SYSTEM`.
6. Assign to the Blueprint holding the migrated, federated Windows devices.

Notes:

- Per Iru's current documentation, Windows Custom Scripts execute **once per device**. Treat this as a provisioning-time item: re-scope the Library Item when the host list changes rather than expecting a recurring cycle to converge drift.
- **Retire the Intune profile first** on tenants still co-managed; otherwise Intune's provider and this script write the same node.
- Expected first run on a migrated device: audit exits 1 (value missing), remediation writes it (`method: registry` on current builds), the next audit passes.

## Verification & troubleshooting

On the device, elevated, from a folder holding the two files:

```powershell
# Read-only report and comparison
.\Audit-WebSignInAllowedUrls.ps1 -AllowedUrls "host1;host2"

# What remediation would do, without doing it
.\Remediate-WebSignInAllowedUrls.ps1 -AllowedUrls "host1;host2" -WhatIf

# Effective-value key
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication'

# Is the property exposed on this build?
(Get-CimClass -Namespace root\cimv2\mdm\dmmap -ClassName MDM_Policy_Config01_Authentication02).CimClassProperties.Name

# Logs and state
Get-Content "$env:ProgramData\IruScripts\Logs\Remediate-WebSignInAllowedUrls.log" -Tail 40
Get-ItemProperty 'HKLM:\SOFTWARE\IruScripts\WebSignInAllowedUrls'
```

End-to-end check: sign out or reboot, then from the lock screen choose the PIN credential provider and **I forgot my PIN** with a federated account. The IdP's sign-in page should render in the web view. Destructive PIN reset works with this policy alone; non-destructive reset additionally needs `EnablePinRecovery` and the PIN reset service consent (see Limitations).

| Symptom | Likely cause | What to check |
|---|---|---|
| Both scripts exit 2 with "No host list supplied" | The Command line parameters field is empty or missing `-AllowedUrls` | Add `-AllowedUrls "host1;host2"` to the field; see Examples. |
| Exit 2 with "not bare hostnames" | A path or scheme survived in the list | Reduce to hostnames; the Intune export often carries paths. |
| Audit reports `<not set>` after Remediated | Remediation wrote through WMI but the value did not surface, or the run was on an older build than expected | Compare the audit's WMI and registry lines. Set `$UseWmiWhenAvailable = $false` in both files to force the registry tier. |
| Lock screen still says *We can't open that page right now* | A host in the redirect chain is missing | Capture the chain in Edge on a desktop; add the host; redeploy. |
| Lock screen sits on *Just a moment...* | Value not in effect yet, or device not Entra joined | Sign out or reboot after the first apply; the audit output shows join state. |
| Value disappears later | Another MDM provider took the node, or Intune is still assigned | The audit output shows whether `_WinningProvider` is present; retire the Intune profile. |
| Works from Settings but not from the lock screen | Matching limitation of self-service password reset from the lock screen, or hybrid join | Microsoft's PIN reset limitations; Web sign-in needs Entra join. |

## Behavior matrix

| Device state | Audit | Remediate |
|---|---|---|
| Value absent, WMI property not exposed (expected on current builds) | exit 1, DRIFT | writes registry tier, records `Method=registry`, exit 0 |
| Value absent, WMI property exposed | exit 1, DRIFT | writes via WMI; falls back to registry if read-back fails |
| Value present and matching (any order or case) | exit 0, PASS | no write, state stamped, exit 0 |
| Value present but different | exit 1, DRIFT | rewrites, exit 0 |
| No `-AllowedUrls` supplied | exit 2 | exit 2, nothing written |
| List contains a scheme, path or whitespace | exit 2 | exit 2, nothing written |
| Not elevated / build below `$MinimumBuild` | exit 2 | exit 2 |
| `-WhatIf` | n/a (never writes) | reports the write it would make, exit 0 |

## Limitations & operational notes

- **Untested in this form.** The two-tier logic comes from a customer-delivered draft; the validation, method reporting, state key and discovery output are new and unexecuted.
- **WMI property exposure is unverified.** Microsoft's published `MDM_Policy_Config01_Authentication02` definition does not include `ConfigureWebSignInAllowedUrls`. Until a build is seen exposing it, every device will take the registry tier, and the audit output will say so.
- **The registry tier is community-observed, not supported.** PolicyManager owns `current\device`. If an MDM later delivers the same node, its provider becomes the winning provider and may overwrite this value; if Intune is unassigned while still enrolled it may clear it. The audit makes that visible.
- **Not OOBE or Autopilot.** During OOBE no MDM policy is present under any MDM, and it was not present under Intune either; an OOBE sign-in hang is an enrollment issue, not this policy.
- **Does not configure `EnablePinRecovery`.** Non-destructive PIN reset needs the Microsoft PIN reset service and client applications consented in Entra and `EnablePinRecovery` set; see `Manage-WindowsHelloforBusiness`. Destructive reset from the lock screen works with this policy alone.
- **Entra joined only.** Web sign-in is not supported on hybrid or domain-joined devices.
- **Takes effect at sign-in.** Sign out or reboot after the first apply.
- **Once-per-device execution** in Iru means drift after the first run is not corrected until the item is re-scoped.
- **Keep the two files' CONFIGURATION blocks identical**, or the audit compares against a different view of the device than the remediation writes to.

## Rollback

There is no separate revert script. To remove the policy from a device, run elevated:

```powershell
# Which method wrote it (registry or wmi)
(Get-ItemProperty 'HKLM:\SOFTWARE\IruScripts\WebSignInAllowedUrls').Method

# Registry tier: remove the value and its marker, leave every other value in the key alone
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication' -Name 'ConfigureWebSignInAllowedUrls','ConfigureWebSignInAllowedUrls_ProviderSet' -ErrorAction SilentlyContinue

# WMI tier only (Method = wmi): clear the property on the bridge instance. Inferred behavior, verify by re-reading.
$i = Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_Policy_Config01_Authentication02 -Filter "ParentID='./Vendor/MSFT/Policy/Config' and InstanceID='Authentication'"
$i.CimInstanceProperties['ConfigureWebSignInAllowedUrls'].Value = $null
Set-CimInstance -CimInstance $i

# State key
Remove-Item 'HKLM:\SOFTWARE\IruScripts\WebSignInAllowedUrls' -Recurse -ErrorAction SilentlyContinue
```

Unassign the Library Item first, or the next run re-applies the value. Federated PIN reset from the lock screen stops working again at the next sign-in.

## Exit codes

Both scripts:

| Code | Meaning |
|---|---|
| 0 | Audit: compliant. Remediate: value in place (written now or already matching). |
| 1 | Audit: drift (value missing or different). Remediate: could not set the value by any method. |
| 2 | Precondition failure: not elevated, OS below `$MinimumBuild`, no `-AllowedUrls` supplied, or an entry containing a scheme, path or whitespace. |

---

## Sourcing notes

**Vendor-documented (Microsoft Learn):**

- [Policy CSP - Authentication](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-authentication#configurewebsigninallowedurls): `ConfigureWebSignInAllowedUrls` is device scope, Pro/Enterprise/Education/IoT Enterprise, Windows 10 1803 with KB5001339 and later, format `chr`, list with delimiter `;`; required in federated environments as the mitigation for CVE-2021-27092; the two-domain example. No Group Policy mapping is listed for this node (other nodes on the same page carry one). Also the source for `EnableWebSignIn` and `PreferredAadTenantDomainName`.
- [PIN reset](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/pin-reset): PIN reset on Entra joined devices uses Web sign-in in the lock screen; navigation outside the allow list shows *We can't open that page right now*; the policy is required with AD FS or a non-Microsoft IdP; destructive reset needs no further configuration; non-destructive reset needs the PIN reset service and client consent plus `EnablePinRecovery`; the `login.microsoftonline.us` note for Azure Government; lock screen reset steps.
- [Web sign-in for Windows](https://learn.microsoft.com/en-us/windows/security/identity-protection/web-sign-in/): Entra joined only, not supported for hybrid or domain joined; Windows 11 22H2 with KB5030310 for the expanded scenarios; Intune Settings Catalog and provisioning package routes for the same three Authentication settings.
- [MDM_Policy_Config01_Authentication02 class](https://learn.microsoft.com/en-us/windows/win32/dmwmibridgeprov/mdm-policy-config01-authentication02): the published property list (four `sint32` policies, none of them this one), namespace `Root\CIMv2\MDM\DMMap`, `InstanceID = "Authentication"`, `ParentID = "./Vendor/MSFT/Policy/Config"`.
- [Using PowerShell scripting with the WMI Bridge Provider](https://learn.microsoft.com/en-us/windows/client-management/using-powershell-scripting-with-the-wmi-bridge-provider): device settings require local system context; the `New-CimInstance` / `Get-CimInstance -Filter` / `Set-CimInstance` / `Remove-CimInstance` pattern the scripts follow.
- [Iru - Custom Scripts overview](https://docs.iru.com/en/endpoint/library/library-items-profiles/custom-scripts-overview#windows): audit exits non-zero when non-compliant and the remediation script then runs; the Command line parameters field passes arguments to both scripts; 64-bit / 32-bit execution choice; scripts execute once per device; sign scripts when possible.

**Community-observed:**

- `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\<Area>` holds the effective value of each policy, with `<Policy>_WinningProvider` pointing at the provider GUID under `PolicyManager\Providers` (for example, [vansurksum.com](https://www.vansurksum.com/2021/05/25/mdm-policy-processing-on-windows-10-with-microsoft-endpoint-manager-a-closer-look/)). Writing this key directly is widely warned against on Intune-managed devices because the enrolled provider overwrites it; here there is no enrolled provider for this node.
- The `_ProviderSet` DWORD marker alongside each effective value, and Web sign-in reading its allow list from this location, come from the customer engagement that produced the original draft. Field observation, not documentation.
- The *Just a moment...* hang as the customer-visible symptom of a missing allow list is field observation; Microsoft documents the *We can't open that page right now* message.

**Inferred (design reasoning, verify in your environment):**

- That a build exposing `ConfigureWebSignInAllowedUrls` on the bridge class would accept a string through `Set-CimInstance` the same way the documented `sint32` policies do; the remediation script verifies the read-back rather than assuming.
- That setting the bridge property to `$null` and committing clears just that node (rollback section); re-read to confirm.
- Normalizing case and order for comparison follows the CSP's list format; Microsoft does not state whether the consumer is case-sensitive, so the value written keeps the case supplied.
- The 26100 minimum build is Iru's support floor, not a requirement of the policy.
