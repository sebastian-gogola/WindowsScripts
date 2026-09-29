<#
.SYNOPSIS
    Remediation script for the Iru Windows Custom Script Library Item: sets
    the Windows policy Authentication/ConfigureWebSignInAllowedUrls to the
    expected host list. Exit 0 = value in place, exit 1 = write failed.

.DESCRIPTION
    Paste this file into the Remediation Script field. Iru runs it only when
    Audit-WebSignInAllowedUrls.ps1 (Audit Script field) exits non-zero. Both
    take the same -AllowedUrls value from the Library Item's Command line
    parameters field, which Iru applies to both scripts. Nothing has to be
    edited at paste time.

    Write order:
      1. MDM Bridge WMI provider (root\cimv2\mdm\dmmap, class
         MDM_Policy_Config01_Authentication02). Microsoft documents this as the
         local, SYSTEM-context path into Policy CSP. Microsoft's published
         class definition does NOT list ConfigureWebSignInAllowedUrls, so the
         script checks the class at runtime and uses this tier only when the
         property is exposed on the build.
      2. PolicyManager effective-value key
         HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication
         (REG_SZ value plus REG_DWORD <name>_ProviderSet = 1). Community-
         observed: the Web sign-in component reads its effective value here.
         Not Microsoft-supported. Expected path on current builds.

    The output states which method was used. When the effective value already
    matches, nothing is written. The method and value are recorded under
    HKLM\SOFTWARE\IruScripts\WebSignInAllowedUrls for the audit report and
    for rollback (the README lists the removal commands per method).

    Validation: every entry must be a bare hostname. Anything containing a
    scheme (https://), a path (/), or whitespace is rejected before any write,
    with exit 2. The value written keeps the case given, de-duplicated and
    sorted; comparison is case-insensitive.

    Supports -WhatIf: reports what it would write and changes nothing.

.PARAMETER AllowedUrls
    Semicolon-delimited list of bare hostnames. No default: the list is
    tenant-specific and the script exits 2 without it. Supply it in the
    Library Item's Command line parameters field, for example:
        -AllowedUrls "accounts.google.com;accounts.youtube.com"

    Take the real list from the tenant's former Intune profile or from the
    redirect chain of the IdP sign-in page. Examples (placeholders, not
    recommendations):
      Google Workspace  accounts.google.com;accounts.youtube.com
                        (a field deployment also carried regional hosts such
                        as accounts.google.ca and mysignins.microsoft.com)
      Okta              yourorg.okta.com  (or the Okta custom domain)
      AD FS             adfs.contoso.com
      Microsoft's doc   accounts.contoso.com;signin.contoso.com
      Azure Government  add login.microsoftonline.us (Microsoft PIN reset doc)

.NOTES
    File     : Remediate-WebSignInAllowedUrls.ps1
    Version  : 1.1.0 (2026-09-29)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM (Iru Custom Script) or an elevated administrator shell
    PS       : Windows PowerShell 5.1 (no external modules)
    Scope    : Entra-joined devices. Web sign-in is not supported on hybrid or
               domain-joined devices (Microsoft). Does not affect OOBE or
               Autopilot sign-in. Does not configure EnablePinRecovery; see
               Manage-WindowsHelloforBusiness for that setting.

    Exit codes:
      0 = value in place (written now, or already matching)
      1 = could not set the value by any method
      2 = precondition failure (not elevated, OS below the configured minimum
          build, no host list supplied, or an entry that is not a bare hostname)

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    # No default on purpose: the list is tenant-specific. See .PARAMETER AllowedUrls.
    [AllowEmptyString()]
    [string]$AllowedUrls = ''
)

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Try the MDM Bridge WMI provider before the registry. Set $false to force the
# registry path. Keep identical to the audit script.
$UseWmiWhenAvailable = $true

# Minimum Windows build. 26100 = Windows 11 24H2, the floor Iru supports. The
# policy itself exists since Windows 10 1803; lower this only for lab use.
$MinimumBuild = 26100

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Remediate-WebSignInAllowedUrls.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '1.1.0'
$PolicyName    = 'ConfigureWebSignInAllowedUrls'
$StateKey      = 'HKLM:\SOFTWARE\IruScripts\WebSignInAllowedUrls'

# MDM Bridge WMI provider (Microsoft-documented namespace, class and keys)
$WmiNamespace  = 'root\cimv2\mdm\dmmap'
$WmiClass      = 'MDM_Policy_Config01_Authentication02'
$WmiParentId   = './Vendor/MSFT/Policy/Config'
$WmiInstanceId = 'Authentication'
$WmiFilter     = "ParentID='$WmiParentId' and InstanceID='$WmiInstanceId'"

# PolicyManager effective-value location (community-observed)
$RegPath         = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication'
$ProviderSetName = "${PolicyName}_ProviderSet"

$script:FailureCount = 0

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
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
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
    # Comparison form: lower-case, unique, sorted, ';' joined.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $items = @(ConvertTo-HostArray -Value $Value | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    return ($items -join ';')
}

function Get-InvalidHostEntry {
    # The policy takes hostnames. Returns every entry carrying a scheme, a
    # path, or whitespace.
    param([string[]]$Entries)
    return @($Entries | Where-Object { $_ -match '^[a-z]+://' -or $_ -match '/' -or $_ -match '\s' })
}

