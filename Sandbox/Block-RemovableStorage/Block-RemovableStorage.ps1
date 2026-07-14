<#
.SYNOPSIS
    Blocks access to removable storage on Windows endpoints via the
    machine-level "Removable Storage Access" policies, with a FullBlock
    posture (deny everything) or a ReadOnly posture (deny writes only).

.DESCRIPTION
    Replicates the Intune Settings Catalog / GPO "Removable Storage Access"
    policies (RemovableStorage.admx) by writing directly to the policy store:

        HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices

    Postures:
      FullBlock - root value Deny_All = 1. Per vendor documentation this
                  takes precedence over any individual removable storage
                  policy setting and denies all access (read/write/execute)
                  to every removable storage class at once.
      ReadOnly  - per-class Deny_Write = 1 under six class-GUID subkeys
                  (Removable Disks, CD and DVD, Floppy, Tape, and two WPD
                  keys). Reads stay allowed - useful to stop data
                  exfiltration while vendor media remains readable.

    Enforcement happens at the ACCESS layer: Windows evaluates these denies
    when anything touches removable storage that is already installed. This
    is the complement to Manage-UsbStorageRestrictions in this repo, which
    gates device INSTALLATION and supports per-device allowlists. Do not
    run both mechanisms against the same devices - an access-layer deny has
    no allowlist and will block devices the installation layer permits.

    Modes:
      Enforce  - applies the configured posture and removes the other
                 posture's values, so switching postures converges (default)
      Audit    - reports compliance/drift without changing anything.
                 Compliant means the configured posture's values are exactly
                 present AND the other posture's values are absent.
      Discover - reports the current state of every relevant value, the
                 USBSTOR driver start type, and whether Device Installation
                 Restrictions values (Manage-UsbStorageRestrictions) are
                 present - surfacing the two-mechanisms conflict
      Revert   - removes everything this script manages (Deny_All and the
                 six Deny_Write values) plus the state key

    Designed for deployment as an Iru (formerly Kandji) Windows Custom Script
    Library Item running as NT AUTHORITY\SYSTEM. Pair the same script in the
    Audit slot ($Mode = 'Audit') and Remediation slot ($Mode = 'Enforce').

.NOTES
    File     : Block-RemovableStorage.ps1
    Version  : 2.0.0 (2026-07-14)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM or local Administrator (elevation required)
    PS       : Windows PowerShell 5.1 (no external modules)

    Exit codes:
      0 = success (Enforce/Revert/Discover) or compliant (Audit)
      1 = drift detected (Audit) or one or more runtime operations failed
      2 = precondition failure (not elevated, invalid $Posture in
          Enforce/Audit, or invalid $Mode)

    v2.0.0 modernizes the parameter-based v1 script (config block, four
    modes, current exit codes and log paths). Two v1 behaviors were
    deliberately dropped or corrected - see README.md (History section):
      * the USBSTOR Start=4 driver disable was removed entirely
      * the Removable Disks class GUID was corrected to the
        vendor-documented {53f5630d-...} (v1 used {53f56307-...})

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Mode: 'Enforce' | 'Audit' | 'Discover' | 'Revert'
$Mode = 'Enforce'

# Posture: 'FullBlock' | 'ReadOnly'
#   FullBlock - deny all access (read/write/execute) to every removable
#               storage class (root Deny_All = 1)
#   ReadOnly  - deny writes only; reads remain allowed (per-class
#               Deny_Write = 1)
$Posture = 'FullBlock'

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Block-RemovableStorage.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '2.0.0'
$PolicyRoot    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices'
$StateKey      = 'HKLM:\SOFTWARE\IruScripts\RemovableStorage'

# Removable storage class GUID subkeys written by the ReadOnly posture.
# All are vendor-documented in the ADMX_RemovableStorage / Storage Policy
# CSP references except the second WPD key, which the RemovableStorage.admx
# GPO also writes (community-observed) - see README.md.
# NOTE: v1 of this script used {53f56307-...} for Removable Disks; the
# vendor-documented key is {53f5630d-...}. Corrected in v2.0.0.
$StorageClasses = [ordered]@{
    'Removable Disks'        = '{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}'
    'CD and DVD'             = '{53f56308-b6bf-11d0-94f2-00a0c91efb8b}'
    'Floppy Drives'          = '{53f56311-b6bf-11d0-94f2-00a0c91efb8b}'
    'Tape Drives'            = '{53f5630b-b6bf-11d0-94f2-00a0c91efb8b}'
    'WPD Devices (handheld)' = '{6AC27878-A6FA-4155-BA85-F98F491D4F33}'
    'WPD Devices (media)'    = '{F33FDC04-D1AC-4E8E-9A30-19BBD4B108AE}'
}

