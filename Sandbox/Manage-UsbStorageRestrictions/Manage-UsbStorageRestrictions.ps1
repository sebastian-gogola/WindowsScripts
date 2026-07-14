<#
.SYNOPSIS
    Blocks USB mass storage devices while keeping non-storage USB peripherals
    (headsets, keyboards, mice, webcams) fully functional, with an allowlist
    for sanctioned storage devices identified by device instance ID.
 
.DESCRIPTION
    Replicates the Intune Settings Catalog "Device Installation" restriction
    policies (Policy CSP - DeviceInstallation) by writing directly to the GPO
    policy store consumed by the Windows PnP manager:
 
        HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions
 
    Design (anchored to Microsoft-documented behavior):
 
      * Deny list (Device IDs tier): the compatible ID "USB\Class_08" is added
        to "Prevent installation of devices that match any of these device
        IDs". Every USB mass storage function device (flash drives, external
        HDD/SSD, UASP enclosures, USB card readers, composite-device storage
        interfaces) carries USB\Class_08 in its compatible IDs. Non-storage
        peripherals (audio, HID, video) do not, so they are never affected.
 
      * Allow list (Device instance IDs tier): sanctioned devices are listed in
        "Allow installation of devices that match any of these device instance
        IDs" (e.g. USB\VID_0781&PID_5575\<serial>).
 
      * "Apply layered order of evaluation" (AllowDenyLayered) is enabled so
        the more specific instance-ID Allow supersedes the device-ID Deny,
        per the documented hierarchy:
        Device instance IDs > Device IDs > Device setup class > Removable devices.
 
      * Optionally, the Windows Portable Devices setup class (MTP/PTP phones,
        cameras, media players) is denied at the setup-class tier to close the
        MTP exfiltration path. Because that deny sits at the class tier, both
        instance-ID and hardware-ID (model-level) allow entries can supersede it.
 
      * Optionally, the deny is applied retroactively to matching devices that
        are already installed, and the script actively removes currently
        present, non-allowlisted matching devnodes so enforcement is immediate.
 
    Modes:
      Enforce  - applies the configured policy state (default)
      Audit    - reports compliance/drift without changing anything
      Discover - prints allowlist-ready instance IDs for attached USB storage
      Revert   - removes everything this script manages and rescans devices
 
    Designed for deployment as an Iru (formerly Kandji) Windows Custom Script
    Library Item running as NT AUTHORITY\SYSTEM. Pair the same script in the
    Audit slot ($Mode = 'Audit') and Remediation slot ($Mode = 'Enforce').
 
.NOTES
    File     : Manage-UsbStorageRestrictions.ps1
    Version  : 1.0.0 (2026-07-09)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM or local Administrator (elevation required)
    PS       : Windows PowerShell 5.1 (no external modules)
 
    Exit codes:
      0 = success (Enforce/Revert/Discover) or compliant (Audit)
      1 = drift detected (Audit) or one or more runtime operations failed
      2 = precondition failure (not elevated, or OS build lacks a required policy)
 
    Registry values written (all under ...\DeviceInstall\Restrictions), per the
    ADMX mappings published in the DeviceInstallation Policy CSP reference:
      AllowDenyLayered            = EnableInstallationPolicyLayering
      DenyDeviceIDs (+ subkey)    = PreventInstallationOfMatchingDeviceIDs
      DenyDeviceIDsRetroactive    = "also apply to matching devices already installed"
      DenyDeviceClasses (+subkey) = PreventInstallationOfMatchingDeviceSetupClasses
      DenyDeviceClassesRetroactive
      AllowInstanceIDs (+ subkey) = AllowInstallationOfMatchingDeviceInstanceIDs
      AllowDeviceIDs (+ subkey)   = AllowInstallationOfMatchingDeviceIDs
      AllowAdminInstall           = Allow administrators to override restrictions
 
    Sources: see the accompanying README.md (Sourcing notes section).
#>
 
# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================
 
# Mode: 'Enforce' | 'Audit' | 'Discover' | 'Revert'
$Mode = 'Enforce'
 
# Block USB mass storage (compatible ID USB\Class_08). This is the core control.
# Covers flash drives, external HDD/SSD (BOT and UASP), USB card readers, and
# the storage interface of composite devices. Does NOT touch internal SATA/NVMe
# disks or non-storage USB peripherals.
$BlockUsbMassStorage = $true
 
# Also apply the block to matching devices that are already installed
# (retroactive), and actively remove currently attached, non-allowlisted
# matching devnodes so enforcement does not wait for the next plug-in.
$ApplyToExistingDevices = $true
 
