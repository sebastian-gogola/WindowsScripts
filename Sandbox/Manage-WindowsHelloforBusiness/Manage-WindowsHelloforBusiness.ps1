<#
.SYNOPSIS
    Manages Windows Hello for Business policy on Windows endpoints via registry-based
    (GPO-equivalent) policy, replicating Intune's "Windows Hello for Business" settings
    catalog category. Designed for deployment via Iru MDM Custom Script Library Items.

.DESCRIPTION
    Intune configures Windows Hello for Business through the PassportForWork CSP
    (./Device/Vendor/MSFT/PassportForWork/...). Third-party MDMs cannot write to the
    CSP's tenant-scoped MDM policy store, but every device-scope setting in that CSP
    has a documented Group Policy equivalent under:

        HKLM\SOFTWARE\Policies\Microsoft\PassportForWork        (Passport.admx)
        HKLM\SOFTWARE\Policies\Microsoft\Biometrics\...          (anti-spoofing)

    Windows Hello evaluates these policy keys identically to Group Policy, so writing
    them from a SYSTEM-context script achieves the same enforcement as an Intune
    device-scope profile.

    The script is idempotent and supports two modes:
      - Audit   : Reports drift from desired state. Exit 1 = drift, Exit 0 = compliant.
      - Enforce : Applies desired state. Exit 0 = success, Exit 1 = error.

    Configure desired state in the $Config block below. Three states per setting:
      1 / 0          = explicitly Enabled / Disabled (value written)
      $null          = Not Configured (value REMOVED if present, like un-targeting in Intune)
      integer/string = literal value (PIN lengths, plugin XML, etc.)

.PARAMETER Mode
    'Audit' (default) or 'Enforce'.

.PARAMETER LogPath
    Optional log file. Defaults to C:\ProgramData\Iru\Logs\WHfB-Policy.log

.NOTES
    Author  : Sebastian Gogola
    Context : Must run as SYSTEM or local admin (writes HKLM).
    Exit codes are MDM-compatible: non-zero in Audit mode can trigger remediation.

    SETTING MAP (Intune setting name -> registry policy)
    =====================================================================================
    Root key: HKLM\SOFTWARE\Policies\Microsoft\PassportForWork  [PFW]

    Use Windows Hello For Business (Device)   PFW : Enabled (DWORD 0/1)
                                              PFW : DisablePostLogonProvisioning (DWORD 0/1)
    Require Security Device                   PFW : RequireSecurityDevice (DWORD 0/1)
    Restrict use of TPM 1.2                   PFW\ExcludeSecurityDevices : TPM12 (DWORD 1)
    Enable Pin Recovery                       PFW : EnablePinRecovery (DWORD 0/1)
    Use Certificate For On Prem Auth          PFW : UseCertificateForOnPremAuth (DWORD 0/1)
    Use Cloud Trust For On Prem Auth          PFW : UseCloudTrustForOnPremAuth (DWORD 0/1)
    Use Hello Certificates As Smart Card...   PFW : UseHelloCertificatesAsSmartCardCertificates (DWORD 0/1)
    Use Remote Passport (phone sign-in)*      PFW\Remote : UseRemotePassport (DWORD 0/1)
    Use Security Key For Signin               PFW\SecurityKey : UseSecurityKeyForSignin (DWORD 0/1)
    Allow Use of Biometrics                   PFW\Biometrics : UseBiometrics (DWORD 0/1)
    Facial Features Use Enhanced AntiSpoofing HKLM\SOFTWARE\Policies\Microsoft\Biometrics\FacialFeatures : EnhancedAntiSpoofing (DWORD 0/1)
    Dynamic Lock                              PFW\DynamicLock : DynamicLock (DWORD 0/1)
    Dynamic Lock Plugins                      PFW\DynamicLock : Plugins (String, signal-rule XML)
    Device Unlock Plugins / Group A / Group B PFW\DeviceUnlock : Plugins / GroupA / GroupB (String)
    Minimum PIN Length                        PFW\PINComplexity : MinimumPINLength (DWORD 4-127)
    Maximum PIN Length                        PFW\PINComplexity : MaximumPINLength (DWORD 4-127)
    Digits                                    PFW\PINComplexity : Digits (DWORD 0=Allowed 1=Required 2=Disallowed)
    Lowercase Letters                         PFW\PINComplexity : LowercaseLetters (DWORD 0/1/2)
    Uppercase Letters                         PFW\PINComplexity : UppercaseLetters (DWORD 0/1/2)
    Special Characters                        PFW\PINComplexity : SpecialCharacters (DWORD 0/1/2)
    PIN History                               PFW\PINComplexity : History (DWORD 0-50)
    Expiration                                PFW\PINComplexity : Expiration (DWORD 0-730 days)
    Enable ESS with Supported Peripherals**   HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio : SupportPeripheralsWithEnhancedSignInSecurity (DWORD 0/1)

    *  Phone sign-in (Remote Passport) is deprecated by Microsoft; included for parity only.
    ** ESS is primarily an MDM/CSP + hardware capability setting; the WinBio value controls
       peripheral allowance and is the documented script-level equivalent. Validate on
       ESS-capable hardware before broad deployment.

    The "(User)" variants in Intune map to the same value names under
    HKCU\SOFTWARE\Policies\Microsoft\PassportForWork. This script intentionally manages
    DEVICE scope only (SYSTEM context cannot reliably write per-user policy, and device
    policy is what you want for org-wide enforcement).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Enforce')]
    [string]$Mode = 'Enforce',

    [string]$LogPath = 'C:\ProgramData\Iru\Logs\WHfB-Policy.log'
)