# Device Installation Restrictions values managed by
# Manage-UsbStorageRestrictions - checked (never written) to surface the
# do-not-run-both-mechanisms conflict.
$RestrictionsKey    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$RestrictionsValues = @('AllowDenyLayered','DenyDeviceIDs','DenyDeviceIDsRetroactive',
                        'DenyDeviceClasses','DenyDeviceClassesRetroactive',
                        'AllowInstanceIDs','AllowDeviceIDs','AllowAdminInstall')

# USBSTOR driver service - reported by Discover only, never written.
# (v1 could set Start = 4 here; that capability was removed - see README.)
$UsbStorKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR'

$script:FailureCount = 0
$script:DriftCount   = 0

# =============================================================================
# LOGGING
# =============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DRIFT','OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    try {
        if (-not (Test-Path -Path $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    } catch { }
    if ($Level -eq 'ERROR') { $script:FailureCount++ }
    if ($Level -eq 'DRIFT') { $script:DriftCount++ }
}

# =============================================================================
# PREFLIGHT
# =============================================================================

function Test-IsElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
# REGISTRY HELPERS
# =============================================================================

function Get-RegValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name
    )
    return (Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Set-PolicyDword {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value,
        [string]$Label = ''
    )
    if (-not $Label) { $Label = $Name }
    try {
        if (-not (Test-Path -Path $Key)) { New-Item -Path $Key -Force | Out-Null }
        $current = Get-RegValue -Key $Key -Name $Name
        if ($null -ne $current -and [int]$current -eq $Value) {
            Write-Log "OK      $Label = $Value (already set)" 'OK'
            return
        }
        New-ItemProperty -Path $Key -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
        Write-Log "SET     $Label = $Value (was: $(if ($null -eq $current) { '<absent>' } else { $current }))"
    } catch {
        Write-Log "Failed to set $Label at ${Key}: $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-PolicyValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [string]$Label = ''
    )
    if (-not $Label) { $Label = $Name }
    try {
        $current = Get-RegValue -Key $Key -Name $Name
        if ($null -ne $current) {
            Remove-ItemProperty -Path $Key -Name $Name -Force -ErrorAction Stop
            Write-Log "REMOVED $Label (was: $current)"
        }
    } catch {
        Write-Log "Failed to remove $Label at ${Key}: $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-KeyIfEmpty {
    # Prunes a class-GUID subkey this script may have created, but only when
    # nothing else lives in it (no values, no subkeys) - foreign values such
    # as Deny_Read written by other tooling are never disturbed.
    param([Parameter(Mandatory)][string]$Key)
    try {
        if (Test-Path -Path $Key) {
            $item = Get-Item -Path $Key
            if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
                Remove-Item -Path $Key -Force -ErrorAction Stop
                Write-Log "PRUNED  empty subkey $Key"
            }
        }
    } catch {
        Write-Log "Failed to prune ${Key}: $($_.Exception.Message)" 'ERROR'
    }
}

# =============================================================================
# DESIRED STATE MODEL (shared by Enforce and Audit)
# =============================================================================

function Get-DesiredState {
    # Value name -> desired data; $null = must be absent. Compliance for a
    # posture requires the OTHER posture's values to be absent, so a posture
    # switch converges instead of accumulating.
    $denyAll   = $null
    $denyWrite = $null
    if ($Posture -eq 'FullBlock') { $denyAll = 1 }
    if ($Posture -eq 'ReadOnly')  { $denyWrite = 1 }

    $entries = @()
    $entries += [pscustomobject]@{
        Key     = $PolicyRoot
        Name    = 'Deny_All'
        Desired = $denyAll
        Label   = 'Deny_All (root, all classes)'
    }
    foreach ($class in $StorageClasses.GetEnumerator()) {
        $entries += [pscustomobject]@{
            Key     = Join-Path $PolicyRoot $class.Value
            Name    = 'Deny_Write'
            Desired = $denyWrite
            Label   = "Deny_Write [$($class.Key)]"
        }
    }
    return $entries
}

# =============================================================================
# CONFLICT CHECK (Manage-UsbStorageRestrictions)
# =============================================================================

function Get-InstallRestrictionValues {
    $present = @()
    foreach ($name in $RestrictionsValues) {
        if ($null -ne (Get-RegValue -Key $RestrictionsKey -Name $name)) { $present += $name }
    }
    return @($present)
}

