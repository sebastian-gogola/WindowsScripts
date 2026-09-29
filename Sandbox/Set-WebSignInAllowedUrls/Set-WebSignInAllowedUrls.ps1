<#
.SYNOPSIS
    Sets the Windows policy Authentication/ConfigureWebSignInAllowedUrls on
    Iru-managed, Entra-joined devices so the lock screen "I forgot my PIN" and
    Web sign-in flows can reach a third-party identity provider. Replaces the
    Intune Settings Catalog setting "Configure Web Sign In Allowed Urls".

.DESCRIPTION
    ConfigureWebSignInAllowedUrls is a Policy CSP node with no ADMX or Group
    Policy equivalent, and Iru has no OMA-URI or custom CSP profile Library Item
    for Windows. On an Entra-joined device federated to a non-Microsoft IdP, the
    lock screen web view only navigates to hosts on this list; after a migration
    off Intune the list is gone and the PIN reset flow stops at
    "We can't open that page right now" or hangs on "Just a moment...".

    The script writes the policy locally from SYSTEM context, in two tiers:

      1. MDM Bridge WMI provider (root\cimv2\mdm\dmmap, class
         MDM_Policy_Config01_Authentication02). Microsoft documents this as the
         local path into Policy CSP. Microsoft's published class definition
         does NOT list ConfigureWebSignInAllowedUrls, so the script checks the
         class at runtime and uses this path only when the property is exposed.
      2. PolicyManager effective-value registry location
         HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication.
         Community-observed fallback: the Web sign-in component reads its
         effective value from this key. Not Microsoft-supported. Expected path
         on current builds until the WMI property is verified on hardware.

    Every mode states which method was used or which source held the value.

    Modes:
      Enforce  - writes the list when the effective value differs, records
                 method and value under HKLM\SOFTWARE\IruScripts\WebSignInAllowedUrls
      Audit    - compares the effective value against the desired list
                 (semicolon-delimited, case-insensitive, sorted); exit 1 = drift
      Discover - prints the effective value and its source, the WMI class and
                 property exposure, the registry key contents, join state
      Revert   - clears the value through WMI when that is where it was set,
                 removes the value and its _ProviderSet marker from the registry
                 path, removes the state key

    Comparison rule (Audit and Enforce): entries are split on ';', trimmed,
    lower-cased, de-duplicated and sorted before comparing, so order and case
    on the device never count as drift. The value written keeps the case given
    in -AllowedUrls, sorted and de-duplicated.

    Validation: every entry must be a bare hostname. Anything containing a
    scheme (https://), a path (/), or whitespace is rejected before any write,
    with exit 2.

    Designed for an Iru Windows Custom Script Library Item running as
    NT AUTHORITY\SYSTEM. Put the script in the Audit slot with the $Mode
    default changed to 'Audit' and in the Remediation slot unchanged, and put
    the tenant's -AllowedUrls in the Command line parameters field, which Iru
    applies to both slots.

.PARAMETER Mode
    'Audit' | 'Enforce' | 'Discover' | 'Revert'. Default 'Enforce'.

.PARAMETER AllowedUrls
    Semicolon-delimited list of bare hostnames. No default: the list is
    tenant-specific and Audit/Enforce refuse to run without it (exit 2).
    Supply it in the Library Item's Command line parameters field, which Iru
    passes to both the audit and the remediation script, for example:
        -AllowedUrls "accounts.google.com;accounts.youtube.com"

    Take the real list from the tenant's former Intune profile or from the
    redirect chain of the IdP sign-in page. Examples (placeholders, not
    recommendations):
      Google Workspace  accounts.google.com;accounts.youtube.com
                        (a field deployment also carried regional hosts such as
                        accounts.google.ca and mysignins.microsoft.com, which
                        the Intune export listed with a path that must be
                        dropped)
      Okta              yourorg.okta.com  (or the Okta custom domain)
      AD FS             adfs.contoso.com
      Microsoft's doc   accounts.contoso.com;signin.contoso.com
      Azure Government  add login.microsoftonline.us (Microsoft PIN reset doc)

.NOTES
    File     : Set-WebSignInAllowedUrls.ps1
    Version  : 1.0.0 (2026-09-29)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM (Iru Custom Script) or an elevated administrator shell
    PS       : Windows PowerShell 5.1 (no external modules)
    Scope    : Entra-joined devices. Web sign-in is not supported on hybrid or
               domain-joined devices (Microsoft). Does not affect OOBE or
               Autopilot sign-in. Does not configure EnablePinRecovery; see
               Manage-WindowsHelloforBusiness for that setting.

    Exit codes:
      0 = success / compliant
      1 = drift detected (Audit) or a runtime failure (Enforce, Revert)
      2 = precondition failure (not elevated, OS below the configured minimum
          build, host list missing in Audit/Enforce, or an entry that is not a
          bare hostname)

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Enforce', 'Discover', 'Revert')]
    [string]$Mode = 'Enforce',

    # No default on purpose: the list is tenant-specific. See .PARAMETER AllowedUrls.
    [AllowEmptyString()]
    [string]$AllowedUrls = ''
)

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Try the MDM Bridge WMI provider before the registry. Set $false to force the
# registry path, for example to reproduce the customer's pilot exactly.
$UseWmiWhenAvailable = $true