# =====================================================================================
# DESIRED STATE - edit this block per customer/policy requirements.
# $null = Not Configured (value will be removed). Anything else is enforced.
# =====================================================================================
$PFW = 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork'

$Config = @(
    # --- Core enablement ---
    @{ Name = 'Use Windows Hello For Business (Device)'
       Path = $PFW; Value = 'Enabled'; Type = 'DWord'; Data = 1 }

    @{ Name = 'Do not start provisioning after sign-in'
       Path = $PFW; Value = 'DisablePostLogonProvisioning'; Type = 'DWord'; Data = 0 }

    # --- Hardware requirements ---
    @{ Name = 'Require Security Device (TPM)'
       Path = $PFW; Value = 'RequireSecurityDevice'; Type = 'DWord'; Data = 1 }

    @{ Name = 'Restrict use of TPM 1.2'
       Path = "$PFW\ExcludeSecurityDevices"; Value = 'TPM12'; Type = 'DWord'; Data = $null }

    # --- PIN complexity ---
    @{ Name = 'Minimum PIN Length'
       Path = "$PFW\PINComplexity"; Value = 'MinimumPINLength'; Type = 'DWord'; Data = 6 }

    @{ Name = 'Maximum PIN Length'
       Path = "$PFW\PINComplexity"; Value = 'MaximumPINLength'; Type = 'DWord'; Data = $null }

    @{ Name = 'Digits (0=Allowed 1=Required 2=Disallowed)'
       Path = "$PFW\PINComplexity"; Value = 'Digits'; Type = 'DWord'; Data = 1 }

    @{ Name = 'Lowercase Letters (0=Allowed 1=Required 2=Disallowed)'
       Path = "$PFW\PINComplexity"; Value = 'LowercaseLetters'; Type = 'DWord'; Data = $null }

    @{ Name = 'Uppercase Letters (0=Allowed 1=Required 2=Disallowed)'
       Path = "$PFW\PINComplexity"; Value = 'UppercaseLetters'; Type = 'DWord'; Data = $null }

    @{ Name = 'Special Characters (0=Allowed 1=Required 2=Disallowed)'
       Path = "$PFW\PINComplexity"; Value = 'SpecialCharacters'; Type = 'DWord'; Data = $null }

    @{ Name = 'PIN History'
       Path = "$PFW\PINComplexity"; Value = 'History'; Type = 'DWord'; Data = $null }

    @{ Name = 'PIN Expiration (days, 0=never)'
       Path = "$PFW\PINComplexity"; Value = 'Expiration'; Type = 'DWord'; Data = $null }

    # --- PIN recovery ---
    @{ Name = 'Enable Pin Recovery'
       Path = $PFW; Value = 'EnablePinRecovery'; Type = 'DWord'; Data = 1 }

    # --- Biometrics ---
    @{ Name = 'Allow Use of Biometrics'
       Path = "$PFW\Biometrics"; Value = 'UseBiometrics'; Type = 'DWord'; Data = 1 }

    @{ Name = 'Facial Features Use Enhanced Anti Spoofing'
       Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Biometrics\FacialFeatures'
       Value = 'EnhancedAntiSpoofing'; Type = 'DWord'; Data = 1 }

    @{ Name = 'Enable ESS with Supported Peripherals'
       Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio'
       Value = 'SupportPeripheralsWithEnhancedSignInSecurity'; Type = 'DWord'; Data = $null }

    # --- On-prem auth trust model (pick ONE: cloud trust OR certificate trust) ---
    @{ Name = 'Use Cloud Trust For On Prem Auth'
       Path = $PFW; Value = 'UseCloudTrustForOnPremAuth'; Type = 'DWord'; Data = $null }

    @{ Name = 'Use Certificate For On Prem Auth'
       Path = $PFW; Value = 'UseCertificateForOnPremAuth'; Type = 'DWord'; Data = $null }

    @{ Name = 'Use Hello Certificates As Smart Card Certificates'
       Path = $PFW; Value = 'UseHelloCertificatesAsSmartCardCertificates'; Type = 'DWord'; Data = $null }

    # --- Alternate sign-in methods ---
    @{ Name = 'Use Security Key For Signin (FIDO2)'
       Path = "$PFW\SecurityKey"; Value = 'UseSecurityKeyForSignin'; Type = 'DWord'; Data = $null }

    @{ Name = 'Use Remote Passport (phone sign-in, deprecated)'
       Path = "$PFW\Remote"; Value = 'UseRemotePassport'; Type = 'DWord'; Data = $null }

    # --- Dynamic Lock ---
    @{ Name = 'Dynamic Lock'
       Path = "$PFW\DynamicLock"; Value = 'DynamicLock'; Type = 'DWord'; Data = $null }

    @{ Name = 'Dynamic Lock Plugins (signal rule XML)'
       Path = "$PFW\DynamicLock"; Value = 'Plugins'; Type = 'String'
       Data = $null }
       # Default Microsoft rule if you enable Dynamic Lock:
       # '<rule schemaVersion="1.0"><signal type="bluetooth" scenario="Dynamic Lock" classOfDevice="512" rssiMin="-10" rssiMaxDelta="-10"/></rule>'

    # --- Multifactor Device Unlock ---
    @{ Name = 'Device Unlock - Group A (first factors)'
       Path = "$PFW\DeviceUnlock"; Value = 'GroupA'; Type = 'String'; Data = $null }

    @{ Name = 'Device Unlock - Group B (second factors)'
       Path = "$PFW\DeviceUnlock"; Value = 'GroupB'; Type = 'String'; Data = $null }

    @{ Name = 'Device Unlock - Plugins'
       Path = "$PFW\DeviceUnlock"; Value = 'Plugins'; Type = 'String'; Data = $null }
)

