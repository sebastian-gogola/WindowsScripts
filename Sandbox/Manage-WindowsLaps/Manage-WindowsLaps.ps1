<#
.SYNOPSIS
    Enables and manages Windows LAPS (Local Administrator Password Solution) on
    Iru-managed Windows endpoints by configuring the LAPS CSP policy store, so
    Entra-joined devices back up their local administrator password to Microsoft
    Entra ID without Intune.

.DESCRIPTION
    Windows LAPS is configured through the LAPS CSP
    (./Device/Vendor/MSFT/LAPS/Policies/...). Only the MDM that owns the device's
    MDM enrollment can push OMA-URI nodes, so a third-party MDM script cannot
    literally issue a SyncML Add against those nodes. It does not need to:
    Microsoft assigns each LAPS policy mechanism its own registry root, and the
    root that belongs to the LAPS CSP is

        HKLM\SOFTWARE\Microsoft\Policies\LAPS

    Windows LAPS evaluates that root first, ahead of the LAPS GPO root, the
    local-configuration root, and legacy Microsoft LAPS. Writing the CSP root
    from a SYSTEM-context script therefore produces the same policy state an
    Intune LAPS profile produces, and Windows reports "Policy source: CSP" in
    the 10022 policy event. Microsoft documents this path explicitly for
    Entra-joined devices that are not managed by Intune ("you must deploy policy
    manually (for example, either by using direct registry modification or by
    using Local Computer Group Policy)").

    Once BackupDirectory is set, Windows LAPS itself owns the whole lifecycle -
    generating the password, rotating it on schedule, backing it up to Entra ID
    over HTTPS with the device identity, and blocking anyone else from changing
    the managed account's password. The password is retrieved from the Entra
    admin center, Microsoft Graph, or Get-LapsAADPassword. Nothing about that
    path routes through Iru.

    Settings map 1:1 onto the CSP node names. Each setting has three states:
      <value>  = enforced (value written to the policy root)
      $null    = Not Configured (value REMOVED if present, like un-targeting in
                 Intune). Windows then applies that setting's documented default.

    Modes:
      Enforce  - writes the configured policy, then triggers immediate policy
                 processing and reports the resulting LAPS events
      Audit    - reports drift from the configured policy, changes nothing
      Discover - reports OS/LAPS capability, join state, every populated LAPS
                 policy root, effective values, and recent LAPS events
      Revert   - removes only the values this script wrote, then the policy key
                 if it is left empty, then the script's own state key

    Designed for deployment as an Iru Windows Custom Script Library Item running
    as NT AUTHORITY\SYSTEM. Pair the same script in the Audit slot
    ($Mode = 'Audit') and Remediation slot ($Mode = 'Enforce').

.NOTES
    File     : Manage-WindowsLaps.ps1
    Version  : 1.0.0 (2026-09-08)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM or local Administrator (elevation required)
    PS       : Windows PowerShell 5.1 (no external modules)

    Exit codes:
      0 = success / compliant
      1 = drift detected (Audit) or a runtime failure during Enforce/Revert
      2 = precondition failure (not elevated, OS lacks Windows LAPS, invalid
          configuration, or join state incompatible with BackupDirectory)

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

#Requires -Version 5.1

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Mode: 'Enforce' | 'Audit' | 'Discover' | 'Revert'
$Mode = 'Enforce'

# Which LAPS policy root to write.
#   'CSP'         - HKLM\SOFTWARE\Microsoft\Policies\LAPS
#                   The LAPS CSP's own root and the highest-precedence root.
#                   Use this unless something else already owns it.
#   'LocalConfig' - HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config
#                   Microsoft's testing/development root. Lowest precedence, so
#                   a LAPS GPO would win over it. Use only for lab validation.
$PolicyRoot = 'CSP'

# --- Core settings (apply to both Entra ID and Active Directory backup) ------

# Where the password is backed up.
#   0 = Disabled (no backup)   1 = Microsoft Entra ID only   2 = Active Directory only
# 1 requires the device to be Entra joined; 2 requires AD domain join.
$BackupDirectory = 1

# Name of the managed local administrator account.
# $null   = manage the built-in administrator account, located by its well-known
#           RID (correct even where the account has been renamed or localized).
# 'Name'  = manage that account instead. Windows LAPS does NOT create it - it
#           must already exist (see ../CreateLocalAdmin/).
$AdministratorAccountName = $null

# Maximum password age in days. Range 1-365, but the minimum is 7 when backing
# up to Entra ID. Windows default: 30.
$PasswordAgeDays = 30

# Password composition.
#   1 = large letters
#   2 = large + small letters
#   3 = large + small letters + numbers
#   4 = large + small + numbers + special characters   (Microsoft recommends 4)
#   5 = as 4, improved readability          | Windows 11 24H2 / Server 2025+
#   6 = passphrase (long words)             | Windows 11 24H2 / Server 2025+
#   7 = passphrase (short words)            | Windows 11 24H2 / Server 2025+
#   8 = passphrase (short words, unique prefixes) | Windows 11 24H2 / Server 2025+
$PasswordComplexity = 4

# Password length in characters. Range 8-64. Ignored when $PasswordComplexity
# selects a passphrase (6-8). Windows default: 14.
# Keep this compatible with the device's local password policy or LAPS logs a
# 10027 event and no password is generated.
$PasswordLength = 20

# Number of words in the passphrase. Range 3-10. Only used when
# $PasswordComplexity is 6, 7, or 8. Windows 11 24H2 / Server 2025+.
$PassphraseLength = $null

# Hours to wait after the managed account authenticates before running the
# post-authentication actions. Range 0-24; 0 disables post-authentication
# actions entirely. Windows default: 24.
$PostAuthenticationResetDelay = 8

# What happens when that grace period expires.
#   1  = reset the password
#   3  = reset the password and sign the managed account out   (Windows default)
#   5  = reset the password and reboot the device
#   11 = reset, sign out, and terminate remaining processes | 24H2 / Server 2025+
$PostAuthenticationActions = 3

# --- Active Directory only (ignored when $BackupDirectory = 1) ---------------

# Enforce the maximum password age against the stored expiration timestamp.
# 1 = enabled, 0 = disabled. Windows default: 1.
$PasswordExpirationProtectionEnabled = $null

# Encrypt the password before storing it in AD. Requires domain functional
# level 2016 or higher. 1 = enabled, 0 = disabled. Windows default: 1.
$ADPasswordEncryptionEnabled = $null

# User or group allowed to decrypt the AD-stored password. SID string or fully
# qualified name ('contoso\LAPSAdmins', 'lapsadmins@contoso.com'). No quotes or
# parentheses. Defaults to the device domain's Domain Admins when unset.
$ADPasswordEncryptionPrincipal = $null

# How many previous encrypted passwords AD keeps. Range 0-12. Windows default: 0.
$ADEncryptedPasswordHistorySize = $null

# --- Automatic account management (Windows 11 24H2 / Server 2025 and later) --
# When enabled, Windows LAPS creates and owns the managed account itself and
# $AdministratorAccountName is ignored.

# 1 = enable automatic account management, 0 = disable. Windows default: 0.
$AutomaticAccountManagementEnabled = $null

# 0 = manage the built-in Administrator account
# 1 = manage a new account created by Windows LAPS   (Windows default)
$AutomaticAccountManagementTarget = $null

# Name (or name prefix when randomizing) of the automatically managed account.
# Windows default: 'WLapsAdmin'. Max 20 characters, or 14 when randomizing.
$AutomaticAccountManagementNameOrPrefix = $null

# 1 = the automatically managed account is enabled, 0 = disabled.
# Windows default: 0.
$AutomaticAccountManagementEnableAccount = $null

# 1 = append a random six-digit suffix to the account name on every rotation.
# Windows default: 0.
$AutomaticAccountManagementRandomizeName = $null

# --- Behavior ---------------------------------------------------------------

# After writing policy in Enforce mode, run Invoke-LapsPolicyProcessing so the
# policy takes effect immediately instead of at the next hourly LAPS cycle.
$ApplyPolicyImmediately = $true

# Seconds to wait after policy processing before reading the LAPS event log for
# the outcome. 0 skips the check.
$VerifyBackupSeconds = 45

# Force an immediate password rotation on every Enforce run (Reset-LapsPassword).
# Leave $false: LAPS backs up a password on its own as soon as the policy lands,
# and Microsoft warns that frequent Reset-LapsPassword calls may be throttled.
# Use a one-off run with this set to $true for incident response instead.
$RotateNow = $false

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Manage-WindowsLaps.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '1.0.0'
$StateKey      = 'HKLM:\SOFTWARE\IruScripts\WindowsLaps'
$LapsLogName   = 'Microsoft-Windows-LAPS/Operational'

# Every LAPS policy root, in the precedence order Windows evaluates them.
# The first root holding at least one value becomes the active policy; the
# others are ignored entirely, and settings missing from the winning root take
# their Windows defaults rather than being inherited from a lower root.
$PolicyRootPaths = [ordered]@{
    'CSP'         = 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS'
    'GPO'         = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS'
    'LocalConfig' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config'
    'LegacyLaps'  = 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd'
}

# Minimum update revision (UBR) per servicing build that carries Windows LAPS.
# Builds above the highest entry always include it.
$LapsMinimumUbr = @{
    17763 = 4244   # Windows 10 1809
    19041 = 2784   # Windows 10 2004 servicing family (19041-19045)
    19042 = 2784
    19043 = 2784
    19044 = 2784
    19045 = 2784
    20348 = 1663   # Windows Server 2022
    22000 = 1754   # Windows 11 21H2
    22621 = 1480   # Windows 11 22H2
}
$LapsAlwaysSupportedBuild = 22631   # 23H2 and later shipped with LAPS in-box
$Build24H2                = 26100   # gate for the newer settings and values

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
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    $build = 0
    $ubr   = 0
    if ($props) {
        if ($props.CurrentBuildNumber) { $build = [int]$props.CurrentBuildNumber }
        if ($null -ne $props.UBR)      { $ubr   = [int]$props.UBR }
    }
    [pscustomobject]@{
        Build       = $build
        Ubr         = $ubr
        DisplayName = "$($props.ProductName) $($props.DisplayVersion) ($build.$ubr)"
        Is24H2Plus  = ($build -ge $Build24H2)
    }
}