# Optionally also block Windows Portable Devices (MTP/PTP: phones, cameras,
# media players) via the WPD device setup class. Recommended if the goal is
# data-exfiltration control, since MTP is the classic bypass for a
# storage-only block. Phone *charging* is unaffected.
$BlockPortableDevices = $false
 
# --- Allowlist: sanctioned devices that remain (or become) usable -----------
 
# Device INSTANCE IDs (per-unit, serial-bound). This is the supported way to
# exempt a storage device from the USB\Class_08 deny: with layered evaluation
# enabled, instance-ID Allow entries supersede device-ID Deny entries.
# Capture values with $Mode = 'Discover' on a machine with the device attached.
$AllowedInstanceIds = @(
    # 'USB\VID_0781&PID_5575\4C530001234567891234'    # Example: one specific SanDisk stick
    # 'USB\VID_090C&PID_1000&MI_00\7&2f4a1b3c&0&0000'  # Example: storage interface of a composite device
)
 
# Hardware IDs / compatible IDs (model-level, e.g. 'USB\VID_0781&PID_5575').
# IMPORTANT: per documented precedence these CANNOT supersede the USB\Class_08
# deny (both live in the same "Device IDs" tier, where Prevent wins). They ARE
# effective against the setup-class-tier WPD block above. For storage
# exemptions, use $AllowedInstanceIds. The script warns if this is misused.
$AllowedHardwareIds = @(
    # 'USB\VID_05AC&PID_12A8'    # Example: allow all iPhones through the WPD block
)
 
# Let members of the local Administrators group install/update drivers for any
# device regardless of the restrictions (GPO "Allow administrators to override
# Device Installation Restriction policies").
$AllowAdminOverride = $false
 
# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Manage-UsbStorageRestrictions.log'
 
# =============================================================================
# CONSTANTS
# =============================================================================
 
$ScriptVersion    = '1.0.0'
$RestrictionsKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$StateKey         = 'HKLM:\SOFTWARE\IruScripts\UsbStorageRestrictions'
$UsbMassStorageId = 'USB\Class_08'                                  # compatible ID carried by every USB mass storage function
$WpdClassGuid     = '{eec5ad98-8080-425f-922a-dabf3de3f69a}'        # Windows Portable Devices setup class
$Class08Regex     = '^USB\\Class_08'                                 # matches USB\Class_08, USB\Class_08&SubClass_06, etc.
 
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
 
function Get-OsBuildInfo {
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        Build = [int]$cv.CurrentBuildNumber
        Ubr   = [int]($cv.UBR)
    }
}
 
function Test-LayeringSupported {
    # EnableInstallationPolicyLayering availability per the DeviceInstallation
    # Policy CSP reference: 17763.2145+, 18362.1714+, 19041.1151+ (and the
    # 19042/19043 servicing equivalents), 20348.256+, 22000+.
    param([Parameter(Mandatory)]$Os)
    if ($Os.Build -ge 22000) { return $true }
    if ($Os.Build -eq 20348) { return ($Os.Ubr -ge 256) }
    if ($Os.Build -ge 19044) { return $true }                       # 21H2/22H2 shipped after the backport
    if ($Os.Build -ge 19041) { return ($Os.Ubr -ge 1151) }
    if ($Os.Build -ge 18362) { return ($Os.Ubr -ge 1714) }
    if ($Os.Build -eq 17763) { return ($Os.Ubr -ge 2145) }
    return $false
}
 
# =============================================================================
# REGISTRY HELPERS
# =============================================================================
 
function Set-PolicyDword {
    # Ensures a REG_DWORD exists with the desired data. Returns $true if changed.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    try {
        if (-not (Test-Path -Path $Key)) { New-Item -Path $Key -Force | Out-Null }
        $current = (Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $current -and [int]$current -eq $Value) {
            Write-Log "OK      $Name = $Value (already set)" 'OK'
            return $false
        }
        New-ItemProperty -Path $Key -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
        Write-Log "SET     $Name = $Value (was: $(if ($null -eq $current) { '<absent>' } else { $current }))"
        return $true
    } catch {
        Write-Log "Failed to set $Name at ${Key}: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}
 
function Remove-PolicyValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name
    )
    try {
        $current = (Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $current) {
            Remove-ItemProperty -Path $Key -Name $Name -Force -ErrorAction Stop
            Write-Log "REMOVED $Name (was: $current)"
        }
    } catch {
        Write-Log "Failed to remove value $Name at ${Key}: $($_.Exception.Message)" 'ERROR'
    }
}
 