# =====================================================================================
# Implementation - no edits needed below this line
# =====================================================================================
$script:ExitCode = 0
$script:Drift    = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    if ($LogPath) {
        try {
            $dir = Split-Path -Path $LogPath -Parent
            if (-not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
            Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Get-CurrentData {
    param([string]$Path, [string]$Value)
    if (-not (Test-Path -Path $Path)) { return $null }
    $item = Get-ItemProperty -Path $Path -Name $Value -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Value
}

function Invoke-Setting {
    param([hashtable]$Setting)

    $current = Get-CurrentData -Path $Setting.Path -Value $Setting.Value
    $desired = $Setting.Data

    # --- Desired: Not Configured -> value must be absent ---
    if ($null -eq $desired) {
        if ($null -ne $current) {
            $script:Drift.Add($Setting.Name)
            if ($Mode -eq 'Enforce') {
                Remove-ItemProperty -Path $Setting.Path -Name $Setting.Value -Force -ErrorAction Stop
                Write-Log ('REMOVED  : {0} (was {1})' -f $Setting.Name, $current)
            } else {
                Write-Log ('DRIFT    : {0} - present ({1}), expected Not Configured' -f $Setting.Name, $current) 'WARN'
            }
        } else {
            Write-Log ('OK       : {0} - Not Configured' -f $Setting.Name)
        }
        return
    }

    # --- Desired: explicit value ---
    if ("$current" -ceq "$desired") {
        Write-Log ('OK       : {0} = {1}' -f $Setting.Name, $desired)
        return
    }

    $script:Drift.Add($Setting.Name)
    if ($Mode -eq 'Enforce') {
        if (-not (Test-Path -Path $Setting.Path)) {
            New-Item -Path $Setting.Path -Force | Out-Null
        }
        New-ItemProperty -Path $Setting.Path -Name $Setting.Value `
            -PropertyType $Setting.Type -Value $desired -Force -ErrorAction Stop | Out-Null
        $was = if ($null -eq $current) { '<absent>' } else { $current }
        Write-Log ('SET      : {0} = {1} (was {2})' -f $Setting.Name, $desired, $was)
    } else {
        $cur = if ($null -eq $current) { '<absent>' } else { $current }
        Write-Log ('DRIFT    : {0} - current {1}, expected {2}' -f $Setting.Name, $cur, $desired) 'WARN'
    }
}

# --- Main ---
Write-Log ('===== Windows Hello for Business policy - Mode: {0} =====' -f $Mode)

# Guard: must be elevated/SYSTEM to touch HKLM policies
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'Script must run as SYSTEM or elevated administrator. Aborting.' 'ERROR'
    exit 1
}

foreach ($setting in $Config) {
    try {
        Invoke-Setting -Setting $setting
    } catch {
        Write-Log ('ERROR    : {0} - {1}' -f $setting.Name, $_.Exception.Message) 'ERROR'
        $script:ExitCode = 1
    }
}

# --- Summary & exit-code semantics ---
if ($Mode -eq 'Audit') {
    if ($script:Drift.Count -gt 0) {
        Write-Log ('AUDIT RESULT: NON-COMPLIANT - {0} setting(s) drifted: {1}' -f $script:Drift.Count, ($script:Drift -join '; ')) 'WARN'
        exit 1   # non-zero -> Iru can trigger remediation
    }
    Write-Log 'AUDIT RESULT: COMPLIANT'
    exit 0
}
else {
    if ($script:ExitCode -eq 0 -and $script:Drift.Count -gt 0) {
        Write-Log ('ENFORCE RESULT: {0} setting(s) corrected. Policy is evaluated at next sign-in / PIN change; no reboot required.' -f $script:Drift.Count)
    } elseif ($script:ExitCode -eq 0) {
        Write-Log 'ENFORCE RESULT: Already compliant. No changes made.'
    }
    exit $script:ExitCode
}