function Test-LapsCapable {
    param([Parameter(Mandatory)]$Os)
    if ($Os.Build -ge $LapsAlwaysSupportedBuild) { return $true }
    if ($LapsMinimumUbr.ContainsKey($Os.Build)) {
        return ($Os.Ubr -ge $LapsMinimumUbr[$Os.Build])
    }
    return $false
}

function Get-JoinState {
    # Win32_ComputerSystem carries the AD domain membership; dsregcmd carries the
    # Entra device state. Both are needed to validate BackupDirectory.
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
# SETTINGS TABLE
# =============================================================================

function Get-SettingDefinitions {
    # Type maps the CSP node format onto the registry: int/bool -> REG_DWORD,
    # chr -> REG_SZ. MinBuild gates settings that only newer releases parse.
    @(
        [pscustomobject]@{ Name='BackupDirectory';                        Type='DWord';  Data=$BackupDirectory;                        Allowed=@(0,1,2);     Min=$null; Max=$null; MinBuild=0;          AdOnly=$false }
        [pscustomobject]@{ Name='AdministratorAccountName';               Type='String'; Data=$AdministratorAccountName;               Allowed=$null;        Min=$null; Max=$null; MinBuild=0;          AdOnly=$false }
        [pscustomobject]@{ Name='PasswordAgeDays';                        Type='DWord';  Data=$PasswordAgeDays;                        Allowed=$null;        Min=1;     Max=365;   MinBuild=0;          AdOnly=$false }
        [pscustomobject]@{ Name='PasswordComplexity';                     Type='DWord';  Data=$PasswordComplexity;                     Allowed=@(1,2,3,4,5,6,7,8); Min=$null; Max=$null; MinBuild=0;  AdOnly=$false }
        [pscustomobject]@{ Name='PasswordLength';                         Type='DWord';  Data=$PasswordLength;                         Allowed=$null;        Min=8;     Max=64;    MinBuild=0;          AdOnly=$false }
        [pscustomobject]@{ Name='PassphraseLength';                       Type='DWord';  Data=$PassphraseLength;                       Allowed=$null;        Min=3;     Max=10;    MinBuild=$Build24H2; AdOnly=$false }
        [pscustomobject]@{ Name='PostAuthenticationResetDelay';           Type='DWord';  Data=$PostAuthenticationResetDelay;           Allowed=$null;        Min=0;     Max=24;    MinBuild=0;          AdOnly=$false }
        [pscustomobject]@{ Name='PostAuthenticationActions';              Type='DWord';  Data=$PostAuthenticationActions;              Allowed=@(1,3,5,11);  Min=$null; Max=$null; MinBuild=0;          AdOnly=$false }
        [pscustomobject]@{ Name='PasswordExpirationProtectionEnabled';    Type='DWord';  Data=$PasswordExpirationProtectionEnabled;    Allowed=@(0,1);       Min=$null; Max=$null; MinBuild=0;          AdOnly=$true  }
        [pscustomobject]@{ Name='ADPasswordEncryptionEnabled';            Type='DWord';  Data=$ADPasswordEncryptionEnabled;            Allowed=@(0,1);       Min=$null; Max=$null; MinBuild=0;          AdOnly=$true  }
        [pscustomobject]@{ Name='ADPasswordEncryptionPrincipal';          Type='String'; Data=$ADPasswordEncryptionPrincipal;          Allowed=$null;        Min=$null; Max=$null; MinBuild=0;          AdOnly=$true  }
        [pscustomobject]@{ Name='ADEncryptedPasswordHistorySize';         Type='DWord';  Data=$ADEncryptedPasswordHistorySize;         Allowed=$null;        Min=0;     Max=12;    MinBuild=0;          AdOnly=$true  }
        [pscustomobject]@{ Name='AutomaticAccountManagementEnabled';      Type='DWord';  Data=$AutomaticAccountManagementEnabled;      Allowed=@(0,1);       Min=$null; Max=$null; MinBuild=$Build24H2; AdOnly=$false }
        [pscustomobject]@{ Name='AutomaticAccountManagementTarget';       Type='DWord';  Data=$AutomaticAccountManagementTarget;       Allowed=@(0,1);       Min=$null; Max=$null; MinBuild=$Build24H2; AdOnly=$false }
        [pscustomobject]@{ Name='AutomaticAccountManagementNameOrPrefix'; Type='String'; Data=$AutomaticAccountManagementNameOrPrefix; Allowed=$null;        Min=$null; Max=$null; MinBuild=$Build24H2; AdOnly=$false }
        [pscustomobject]@{ Name='AutomaticAccountManagementEnableAccount';Type='DWord';  Data=$AutomaticAccountManagementEnableAccount;Allowed=@(0,1);       Min=$null; Max=$null; MinBuild=$Build24H2; AdOnly=$false }
        [pscustomobject]@{ Name='AutomaticAccountManagementRandomizeName';Type='DWord';  Data=$AutomaticAccountManagementRandomizeName;Allowed=@(0,1);       Min=$null; Max=$null; MinBuild=$Build24H2; AdOnly=$false }
    )
}

function Test-Configuration {
    # Validates the config block against the documented ranges and the running
    # OS. Returns $true when the configuration is safe to write. Anything that
    # would silently produce a policy Windows cannot honor is an error (exit 2);
    # anything Windows simply ignores is a warning.
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Os,
        [Parameter(Mandatory)]$Join
    )
    $ok = $true

    foreach ($s in $Settings) {
        if ($null -eq $s.Data) { continue }

        if ($s.MinBuild -gt 0 -and $Os.Build -lt $s.MinBuild) {
            Write-Log "$($s.Name) requires build $($s.MinBuild) or later; this device is $($Os.Build). Leave it `$null on this OS." 'ERROR'
            $ok = $false
            continue
        }
        if ($s.Type -eq 'String') {
            if ([string]::IsNullOrWhiteSpace([string]$s.Data)) {
                Write-Log "$($s.Name) is set to an empty string. Use `$null for Not Configured." 'ERROR'
                $ok = $false
            }
            continue
        }
        [int]$value = 0
        if (-not [int]::TryParse([string]$s.Data, [ref]$value)) {
            Write-Log "$($s.Name) must be a number, got '$($s.Data)'." 'ERROR'
            $ok = $false
            continue
        }
        if ($null -ne $s.Allowed -and $s.Allowed -notcontains $value) {
            Write-Log "$($s.Name) = $value is not one of the allowed values ($($s.Allowed -join ', '))." 'ERROR'
            $ok = $false
        }
        if ($null -ne $s.Min -and $value -lt $s.Min) {
            Write-Log "$($s.Name) = $value is below the minimum of $($s.Min)." 'ERROR'
            $ok = $false
        }
        if ($null -ne $s.Max -and $value -gt $s.Max) {
            Write-Log "$($s.Name) = $value is above the maximum of $($s.Max)." 'ERROR'
            $ok = $false
        }
    }

    # --- Cross-setting rules --------------------------------------------------

    if ($null -eq $BackupDirectory) {
        Write-Log 'BackupDirectory is Not Configured. Windows defaults it to 0 (Disabled) and every other LAPS setting is ignored. Set it to 1 (Entra ID) or 2 (Active Directory).' 'ERROR'
        $ok = $false
    }
    elseif ($BackupDirectory -eq 0) {
        Write-Log 'BackupDirectory = 0 (Disabled). No password will be backed up; all other settings are ignored.' 'WARN'
    }
    elseif ($BackupDirectory -eq 1) {
        if (-not $Join.EntraJoined) {
            Write-Log 'BackupDirectory = 1 backs the password up to Microsoft Entra ID, but this device is not Entra joined (dsregcmd reports AzureAdJoined : NO). Entra-registered/workplace-joined devices do not qualify.' 'ERROR'
            $ok = $false
        }
        if ($null -ne $PasswordAgeDays -and $PasswordAgeDays -lt 7) {
            Write-Log "PasswordAgeDays = $PasswordAgeDays is below the minimum of 7 days that applies when backing up to Entra ID." 'ERROR'
            $ok = $false
        }
        foreach ($s in $Settings) {
            if ($s.AdOnly -and $null -ne $s.Data) {
                Write-Log "$($s.Name) only applies when backing up to Active Directory and will be ignored with BackupDirectory = 1." 'WARN'
            }
        }
    }
    elseif ($BackupDirectory -eq 2) {
        if (-not $Join.DomainJoined) {
            Write-Log 'BackupDirectory = 2 backs the password up to Active Directory, but this device is not domain joined.' 'ERROR'
            $ok = $false
        }
    }

    if ($null -ne $PasswordComplexity) {
        if ($PasswordComplexity -ge 5 -and -not $Os.Is24H2Plus) {
            Write-Log "PasswordComplexity = $PasswordComplexity requires Windows 11 24H2 / Server 2025 (build $Build24H2) or later; this device is $($Os.Build) and would silently fall back to the default of 4." 'ERROR'
            $ok = $false
        }
        if ($PasswordComplexity -ge 6) {
            if ($null -ne $PasswordLength) {
                Write-Log 'PasswordComplexity selects a passphrase (6-8), so PasswordLength is ignored. Configure PassphraseLength instead.' 'WARN'
            }
        }
        elseif ($null -ne $PassphraseLength) {
            Write-Log 'PassphraseLength is ignored unless PasswordComplexity is 6, 7, or 8.' 'WARN'
        }
    }

    if ($null -ne $PostAuthenticationActions -and $PostAuthenticationActions -eq 11 -and -not $Os.Is24H2Plus) {
        Write-Log "PostAuthenticationActions = 11 requires Windows 11 24H2 / Server 2025 (build $Build24H2) or later; this device is $($Os.Build)." 'ERROR'
        $ok = $false
    }
    if ($null -ne $PostAuthenticationResetDelay -and $PostAuthenticationResetDelay -eq 0) {
        Write-Log 'PostAuthenticationResetDelay = 0 disables all post-authentication actions - the password will not be rotated after the managed account is used.' 'WARN'
    }

    if ($null -ne $AdministratorAccountName) {
        if ($AdministratorAccountName.Length -gt 20) {
            Write-Log "AdministratorAccountName '$AdministratorAccountName' exceeds the 20 character limit for Windows local account names." 'ERROR'
            $ok = $false
        }
        if (-not (Test-LocalAccountExists -Name $AdministratorAccountName)) {
            Write-Log "AdministratorAccountName '$AdministratorAccountName' does not exist on this device. Windows LAPS does not create accounts - create it first (see ../CreateLocalAdmin/) or leave the setting `$null to manage the built-in administrator." 'ERROR'
            $ok = $false
        }
        if ($null -ne $AutomaticAccountManagementEnabled -and $AutomaticAccountManagementEnabled -eq 1) {
            Write-Log 'AdministratorAccountName is ignored while AutomaticAccountManagementEnabled = 1 - Windows LAPS manages its own account instead.' 'WARN'
        }
    }

    if ($null -ne $AutomaticAccountManagementNameOrPrefix) {
        $limit = 20
        if ($null -ne $AutomaticAccountManagementRandomizeName -and $AutomaticAccountManagementRandomizeName -eq 1) { $limit = 14 }
        if ($AutomaticAccountManagementNameOrPrefix.Length -gt $limit) {
            Write-Log "AutomaticAccountManagementNameOrPrefix '$AutomaticAccountManagementNameOrPrefix' exceeds $limit characters and would be truncated by Windows." 'WARN'
        }
    }

    return $ok
}