function Get-PolicyListEntries {
    # Reads the numbered REG_SZ values ("1","2",...) of a policy list subkey.
    param([Parameter(Mandatory)][string]$SubKey)
    $entries = @()
    if (Test-Path -Path $SubKey) {
        $item = Get-Item -Path $SubKey
        foreach ($name in $item.GetValueNames()) {
            if ($name -match '^\d+$') { $entries += [string]$item.GetValue($name) }
        }
    }
    return @($entries)
}
 
function Set-PolicyList {
    # Rewrites a policy list subkey so it contains exactly $Entries as
    # numbered REG_SZ values 1..N. Foreign (non-numeric) values are preserved
    # but flagged. Returns $true if anything changed.
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Entries
    )
    try {
        $existing = Get-PolicyListEntries -SubKey $SubKey
        $desired  = @($Entries | Where-Object { $_ } | Select-Object -Unique)
 
        $same = ($existing.Count -eq $desired.Count)
        if ($same) {
            $a = @($existing | Sort-Object { $_.ToLowerInvariant() })
            $b = @($desired  | Sort-Object { $_.ToLowerInvariant() })
            for ($i = 0; $i -lt $a.Count; $i++) {
                if ($a[$i] -ne $b[$i]) { $same = $false; break }
            }
        }
        if ($same) {
            Write-Log "OK      $SubKey list already matches ($($desired.Count) entries)" 'OK'
            return $false
        }
 
        if (-not (Test-Path -Path $SubKey)) { New-Item -Path $SubKey -Force | Out-Null }
        $item = Get-Item -Path $SubKey
        foreach ($name in $item.GetValueNames()) {
            if ($name -match '^\d+$') {
                Remove-ItemProperty -Path $SubKey -Name $name -Force -ErrorAction SilentlyContinue
            } else {
                Write-Log "Foreign value '$name' found under $SubKey - left in place, review manually" 'WARN'
            }
        }
        $index = 1
        foreach ($entry in $desired) {
            New-ItemProperty -Path $SubKey -Name "$index" -PropertyType String -Value $entry -Force | Out-Null
            $index++
        }
        Write-Log "SET     $SubKey list -> $($desired.Count) entries (was $($existing.Count))"
        foreach ($entry in $desired) { Write-Log "          + $entry" }
        return $true
    } catch {
        Write-Log "Failed to write list at ${SubKey}: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}
 
function Remove-PolicyList {
    param([Parameter(Mandatory)][string]$SubKey)
    if (Test-Path -Path $SubKey) {
        try {
            Remove-Item -Path $SubKey -Recurse -Force -ErrorAction Stop
            Write-Log "REMOVED subkey $SubKey"
        } catch {
            Write-Log "Failed to remove subkey ${SubKey}: $($_.Exception.Message)" 'ERROR'
        }
    }
}
 
# =============================================================================
# DEVICE ENUMERATION
# =============================================================================
 
function Get-UsbMassStorageDevices {
    # Present devices whose compatible IDs mark them as USB mass storage
    # functions (parents or composite-device storage interfaces).
    Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
        $_.CompatibleID -and (@($_.CompatibleID) -match $Class08Regex).Count -gt 0
    }
}
 
function Get-WpdDevices {
    Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
        $_.ClassGuid -eq $WpdClassGuid
    }
}
 
function Test-DeviceAllowed {
    param(
        [Parameter(Mandatory)]$Device,
        [switch]$IncludeHardwareIdMatch   # only valid for class-tier denies (WPD)
    )
    if ($AllowedInstanceIds -contains $Device.PNPDeviceID) { return $true }
    if ($IncludeHardwareIdMatch -and $AllowedHardwareIds.Count -gt 0) {
        $ids = @()
        if ($Device.HardwareID)   { $ids += @($Device.HardwareID) }
        if ($Device.CompatibleID) { $ids += @($Device.CompatibleID) }
        foreach ($id in $ids) {
            if ($AllowedHardwareIds -contains $id) { return $true }
        }
    }
    return $false
}
 
function Remove-BlockedDevice {
    param([Parameter(Mandatory)]$Device)
    $id = $Device.PNPDeviceID
    Write-Log "Removing devnode: '$($Device.Name)' [$id]"
    & pnputil.exe /remove-device "$id" 2>&1 | ForEach-Object { Write-Log "          pnputil: $_" }
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Log "pnputil /remove-device returned $LASTEXITCODE, falling back to Disable-PnpDevice" 'WARN'
    try {
        Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
        Write-Log "          disabled via Disable-PnpDevice"
        return $true
    } catch {
        Write-Log "Could not remove or disable '$id': $($_.Exception.Message)" 'ERROR'
        return $false
    }
}
 
