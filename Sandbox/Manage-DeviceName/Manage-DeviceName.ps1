<#
.SYNOPSIS
    Renames Windows devices to match a configurable naming template, replicating
    the Intune Autopilot "Apply device name template" and the Intune "Rename
    device" action for endpoints managed by Iru.

.DESCRIPTION
    Computes a desired computer name from a token-based template, compares it to
    the live name (including any rename already pending a reboot), and renames
    the device with Rename-Computer when they differ.

    Supported template tokens:

      %SERIAL%      BIOS serial number (Win32_BIOS.SerialNumber), sanitized
      %SERIAL:n%    Last n characters of the sanitized serial
      %ASSETTAG%    SMBIOS asset tag (Win32_SystemEnclosure.SMBIOSAssetTag)
      %ASSETTAG:n%  Last n characters of the sanitized asset tag
      %CHASSIS%     One letter: L (laptop/tablet), D (desktop), V (VM), O (other)
      %RAND:n%      n random digits - resolved ONCE per device, then persisted
                    so recurring audit/remediation runs do not rename forever

    %SERIAL% and %RAND:n% mirror the macros Intune supports in the Autopilot
    device name template; the rest are extensions. Intune's documented name
    rules are enforced after substitution: 15 characters or less, letters,
    numbers, and hyphens only, and not all numbers.

    Join-state handling:
      * Entra joined / workgroup: renamed locally. The name takes effect at the
        next reboot; the Entra device displayName updates after the device's
        next sync (may lag the reboot).
      * AD domain joined / hybrid: renaming requires domain connectivity and
        rights on the computer object (typically SELF delegated rename rights
        on the OU). The script refuses these devices unless
        $AllowDomainJoinedRename = $true, because a rename without those
        prerequisites breaks the machine's domain trust.

    Modes:
      Enforce  - renames if the live/pending name differs from the template result
      Audit    - reports compliance/drift without changing anything
      Discover - prints join state, raw identifiers, and a name preview
      Revert   - renames back to the original name captured before first rename

    Designed for deployment as an Iru Windows Custom Script Library Item
    running as NT AUTHORITY\SYSTEM. Pair the same script in the Audit slot
    ($Mode = 'Audit') and Remediation slot ($Mode = 'Enforce').

.NOTES
    File     : Manage-DeviceName.ps1
    Version  : 1.0.0 (2026-07-14)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM or local Administrator (elevation required)
    PS       : Windows PowerShell 5.1 (no external modules)

    Exit codes:
      0 = success / compliant / rename correctly pending reboot
      1 = drift detected (Audit) or the rename operation failed
      2 = precondition failure (not elevated, invalid template, unusable
          identifier, or unsupported join state)

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Mode: 'Enforce' | 'Audit' | 'Discover' | 'Revert'
$Mode = 'Enforce'

# Naming template. Tokens: %SERIAL%, %SERIAL:n%, %ASSETTAG%, %ASSETTAG:n%,
# %CHASSIS%, %RAND:n%. Literal characters must be letters, numbers, or hyphens.
# Result must be 15 characters or less and not all numbers - the script
# validates this after substitution and fails fast if violated.
$NameTemplate = 'IRU-%SERIAL%'

# What to do when the substituted name exceeds 15 characters:
#   'Fail'        - exit 2 so the template gets fixed (recommended; use
#                   %SERIAL:n% to make the length deterministic)
#   'TruncateEnd' - keep the first 15 characters. WARNING: with trailing
#                   %SERIAL% this cuts the end of the serial, which is usually
#                   its most distinctive part - collisions become possible.
$OnNameTooLong = 'Fail'

# Restart behavior after a successful rename. The new name only takes effect
# after a reboot.
#   'None'      - do nothing; the name applies at the next natural restart
#   'Delayed'   - shutdown.exe /r with $RestartDelaySeconds and a user message
#   'Immediate' - restart after a 10 second warning
$RestartBehavior     = 'None'
$RestartDelaySeconds = 300
$RestartMessage      = 'Your device is being renamed by IT and will restart shortly. Please save your work.'