function Test-LocalAccountExists {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $accounts = Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount = TRUE' -ErrorAction Stop
        return ($null -ne ($accounts | Where-Object { $_.Name -ieq $Name }))
    } catch {
        Write-Log "Could not enumerate local accounts to validate '$Name': $($_.Exception.Message)" 'WARN'
        return $true   # do not block enforcement on a WMI hiccup
    }
}

# =============================================================================
# POLICY REGISTRY
# =============================================================================

function Get-PolicyValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -Path $Path)) { return $null }
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

function Get-PopulatedRoots {
    # Returns every LAPS policy root that currently holds at least one of the
    # known LAPS value names, in precedence order.
    param([Parameter(Mandatory)]$Settings)
    $known = @($Settings | ForEach-Object { $_.Name })
    $result = @()
    foreach ($rootName in $PolicyRootPaths.Keys) {
        $path = $PolicyRootPaths[$rootName]
        if (-not (Test-Path -Path $path)) { continue }
        $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        $names = @($props.PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            ForEach-Object { $_.Name })
        # Legacy LAPS uses its own value names, so count any value under that root.
        if ($rootName -ne 'LegacyLaps') {
            $names = @($names | Where-Object { $known -contains $_ })
        }
        if ($names.Count -gt 0) {
            $result += [pscustomobject]@{ Root = $rootName; Path = $path; Values = $names }
        }
    }
    return $result
}