# =============================================================================
# DESIRED STATE MODEL (shared by Enforce and Audit)
# =============================================================================
 
function Get-DesiredState {
    $denyIds = @()
    if ($BlockUsbMassStorage) { $denyIds += $UsbMassStorageId }
 
    $denyClasses = @()
    if ($BlockPortableDevices) { $denyClasses += $WpdClassGuid }
 
    $retro = 0
    if ($ApplyToExistingDevices) { $retro = 1 }
 
    [pscustomobject]@{
        # value name                 -> desired data ($null = must be absent)
        Dwords = [ordered]@{
            'AllowDenyLayered'             = 1
            'DenyDeviceIDs'                = $(if ($denyIds.Count -gt 0) { 1 } else { $null })
            'DenyDeviceIDsRetroactive'     = $(if ($denyIds.Count -gt 0) { $retro } else { $null })
            'DenyDeviceClasses'            = $(if ($denyClasses.Count -gt 0) { 1 } else { $null })
            'DenyDeviceClassesRetroactive' = $(if ($denyClasses.Count -gt 0) { $retro } else { $null })
            'AllowInstanceIDs'             = $(if ($AllowedInstanceIds.Count -gt 0) { 1 } else { $null })
            'AllowDeviceIDs'               = $(if ($AllowedHardwareIds.Count -gt 0) { 1 } else { $null })
            'AllowAdminInstall'            = $(if ($AllowAdminOverride) { 1 } else { $null })
        }
        Lists = [ordered]@{
            'DenyDeviceIDs'     = $denyIds
            'DenyDeviceClasses' = $denyClasses
            'AllowInstanceIDs'  = @($AllowedInstanceIds)
            'AllowDeviceIDs'    = @($AllowedHardwareIds)
        }
    }
}
 
# =============================================================================
# MODES
# =============================================================================
 