# Minimum Windows build. 26100 = Windows 11 24H2, the floor Iru supports. The
# policy itself exists since Windows 10 1803; lower this only for lab use.
$MinimumBuild = 26100

# Revert normally removes only what the state key records as written by this
# script. Set $true to remove the registry value and its _ProviderSet marker
# even when no state key exists, for example on a device configured by the
# earlier separate audit/remediation drafts, which kept no state.
$RevertWithoutState = $false

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Set-WebSignInAllowedUrls.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '1.0.0'
$PolicyName    = 'ConfigureWebSignInAllowedUrls'
$StateKey      = 'HKLM:\SOFTWARE\IruScripts\WebSignInAllowedUrls'

# MDM Bridge WMI provider (Microsoft-documented namespace, class and keys)
$WmiNamespace  = 'root\cimv2\mdm\dmmap'
$WmiClass      = 'MDM_Policy_Config01_Authentication02'
$WmiParentId   = './Vendor/MSFT/Policy/Config'
$WmiInstanceId = 'Authentication'
$WmiFilter     = "ParentID='$WmiParentId' and InstanceID='$WmiInstanceId'"

# PolicyManager effective-value location (community-observed)
$RegPath          = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication'
$ProviderSetName  = "${PolicyName}_ProviderSet"
$WinningProvName  = "${PolicyName}_WinningProvider"

$script:FailureCount = 0
$script:DriftCount   = 0

# =============================================================================
# LOGGING
# =============================================================================