function Write-CompetingRootWarnings {
    param([Parameter(Mandatory)]$Settings)
    foreach ($root in (Get-PopulatedRoots -Settings $Settings)) {
        if ($root.Root -eq $PolicyRoot) { continue }
        $order = @($PolicyRootPaths.Keys)
        if ([array]::IndexOf($order, $root.Root) -lt [array]::IndexOf($order, $PolicyRoot)) {
            Write-Log "The higher-precedence $($root.Root) root ($($root.Path)) holds $($root.Values.Count) value(s) and will WIN over the $PolicyRoot root this script writes. Clear it or switch `$PolicyRoot." 'WARN'
        } else {
            Write-Log "The $($root.Root) root ($($root.Path)) holds $($root.Values.Count) value(s). Writing the $PolicyRoot root makes Windows ignore it completely - those settings will not be inherited, they revert to Windows defaults." 'WARN'
        }
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

function Get-ManagedValueNames {
    # The value names this script has written, so Revert only removes its own.
    if (-not (Test-Path -Path $StateKey)) { return @() }
    $props = Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue
    if ($null -eq $props -or [string]::IsNullOrWhiteSpace($props.ManagedValues)) { return @() }
    return @($props.ManagedValues -split ',' | Where-Object { $_ -ne '' })
}

function Invoke-Setting {
    # Applies (Enforce) or reports (Audit) one setting. $null desired data means
    # Not Configured, which removes the value so Windows falls back to default.
    param([Parameter(Mandatory)]$Setting, [Parameter(Mandatory)][string]$Path, [switch]$AuditOnly)

    $current = Get-PolicyValue -Path $Path -Name $Setting.Name
    $desired = $Setting.Data

    if ($null -eq $desired) {
        if ($null -ne $current) {
            if ($AuditOnly) {
                Write-Log "DRIFT   $($Setting.Name) is present ($current), expected Not Configured" 'DRIFT'
            } else {
                Remove-ItemProperty -Path $Path -Name $Setting.Name -Force -ErrorAction Stop
                Write-Log "REMOVED $($Setting.Name) (was $current)"
                $script:DriftCount++
            }
        } else {
            Write-Log "OK      $($Setting.Name) Not Configured" 'OK'
        }
        return
    }

    if ("$current" -ceq "$desired") {
        Write-Log "OK      $($Setting.Name) = $desired" 'OK'
        return
    }

    $was = '<absent>'
    if ($null -ne $current) { $was = "$current" }

    if ($AuditOnly) {
        Write-Log "DRIFT   $($Setting.Name) is $was, expected $desired" 'DRIFT'
        return
    }

    if (-not (Test-Path -Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Setting.Name -PropertyType $Setting.Type `
        -Value $desired -Force -ErrorAction Stop | Out-Null
    Write-Log "SET     $($Setting.Name) = $desired (was $was)"
    $script:DriftCount++
}

# =============================================================================
# LAPS ENGINE
# =============================================================================

function Test-LapsModuleAvailable {
    return ($null -ne (Get-Command -Name 'Invoke-LapsPolicyProcessing' -ErrorAction SilentlyContinue))
}

function Get-LapsEvent {
    param([datetime]$Since, [int]$MaxEvents = 25)
    $filter = @{ LogName = $LapsLogName }
    if ($PSBoundParameters.ContainsKey('Since')) { $filter['StartTime'] = $Since }
    try {
        return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop |
            Sort-Object TimeCreated)
    } catch {
        return @()
    }
}

function Write-LapsEventSummary {
    param([Parameter(Mandatory)]$Events)
    foreach ($e in $Events) {
        $level = 'INFO'
        if ($e.Id -eq 10005 -or $e.Id -eq 10043) { $level = 'ERROR' }
        if ($e.Id -eq 10031) { $level = 'WARN' }
        $text = ($e.Message -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join ' | '
        Write-Log ("LAPS event {0} at {1}: {2}" -f $e.Id, $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $text) $level
    }
}

function Invoke-LapsPolicyNow {
    # Triggers an immediate LAPS policy cycle and reports what it produced.
    # Absence of a backup event is normal on a device whose password is not yet
    # due for rotation, so only an explicit failure event is treated as an error.
    if (-not (Test-LapsModuleAvailable)) {
        Write-Log 'The in-box LAPS PowerShell module is not available, so policy processing cannot be triggered. Windows LAPS will pick the policy up within its next hourly cycle.' 'WARN'
        return
    }
    $start = (Get-Date).AddSeconds(-5)
    try {
        Invoke-LapsPolicyProcessing -ErrorAction Stop
        Write-Log 'Invoke-LapsPolicyProcessing completed.'
    } catch {
        Write-Log "Invoke-LapsPolicyProcessing failed: $($_.Exception.Message)" 'ERROR'
        return
    }

    if ($RotateNow) {
        try {
            Reset-LapsPassword -ErrorAction Stop
            Write-Log 'Reset-LapsPassword completed - the managed account password was rotated immediately.'
        } catch {
            Write-Log "Reset-LapsPassword failed: $($_.Exception.Message)" 'ERROR'
        }
    }

    if ($VerifyBackupSeconds -le 0) { return }
    Write-Log "Waiting $VerifyBackupSeconds second(s) for LAPS to report the outcome in $LapsLogName."
    Start-Sleep -Seconds $VerifyBackupSeconds

    $events = Get-LapsEvent -Since $start
    if ($events.Count -eq 0) {
        Write-Log "No LAPS events were written since policy processing started. Check $LapsLogName manually." 'WARN'
        return
    }
    Write-LapsEventSummary -Events $events

    if ($events | Where-Object { $_.Id -eq 10029 }) {
        Write-Log 'Confirmed: LAPS backed the password up to Microsoft Entra ID (event 10029).' 'OK'
    } elseif ($events | Where-Object { $_.Id -eq 10018 }) {
        Write-Log 'Confirmed: LAPS backed the password up to Active Directory (event 10018).' 'OK'
    } elseif ($events | Where-Object { $_.Id -eq 10004 }) {
        Write-Log 'LAPS policy processing succeeded (event 10004). No password backup was due on this cycle.' 'OK'
    }
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-Enforce {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Path)

    Write-Log "=== ENFORCE: writing LAPS policy to the $PolicyRoot root ($Path) ==="
    Write-CompetingRootWarnings -Settings $Settings

    $applied = @()
    foreach ($setting in $Settings) {
        try {
            Invoke-Setting -Setting $setting -Path $Path
            if ($null -ne $setting.Data) { $applied += $setting.Name }
        } catch {
            Write-Log "Failed to apply $($setting.Name): $($_.Exception.Message)" 'ERROR'
        }
    }

    Save-StateValue -Name 'ManagedValues' -Value ($applied -join ',')
    Save-StateValue -Name 'PolicyRoot'    -Value $PolicyRoot
    Save-StateValue -Name 'ScriptVersion' -Value $ScriptVersion
    Save-StateValue -Name 'LastEnforceUtc' -Value (Get-Date).ToUniversalTime().ToString('o')

    if ($script:FailureCount -gt 0) { return }

    if ($ApplyPolicyImmediately) {
        Invoke-LapsPolicyNow
    } else {
        Write-Log 'ApplyPolicyImmediately is $false - Windows LAPS will pick the policy up within its next hourly cycle.'
    }
}

function Invoke-Audit {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Path)

    Write-Log "=== AUDIT: comparing the $PolicyRoot root ($Path) against the configured policy ==="
    Write-CompetingRootWarnings -Settings $Settings

    foreach ($setting in $Settings) {
        try {
            Invoke-Setting -Setting $setting -Path $Path -AuditOnly
        } catch {
            Write-Log "Failed to read $($setting.Name): $($_.Exception.Message)" 'ERROR'
        }
    }

    if ($script:DriftCount -eq 0) {
        Write-Log 'Audit result: COMPLIANT'
    } else {
        Write-Log "Audit result: $($script:DriftCount) drift item(s) found" 'WARN'
    }
}

function Invoke-Discover {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Os, [Parameter(Mandatory)]$Join)

    Write-Log '=== DISCOVER: Windows LAPS capability and current state ==='
    Write-Log "OS                  : $($Os.DisplayName)"
    Write-Log "LAPS capable        : $(Test-LapsCapable -Os $Os)"
    Write-Log "24H2+ settings      : $($Os.Is24H2Plus)"
    Write-Log "LAPS PS module      : $(Test-LapsModuleAvailable)"
    Write-Log "Join state          : DomainJoined=$($Join.DomainJoined) EntraJoined=$($Join.EntraJoined) Hybrid=$($Join.Hybrid) Workgroup=$($Join.Workgroup)"

    $populated = Get-PopulatedRoots -Settings $Settings
    if ($populated.Count -eq 0) {
        Write-Log 'No LAPS policy root holds any values - Windows LAPS is unconfigured on this device.'
    } else {
        $winner = $populated[0]
        Write-Log "Active policy root  : $($winner.Root) ($($winner.Path)) - first root in precedence order holding values"
        foreach ($root in $populated) {
            Write-Log "Populated root      : $($root.Root) -> $($root.Path)"
            $props = Get-ItemProperty -Path $root.Path -ErrorAction SilentlyContinue
            foreach ($name in ($root.Values | Sort-Object)) {
                Write-Log "    $name = $($props.$name)"
            }
        }
        if ($populated.Count -gt 1) {
            Write-Log 'More than one LAPS policy root holds values. Only the first is used; the others are ignored entirely.' 'WARN'
        }
    }

    $managed = Get-ManagedValueNames
    if ($managed.Count -gt 0) {
        Write-Log "This script owns    : $($managed -join ', ')"
    }

    Write-Log '--- Recent LAPS events ---'
    $events = Get-LapsEvent -MaxEvents 15
    if ($events.Count -eq 0) {
        Write-Log "No events in $LapsLogName (the channel may not exist until LAPS first runs)."
    } else {
        Write-LapsEventSummary -Events $events
    }
}

function Invoke-Revert {
    param([Parameter(Mandatory)][string]$Path)

    # Revert the root the values were actually written to, which may differ from
    # $PolicyRoot if the configuration was changed after enforcement.
    $recorded = $null
    if (Test-Path -Path $StateKey) {
        $recorded = (Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue).PolicyRoot
    }
    if ($recorded -and $PolicyRootPaths.Contains($recorded) -and $recorded -ne $PolicyRoot) {
        Write-Log "State records the policy was written to the $recorded root, not the configured $PolicyRoot root. Reverting $recorded." 'WARN'
        $Path = $PolicyRootPaths[$recorded]
    }

    Write-Log "=== REVERT: removing the values this script wrote from $Path ==="
    $managed = Get-ManagedValueNames
    if ($managed.Count -eq 0) {
        Write-Log 'No values are recorded as owned by this script - nothing to revert.' 'WARN'
    }

    foreach ($name in $managed) {
        try {
            if ($null -ne (Get-PolicyValue -Path $Path -Name $name)) {
                Remove-ItemProperty -Path $Path -Name $name -Force -ErrorAction Stop
                Write-Log "REMOVED $name"
            } else {
                Write-Log "OK      $name already absent" 'OK'
            }
        } catch {
            Write-Log "Failed to remove ${name}: $($_.Exception.Message)" 'ERROR'
        }
    }

    # Remove the policy key itself only when nothing else is left under it.
    if (Test-Path -Path $Path) {
        $props = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
        $left = @()
        if ($null -ne $props) {
            $left = @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
        }
        $hasSubKeys = @(Get-ChildItem -Path $Path -ErrorAction SilentlyContinue).Count -gt 0
        if ($left.Count -eq 0 -and -not $hasSubKeys) {
            Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
            Write-Log "REMOVED empty policy key $Path"
        } else {
            Write-Log "Left $Path in place - it still holds $($left.Count) value(s) this script does not own."
        }
    }

    Remove-Item -Path $StateKey -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "REMOVED state key $StateKey"
    Write-Log 'Windows LAPS stops managing the account at its next policy cycle. The password already stored in the directory is NOT deleted, and the managed local account keeps its current password - reset or disable that account separately if it should no longer be usable.' 'WARN'
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Manage-WindowsLaps v$ScriptVersion starting in mode: $Mode"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

$os = Get-OsBuildInfo
if (-not (Test-LapsCapable -Os $os)) {
    Write-Log "Windows LAPS is not present on this build ($($os.DisplayName)). It requires the April 11 2023 update or later on Windows 10 1809+/11 21H2+/Server 2022, and ships in-box from Windows 11 23H2 onward." 'ERROR'
    exit 2
}

$join     = Get-JoinState
$settings = Get-SettingDefinitions

# Only the CSP and local-configuration roots are writable here. The GPO and
# legacy roots are owned by Group Policy and are read for reporting only.
if ($PolicyRoot -ne 'CSP' -and $PolicyRoot -ne 'LocalConfig') {
    Write-Log "PolicyRoot '$PolicyRoot' is not valid. Use 'CSP' or 'LocalConfig'." 'ERROR'
    exit 2
}
$policyPath = $PolicyRootPaths[$PolicyRoot]

switch ($Mode) {
    'Enforce' {
        if (-not (Test-Configuration -Settings $settings -Os $os -Join $join)) {
            Write-Log 'Configuration is not valid for this device - nothing was written.' 'ERROR'
            exit 2
        }
        Invoke-Enforce -Settings $settings -Path $policyPath
    }
    'Audit' {
        if (-not (Test-Configuration -Settings $settings -Os $os -Join $join)) {
            Write-Log 'Configuration is not valid for this device - the audit cannot be trusted.' 'ERROR'
            exit 2
        }
        Invoke-Audit -Settings $settings -Path $policyPath
    }
    'Discover' { Invoke-Discover -Settings $settings -Os $os -Join $join }
    'Revert'   { Invoke-Revert -Path $policyPath }
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