# =============================================================================
# READ TIERS
# =============================================================================

function Get-WmiPolicyState {
    $state = [pscustomobject]@{
        ClassAvailable  = $false
        PropertyExposed = $false
        Value           = $null
        Error           = $null
    }
    try {
        $cls = Get-CimClass -Namespace $WmiNamespace -ClassName $WmiClass -ErrorAction Stop
        $state.ClassAvailable = $true
        $state.PropertyExposed = (@($cls.CimClassProperties | ForEach-Object { $_.Name }) -contains $PolicyName)
        if ($state.PropertyExposed) {
            $inst = Get-CimInstance -Namespace $WmiNamespace -ClassName $WmiClass -Filter $WmiFilter -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($inst) {
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

function Get-RegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -Path $Path)) { return $null }
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

function Get-EffectiveState {
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

function Format-Display {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<not set>' }
    return $Value
}

# =============================================================================
# WRITE TIERS
# =============================================================================

function Set-PolicyViaWmi {
    # Creates or modifies the Authentication policy instance. Returns $true only
    # when the value reads back as expected. Honors -WhatIf.
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

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Remediate-WebSignInAllowedUrls v$ScriptVersion starting"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

$os = Get-OsBuildInfo
if ($os.Build -lt $MinimumBuild) {
    Write-Log "Unsupported OS ($($os.DisplayName)). Minimum configured build is $MinimumBuild (Windows 11 24H2, the floor Iru supports)." 'ERROR'
    exit 2
}

$entries = ConvertTo-HostArray -Value $AllowedUrls
if ($entries.Count -eq 0) {
    Write-Log 'No host list supplied. Put -AllowedUrls "host1;host2" in the Library Item Command line parameters field (Iru applies it to both the audit and the remediation script). Examples are in the script header and README.' 'ERROR'
    exit 2
}
$invalid = Get-InvalidHostEntry -Entries $entries
if ($invalid.Count -gt 0) {
    Write-Log "AllowedUrls contains entries that are not bare hostnames: $($invalid -join ', '). The policy takes hostnames only (no scheme, no path)." 'ERROR'
    exit 2
}
# The value written: entries as given, de-duplicated and sorted.
$desired  = (@($entries | Sort-Object -Unique) -join ';')
$expected = ConvertTo-NormalizedList -Value $desired

$effective = Get-EffectiveState
Write-Log "OS       : $($os.DisplayName)"
Write-Log "Expected : $expected"
Write-Log "Current  : $(Format-Display (ConvertTo-NormalizedList -Value $effective.Value)) (source: $($effective.Source))"

if ((ConvertTo-NormalizedList -Value $effective.Value) -eq $expected) {
    Write-Log "OK      $PolicyName already matches (source: $($effective.Source)); nothing written." 'OK'
    if (-not $WhatIfPreference) {
        if ($null -eq (Get-RegistryValue -Path $StateKey -Name 'Method')) {
            Save-StateValue -Name 'Method' -Value $effective.Source
            Save-StateValue -Name 'Value'  -Value $desired
        }
        Save-StateValue -Name 'ScriptVersion'  -Value $ScriptVersion
        Save-StateValue -Name 'LastEnforceUtc' -Value (Get-Date).ToUniversalTime().ToString('o')
    }
    exit 0
}

$wmi = $effective.Wmi
if ($wmi.ClassAvailable) {
    Write-Log "WMI class $WmiClass present; exposes ${PolicyName}: $($wmi.PropertyExposed)"
} elseif ($wmi.Error) {
    Write-Log "WMI class $WmiClass not available: $($wmi.Error)"
}

$method = 'none'
if ($UseWmiWhenAvailable -and $wmi.PropertyExposed) {
    if (Set-PolicyViaWmi -Desired $desired -Expected $expected) { $method = 'wmi' }
    elseif (-not $WhatIfPreference) { Write-Log 'Falling back to the PolicyManager registry location.' }
} elseif ($UseWmiWhenAvailable) {
    Write-Log "$WmiClass does not expose $PolicyName on this build; using the PolicyManager registry location."
} else {
    Write-Log 'UseWmiWhenAvailable is $false; using the PolicyManager registry location.'
}

if ($method -eq 'none') {
    if (Set-PolicyViaRegistry -Desired $desired -Expected $expected) { $method = 'registry' }
}

if ($method -eq 'none') {
    if ($WhatIfPreference) {
        Write-Log 'WhatIf: no changes were made.'
        exit 0
    }
    Write-Log "FAILED  could not set $PolicyName by any method." 'ERROR'
    exit 1
}

Write-Log "REMEDIATED $PolicyName = $desired (method: $method)" 'OK'
Save-StateValue -Name 'Method'         -Value $method
Save-StateValue -Name 'Value'          -Value $desired
Save-StateValue -Name 'ScriptVersion'  -Value $ScriptVersion
Save-StateValue -Name 'LastEnforceUtc' -Value (Get-Date).ToUniversalTime().ToString('o')
Write-Log 'Sign out or reboot before testing the lock screen "I forgot my PIN" flow; the credential provider reads the list at sign-in.' 'WARN'

if ($script:FailureCount -gt 0) {
    Write-Log "Completed with $($script:FailureCount) error(s)." 'WARN'
    exit 1
}
exit 0