# AD-joined / hybrid-joined safety gate. Leave $false unless SELF has been
# delegated rename rights on the computer objects' OU and the device has
# line of sight to a domain controller when this runs - otherwise the rename
# breaks domain trust.
$AllowDomainJoinedRename = $false

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Manage-DeviceName.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion   = '1.0.0'
$StateKey        = 'HKLM:\SOFTWARE\IruScripts\DeviceName'
$ActiveNameKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'
$PendingNameKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'

# BIOS/enclosure values that mean "the OEM never set this field"
$PlaceholderValues = @(
    '', '0', '00000000', 'None', 'Default string', 'Default', 'Not Specified',
    'Not Available', 'To Be Filled By O.E.M.', 'To be filled by O.E.M.',
    'System Serial Number', 'Chassis Serial Number', 'No Asset Tag',
    'Asset-1234567890', 'INVALID', 'N/A', 'NA', '123456789', 'OEM'
)

# Win32_SystemEnclosure ChassisTypes -> letter (SMBIOS enclosure type enum)
$LaptopChassisTypes  = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)   # portables, notebooks, tablets, convertibles, detachables
$DesktopChassisTypes = @(3, 4, 5, 6, 7, 13, 15, 16, 24, 34, 35, 36)  # desktops, towers, all-in-ones, minis, sticks

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

function Get-JoinState {
    # Combines Win32_ComputerSystem.PartOfDomain with dsregcmd /status device state.
    $partOfDomain = $false
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $partOfDomain = [bool]$cs.PartOfDomain
    } catch {
        Write-Log "Could not query Win32_ComputerSystem: $($_.Exception.Message)" 'WARN'
    }
    $entraJoined = $false
    try {
        $ds = & dsregcmd.exe /status 2>$null
        foreach ($line in $ds) {
            if ($line -match 'AzureAdJoined\s*:\s*YES') { $entraJoined = $true }
        }
    } catch {
        Write-Log "dsregcmd /status failed: $($_.Exception.Message)" 'WARN'
    }
    [pscustomobject]@{
        DomainJoined = $partOfDomain
        EntraJoined  = $entraJoined
        Hybrid       = ($partOfDomain -and $entraJoined)
        Workgroup    = (-not $partOfDomain -and -not $entraJoined)
    }
}

# =============================================================================
# IDENTIFIER COLLECTION
# =============================================================================

function ConvertTo-NameToken {
    # Uppercases and strips anything that is not A-Z or 0-9. Hyphens belong to
    # the template's literal text, not to token values, so double/trailing
    # hyphen edge cases cannot occur.
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return (($Value.ToUpperInvariant()) -replace '[^A-Z0-9]', '')
}

function Test-IsPlaceholder {
    param([string]$Value)
    if ($null -eq $Value) { return $true }
    return ($PlaceholderValues -contains $Value.Trim())
}

function Get-SerialNumber {
    try {
        $raw = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    } catch {
        Write-Log "Could not read Win32_BIOS: $($_.Exception.Message)" 'ERROR'
        return $null
    }
    if (Test-IsPlaceholder -Value $raw) {
        Write-Log "BIOS serial number is empty or an OEM placeholder ('$raw')." 'WARN'
        return $null
    }
    $clean = ConvertTo-NameToken -Value $raw
    if ($clean.Length -eq 0) {
        Write-Log "BIOS serial number '$raw' contains no usable characters after sanitization." 'WARN'
        return $null
    }
    [pscustomobject]@{ Raw = $raw; Clean = $clean }
}

function Get-AssetTag {
    try {
        $raw = (Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop | Select-Object -First 1).SMBIOSAssetTag
    } catch {
        Write-Log "Could not read Win32_SystemEnclosure: $($_.Exception.Message)" 'ERROR'
        return $null
    }
    if (Test-IsPlaceholder -Value $raw) {
        Write-Log "SMBIOS asset tag is empty or an OEM placeholder ('$raw')." 'WARN'
        return $null
    }
    $clean = ConvertTo-NameToken -Value $raw
    if ($clean.Length -eq 0) {
        Write-Log "Asset tag '$raw' contains no usable characters after sanitization." 'WARN'
        return $null
    }
    [pscustomobject]@{ Raw = $raw; Clean = $clean }
}

