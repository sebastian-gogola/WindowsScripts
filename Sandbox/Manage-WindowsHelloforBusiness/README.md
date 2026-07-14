# Manage-WindowsHelloForBusiness.ps1

PowerShell script for managing **Windows Hello for Business (WHfB)** policy on Windows endpoints enrolled in **Iru MDM**, replicating the full Intune **"Windows Hello for Business"** settings catalog category (36 settings) without requiring Intune enrollment.

## How it works

Intune writes these settings through the **PassportForWork CSP** (`./Device/Vendor/MSFT/PassportForWork/{TenantId}/...`). The CSP's MDM policy store is tenant-scoped and not writable by third-party tooling — but every device-scope setting in the category has a documented **Group Policy equivalent** (Passport.admx) under:

| Policy area | Registry key |
|---|---|
| WHfB core, trust model, PIN recovery | `HKLM\SOFTWARE\Policies\Microsoft\PassportForWork` |
| PIN complexity | `HKLM\...\PassportForWork\PINComplexity` |
| Biometrics, security key, Dynamic Lock, Device Unlock, Remote, TPM exclusion | Subkeys of `PassportForWork` |
| Enhanced anti-spoofing | `HKLM\SOFTWARE\Policies\Microsoft\Biometrics\FacialFeatures` |

Windows Hello evaluates these policy registry values exactly as it evaluates Group Policy, so a SYSTEM-context script achieves the same enforcement as an Intune device-scope profile.

## Intune setting → registry mapping

All paths relative to `HKLM\SOFTWARE\Policies\Microsoft\PassportForWork` (`PFW`) unless noted.