function Invoke-Enforce {
    Write-Log "=== ENFORCE: applying USB storage restriction policy ==="
    $state = Get-DesiredState
 
    foreach ($name in $state.Dwords.Keys) {
        $value = $state.Dwords[$name]
        if ($null -ne $value) {
            Set-PolicyDword -Key $RestrictionsKey -Name $name -Value $value | Out-Null
        } else {
            Remove-PolicyValue -Key $RestrictionsKey -Name $name
        }
    }
 
    foreach ($listName in $state.Lists.Keys) {
        $entries = @($state.Lists[$listName])
        $subKey  = Join-Path $RestrictionsKey $listName
        if ($entries.Count -gt 0) {
            Set-PolicyList -SubKey $subKey -Entries $entries | Out-Null
        } else {
            Remove-PolicyList -SubKey $subKey
        }
    }
 
    # Immediate enforcement against devices that are already attached.
    if ($ApplyToExistingDevices -and $BlockUsbMassStorage) {
        Write-Log "Sweeping currently attached USB mass storage devices..."
        $devices = @(Get-UsbMassStorageDevices)
        if ($devices.Count -eq 0) {
            Write-Log "OK      no USB mass storage devices currently attached" 'OK'
        }
        foreach ($dev in $devices) {
            if (Test-DeviceAllowed -Device $dev) {
                Write-Log "OK      allowlisted, left in place: '$($dev.Name)' [$($dev.PNPDeviceID)]" 'OK'
            } else {
                Remove-BlockedDevice -Device $dev | Out-Null
            }
        }
    }
    if ($ApplyToExistingDevices -and $BlockPortableDevices) {
        Write-Log "Sweeping currently attached Windows Portable Devices..."
        foreach ($dev in @(Get-WpdDevices)) {
            if (Test-DeviceAllowed -Device $dev -IncludeHardwareIdMatch) {
                Write-Log "OK      allowlisted, left in place: '$($dev.Name)' [$($dev.PNPDeviceID)]" 'OK'
            } else {
                Remove-BlockedDevice -Device $dev | Out-Null
            }
        }
    }
 
    # State stamp for fleet forensics (informational only; Audit reads live policy).
    try {
        if (-not (Test-Path -Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        New-ItemProperty -Path $StateKey -Name 'ScriptVersion'  -PropertyType String -Value $ScriptVersion -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'LastEnforceUtc' -PropertyType String -Value (Get-Date).ToUniversalTime().ToString('o') -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'ConfigSummary'  -PropertyType String -Value ("MassStorage=$BlockUsbMassStorage; WPD=$BlockPortableDevices; Retro=$ApplyToExistingDevices; AllowedInstances=$($AllowedInstanceIds.Count); AllowedHwIds=$($AllowedHardwareIds.Count); AdminOverride=$AllowAdminOverride") -Force | Out-Null
    } catch {
        Write-Log "Could not write state stamp: $($_.Exception.Message)" 'WARN'
    }
 
    Write-Log "Enforcement pass complete. New installation attempts are evaluated immediately; a reboot guarantees full retroactive coverage of previously installed matches."
}
 
function Invoke-Audit {
    Write-Log "=== AUDIT: comparing live policy state to configuration ==="
    $state = Get-DesiredState
 
    foreach ($name in $state.Dwords.Keys) {
        $desired = $state.Dwords[$name]
        $actual  = (Get-ItemProperty -Path $RestrictionsKey -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -eq $desired) {
            if ($null -ne $actual) {
                Write-Log "DRIFT   $name present with value $actual, expected absent" 'DRIFT'
            } else {
                Write-Log "OK      $name absent as expected" 'OK'
            }
        } else {
            if ($null -eq $actual) {
                Write-Log "DRIFT   $name absent, expected $desired" 'DRIFT'
            } elseif ([int]$actual -ne [int]$desired) {
                Write-Log "DRIFT   $name = $actual, expected $desired" 'DRIFT'
            } else {
                Write-Log "OK      $name = $desired" 'OK'
            }
        }
    }
 
    foreach ($listName in $state.Lists.Keys) {
        $subKey  = Join-Path $RestrictionsKey $listName
        $desired = @($state.Lists[$listName] | Sort-Object { $_.ToLowerInvariant() })
        $actual  = @(Get-PolicyListEntries -SubKey $subKey | Sort-Object { $_.ToLowerInvariant() })
        $match = ($desired.Count -eq $actual.Count)
        if ($match) {
            for ($i = 0; $i -lt $desired.Count; $i++) {
                if ($desired[$i] -ne $actual[$i]) { $match = $false; break }
            }
        }
        if ($match) {
            Write-Log "OK      $listName list matches ($($desired.Count) entries)" 'OK'
        } else {
            Write-Log "DRIFT   $listName list mismatch. Expected [$($desired -join '; ')] Actual [$($actual -join '; ')]" 'DRIFT'
        }
    }
 
    if ($ApplyToExistingDevices -and $BlockUsbMassStorage) {
        foreach ($dev in @(Get-UsbMassStorageDevices)) {
            if (-not (Test-DeviceAllowed -Device $dev)) {
                Write-Log "DRIFT   non-allowlisted USB mass storage device present: '$($dev.Name)' [$($dev.PNPDeviceID)]" 'DRIFT'
            }
        }
    }
 
    if ($script:DriftCount -eq 0) {
        Write-Log "Audit result: COMPLIANT"
    } else {
        Write-Log "Audit result: $($script:DriftCount) drift item(s) found" 'WARN'
    }
}
 
function Invoke-Discover {
    Write-Log "=== DISCOVER: enumerating attached USB storage for allowlisting ==="
    $devices = @(Get-UsbMassStorageDevices)
    $wpd     = @(Get-WpdDevices)
 
    if ($devices.Count -eq 0 -and $wpd.Count -eq 0) {
        Write-Log "No USB mass storage or portable devices are currently attached. Plug in the device to sanction and re-run." 'WARN'
        return
    }
 
    foreach ($dev in $devices) {
        Write-Log "--------------------------------------------------------------"
        Write-Log "Name        : $($dev.Name)"
        Write-Log "Instance ID : $($dev.PNPDeviceID)"
        if ($dev.HardwareID) { Write-Log "Hardware IDs: $((@($dev.HardwareID) | Select-Object -First 2) -join ' | ')" }
        if ($dev.PNPDeviceID -match '\\\d+&') {
            Write-Log "NOTE: this instance path looks port-generated (no unique serial). It will change if the device is moved to another port or machine - prefer serialized drives for allowlisting." 'WARN'
        }
    }
    if ($wpd.Count -gt 0) {
        Write-Log "--- Windows Portable Devices (relevant if `$BlockPortableDevices = `$true) ---"
        foreach ($dev in $wpd) {
            Write-Log "Name: $($dev.Name)  Instance ID: $($dev.PNPDeviceID)  HW: $((@($dev.HardwareID) | Select-Object -First 1))"
        }
    }
 
    Write-Log "--------------------------------------------------------------"
    Write-Log "Paste-ready block for the CONFIGURATION section:"
    Write-Output ''
    Write-Output '$AllowedInstanceIds = @('
    foreach ($dev in $devices) {
        Write-Output ("    '{0}'    # {1}" -f $dev.PNPDeviceID, $dev.Name)
    }
    Write-Output ')'
    Write-Output ''
}
 
function Invoke-Revert {
    Write-Log "=== REVERT: removing all policy state managed by this script ==="
    foreach ($name in @('AllowDenyLayered','DenyDeviceIDs','DenyDeviceIDsRetroactive',
                        'DenyDeviceClasses','DenyDeviceClassesRetroactive',
                        'AllowInstanceIDs','AllowDeviceIDs','AllowAdminInstall')) {
        Remove-PolicyValue -Key $RestrictionsKey -Name $name
    }
    foreach ($listName in @('DenyDeviceIDs','DenyDeviceClasses','AllowInstanceIDs','AllowDeviceIDs')) {
        Remove-PolicyList -SubKey (Join-Path $RestrictionsKey $listName)
    }
    if (Test-Path -Path $StateKey) {
        Remove-Item -Path $StateKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "REMOVED state key $StateKey"
    }
    Write-Log "Rescanning the device tree so removed devices can reinstall..."
    & pnputil.exe /scan-devices 2>&1 | ForEach-Object { Write-Log "          pnputil: $_" }
    Write-Log "Revert complete. Previously removed devices reinstall on rescan or replug."
}
 
# =============================================================================
# MAIN
# =============================================================================
 
Write-Log "Manage-UsbStorageRestrictions v$ScriptVersion starting in mode: $Mode"
 
if (-not (Test-IsElevated)) {
    Write-Log "This script must run elevated (SYSTEM via Iru, or an elevated shell for testing)." 'ERROR'
    exit 2
}
 
$os = Get-OsBuildInfo
Write-Log "OS build $($os.Build).$($os.Ubr)"
 
# Config sanity checks
if ($Mode -in @('Enforce','Audit')) {
    if ($AllowedInstanceIds.Count -gt 0 -and $os.Build -lt 19041) {
        Write-Log "Device instance ID allow policies require Windows 10 2004 (build 19041) or later. This build cannot honor the allowlist - refusing to apply a policy that would block sanctioned devices." 'ERROR'
        exit 2
    }
    if (-not (Test-LayeringSupported -Os $os)) {
        if (($AllowedInstanceIds.Count + $AllowedHardwareIds.Count) -gt 0) {
            Write-Log "This build predates 'Apply layered order of evaluation' support, so Allow entries cannot supersede the deny. Refusing to apply - patch the OS or clear the allowlist." 'ERROR'
            exit 2
        }
        Write-Log "Build predates layered-evaluation support. Proceeding with deny-only policy (no allowlist configured)." 'WARN'
    }
    if ($AllowedHardwareIds.Count -gt 0 -and $BlockUsbMassStorage) {
        Write-Log "NOTE: entries in `$AllowedHardwareIds cannot exempt a device from the USB\Class_08 mass-storage deny (same 'Device IDs' evaluation tier, where Prevent wins). Use `$AllowedInstanceIds for storage exemptions. Hardware ID entries remain effective against the WPD class block only." 'WARN'
    }
    foreach ($entry in ($AllowedInstanceIds + $AllowedHardwareIds)) {
        if ($entry -and $entry -notmatch '\\') {
            Write-Log "Allowlist entry '$entry' does not look like a PnP identifier (no enumerator prefix such as USB\...). Verify with Discover mode." 'WARN'
        }
    }
}
 
switch ($Mode) {
    'Enforce'  { Invoke-Enforce }
    'Audit'    { Invoke-Audit }
    'Discover' { Invoke-Discover }
    'Revert'   { Invoke-Revert }
    default    { Write-Log "Unknown mode '$Mode'. Valid: Enforce, Audit, Discover, Revert." 'ERROR' }
}
 
if ($script:FailureCount -gt 0) {
    Write-Log "Completed with $($script:FailureCount) error(s)." 'WARN'
    exit 1
}
if ($Mode -eq 'Audit' -and $script:DriftCount -gt 0) {
    exit 1
}
Write-Log "Completed successfully."
exit 0