# Write-Log is the logging function every Sandbox script defines by convention.
# PSScriptAnalyzer lists a Write-Log in one PowerShell Core compatibility
# profile; Windows PowerShell 5.1 has no such cmdlet, so nothing is shadowed.
function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Repo-wide logging convention; no Write-Log cmdlet exists in Windows PowerShell 5.1')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DRIFT', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    try {
        if (-not (Test-Path -Path $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $line -ErrorAction Stop
    } catch {
        # Logging to file must never fail the run; stdout already carries the line.
        Write-Verbose "Log file write failed: $($_.Exception.Message)"
    }
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
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = 0
    if ($cv -and $cv.CurrentBuildNumber) { $build = [int]$cv.CurrentBuildNumber }
    $display = ''
    if ($cv -and ($cv.PSObject.Properties.Match('DisplayVersion').Count -gt 0)) { $display = [string]$cv.DisplayVersion }
    $edition = ''
    if ($cv -and $cv.EditionID) { $edition = [string]$cv.EditionID }
    [pscustomobject]@{
        Build       = $build
        DisplayName = ('build {0} ({1}) {2}' -f $build, $display, $edition).Trim()
    }
}

function Get-JoinState {
    $entraJoined = $false
    $domainJoined = $false
    try {
        $ds = & dsregcmd.exe /status 2>$null
        foreach ($line in $ds) {
            if ($line -match 'AzureAdJoined\s*:\s*YES') { $entraJoined = $true }
            if ($line -match 'DomainJoined\s*:\s*YES')  { $domainJoined = $true }
        }
    } catch {
        Write-Log "dsregcmd /status failed: $($_.Exception.Message)" 'WARN'
    }
    [pscustomobject]@{ EntraJoined = $entraJoined; DomainJoined = $domainJoined }
}

# =============================================================================
# HOST LIST HANDLING
# =============================================================================

function ConvertTo-HostArray {
    # Splits the delimited list, trims, drops empties. Keeps case and order.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function ConvertTo-NormalizedList {
    # Comparison form: lower-case, unique, sorted, ';' joined. Order and case on
    # the device never count as drift.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $items = @(ConvertTo-HostArray -Value $Value | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    return ($items -join ';')
}

function Get-InvalidHostEntry {
    # The policy takes hostnames. Returns every entry carrying a scheme, a
    # path, or whitespace (same rule as the original remediation draft).
    param([string[]]$Entries)
    return @($Entries | Where-Object { $_ -match '^[a-z]+://' -or $_ -match '/' -or $_ -match '\s' })
}

function Get-DesiredValue {
    # The string actually written: entries as given, de-duplicated and sorted.
    param([string[]]$Entries)
    return (@($Entries | Sort-Object -Unique) -join ';')
}

# =============================================================================
# WMI TIER
# =============================================================================

function Get-WmiPolicyState {
    # Reports whether the bridge class exists on this build, whether it exposes
    # the property, and the current instance value if any.
    $state = [pscustomobject]@{
        ClassAvailable  = $false
        PropertyExposed = $false
        Instance        = $null
        Value           = $null
        Error           = $null
        Properties      = @()
    }
    try {
        $cls = Get-CimClass -Namespace $WmiNamespace -ClassName $WmiClass -ErrorAction Stop
        $state.ClassAvailable = $true
        $state.Properties = @($cls.CimClassProperties | Where-Object { $_.Name -ne 'InstanceID' -and $_.Name -ne 'ParentID' } | ForEach-Object { $_.Name })
        $state.PropertyExposed = ($state.Properties -contains $PolicyName)
        if ($state.PropertyExposed) {
            $inst = Get-CimInstance -Namespace $WmiNamespace -ClassName $WmiClass -Filter $WmiFilter -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($inst) {
                $state.Instance = $inst
                $prop = $inst.CimInstanceProperties[$PolicyName]
                if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                    $state.Value = [string]$prop.Value
                }
            }
        }
    } catch {
        $state.Error = $_.Exception.Message
    }
    return $state
}

