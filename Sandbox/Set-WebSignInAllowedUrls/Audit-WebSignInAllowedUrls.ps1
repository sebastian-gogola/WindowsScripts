<#
.SYNOPSIS
    Audit script for the Iru Windows Custom Script Library Item: reports
    whether the Windows policy Authentication/ConfigureWebSignInAllowedUrls
    matches the expected host list. Exit 0 = compliant, exit 1 = drift.

.DESCRIPTION
    Paste this file into the Audit Script field. Its companion,
    Remediate-WebSignInAllowedUrls.ps1, goes into the Remediation Script field
    and runs only when this script exits non-zero. Both take the same
    -AllowedUrls value from the Library Item's Command line parameters field,
    which Iru applies to both scripts. Nothing has to be edited at paste time.

    The policy restores the lock screen "I forgot my PIN" and Web sign-in
    flows on Entra-joined devices federated to a third-party identity
    provider: the lock screen web view only navigates to hosts on this list.
    It is a Policy CSP node with no ADMX equivalent, and Iru has no OMA-URI
    Library Item for Windows, hence the script pair.

    Read order for the effective value:
      1. MDM Bridge WMI provider (root\cimv2\mdm\dmmap, class
         MDM_Policy_Config01_Authentication02), only when the class on this
         build exposes the property. Microsoft's published class definition
         does not list it, so on current builds this tier is usually skipped.
      2. PolicyManager effective-value key
         HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Authentication
         (community-observed location the Web sign-in component reads).

    Comparison: both lists are split on ';', trimmed, lower-cased,
    de-duplicated and sorted, so order and case on the device never count as
    drift. Every expected entry must be a bare hostname (no scheme, no path,
    no whitespace) or the script exits 2 without comparing.

    The output doubles as a discovery report: OS build, join state, whether
    the WMI class exposes the property, the registry key contents including
    the _ProviderSet and _WinningProvider markers, the effective value and its
    source, and the remediation script's state key. This script never writes.

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
    File     : Audit-WebSignInAllowedUrls.ps1
    Version  : 1.1.0 (2026-09-29)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM (Iru Custom Script) or an elevated administrator shell
    PS       : Windows PowerShell 5.1 (no external modules)
    Scope    : Entra-joined devices. Web sign-in is not supported on hybrid or
               domain-joined devices (Microsoft). Does not affect OOBE or
               Autopilot sign-in. Does not evaluate EnablePinRecovery; see
               Manage-WindowsHelloforBusiness for that setting.

    Exit codes:
      0 = compliant
      1 = drift (value missing or different)
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

[CmdletBinding()]
param(
    # No default on purpose: the list is tenant-specific. See .PARAMETER AllowedUrls.
    [AllowEmptyString()]
    [string]$AllowedUrls = ''
)

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Read the MDM Bridge WMI provider before the registry. Set $false to read the
# registry location only. Keep identical to the remediation script.
$UseWmiWhenAvailable = $true

# Minimum Windows build. 26100 = Windows 11 24H2, the floor Iru supports. The
# policy itself exists since Windows 10 1803; lower this only for lab use.
$MinimumBuild = 26100

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Audit-WebSignInAllowedUrls.log'

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
$WinningProvName = "${PolicyName}_WinningProvider"

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

function Format-Display {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<not set>' }
    return $Value
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Audit-WebSignInAllowedUrls v$ScriptVersion starting"

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
$expected = ConvertTo-NormalizedList -Value ($entries -join ';')

# --- Discovery report (read-only) --------------------------------------------
Write-Log "OS                  : $($os.DisplayName)"
$join = Get-JoinState
Write-Log "Entra joined        : $($join.EntraJoined)"
Write-Log "Domain joined       : $($join.DomainJoined)"
if (-not $join.EntraJoined) {
    Write-Log 'Web sign-in and lock screen PIN reset via web sign-in apply to Entra-joined devices only (Microsoft).' 'WARN'
}

$effective = Get-EffectiveState
$wmi = $effective.Wmi
Write-Log "WMI class present   : $($wmi.ClassAvailable)"
if ($wmi.Error) { Write-Log "WMI error           : $($wmi.Error)" }
if ($wmi.ClassAvailable) {
    Write-Log "WMI class properties: $($wmi.Properties -join ', ')"
    Write-Log "Exposes $PolicyName : $($wmi.PropertyExposed)"
    if (-not $wmi.PropertyExposed) {
        Write-Log 'Property not exposed on this build; the registry location is the effective source.'
    }
}

Write-Log "Registry key        : $RegPath"
if (Test-Path -Path $RegPath) {
    $props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    $names = @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name } | Sort-Object)
    foreach ($name in $names) { Write-Log "    $name = $($props.$name)" }
    if ($names.Count -eq 0) { Write-Log '    (key exists, no values)' }
} else {
    Write-Log '    (key absent)'
}
Write-Log "    $ProviderSetName present : $($null -ne (Get-RegistryValue -Path $RegPath -Name $ProviderSetName))"
Write-Log "    $WinningProvName present : $($null -ne (Get-RegistryValue -Path $RegPath -Name $WinningProvName))"

if (Test-Path -Path $StateKey) {
    $st = Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue
    Write-Log ("State key           : Method={0} Value={1} Version={2} LastEnforceUtc={3}" -f (Format-Display ([string]$st.Method)), (Format-Display ([string]$st.Value)), (Format-Display ([string]$st.ScriptVersion)), (Format-Display ([string]$st.LastEnforceUtc)))
} else {
    Write-Log "State key           : $StateKey (absent - remediation has not run here)"
}

# --- Comparison ----------------------------------------------------------------
$current = ConvertTo-NormalizedList -Value $effective.Value
Write-Log "Expected : $expected"
Write-Log "Current  : $(Format-Display $current) (source: $($effective.Source))"

if ($script:FailureCount -gt 0) {
    Write-Log "Completed with $($script:FailureCount) error(s)." 'WARN'
    exit 1
}

if ($current -eq $expected) {
    Write-Log "PASS    $PolicyName matches the expected list." 'OK'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($current)) {
    Write-Log "DRIFT   $PolicyName is not set" 'DRIFT'
} else {
    Write-Log "DRIFT   $PolicyName differs from the expected list" 'DRIFT'
}
exit 1