function Test-MechanismConflict {
    # Warns (and proceeds) when Device Installation Restrictions policy is
    # active on this machine. Both mechanisms blocking at once is not a
    # broken state - the stricter control simply wins - but an access-layer
    # deny defeats the installation layer's allowlist, so surface it loudly.
    $present = Get-InstallRestrictionValues
    if ($present.Count -gt 0) {
        Write-Log "Device Installation Restrictions policy detected at $RestrictionsKey (values: $($present -join ', ')). If Manage-UsbStorageRestrictions manages this fleet with an allowlist, this script's access-layer deny will still block the allowlisted devices - the two mechanisms have no shared exemption model. See README.md (Choosing the layer)." 'WARN'
    }
    return ($present.Count -gt 0)
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-Enforce {
    Write-Log "=== ENFORCE: applying removable storage access posture '$Posture' ==="
    Test-MechanismConflict | Out-Null

    $state = Get-DesiredState
    foreach ($entry in $state) {
        if ($null -ne $entry.Desired) {
            Set-PolicyDword -Key $entry.Key -Name $entry.Name -Value $entry.Desired -Label $entry.Label
        } else {
            Remove-PolicyValue -Key $entry.Key -Name $entry.Name -Label $entry.Label
        }
    }
    # After removing per-class Deny_Write (FullBlock posture), prune any
    # class subkeys that are now completely empty.
    if ($Posture -eq 'FullBlock') {
        foreach ($class in $StorageClasses.GetEnumerator()) {
            Remove-KeyIfEmpty -Key (Join-Path $PolicyRoot $class.Value)
        }
    }

    # Verify every desired value reads back correctly.
    $verifyFailed = $false
    foreach ($entry in $state) {
        $actual = Get-RegValue -Key $entry.Key -Name $entry.Name
        if ($null -ne $entry.Desired) {
            if ($null -eq $actual -or [int]$actual -ne [int]$entry.Desired) {
                Write-Log "Verification failed: $($entry.Label) reads back as $(if ($null -eq $actual) { '<absent>' } else { $actual }), expected $($entry.Desired)" 'ERROR'
                $verifyFailed = $true
            }
        } else {
            if ($null -ne $actual) {
                Write-Log "Verification failed: $($entry.Label) still present with value $actual, expected absent" 'ERROR'
                $verifyFailed = $true
            }
        }
    }
    if (-not $verifyFailed) {
        Write-Log "OK      all values verified for posture '$Posture'" 'OK'
    }

    # State stamp for fleet forensics (informational only; Audit reads live policy).
    try {
        if (-not (Test-Path -Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        New-ItemProperty -Path $StateKey -Name 'ScriptVersion'  -PropertyType String -Value $ScriptVersion -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'LastEnforceUtc' -PropertyType String -Value (Get-Date).ToUniversalTime().ToString('o') -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'Posture'        -PropertyType String -Value $Posture -Force | Out-Null
    } catch {
        Write-Log "Could not write state stamp: $($_.Exception.Message)" 'WARN'
    }

    Write-Log 'Enforcement pass complete. New device connections are evaluated immediately; a reboot or user re-logon is recommended so the policy fully applies to devices already in session.'
}

function Invoke-Audit {
    Write-Log "=== AUDIT: comparing live policy state to posture '$Posture' ==="
    Test-MechanismConflict | Out-Null

    foreach ($entry in Get-DesiredState) {
        $actual = Get-RegValue -Key $entry.Key -Name $entry.Name
        if ($null -eq $entry.Desired) {
            if ($null -ne $actual) {
                Write-Log "DRIFT   $($entry.Label) present with value $actual, expected absent" 'DRIFT'
            } else {
                Write-Log "OK      $($entry.Label) absent as expected" 'OK'
            }
        } else {
            if ($null -eq $actual) {
                Write-Log "DRIFT   $($entry.Label) absent, expected $($entry.Desired)" 'DRIFT'
            } elseif ([int]$actual -ne [int]$entry.Desired) {
                Write-Log "DRIFT   $($entry.Label) = $actual, expected $($entry.Desired)" 'DRIFT'
            } else {
                Write-Log "OK      $($entry.Label) = $($entry.Desired)" 'OK'
            }
        }
    }

    # Foreign values in the same policy space (not managed, not drift).
    foreach ($class in $StorageClasses.GetEnumerator()) {
        $classKey = Join-Path $PolicyRoot $class.Value
        foreach ($foreign in @('Deny_Read','Deny_Execute')) {
            $value = Get-RegValue -Key $classKey -Name $foreign
            if ($null -ne $value) {
                Write-Log "Foreign value $foreign = $value under [$($class.Key)] - not managed by this script, left in place; review manually" 'WARN'
            }
        }
    }

    if ($script:DriftCount -eq 0) {
        Write-Log 'Audit result: COMPLIANT'
    } else {
        Write-Log "Audit result: $($script:DriftCount) drift item(s) found" 'WARN'
    }
}

function Invoke-Discover {
    Write-Log '=== DISCOVER: reporting removable storage policy state ==='

    $denyAll = Get-RegValue -Key $PolicyRoot -Name 'Deny_All'
    Write-Log "Deny_All (root, all classes): $(if ($null -eq $denyAll) { '<absent>' } else { $denyAll })"

    foreach ($class in $StorageClasses.GetEnumerator()) {
        $classKey = Join-Path $PolicyRoot $class.Value
        $parts = @()
        foreach ($name in @('Deny_Write','Deny_Read','Deny_Execute')) {
            $value = Get-RegValue -Key $classKey -Name $name
            if ($null -ne $value) { $parts += "$name=$value" }
        }
        if ($parts.Count -eq 0) {
            Write-Log "[$($class.Key)] $($class.Value): no deny values"
        } else {
            Write-Log "[$($class.Key)] $($class.Value): $($parts -join ', ')"
        }
    }

    # USBSTOR driver start type - reported because v1 of this script could
    # disable it (Start = 4), which leaves USB storage dead invisibly to
    # policy tooling. Default is 3 (manual start).
    $usbStorStart = Get-RegValue -Key $UsbStorKey -Name 'Start'
    Write-Log "USBSTOR driver Start: $(if ($null -eq $usbStorStart) { '<absent>' } else { $usbStorStart }) (3 = default/manual, 4 = disabled - if 4, USB mass storage cannot mount regardless of the policies above)"
    if ($null -ne $usbStorStart -and [int]$usbStorStart -eq 4) {
        Write-Log 'USBSTOR is DISABLED. This script no longer manages the driver; restore manually with Start = 3 if unintended. See README.md (History).' 'WARN'
    }

    # Device Installation Restrictions (Manage-UsbStorageRestrictions).
    $present = Get-InstallRestrictionValues
    if ($present.Count -gt 0) {
        Write-Log "Device Installation Restrictions values present at ${RestrictionsKey}: $($present -join ', ') - the installation-layer mechanism (Manage-UsbStorageRestrictions) appears active on this machine. Running both mechanisms defeats its allowlist; see README.md (Choosing the layer)." 'WARN'
    } else {
        Write-Log 'Device Installation Restrictions: no managed values present (no mechanism conflict).'
    }
}

function Invoke-Revert {
    Write-Log '=== REVERT: removing all policy state managed by this script ==='

    Remove-PolicyValue -Key $PolicyRoot -Name 'Deny_All' -Label 'Deny_All (root, all classes)'
    foreach ($class in $StorageClasses.GetEnumerator()) {
        $classKey = Join-Path $PolicyRoot $class.Value
        Remove-PolicyValue -Key $classKey -Name 'Deny_Write' -Label "Deny_Write [$($class.Key)]"
        foreach ($foreign in @('Deny_Read','Deny_Execute')) {
            $value = Get-RegValue -Key $classKey -Name $foreign
            if ($null -ne $value) {
                Write-Log "Foreign value $foreign = $value under [$($class.Key)] - not managed by this script, left in place" 'WARN'
            }
        }
        Remove-KeyIfEmpty -Key $classKey
    }
    Remove-KeyIfEmpty -Key $PolicyRoot

    if (Test-Path -Path $StateKey) {
        try {
            Remove-Item -Path $StateKey -Recurse -Force -ErrorAction Stop
            Write-Log "REMOVED state key $StateKey"
        } catch {
            Write-Log "Failed to remove state key ${StateKey}: $($_.Exception.Message)" 'ERROR'
        }
    }

    Write-Log 'Revert complete. A reboot or user re-logon is recommended so in-session devices regain access.'
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Block-RemovableStorage v$ScriptVersion starting in mode: $Mode"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

if ($Mode -in @('Enforce','Audit') -and $Posture -notin @('FullBlock','ReadOnly')) {
    Write-Log "Invalid `$Posture '$Posture'. Valid: FullBlock, ReadOnly." 'ERROR'
    exit 2
}

switch ($Mode) {
    'Enforce'  { Invoke-Enforce }
    'Audit'    { Invoke-Audit }
    'Discover' { Invoke-Discover }
    'Revert'   { Invoke-Revert }
    default    {
        Write-Log "Unknown mode '$Mode'. Valid: Enforce, Audit, Discover, Revert." 'ERROR'
        exit 2
    }
}

if ($script:FailureCount -gt 0) {
    Write-Log "Completed with $($script:FailureCount) error(s)." 'WARN'
    exit 1
}
if ($Mode -eq 'Audit' -and $script:DriftCount -gt 0) {
    exit 1
}
Write-Log 'Completed successfully.'
exit 0