| Intune setting name | Value (Type) | Notes |
|---|---|---|
| Use Windows Hello For Business (Device) | `PFW : Enabled` (DWORD 0/1) | Core on/off switch |
| — sub-setting: don't provision post-logon | `PFW : DisablePostLogonProvisioning` (DWORD) | Set 1 when a third-party provisions WHfB |
| Require Security Device | `PFW : RequireSecurityDevice` (DWORD 0/1) | TPM-only provisioning |
| Restrict use of TPM 1.2 | `PFW\ExcludeSecurityDevices : TPM12` (DWORD 1) | |
| Enable Pin Recovery | `PFW : EnablePinRecovery` (DWORD 0/1) | |
| Use Certificate For On Prem Auth | `PFW : UseCertificateForOnPremAuth` (DWORD 0/1) | Certificate trust |
| Use Cloud Trust For On Prem Auth | `PFW : UseCloudTrustForOnPremAuth` (DWORD 0/1) | Cloud Kerberos trust (preferred for Entra-joined + on-prem resources) |
| Use Hello Certificates As Smart Card Certificates | `PFW : UseHelloCertificatesAsSmartCardCertificates` (DWORD 0/1) | |
| Use Remote Passport | `PFW\Remote : UseRemotePassport` (DWORD 0/1) | Phone sign-in — **deprecated by Microsoft**, parity only |
| Use Security Key For Signin | `PFW\SecurityKey : UseSecurityKeyForSignin` (DWORD 0/1) | FIDO2 security key sign-in |
| Allow Use of Biometrics | `PFW\Biometrics : UseBiometrics` (DWORD 0/1) | |
| Facial Features Use Enhanced Anti Spoofing | `HKLM\SOFTWARE\Policies\Microsoft\Biometrics\FacialFeatures : EnhancedAntiSpoofing` (DWORD 0/1) | STIG-relevant |
| Enable ESS with Supported Peripherals | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio : SupportPeripheralsWithEnhancedSignInSecurity` (DWORD 0/1) | ⚠️ See caveat below |
| Dynamic Lock | `PFW\DynamicLock : DynamicLock` (DWORD 1) | |
| Dynamic Lock Plugins | `PFW\DynamicLock : Plugins` (String) | Signal-rule XML; default rule included in script comments |
| Device Unlock Plugins / Group A / Group B | `PFW\DeviceUnlock : Plugins / GroupA / GroupB` (String) | Multifactor device unlock (factor GUID lists) |
| Minimum / Maximum PIN Length | `PFW\PINComplexity : MinimumPINLength / MaximumPINLength` (DWORD 4–127) | |
| Digits / Lowercase / Uppercase / Special Characters | `PFW\PINComplexity : Digits / LowercaseLetters / UppercaseLetters / SpecialCharacters` (DWORD) | **0 = Allowed, 1 = Required, 2 = Disallowed** |
| PIN History | `PFW\PINComplexity : History` (DWORD 0–50) | |
| Expiration | `PFW\PINComplexity : Expiration` (DWORD 0–730 days, 0 = never) | |

### The "(User)" variants

Intune's 12 `(User)` settings map to the **same value names under `HKCU\SOFTWARE\Policies\Microsoft\PassportForWork`**. This script deliberately manages **device scope only**:

- SYSTEM context cannot reliably write per-user policy hives.
- Device-scope policy is the correct vehicle for org-wide enforcement; user scope exists in Intune for user-group targeting, which Iru device targeting replaces.

## Deployment via Iru

Deploy as a **Custom Script Library Item** running in SYSTEM context:

- **Single-script enforcement**: run with `-Mode Enforce` (default) on your schedule. Idempotent — re-runs make no changes when compliant.
- **Audit/remediation pattern**: run `-Mode Audit` as the audit script (exit 1 = drift → triggers remediation), and `-Mode Enforce` as remediation.

Logs to `C:\ProgramData\Iru\Logs\WHfB-Policy.log` and stdout (visible in Iru script output).

## Configuration

Edit the `$Config` block at the top of the script. Each setting supports three states, mirroring Intune semantics:

```powershell
Data = 1        # Enabled / explicit value — enforced
Data = 0        # Disabled — enforced
Data = $null    # Not Configured — value is REMOVED if present
```

The shipped defaults are a sensible cloud-native baseline: WHfB enabled, TPM required, 6-digit minimum PIN with digits required, PIN recovery enabled, biometrics allowed with enhanced anti-spoofing required. Everything else is Not Configured.

## Caveats

1. **Dual-management conflict.** For WHfB, Group Policy (which includes these registry policy values) takes precedence over MDM-delivered CSP policy. If a device is *also* Intune-enrolled with a WHfB profile, this script will win — by design for Iru-primary devices, but worth knowing in dual-MDM Autopilot routing scenarios.
2. **Provisioning timing.** Policy is read at sign-in / PIN change. Enabling WHfB triggers the provisioning prompt at the user's next sign-in; no reboot required, though a `gpupdate /force` or sign-out accelerates pickup.
3. **Existing PINs.** PIN complexity changes apply to new PIN creation/changes only; existing PINs are not retroactively invalidated.
4. **ESS.** "Enable ESS with Supported Peripherals" is primarily an MDM/CSP + hardware-capability setting. The `WinBio\SupportPeripheralsWithEnhancedSignInSecurity` value is the documented script-level control for peripheral allowance, but behavior depends on ESS-capable hardware (secure biometric sensors). Validate on representative hardware before enforcing fleet-wide — this is the one mapping in the table that is not a straight Passport.admx policy.
5. **Trust model.** Configure at most one of `UseCloudTrustForOnPremAuth` / `UseCertificateForOnPremAuth`. Cloud Kerberos trust additionally requires the Entra Kerberos server object in AD; the registry value alone does nothing without that prerequisite.
6. **No tamper re-enforcement.** Unlike a CSP-managed value, nothing re-applies these keys automatically if a local admin deletes them — hence the recurring Audit/Enforce schedule in Iru.

## Sources

- PassportForWork CSP reference (setting definitions, allowed values, GPO mappings): `learn.microsoft.com/windows/client-management/mdm/passportforwork-csp`
- Passport.admx (registry key/value names for GPO equivalents)
- PIN complexity registry values: `admx.help/HKLM/SOFTWARE/Policies/Microsoft/PassportForWork/PINComplexity`; corroborated by Windows 10/11 STIG (e.g., V-220847 MinimumPINLength)
- ESS: Windows Hello Enhanced Sign-in Security (`learn.microsoft.com/windows-hardware/design/device-experiences/windows-hello-enhanced-sign-in-security`)