function Set-PolicyViaWmi {
    # Creates or modifies the Authentication policy instance. Returns $true only
    # when the value reads back as expected. Honors -WhatIf from the script.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Desired, [Parameter(Mandatory)][string]$Expected)
    if (-not $PSCmdlet.ShouldProcess("$WmiClass instance '$WmiInstanceId'", "Set $PolicyName = $Desired")) {
        Write-Log "WhatIf: would set $PolicyName through $WmiClass."
        return $false
    }
    try {
        $inst = Get-CimInstance -Namespace $WmiNamespace -ClassName $WmiClass -Filter $WmiFilter -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($inst) {
            $inst.CimInstanceProperties[$PolicyName].Value = $Desired
            Set-CimInstance -CimInstance $inst -ErrorAction Stop | Out-Null
            Write-Log "WMI: modified existing $WmiClass instance."
        } else {
            $props = @{ ParentID = $WmiParentId; InstanceID = $WmiInstanceId }
            $props[$PolicyName] = $Desired
            New-CimInstance -Namespace $WmiNamespace -ClassName $WmiClass -Property $props -ErrorAction Stop | Out-Null
            Write-Log "WMI: created $WmiClass instance."
        }
        $check = Get-WmiPolicyState
        if ((ConvertTo-NormalizedList -Value $check.Value) -eq $Expected) { return $true }
        Write-Log "WMI: write did not read back as expected (read '$($check.Value)')." 'WARN'
        return $false
    } catch {
        Write-Log "WMI: write failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Clear-PolicyViaWmi {
    # Clears just this property on the instance. Setting a bridge property to
    # null and committing is inferred behavior, so the result is verified and
    # reported rather than assumed.
    try {
        $inst = Get-CimInstance -Namespace $WmiNamespace -ClassName $WmiClass -Filter $WmiFilter -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $inst) {
            Write-Log 'WMI: no Authentication policy instance present; nothing to clear.' 'OK'
            return $true
        }
        $inst.CimInstanceProperties[$PolicyName].Value = $null
        Set-CimInstance -CimInstance $inst -ErrorAction Stop | Out-Null
        $check = Get-WmiPolicyState
        if ([string]::IsNullOrWhiteSpace($check.Value)) {
            Write-Log "WMI: cleared $PolicyName on the Authentication instance."
            return $true
        }
        Write-Log "WMI: property still reads '$($check.Value)' after clearing." 'WARN'
        return $false
    } catch {
        Write-Log "WMI: clear failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# =============================================================================
# REGISTRY TIER
# =============================================================================

function Get-RegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -Path $Path)) { return $null }
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