function Get-ChassisLetter {
    # V for virtual machines, else L/D/O from the SMBIOS enclosure type.
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if (("$($cs.Manufacturer) $($cs.Model)") -match 'Virtual|VMware|VirtualBox|KVM|QEMU|Xen|Parallels|Proxmox') {
            return 'V'
        }
    } catch { }
    try {
        $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop | Select-Object -First 1
        $type = @($enclosure.ChassisTypes) | Select-Object -First 1
        if ($LaptopChassisTypes  -contains $type) { return 'L' }
        if ($DesktopChassisTypes -contains $type) { return 'D' }
        Write-Log "Chassis type $type is not in the laptop/desktop maps - using 'O'." 'WARN'
    } catch {
        Write-Log "Could not read chassis type: $($_.Exception.Message)" 'WARN'
    }
    return 'O'
}

# =============================================================================
# STATE (persists %RAND% resolutions and the pre-rename original name)
# =============================================================================

function Get-StoredState {
    if (-not (Test-Path -Path $StateKey)) { return $null }
    $props = Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Template     = [string]$props.Template
        ResolvedName = [string]$props.ResolvedName
        OriginalName = [string]$props.OriginalName
    }
}

function Save-StateValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    try {
        if (-not (Test-Path -Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        New-ItemProperty -Path $StateKey -Name $Name -PropertyType String -Value $Value -Force | Out-Null
    } catch {
        Write-Log "Could not write state value ${Name}: $($_.Exception.Message)" 'WARN'
    }
}

# =============================================================================
# NAME RESOLUTION
# =============================================================================

function Resolve-DesiredName {
    # Returns the target computer name for this device, or $null on failure
    # (failure reasons are logged and treated as exit-2 preconditions).
    param([switch]$PreviewOnly)   # Discover: do not persist a fresh %RAND%

    $template = $NameTemplate.Trim()
    if ([string]::IsNullOrWhiteSpace($template)) {
        Write-Log 'No $NameTemplate configured.' 'ERROR'
        return $null
    }

    $containsRand = ($template -match '%RAND:\d+%')

    # Reuse a previously persisted resolution when the template is random-based
    # and unchanged - otherwise every run would generate a new name and the
    # audit/remediation pair would rename the device forever. This is the known
    # failure mode of pushing %RAND% via a recurring Accounts CSP profile.
    $stored = Get-StoredState
    if ($containsRand -and $stored -and $stored.ResolvedName -and $stored.Template -eq $template) {
        Write-Log "Reusing persisted resolution '$($stored.ResolvedName)' for random-based template." 'OK'
        return $stored.ResolvedName
    }

    $name = $template.ToUpperInvariant()

    # %SERIAL% / %SERIAL:n%
    if ($name -match '%SERIAL(:\d+)?%') {
        $serial = Get-SerialNumber
        if ($null -eq $serial) {
            Write-Log 'Template requires %SERIAL% but no usable serial exists on this device. Use %RAND:n% or %ASSETTAG% for this hardware.' 'ERROR'
            return $null
        }
        $name = [regex]::Replace($name, '%SERIAL:(\d+)%', {
            param($m)
            $n = [int]$m.Groups[1].Value
            if ($serial.Clean.Length -le $n) { $serial.Clean } else { $serial.Clean.Substring($serial.Clean.Length - $n) }
        })
        $name = $name -replace '%SERIAL%', $serial.Clean
    }

    # %ASSETTAG% / %ASSETTAG:n%
    if ($name -match '%ASSETTAG(:\d+)?%') {
        $tag = Get-AssetTag
        if ($null -eq $tag) {
            Write-Log 'Template requires %ASSETTAG% but no usable SMBIOS asset tag exists on this device.' 'ERROR'
            return $null
        }
        $name = [regex]::Replace($name, '%ASSETTAG:(\d+)%', {
            param($m)
            $n = [int]$m.Groups[1].Value
            if ($tag.Clean.Length -le $n) { $tag.Clean } else { $tag.Clean.Substring($tag.Clean.Length - $n) }
        })
        $name = $name -replace '%ASSETTAG%', $tag.Clean
    }

    # %CHASSIS%
    if ($name -match '%CHASSIS%') {
        $name = $name -replace '%CHASSIS%', (Get-ChassisLetter)
    }

    # %RAND:n%
    $name = [regex]::Replace($name, '%RAND:(\d+)%', {
        param($m)
        $n = [int]$m.Groups[1].Value
        $digits = ''
        for ($i = 0; $i -lt $n; $i++) { $digits += (Get-Random -Minimum 0 -Maximum 10) }
        $digits
    })

    # Any token left unresolved is a config error.
    if ($name -match '%[A-Z]+(:\d+)?%') {
        Write-Log "Template contains an unrecognized token: '$NameTemplate'. Supported: %SERIAL%, %SERIAL:n%, %ASSETTAG%, %ASSETTAG:n%, %CHASSIS%, %RAND:n%." 'ERROR'
        return $null
    }

    # --- Validation against the documented computer name rules ---

    if ($name -match '[^A-Z0-9-]') {
        Write-Log "Resolved name '$name' contains characters other than letters, numbers, and hyphens. Fix the literal text in the template." 'ERROR'
        return $null
    }
    $trimmed = $name.Trim('-')
    if ($trimmed -ne $name) {
        Write-Log "Resolved name '$name' had a leading/trailing hyphen - trimmed to '$trimmed'." 'WARN'
        $name = $trimmed
    }
    if ($name.Length -eq 0) {
        Write-Log 'Resolved name is empty after sanitization.' 'ERROR'
        return $null
    }
    if ($name.Length -gt 15) {
        if ($OnNameTooLong -eq 'TruncateEnd') {
            $original = $name
            $name = $name.Substring(0, 15).Trim('-')
            Write-Log "Resolved name '$original' exceeds 15 characters - truncated to '$name'. Consider %SERIAL:n% for deterministic length and uniqueness." 'WARN'
        } else {
            Write-Log "Resolved name '$name' exceeds the 15 character NetBIOS limit. Use %SERIAL:n% / %ASSETTAG:n% or shorten the prefix." 'ERROR'
            return $null
        }
    }
    if ($name -match '^[0-9]+$') {
        Write-Log "Resolved name '$name' is all numbers, which Windows does not allow. Add a letter prefix to the template." 'ERROR'
        return $null
    }
    if ($name -match '^[0-9-]+$') {
        Write-Log "Resolved name '$name' contains only digits and hyphens - some tooling treats this like an all-numeric name. Consider adding a letter prefix." 'WARN'
    }

    # Persist random-based resolutions so they are stable across runs.
    if ($containsRand -and -not $PreviewOnly) {
        Save-StateValue -Name 'Template'     -Value $template
        Save-StateValue -Name 'ResolvedName' -Value $name
        Save-StateValue -Name 'ResolvedUtc'  -Value (Get-Date).ToUniversalTime().ToString('o')
        Write-Log "Persisted random-based resolution '$name' to $StateKey."
    }

    return $name
}

# =============================================================================
# NAME STATE (active vs pending)
# =============================================================================

function Get-ComputerNameState {
    $active  = (Get-ItemProperty -Path $ActiveNameKey  -Name 'ComputerName' -ErrorAction SilentlyContinue).ComputerName
    $pending = (Get-ItemProperty -Path $PendingNameKey -Name 'ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if (-not $active) { $active = $env:COMPUTERNAME }
    [pscustomobject]@{
        Active        = [string]$active
        Pending       = [string]$pending
        RenamePending = ($pending -and $active -and ($pending -ne $active))
    }
}

# =============================================================================
# RESTART HANDLING
# =============================================================================

function Invoke-RestartBehavior {
    switch ($RestartBehavior) {
        'None' {
            Write-Log 'RestartBehavior=None - the new name takes effect at the next natural restart.'
        }
        'Delayed' {
            Write-Log "Scheduling restart in $RestartDelaySeconds seconds."
            & shutdown.exe /r /t $RestartDelaySeconds /c "$RestartMessage" 2>&1 | ForEach-Object { Write-Log "          shutdown: $_" }
        }
        'Immediate' {
            Write-Log 'Restarting in 10 seconds.'
            & shutdown.exe /r /t 10 /c "$RestartMessage" 2>&1 | ForEach-Object { Write-Log "          shutdown: $_" }
        }
        default {
            Write-Log "Unknown RestartBehavior '$RestartBehavior' - treating as None." 'WARN'
        }
    }
}

# =============================================================================
# JOIN-STATE GATE
# =============================================================================

function Test-RenamePermitted {
    param([Parameter(Mandatory)]$Join)
    if (-not $Join.DomainJoined) { return $true }
    if ($AllowDomainJoinedRename) {
        Write-Log 'Device is AD domain joined and $AllowDomainJoinedRename is set. This only works when SELF has delegated rename rights on the computer object and a DC is reachable right now - otherwise domain trust will break.' 'WARN'
        return $true
    }
    Write-Log 'Device is AD domain joined (or hybrid joined). Renaming is blocked by default because it requires delegated rename rights and DC connectivity. Set $AllowDomainJoinedRename = $true only after both are in place.' 'ERROR'
    return $false
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-Enforce {
    Write-Log '=== ENFORCE: applying device naming template ==='
    $desired = Resolve-DesiredName
    if ($null -eq $desired) { exit 2 }

    $names = Get-ComputerNameState
    Write-Log "Active name: $($names.Active)  Pending name: $(if ($names.Pending) { $names.Pending } else { '<none>' })  Desired: $desired"

    if ($names.Active -ieq $desired -and (-not $names.RenamePending)) {
        Write-Log 'OK      device name already matches the template' 'OK'
        return
    }
    if ($names.RenamePending -and $names.Pending -ieq $desired) {
        Write-Log 'OK      rename to the desired name is already pending a reboot' 'OK'
        Invoke-RestartBehavior
        return
    }

    $join = Get-JoinState
    Write-Log "Join state: DomainJoined=$($join.DomainJoined) EntraJoined=$($join.EntraJoined) Hybrid=$($join.Hybrid) Workgroup=$($join.Workgroup)"
    if (-not (Test-RenamePermitted -Join $join)) { exit 2 }

    # Capture the original name once, before the first rename, so Revert works.
    $stored = Get-StoredState
    if (-not ($stored -and $stored.OriginalName)) {
        Save-StateValue -Name 'OriginalName' -Value $names.Active
        Write-Log "Captured original name '$($names.Active)' for Revert."
    }

    try {
        Rename-Computer -NewName $desired -Force -ErrorAction Stop
        Write-Log "RENAMED '$($names.Active)' -> '$desired' (effective after reboot)"
    } catch {
        Write-Log "Rename-Computer failed: $($_.Exception.Message)" 'ERROR'
        return
    }

    Save-StateValue -Name 'ScriptVersion' -Value $ScriptVersion
    Save-StateValue -Name 'LastRenameUtc' -Value (Get-Date).ToUniversalTime().ToString('o')
    Save-StateValue -Name 'LastRenameTo'  -Value $desired

    if ($join.EntraJoined) {
        Write-Log 'Entra joined: the device displayName in Entra/Iru updates after the next device sync following the reboot, and may lag the local rename.'
    }

    Invoke-RestartBehavior
}

function Invoke-Audit {
    Write-Log '=== AUDIT: comparing device name to naming template ==='
    $desired = Resolve-DesiredName
    if ($null -eq $desired) { exit 2 }

    $names = Get-ComputerNameState
    Write-Log "Active name: $($names.Active)  Pending name: $(if ($names.Pending) { $names.Pending } else { '<none>' })  Desired: $desired"

    if ($names.Active -ieq $desired -and (-not $names.RenamePending)) {
        Write-Log 'Audit result: COMPLIANT'
        return
    }
    if ($names.RenamePending -and $names.Pending -ieq $desired) {
        Write-Log 'Audit result: COMPLIANT (rename pending reboot)'
        return
    }
    if ($names.RenamePending) {
        Write-Log "DRIFT   a rename to '$($names.Pending)' is pending, which does not match the template result '$desired'" 'DRIFT'
    } else {
        Write-Log "DRIFT   device name '$($names.Active)' does not match the template result '$desired'" 'DRIFT'
    }
    Write-Log "Audit result: $($script:DriftCount) drift item(s) found" 'WARN'
}

function Invoke-Discover {
    Write-Log '=== DISCOVER: device identity and naming preview ==='
    $names = Get-ComputerNameState
    $join  = Get-JoinState

    Write-Log "Active name        : $($names.Active)"
    Write-Log "Pending name       : $(if ($names.Pending -and $names.RenamePending) { $names.Pending + '  (reboot required)' } else { '<none>' })"
    Write-Log "Join state         : DomainJoined=$($join.DomainJoined) EntraJoined=$($join.EntraJoined) Hybrid=$($join.Hybrid) Workgroup=$($join.Workgroup)"

    $serial = Get-SerialNumber
    if ($serial) { Write-Log "Serial (raw/clean) : '$($serial.Raw)' / '$($serial.Clean)' ($($serial.Clean.Length) chars)" }
    else         { Write-Log 'Serial             : <unusable - empty or OEM placeholder>' 'WARN' }

    $tag = Get-AssetTag
    if ($tag) { Write-Log "Asset tag          : '$($tag.Raw)' / '$($tag.Clean)'" }
    else      { Write-Log 'Asset tag          : <unusable - empty or OEM placeholder>' }

    Write-Log "Chassis letter     : $(Get-ChassisLetter)"

    $stored = Get-StoredState
    if ($stored -and $stored.ResolvedName) {
        Write-Log "Persisted resolution: '$($stored.ResolvedName)' (template '$($stored.Template)')"
    }
    if ($stored -and $stored.OriginalName) {
        Write-Log "Original name       : '$($stored.OriginalName)' (Revert target)"
    }

    $preview = Resolve-DesiredName -PreviewOnly
    if ($preview) {
        Write-Log "Template '$NameTemplate' resolves to: '$preview' ($($preview.Length) chars)"
        if ($NameTemplate -match '%RAND:\d+%' -and -not ($stored -and $stored.ResolvedName)) {
            Write-Log 'Random token shown above is a sample - the persisted value is generated at first Enforce.' 'WARN'
        }
    }
}

function Invoke-Revert {
    Write-Log '=== REVERT: renaming back to the original name ==='
    $stored = Get-StoredState
    if (-not ($stored -and $stored.OriginalName)) {
        Write-Log 'No original name is stored - nothing to revert.' 'WARN'
        return
    }
    $names = Get-ComputerNameState
    if ($names.Active -ieq $stored.OriginalName -and -not $names.RenamePending) {
        Write-Log "Device is already named '$($stored.OriginalName)'. Clearing state."
    } else {
        $join = Get-JoinState
        if (-not (Test-RenamePermitted -Join $join)) { exit 2 }
        try {
            Rename-Computer -NewName $stored.OriginalName -Force -ErrorAction Stop
            Write-Log "RENAMED '$($names.Active)' -> '$($stored.OriginalName)' (effective after reboot)"
        } catch {
            Write-Log "Rename-Computer failed: $($_.Exception.Message)" 'ERROR'
            return
        }
        Invoke-RestartBehavior
    }
    Remove-Item -Path $StateKey -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "REMOVED state key $StateKey"
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Manage-DeviceName v$ScriptVersion starting in mode: $Mode"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
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
Write-Log 'Completed successfully.'
exit 0