function Set-PolicyViaRegistry {
    # Writes the effective value and its _ProviderSet marker. Honors -WhatIf.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Desired, [Parameter(Mandatory)][string]$Expected)
    if (-not $PSCmdlet.ShouldProcess($RegPath, "Set $PolicyName = $Desired and $ProviderSetName = 1")) {
        Write-Log "WhatIf: would set $PolicyName in $RegPath."
        return $false
    }
    try {
        if (-not (Test-Path -Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
        New-ItemProperty -Path $RegPath -Name $PolicyName -Value $Desired -PropertyType String -Force -ErrorAction Stop | Out-Null
        # _ProviderSet marks the policy as configured in the PolicyManager store
        # (community-observed convention, mirrors what MDM-delivered values carry).
        New-ItemProperty -Path $RegPath -Name $ProviderSetName -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $readBack = Get-RegistryValue -Path $RegPath -Name $PolicyName
        if ((ConvertTo-NormalizedList -Value ([string]$readBack)) -eq $Expected) { return $true }
        Write-Log "Registry: write did not read back as expected (read '$readBack')." 'ERROR'
        return $false
    } catch {
        Write-Log "Registry: write failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Remove-PolicyFromRegistry {
    # Removes only the policy value and its _ProviderSet marker. Leaves the
    # Authentication key and any other values (other policies) untouched.
    # Honors -WhatIf.
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $removed = 0
    foreach ($name in @($PolicyName, $ProviderSetName)) {
        try {
            if ($null -ne (Get-RegistryValue -Path $RegPath -Name $name)) {
                if (-not $PSCmdlet.ShouldProcess($RegPath, "Remove value $name")) {
                    Write-Log "WhatIf: would remove registry value $name."
                    continue
                }
                Remove-ItemProperty -Path $RegPath -Name $name -Force -ErrorAction Stop
                Write-Log "REMOVED registry value $name"
                $removed++
            } else {
                Write-Log "OK      registry value $name already absent" 'OK'
            }
        } catch {
            Write-Log "Failed to remove registry value ${name}: $($_.Exception.Message)" 'ERROR'
        }
    }
    return $removed
}

# =============================================================================
# EFFECTIVE STATE AND SCRIPT STATE
# =============================================================================

function Get-EffectiveState {
    # WMI value wins when the property is exposed and holds a value; otherwise
    # the PolicyManager effective-value key; otherwise not set.
    $wmi = Get-WmiPolicyState
    if ($UseWmiWhenAvailable -and $wmi.PropertyExposed -and -not [string]::IsNullOrWhiteSpace($wmi.Value)) {
        return [pscustomobject]@{ Value = $wmi.Value; Source = 'wmi'; Wmi = $wmi }
    }
    $reg = Get-RegistryValue -Path $RegPath -Name $PolicyName
    if (-not [string]::IsNullOrWhiteSpace([string]$reg)) {
        return [pscustomobject]@{ Value = [string]$reg; Source = 'registry'; Wmi = $wmi }
    }
    return [pscustomobject]@{ Value = $null; Source = 'none'; Wmi = $wmi }
}

function Save-StateValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    try {
        if (-not (Test-Path -Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        New-ItemProperty -Path $StateKey -Name $Name -PropertyType String -Value $Value -Force | Out-Null
    } catch {
        Write-Log "Could not write state value ${Name}: $($_.Exception.Message)" 'WARN'
    }
}

function Get-StateValue {
    param([Parameter(Mandatory)][string]$Name)
    return Get-RegistryValue -Path $StateKey -Name $Name
}

function Format-Display {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<not set>' }
    return $Value
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-Enforce {
    param([Parameter(Mandatory)][string]$Desired, [Parameter(Mandatory)][string]$Expected)

    Write-Log "=== ENFORCE: $PolicyName ==="
    $effective = Get-EffectiveState
    Write-Log "Expected : $Expected"
    Write-Log "Current  : $(Format-Display (ConvertTo-NormalizedList -Value $effective.Value)) (source: $($effective.Source))"

    if ((ConvertTo-NormalizedList -Value $effective.Value) -eq $Expected) {
        Write-Log "OK      $PolicyName already matches (source: $($effective.Source)); nothing written." 'OK'
        if (-not (Get-StateValue -Name 'Method')) {
            Save-StateValue -Name 'Method' -Value $effective.Source
            Save-StateValue -Name 'Value'  -Value $Desired
        }
        Save-StateValue -Name 'ScriptVersion'  -Value $ScriptVersion
        Save-StateValue -Name 'LastEnforceUtc' -Value (Get-Date).ToUniversalTime().ToString('o')
        return
    }

    $wmi = $effective.Wmi
    if ($wmi.ClassAvailable) {
        Write-Log "WMI class $WmiClass present; exposes ${PolicyName}: $($wmi.PropertyExposed)"
    } elseif ($wmi.Error) {
        Write-Log "WMI class $WmiClass not available: $($wmi.Error)"
    }

    $method = 'none'
    if ($UseWmiWhenAvailable -and $wmi.PropertyExposed) {
        if (Set-PolicyViaWmi -Desired $Desired -Expected $Expected) { $method = 'wmi' }
        else { Write-Log 'Falling back to the PolicyManager registry location.' }
    } elseif ($UseWmiWhenAvailable) {
        Write-Log "$WmiClass does not expose $PolicyName on this build; using the PolicyManager registry location."
    } else {
        Write-Log 'UseWmiWhenAvailable is $false; using the PolicyManager registry location.'
    }

    if ($method -eq 'none') {
        if (Set-PolicyViaRegistry -Desired $Desired -Expected $Expected) { $method = 'registry' }
    }

    if ($method -eq 'none') {
        if ($WhatIfPreference) {
            Write-Log 'WhatIf: no changes were made.'
            return
        }
        Write-Log "FAILED  could not set $PolicyName by any method." 'ERROR'
        return
    }

    $script:DriftCount++
    Write-Log "SET     $PolicyName = $Desired (method: $method)"
    Save-StateValue -Name 'Method'         -Value $method
    Save-StateValue -Name 'Value'          -Value $Desired
    Save-StateValue -Name 'ScriptVersion'  -Value $ScriptVersion
    Save-StateValue -Name 'LastEnforceUtc' -Value (Get-Date).ToUniversalTime().ToString('o')
    Write-Log 'Sign out or reboot before testing the lock screen "I forgot my PIN" flow; the credential provider reads the list at sign-in.' 'WARN'
}

function Invoke-Audit {
    param([Parameter(Mandatory)][string]$Expected)

    Write-Log "=== AUDIT: $PolicyName ==="
    $effective = Get-EffectiveState
    $current = ConvertTo-NormalizedList -Value $effective.Value
    Write-Log "Expected : $Expected"
    Write-Log "Current  : $(Format-Display $current) (source: $($effective.Source))"
    if ($effective.Wmi.ClassAvailable -and -not $effective.Wmi.PropertyExposed) {
        Write-Log "$WmiClass does not expose $PolicyName on this build; the registry location is the effective source."
    }

    if ($current -eq $Expected) {
        Write-Log "OK      $PolicyName matches the desired list." 'OK'
        Write-Log 'Audit result: COMPLIANT'
    } else {
        if ([string]::IsNullOrWhiteSpace($current)) {
            Write-Log "DRIFT   $PolicyName is not set" 'DRIFT'
        } else {
            Write-Log "DRIFT   $PolicyName differs from the desired list" 'DRIFT'
        }
        Write-Log 'Audit result: 1 drift item found' 'WARN'
    }
}

function Invoke-Discover {
    param([Parameter(Mandatory)]$Os, [AllowEmptyString()][string]$Expected)

    Write-Log "=== DISCOVER: $PolicyName ==="
    Write-Log "OS                  : $($Os.DisplayName)"
    $join = Get-JoinState
    Write-Log "Entra joined        : $($join.EntraJoined)"
    Write-Log "Domain joined       : $($join.DomainJoined)"
    if (-not $join.EntraJoined) {
        Write-Log 'Web sign-in and lock screen PIN reset via web sign-in apply to Entra-joined devices only (Microsoft).' 'WARN'
    }

    $wmi = Get-WmiPolicyState
    Write-Log "WMI namespace       : $WmiNamespace"
    Write-Log "WMI class present   : $($wmi.ClassAvailable)"
    if ($wmi.Error) { Write-Log "WMI error           : $($wmi.Error)" }
    if ($wmi.ClassAvailable) {
        Write-Log "WMI class properties: $($wmi.Properties -join ', ')"
        Write-Log "Exposes $PolicyName : $($wmi.PropertyExposed)"
        if ($wmi.PropertyExposed) {
            Write-Log "WMI instance value  : $(Format-Display $wmi.Value)"
        }
    }

    Write-Log "Registry key        : $RegPath"
    if (Test-Path -Path $RegPath) {
        $props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
        $names = @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name } | Sort-Object)
        foreach ($name in $names) {
            Write-Log "    $name = $($props.$name)"
        }
        if ($names.Count -eq 0) { Write-Log '    (key exists, no values)' }
    } else {
        Write-Log '    (key absent)'
    }
    Write-Log "    $ProviderSetName present : $($null -ne (Get-RegistryValue -Path $RegPath -Name $ProviderSetName))"
    Write-Log "    $WinningProvName present : $($null -ne (Get-RegistryValue -Path $RegPath -Name $WinningProvName))"

    $effective = Get-EffectiveState
    Write-Log "Effective value     : $(Format-Display $effective.Value)"
    Write-Log "Effective source    : $($effective.Source)"
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        Write-Log 'Desired (normalized): <none supplied - pass -AllowedUrls to compare>'
    } else {
        Write-Log "Desired (normalized): $Expected"
        Write-Log "Matches desired     : $((ConvertTo-NormalizedList -Value $effective.Value) -eq $Expected)"
    }

    if (Test-Path -Path $StateKey) {
        Write-Log "State key           : $StateKey"
        foreach ($name in @('Method', 'Value', 'ScriptVersion', 'LastEnforceUtc')) {
            Write-Log "    $name = $(Format-Display ([string](Get-StateValue -Name $name)))"
        }
    } else {
        Write-Log "State key           : $StateKey (absent - this script has not enforced here)"
    }
}

function Invoke-Revert {
    Write-Log "=== REVERT: $PolicyName ==="
    $method = [string](Get-StateValue -Name 'Method')

    if ([string]::IsNullOrWhiteSpace($method)) {
        if ($RevertWithoutState) {
            Write-Log 'No state key found; RevertWithoutState is $true, removing the registry value and marker anyway.' 'WARN'
            $method = 'registry'
        } else {
            Write-Log 'No state key found; this script has not recorded a write on this device. Nothing removed. Set $RevertWithoutState = $true to remove the registry value regardless.' 'WARN'
            return
        }
    }

    Write-Log "Recorded write method: $method"

    if ($method -eq 'wmi') {
        $wmi = Get-WmiPolicyState
        if ($wmi.PropertyExposed) {
            if (-not (Clear-PolicyViaWmi)) {
                Write-Log 'WMI clear did not verify; continuing with the registry cleanup.' 'WARN'
            }
        } else {
            Write-Log "$WmiClass no longer exposes $PolicyName; skipping the WMI clear." 'WARN'
        }
    }

    $null = Remove-PolicyFromRegistry

    if ($WhatIfPreference) {
        Write-Log 'WhatIf: no changes were made.'
        return
    }

    $after = Get-EffectiveState
    if ([string]::IsNullOrWhiteSpace($after.Value)) {
        Write-Log "OK      $PolicyName is no longer set." 'OK'
    } else {
        Write-Log "$PolicyName still reads '$($after.Value)' from source '$($after.Source)' after revert." 'ERROR'
    }

    Remove-Item -Path $StateKey -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "REMOVED state key $StateKey"
    Write-Log 'Sign out or reboot for the lock screen credential provider to drop the list. Federated PIN reset from the lock screen will stop working again.' 'WARN'
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Set-WebSignInAllowedUrls v$ScriptVersion starting in mode: $Mode"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

$os = Get-OsBuildInfo
if ($os.Build -lt $MinimumBuild) {
    Write-Log "Unsupported OS ($($os.DisplayName)). Minimum configured build is $MinimumBuild (Windows 11 24H2, the floor Iru supports)." 'ERROR'
    exit 2
}

# Host list handling. Audit and Enforce cannot run without a list; Discover
# reports the device state with or without one; Revert never needs it.
$entries  = @()
$expected = ''
$desired  = ''
if ($Mode -ne 'Revert') {
    $entries = ConvertTo-HostArray -Value $AllowedUrls
    if ($entries.Count -eq 0) {
        if ($Mode -eq 'Discover') {
            Write-Log 'No -AllowedUrls supplied; reporting device state only.'
        } else {
            Write-Log 'No host list supplied. Pass -AllowedUrls "host1;host2" in the Library Item Command line parameters field (Iru applies it to both slots), or set the parameter default in the file. Examples are in the script header and README.' 'ERROR'
            exit 2
        }
    } else {
        $invalid = Get-InvalidHostEntry -Entries $entries
        if ($invalid.Count -gt 0) {
            Write-Log "AllowedUrls contains entries that are not bare hostnames: $($invalid -join ', '). The policy takes hostnames only (no scheme, no path)." 'ERROR'
            exit 2
        }
        $desired  = Get-DesiredValue -Entries $entries
        $expected = ConvertTo-NormalizedList -Value $desired
    }
}

switch ($Mode) {
    'Enforce'  { Invoke-Enforce -Desired $desired -Expected $expected }
    'Audit'    { Invoke-Audit -Expected $expected }
    'Discover' { Invoke-Discover -Os $os -Expected $expected }
    'Revert'   { Invoke-Revert }
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
