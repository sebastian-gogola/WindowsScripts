<#
.SYNOPSIS
    Manages local user accounts on Iru-managed Windows endpoints - creation,
    take-over, Administrators membership, enable/disable, sign-in screen
    visibility, and password strategy - standing in for the local-user
    management that MDMs such as JumpCloud provide through user-to-device
    binding.

.DESCRIPTION
    Iru has no native feature for creating local accounts or setting their
    passwords. This script fills that gap from a declared list of accounts in
    $Users. For each entry it ensures the account exists (creating it, or taking
    over an existing one), is enabled or disabled as declared, is in or out of
    the local Administrators group, is shown or hidden on the sign-in screen,
    and has its password handled by one of three strategies:

      Static  - the password given in the entry, identical on every device.
                Simple, and the only option when nothing can escrow a random
                password for later retrieval.
      Rotate  - a cryptographically random password per device, posted to the
                device's notes in Iru through the Iru API and re-rotated once
                older than $RotationDays. Retrieval is the device's Notes tab.
                The note is posted BEFORE the local password changes, so the
                console never lacks a password that was applied.
      Keep    - never touch the password; manage everything else. This is how
                an existing account is taken over without resetting it.

    Accounts this script created are recorded in its state key, so an entry
    later removed from $Users can be disabled or deleted (an MDM "unbind"),
    while accounts the script merely took over are never deleted. Before any
    action that would leave the device with no enabled administrator at all,
    the script refuses (exit 2) rather than lock the device out.

    Modes:
      Enforce  - apply the declared state
      Audit    - report drift, change nothing
      Discover - inventory every local account and the script's state
      Revert   - undo what the script itself changed: sign-in visibility,
                 built-in Administrator state, the rotation task, legacy
                 artifacts, and state. Accounts it created are deleted only
                 when $RevertRemovesAccounts = $true. Passwords are never reset.

    Designed for deployment as an Iru Windows Custom Script Library Item running
    as NT AUTHORITY\SYSTEM. Pair the same script in the Audit slot
    ($Mode = 'Audit') and Remediation slot ($Mode = 'Enforce').

.NOTES
    File     : Manage-LocalAdmin.ps1
    Version  : 1.0.0 (2026-09-15) - supersedes CreateLocalAdmin.ps1 and
               SetLocalAdminPassword.ps1
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Target   : Windows 11 24H2 or later
    Runs as  : SYSTEM or local Administrator (elevation required). Run in the
               64-bit PowerShell host - the LocalAccounts module is not
               available to 32-bit PowerShell on 64-bit Windows.
    PS       : Windows PowerShell 5.1 (in-box modules only)
    Status   : UNTESTED - not yet validated on a device or tenant

    Exit codes:
      0 = success / compliant
      1 = drift detected (Audit) or a runtime failure during Enforce/Revert
      2 = precondition failure (not elevated, invalid configuration) or a
          refused action that would have left no enabled administrator

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

# Accounts to manage - one hashtable per account.
#   Name            required; 1-20 characters; none of  " / \ [ ] : ; | = , + * ? < > @
#   Description     optional; applied on creation and corrected on take-over
#   Admin           $true = member of the local Administrators group (added if
#                   missing); $false = not a member (removed if present). Default $false
#   Enabled         $true | $false. Default $true
#   HideFromLogin   $true hides the account tile on the sign-in and lock screens.
#                   The account still works via "Other user", RDP, and runas. Default $false
#   Password        'Static' | 'Rotate' | 'Keep'. Default 'Keep'. Keep requires the
#                   account to already exist - a new account needs a password.
#   StaticPassword  required when Password = 'Static'. Must satisfy the device's
#                   local password policy. CHANGE THE PLACEHOLDER BELOW.
$Users = @(
    @{
        Name           = 'LocalITAdmin'
        Description    = 'Iru-managed local administrator'
        Admin          = $true
        Enabled        = $true
        HideFromLogin  = $true
        Password       = 'Static'
        StaticPassword = 'Ch@ngeM3!BeforeDeploying'
    }
)

# Accounts THIS SCRIPT CREATED that are no longer listed in $Users (the MDM
# "unbind" case). Accounts it only took over are never touched by this.
#   'Leave' | 'Disable' | 'Delete'   (Delete leaves the profile folder on disk)
$UnlistedCreatedAccounts = 'Leave'

# Built-in Administrator (RID 500), located by SID so a rename does not matter.
#   'Leave' | 'Disable' | 'Enable'
$BuiltInAdministrator = 'Leave'

# --- Rotate strategy (only read when at least one account uses it) -----------

$IruSubdomain   = ''        # 'acme' from acme.api.kandji.io
$IruRegion      = 'us'      # 'us' | 'eu'
$IruApiToken    = ''        # scope to: Device list, Device notes (create) - nothing more
$PasswordLength = 24        # 8-64
$RotationDays   = 30        # 1-365; rotate when the last rotation is older than this

# Iru executes Windows Custom Scripts once per device, so recurring rotation
# needs a scheduled task on the device. That task runs a COPY of this script -
# including $IruApiToken - from %ProgramData%, readable by any local admin.
# Leave $false unless that trade-off is acceptable. Installed from Enforce only.
$InstallRotationTask = $false

# --- Revert ------------------------------------------------------------------

# Revert always undoes sign-in visibility, built-in Administrator state, the
# rotation task, legacy artifacts, and state. Deleting the accounts this script
# created is opt-in. Passwords are never reset by Revert.
$RevertRemovesAccounts = $false

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Manage-LocalAdmin.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion      = '1.0.0'
$StateKey           = 'HKLM:\SOFTWARE\IruScripts\LocalAdmin'
$AdminGroupSid      = 'S-1-5-32-544'
$UserListKey        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
$PlaceholderPassword = 'Ch@ngeM3!BeforeDeploying'
$InvalidNameChars   = [char[]]'"/\[]:;|=,+*?<>@'

$RotationTaskName   = 'IruScripts-LocalAdminRotation'
$RotationScriptDir  = Join-Path $env:ProgramData 'IruScripts\LocalAdmin'
$RotationScriptPath = Join-Path $RotationScriptDir 'Manage-LocalAdmin.ps1'

# Left behind by the superseded SetLocalAdminPassword.ps1; both hold an API token copy.
$LegacyTaskName     = 'IruLAPS-PasswordRotation'
$LegacyDir          = Join-Path $env:ProgramData 'IruLAPS'

$script:FailureCount  = 0
$script:DriftCount    = 0
$script:SafetyRefusal = $false

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

function Get-UserDefinitions {
    # Normalises the $Users hashtables into objects with every key present.
    $defs = @()
    foreach ($u in @($Users)) {
        $d = [ordered]@{
            Name = ''; Description = $null; Admin = $false; Enabled = $true
            HideFromLogin = $false; Password = 'Keep'; StaticPassword = $null
        }
        foreach ($k in $u.Keys) { $d[$k] = $u[$k] }
        $defs += [pscustomobject]$d
    }
    return @($defs)
}

function Test-Configuration {
    param([Parameter(Mandatory)]$Defs)
    $ok = $true
    $knownKeys = @('Name','Description','Admin','Enabled','HideFromLogin','Password','StaticPassword')

    if (@('Enforce','Audit','Discover','Revert') -notcontains $Mode) {
        Write-Log "Unknown Mode '$Mode'. Valid: Enforce, Audit, Discover, Revert." 'ERROR'; $ok = $false
    }
    if (@('Leave','Disable','Delete') -notcontains $UnlistedCreatedAccounts) {
        Write-Log "UnlistedCreatedAccounts '$UnlistedCreatedAccounts' is not valid. Use Leave, Disable, or Delete." 'ERROR'; $ok = $false
    }
    if (@('Leave','Disable','Enable') -notcontains $BuiltInAdministrator) {
        Write-Log "BuiltInAdministrator '$BuiltInAdministrator' is not valid. Use Leave, Disable, or Enable." 'ERROR'; $ok = $false
    }

    $seen = @{}
    $anyRotate = $false
    foreach ($u in @($Users)) {
        foreach ($k in $u.Keys) {
            if ($knownKeys -notcontains $k) { Write-Log "User entry has an unknown key '$k' - it is ignored." 'WARN' }
        }
    }
    foreach ($d in $Defs) {
        $n = [string]$d.Name
        if ([string]::IsNullOrWhiteSpace($n)) { Write-Log 'A $Users entry has no Name.' 'ERROR'; $ok = $false; continue }
        if ($n.Length -gt 20) { Write-Log "User '$n' exceeds the 20 character limit for local account names." 'ERROR'; $ok = $false }
        if ($n.IndexOfAny($InvalidNameChars) -ge 0 -or $n.Trim() -ne $n -or $n.EndsWith('.')) {
            Write-Log "User '$n' contains characters Windows does not allow in an account name." 'ERROR'; $ok = $false
        }
        if ($seen.ContainsKey($n.ToLowerInvariant())) { Write-Log "User '$n' is listed more than once." 'ERROR'; $ok = $false }
        $seen[$n.ToLowerInvariant()] = $true

        if (@('Static','Rotate','Keep') -notcontains [string]$d.Password) {
            Write-Log "User '$n': Password '$($d.Password)' is not valid. Use Static, Rotate, or Keep." 'ERROR'; $ok = $false
        }
        if ([string]$d.Password -eq 'Static') {
            if ([string]::IsNullOrEmpty([string]$d.StaticPassword)) {
                Write-Log "User '$n': Password = Static requires StaticPassword." 'ERROR'; $ok = $false
            } elseif ([string]$d.StaticPassword -ceq $PlaceholderPassword) {
                Write-Log "User '$n': StaticPassword is still the placeholder. Set a real password before deploying." 'ERROR'; $ok = $false
            }
        }
        if ([string]$d.Password -eq 'Rotate') { $anyRotate = $true }
        if (-not [bool]$d.Enabled -and [bool]$d.Admin) {
            Write-Log "User '$n' is declared as a disabled administrator - allowed, but it will not count toward the lockout guard." 'WARN'
        }
    }

    if ($anyRotate) {
        if ([string]::IsNullOrWhiteSpace($IruSubdomain)) { Write-Log 'Rotate is in use but IruSubdomain is empty.' 'ERROR'; $ok = $false }
        if (@('us','eu') -notcontains $IruRegion)        { Write-Log "IruRegion '$IruRegion' is not valid. Use us or eu." 'ERROR'; $ok = $false }
        if ([string]::IsNullOrWhiteSpace($IruApiToken))  { Write-Log 'Rotate is in use but IruApiToken is empty.' 'ERROR'; $ok = $false }
        if ($PasswordLength -lt 8 -or $PasswordLength -gt 64) { Write-Log "PasswordLength = $PasswordLength is outside 8-64." 'ERROR'; $ok = $false }
        if ($RotationDays -lt 1 -or $RotationDays -gt 365)    { Write-Log "RotationDays = $RotationDays is outside 1-365." 'ERROR'; $ok = $false }
    }
    elseif ($InstallRotationTask) {
        Write-Log 'InstallRotationTask is $true but no account uses Password = Rotate; the task will not be installed.' 'WARN'
    }
    return $ok
}

# =============================================================================
# STATE
# =============================================================================

function Get-StateValue {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -Path $StateKey)) { return $null }
    $props = Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $null }
    return $props.$Name
}

function Set-StateValue {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    try {
        if (-not (Test-Path -Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        New-ItemProperty -Path $StateKey -Name $Name -PropertyType String -Value $Value -Force | Out-Null
    } catch {
        Write-Log "Could not write state value ${Name}: $($_.Exception.Message)" 'WARN'
    }
}

function Get-StateList {
    param([Parameter(Mandatory)][string]$Name)
    $raw = [string](Get-StateValue -Name $Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw -split ',' | Where-Object { $_ -ne '' })
}

function Add-StateListItem {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Item)
    $list = @(Get-StateList -Name $Name)
    if ($list -notcontains $Item) { $list += $Item }
    Set-StateValue -Name $Name -Value ($list -join ',')
}

function Remove-StateListItem {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Item)
    $list = @(Get-StateList -Name $Name | Where-Object { $_ -ne $Item })
    Set-StateValue -Name $Name -Value ($list -join ',')
}

# =============================================================================
# ACCOUNT HELPERS
# =============================================================================

function Get-LocalAccount {
    param([Parameter(Mandatory)][string]$Name)
    try { return (Get-LocalUser -Name $Name -ErrorAction Stop) } catch { return $null }
}

function Get-BuiltInAdministrator {
    # RID 500 identifies the built-in Administrator regardless of its name.
    return (Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' } | Select-Object -First 1)
}

function Get-AdminGroupName {
    return (Get-LocalGroup -SID $AdminGroupSid -ErrorAction Stop).Name
}

function Get-AdminGroupMemberSids {
    # Get-LocalGroupMember fails on some Entra-joined devices when the group
    # holds members it cannot resolve. ADSI enumerates the same membership as
    # raw SIDs and is used as the fallback.
    $group = Get-AdminGroupName
    try {
        return @(Get-LocalGroupMember -Group $group -ErrorAction Stop | ForEach-Object { $_.SID.Value })
    } catch {
        Write-Log "Get-LocalGroupMember failed ($($_.Exception.Message)); enumerating via ADSI instead." 'WARN'
    }
    $sids = @()
    try {
        $adsi = [ADSI]"WinNT://./$group,group"
        foreach ($m in @($adsi.psbase.Invoke('Members'))) {
            $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
            $sids += (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value
        }
    } catch {
        Write-Log "ADSI enumeration of $group failed: $($_.Exception.Message)" 'ERROR'
    }
    return $sids
}

function Test-IsAdminMember {
    param([Parameter(Mandatory)]$Account)
    return ((Get-AdminGroupMemberSids) -contains $Account.SID.Value)
}

function Test-WouldOrphanAdministrators {
    # $true when removing/disabling the account with $ExcludeSid would leave the
    # Administrators group with no enabled local user and no other principal
    # (cloud or domain identities count as "someone can still administer").
    param([string]$ExcludeSid = '')
    $locals = @{}
    foreach ($u in Get-LocalUser) { $locals[$u.SID.Value] = $u }
    $remaining = 0
    foreach ($sid in Get-AdminGroupMemberSids) {
        if ($sid -eq $ExcludeSid) { continue }
        if ($locals.ContainsKey($sid)) {
            if ($locals[$sid].Enabled) { $remaining++ }
        } else {
            $remaining++   # non-local principal
        }
    }
    return ($remaining -eq 0)
}

function Test-IsHidden {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -Path $UserListKey)) { return $false }
    $v = (Get-ItemProperty -Path $UserListKey -Name $Name -ErrorAction SilentlyContinue).$Name
    return ($null -ne $v -and [int]$v -eq 0)
}

function Test-LocalCredential {
    # Validates a local account's password without changing it. Returns $true /
    # $false, or $null when validation itself is unavailable.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Password)
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine', $env:COMPUTERNAME)
        $result = $ctx.ValidateCredentials($Name, $Password)
        $ctx.Dispose()
        return [bool]$result
    } catch {
        Write-Log "Could not validate the password for '$Name' ($($_.Exception.Message)); treating as unverifiable." 'WARN'
        return $null
    }
}

function New-RandomPassword {
    param([Parameter(Mandatory)][int]$Length)
    # Ambiguous characters (O 0 l 1 I) excluded; at least one of each class;
    # positions shuffled with the same CSPRNG.
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghjkmnpqrstuvwxyz'
    $digits  = '23456789'
    $special = '!@#$%^&*()-_=+'
    $all     = $upper + $lower + $digits + $special

    $rng   = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)

    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($upper[$bytes[0] % $upper.Length])
    $chars.Add($lower[$bytes[1] % $lower.Length])
    $chars.Add($digits[$bytes[2] % $digits.Length])
    $chars.Add($special[$bytes[3] % $special.Length])
    for ($i = 4; $i -lt $Length; $i++) { $chars.Add($all[$bytes[$i] % $all.Length]) }

    $swap = New-Object byte[] 4
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $rng.GetBytes($swap)
        $j = [int]([BitConverter]::ToUInt32($swap, 0) % ($i + 1))
        $t = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $t
    }
    $rng.Dispose()
    return (-join $chars.ToArray())
}

# =============================================================================
# IRU API (Rotate strategy)
# =============================================================================

function Get-IruBaseUrl {
    if ($IruRegion -eq 'eu') { return "https://$IruSubdomain.api.eu.kandji.io/api/v1" }
    return "https://$IruSubdomain.api.kandji.io/api/v1"
}

function Invoke-IruApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $BodyObject = $null
    )
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $params = @{
        Method  = $Method
        Uri     = (Get-IruBaseUrl) + $Path
        Headers = @{ Authorization = "Bearer $IruApiToken"; 'Content-Type' = 'application/json'; Accept = 'application/json' }
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $BodyObject) { $params['Body'] = ($BodyObject | ConvertTo-Json -Compress) }
    return Invoke-RestMethod @params
}

function Get-DeviceSerialNumber {
    $serial = [string](Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    if ([string]::IsNullOrWhiteSpace($serial) -or $serial -match 'To Be Filled|Default string|System Serial Number') {
        throw "BIOS serial number is unusable ('$serial'); cannot look the device up in Iru."
    }
    return $serial.Trim()
}

function Get-IruDeviceId {
    $serial = Get-DeviceSerialNumber
    $items  = @(Invoke-IruApi -Method GET -Path ('/devices?serial_number=' + [uri]::EscapeDataString($serial)))
    foreach ($d in $items) {
        if ([string]$d.serial_number -and ([string]$d.serial_number).Trim() -ieq $serial) { return [string]$d.device_id }
    }
    throw "No Iru device matched serial number '$serial'."
}

function Add-IruDeviceNote {
    param([Parameter(Mandatory)][string]$DeviceId, [Parameter(Mandatory)][string]$Content)
    $delays = @(0, 3, 8)
    for ($attempt = 0; $attempt -lt $delays.Count; $attempt++) {
        if ($delays[$attempt] -gt 0) { Start-Sleep -Seconds $delays[$attempt] }
        try {
            Invoke-IruApi -Method POST -Path "/devices/$DeviceId/notes" -BodyObject @{ content = $Content } | Out-Null
            return
        } catch {
            $last = $_.Exception.Message
            Write-Log "Posting the device note failed (attempt $($attempt + 1) of $($delays.Count)): $last" 'WARN'
        }
    }
    throw "Could not post the device note after $($delays.Count) attempts: $last"
}

# =============================================================================
# PER-ACCOUNT ENFORCEMENT / AUDIT
# =============================================================================

function Set-ManagedAccount {
    # Applies (or, with -AuditOnly, reports) one $Users entry.
    param([Parameter(Mandatory)]$Def, [switch]$AuditOnly)

    $name    = [string]$Def.Name
    $account = Get-LocalAccount -Name $name
    $created = $false

    if ($null -ne $account -and $account.SID.Value -like 'S-1-5-21-*-500') {
        Write-Log "'$name' is the built-in Administrator. Manage it with `$BuiltInAdministrator, not `$Users - entry skipped." 'ERROR'
        return
    }

    # --- existence -----------------------------------------------------------
    if ($null -eq $account) {
        if ($AuditOnly) { Write-Log "DRIFT   $name does not exist" 'DRIFT'; return }
        if ([string]$Def.Password -eq 'Keep') {
            Write-Log "$name does not exist and Password = Keep gives nothing to create it with. Use Static or Rotate for new accounts." 'ERROR'
            return
        }
        # Created with a throwaway random password; the strategy sets the real one below.
        $bootstrap = ConvertTo-SecureString -String (New-RandomPassword -Length 24) -AsPlainText -Force
        $params = @{ Name = $name; Password = $bootstrap; PasswordNeverExpires = $true; AccountNeverExpires = $true; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrEmpty([string]$Def.Description)) { $params['Description'] = [string]$Def.Description }
        New-LocalUser @params | Out-Null
        $account = Get-LocalAccount -Name $name
        $created = $true
        Add-StateListItem -Name 'CreatedAccounts' -Item $name
        Write-Log "CREATED $name"
        $script:DriftCount++
    } else {
        Write-Log "OK      $name exists" 'OK'
    }

    # --- description (take-over correction) -----------------------------------
    if (-not $created -and -not [string]::IsNullOrEmpty([string]$Def.Description) -and ([string]$account.Description) -cne [string]$Def.Description) {
        if ($AuditOnly) { Write-Log "DRIFT   $name description is '$($account.Description)', expected '$($Def.Description)'" 'DRIFT' }
        else { Set-LocalUser -Name $name -Description ([string]$Def.Description) -ErrorAction Stop; Write-Log "SET     $name description"; $script:DriftCount++ }
    }

    # --- password ---------------------------------------------------------------
    switch ([string]$Def.Password) {
        'Static' {
            $verified = $null
            if (-not $created -and [bool]$account.Enabled) { $verified = Test-LocalCredential -Name $name -Password ([string]$Def.StaticPassword) }
            if ($verified -eq $true) {
                Write-Log "OK      $name password matches the configured static value" 'OK'
            } elseif ($AuditOnly) {
                if ($verified -eq $false) { Write-Log "DRIFT   $name password does not match the configured static value" 'DRIFT' }
                else { Write-Log "$name static password cannot be verified while the account is disabled or validation is unavailable." }
            } else {
                Set-LocalUser -Name $name -Password (ConvertTo-SecureString -String ([string]$Def.StaticPassword) -AsPlainText -Force) -PasswordNeverExpires $true -ErrorAction Stop
                Write-Log "SET     $name static password"
                if (-not $created) { $script:DriftCount++ }
            }
        }
        'Rotate' {
            $last = [string](Get-StateValue -Name "LastRotation_$name")
            $due  = $true
            if (-not [string]::IsNullOrWhiteSpace($last)) {
                $lastDate = [datetime]::MinValue
                if ([datetime]::TryParse($last, [ref]$lastDate)) { $due = ($lastDate.AddDays($RotationDays) -lt (Get-Date)) }
            }
            if ($created) { $due = $true }
            if (-not $due) {
                Write-Log "OK      $name password rotated $last, within $RotationDays days" 'OK'
            } elseif ($AuditOnly) {
                Write-Log "DRIFT   $name password rotation is due (last: $(if ($last) { $last } else { 'never' }))" 'DRIFT'
            } else {
                Invoke-PasswordRotation -Name $name
                if (-not $created) { $script:DriftCount++ }
            }
        }
        'Keep' { Write-Log "OK      $name password left as-is (Keep)" 'OK' }
    }

    # --- enabled state ------------------------------------------------------------
    $account = Get-LocalAccount -Name $name
    if ([bool]$Def.Enabled -ne [bool]$account.Enabled) {
        if ($AuditOnly) {
            Write-Log "DRIFT   $name is $(if ($account.Enabled) { 'enabled' } else { 'disabled' }), expected $(if ($Def.Enabled) { 'enabled' } else { 'disabled' })" 'DRIFT'
        } elseif ([bool]$Def.Enabled) {
            Enable-LocalUser -Name $name -ErrorAction Stop; Write-Log "ENABLED $name"; $script:DriftCount++
        } else {
            if ((Test-IsAdminMember -Account $account) -and (Test-WouldOrphanAdministrators -ExcludeSid $account.SID.Value)) {
                Write-Log "REFUSED to disable $name - it is the last enabled administrator on this device." 'ERROR'
                $script:SafetyRefusal = $true
            } else {
                Disable-LocalUser -Name $name -ErrorAction Stop; Write-Log "DISABLED $name"; $script:DriftCount++
            }
        }
    } else {
        Write-Log "OK      $name is $(if ($account.Enabled) { 'enabled' } else { 'disabled' })" 'OK'
    }

    # --- Administrators membership -------------------------------------------------
    $isMember = Test-IsAdminMember -Account $account
    $group    = Get-AdminGroupName
    if ([bool]$Def.Admin -and -not $isMember) {
        if ($AuditOnly) { Write-Log "DRIFT   $name is not in $group" 'DRIFT' }
        else {
            try { Add-LocalGroupMember -Group $group -Member $account.SID -ErrorAction Stop; Write-Log "ADDED   $name to $group"; $script:DriftCount++ }
            catch {
                if ($_.Exception.GetType().Name -eq 'MemberExistsException') { Write-Log "OK      $name already in $group" 'OK' } else { throw }
            }
        }
    } elseif (-not [bool]$Def.Admin -and $isMember) {
        if ($AuditOnly) { Write-Log "DRIFT   $name is in $group but declared Admin = `$false" 'DRIFT' }
        elseif ($account.Enabled -and (Test-WouldOrphanAdministrators -ExcludeSid $account.SID.Value)) {
            Write-Log "REFUSED to remove $name from $group - it is the last enabled administrator on this device." 'ERROR'
            $script:SafetyRefusal = $true
        } else {
            try { Remove-LocalGroupMember -Group $group -Member $account.SID -ErrorAction Stop; Write-Log "REMOVED $name from $group"; $script:DriftCount++ }
            catch {
                if ($_.Exception.GetType().Name -eq 'MemberNotFoundException') { Write-Log "OK      $name not in $group" 'OK' } else { throw }
            }
        }
    } else {
        Write-Log "OK      $name $(if ($isMember) { 'is' } else { 'is not' }) in $group" 'OK'
    }

    # --- sign-in screen visibility --------------------------------------------------
    $hidden = Test-IsHidden -Name $name
    if ([bool]$Def.HideFromLogin -and -not $hidden) {
        if ($AuditOnly) { Write-Log "DRIFT   $name is visible on the sign-in screen, expected hidden" 'DRIFT' }
        else {
            if (-not (Test-Path -Path $UserListKey)) { New-Item -Path $UserListKey -Force | Out-Null }
            New-ItemProperty -Path $UserListKey -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
            Add-StateListItem -Name 'HiddenAccounts' -Item $name
            Write-Log "HIDDEN  $name from the sign-in screen"; $script:DriftCount++
        }
    } elseif (-not [bool]$Def.HideFromLogin -and $hidden) {
        if ($AuditOnly) { Write-Log "DRIFT   $name is hidden from the sign-in screen, expected visible" 'DRIFT' }
        else {
            Remove-ItemProperty -Path $UserListKey -Name $name -Force -ErrorAction Stop
            Remove-StateListItem -Name 'HiddenAccounts' -Item $name
            Write-Log "SHOWN   $name on the sign-in screen"; $script:DriftCount++
        }
    } else {
        Write-Log "OK      $name is $(if ($hidden) { 'hidden from' } else { 'visible on' }) the sign-in screen" 'OK'
    }
}

function Invoke-PasswordRotation {
    # Order matters: find the device, post the note, THEN change the password.
    # A network or API failure therefore happens before any local change, and
    # a local failure is followed by a correction note.
    param([Parameter(Mandatory)][string]$Name)

    $deviceId = Get-IruDeviceId
    $password = New-RandomPassword -Length $PasswordLength
    $stamp    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
    $note     = "[Manage-LocalAdmin] $env:COMPUTERNAME | Account: $Name | Password: $password | Rotated: $stamp"

    Add-IruDeviceNote -DeviceId $deviceId -Content $note
    Write-Log "Posted the new password for $Name to the Iru device notes."

    try {
        Set-LocalUser -Name $Name -Password (ConvertTo-SecureString -String $password -AsPlainText -Force) -PasswordNeverExpires $true -ErrorAction Stop
    } catch {
        $err = $_.Exception.Message
        Write-Log "Set-LocalUser failed after the note was posted: $err" 'ERROR'
        try {
            Add-IruDeviceNote -DeviceId $deviceId -Content "[Manage-LocalAdmin] $env:COMPUTERNAME | Account: $Name | ROTATION FAILED at $stamp - the password posted at $stamp was NOT applied; the previous password remains valid. Error: $err"
        } catch {
            Write-Log "Could not post the correction note either: $($_.Exception.Message)" 'ERROR'
        }
        return
    }
    Set-StateValue -Name "LastRotation_$Name" -Value (Get-Date).ToString('o')
    Write-Log "ROTATED $Name password ($PasswordLength characters); retrieve it from the device's Notes in Iru."
}

# =============================================================================
# BUILT-IN ADMINISTRATOR / UNLISTED ACCOUNTS / ROTATION TASK / LEGACY
# =============================================================================

function Set-BuiltInAdministratorState {
    param([switch]$AuditOnly)
    if ($BuiltInAdministrator -eq 'Leave') { return }
    $bi = Get-BuiltInAdministrator
    if ($null -eq $bi) { Write-Log 'Built-in Administrator (RID 500) not found.' 'WARN'; return }

    $wantEnabled = ($BuiltInAdministrator -eq 'Enable')
    if ([bool]$bi.Enabled -eq $wantEnabled) {
        Write-Log "OK      built-in Administrator '$($bi.Name)' is $(if ($bi.Enabled) { 'enabled' } else { 'disabled' })" 'OK'
        return
    }
    if ($AuditOnly) {
        Write-Log "DRIFT   built-in Administrator '$($bi.Name)' is $(if ($bi.Enabled) { 'enabled' } else { 'disabled' }), expected $BuiltInAdministrator" 'DRIFT'
        return
    }
    if ($null -eq (Get-StateValue -Name 'BuiltInAdminPriorState')) {
        Set-StateValue -Name 'BuiltInAdminPriorState' -Value $(if ($bi.Enabled) { 'Enabled' } else { 'Disabled' })
    }
    if ($wantEnabled) {
        Enable-LocalUser -Name $bi.Name -ErrorAction Stop; Write-Log "ENABLED built-in Administrator '$($bi.Name)'"; $script:DriftCount++
    } elseif (Test-WouldOrphanAdministrators -ExcludeSid $bi.SID.Value) {
        Write-Log "REFUSED to disable built-in Administrator '$($bi.Name)' - no other enabled administrator exists on this device." 'ERROR'
        $script:SafetyRefusal = $true
    } else {
        Disable-LocalUser -Name $bi.Name -ErrorAction Stop; Write-Log "DISABLED built-in Administrator '$($bi.Name)'"; $script:DriftCount++
    }
}

function Set-UnlistedCreatedAccounts {
    param([Parameter(Mandatory)]$Defs, [switch]$AuditOnly)
    if ($UnlistedCreatedAccounts -eq 'Leave') { return }
    $listed = @($Defs | ForEach-Object { ([string]$_.Name).ToLowerInvariant() })
    foreach ($name in Get-StateList -Name 'CreatedAccounts') {
        if ($listed -contains $name.ToLowerInvariant()) { continue }
        $account = Get-LocalAccount -Name $name
        if ($null -eq $account) { Remove-StateListItem -Name 'CreatedAccounts' -Item $name; continue }

        if ($UnlistedCreatedAccounts -eq 'Disable' -and -not $account.Enabled) { Write-Log "OK      unlisted $name already disabled" 'OK'; continue }
        if ($AuditOnly) { Write-Log "DRIFT   $name was created by this script, is no longer listed, and should be ${UnlistedCreatedAccounts}d" 'DRIFT'; continue }

        if ($account.Enabled -and (Test-IsAdminMember -Account $account) -and (Test-WouldOrphanAdministrators -ExcludeSid $account.SID.Value)) {
            Write-Log "REFUSED to $($UnlistedCreatedAccounts.ToLower()) unlisted $name - it is the last enabled administrator on this device." 'ERROR'
            $script:SafetyRefusal = $true
            continue
        }
        if ($UnlistedCreatedAccounts -eq 'Disable') {
            Disable-LocalUser -Name $name -ErrorAction Stop; Write-Log "DISABLED unlisted $name"
        } else {
            Remove-LocalUser -Name $name -ErrorAction Stop
            Remove-ItemProperty -Path $UserListKey -Name $name -Force -ErrorAction SilentlyContinue
            Remove-StateListItem -Name 'HiddenAccounts'  -Item $name
            Remove-StateListItem -Name 'CreatedAccounts' -Item $name
            Write-Log "DELETED unlisted $name (profile folder left on disk)"
        }
        $script:DriftCount++
    }
}

function Set-RotationTaskState {
    param([Parameter(Mandatory)][bool]$AnyRotate, [switch]$AuditOnly)
    $task = Get-ScheduledTask -TaskName $RotationTaskName -ErrorAction SilentlyContinue
    $want = ($InstallRotationTask -and $AnyRotate)

    if ($want -and $null -eq $task) {
        if ($AuditOnly) { Write-Log "DRIFT   rotation task $RotationTaskName is not installed" 'DRIFT'; return }
        if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
            Write-Log 'Cannot install the rotation task: this script is not running from a file, so there is nothing to copy.' 'ERROR'; return
        }
        if (-not (Test-Path -Path $RotationScriptDir)) { New-Item -Path $RotationScriptDir -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $PSCommandPath -Destination $RotationScriptPath -Force -ErrorAction Stop
        $psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action  = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$RotationScriptPath`""
        $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $RotationDays -At (Get-Date).Date.AddDays(1).AddHours(2)
        $princ   = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest -LogonType ServiceAccount
        $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)
        Register-ScheduledTask -TaskName $RotationTaskName -Action $action -Trigger $trigger -Principal $princ -Settings $set -Description "Manage-LocalAdmin: rotates Rotate-strategy local passwords every $RotationDays days and posts them to Iru device notes." -Force | Out-Null
        Write-Log "INSTALLED rotation task $RotationTaskName (copy at $RotationScriptPath contains the API token)"
        $script:DriftCount++
    }
    elseif (-not $want -and $null -ne $task) {
        if ($AuditOnly) { Write-Log "DRIFT   rotation task $RotationTaskName is installed but not wanted" 'DRIFT'; return }
        Remove-RotationTask
        $script:DriftCount++
    }
    elseif ($want) { Write-Log "OK      rotation task $RotationTaskName installed" 'OK' }
}

function Remove-RotationTask {
    if (Get-ScheduledTask -TaskName $RotationTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $RotationTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "REMOVED rotation task $RotationTaskName"
    }
    if (Test-Path -Path $RotationScriptDir) {
        Remove-Item -Path $RotationScriptDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "REMOVED $RotationScriptDir"
    }
}

function Remove-LegacyArtifacts {
    # SetLocalAdminPassword.ps1 left a task and a script copy holding an API token.
    if (Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "REMOVED legacy task $LegacyTaskName"
    }
    if (Test-Path -Path $LegacyDir) {
        Remove-Item -Path $LegacyDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "REMOVED legacy folder $LegacyDir"
    }
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-Enforce {
    param([Parameter(Mandatory)]$Defs)
    Write-Log '=== ENFORCE: applying declared local account state ==='
    Remove-LegacyArtifacts
    foreach ($d in $Defs) {
        try { Set-ManagedAccount -Def $d }
        catch { Write-Log "Failed while managing '$($d.Name)': $($_.Exception.Message)" 'ERROR' }
    }
    try { Set-UnlistedCreatedAccounts -Defs $Defs } catch { Write-Log "Failed handling unlisted accounts: $($_.Exception.Message)" 'ERROR' }
    try { Set-BuiltInAdministratorState }          catch { Write-Log "Failed handling the built-in Administrator: $($_.Exception.Message)" 'ERROR' }
    $anyRotate = [bool](@($Defs | Where-Object { [string]$_.Password -eq 'Rotate' }).Count -gt 0)
    try { Set-RotationTaskState -AnyRotate $anyRotate } catch { Write-Log "Failed handling the rotation task: $($_.Exception.Message)" 'ERROR' }
    Set-StateValue -Name 'ScriptVersion'  -Value $ScriptVersion
    Set-StateValue -Name 'LastEnforceUtc' -Value (Get-Date).ToUniversalTime().ToString('o')
}

function Invoke-Audit {
    param([Parameter(Mandatory)]$Defs)
    Write-Log '=== AUDIT: comparing local account state to the declaration ==='
    foreach ($d in $Defs) {
        try { Set-ManagedAccount -Def $d -AuditOnly }
        catch { Write-Log "Failed while auditing '$($d.Name)': $($_.Exception.Message)" 'ERROR' }
    }
    try { Set-UnlistedCreatedAccounts -Defs $Defs -AuditOnly } catch { Write-Log "Failed auditing unlisted accounts: $($_.Exception.Message)" 'ERROR' }
    try { Set-BuiltInAdministratorState -AuditOnly }          catch { Write-Log "Failed auditing the built-in Administrator: $($_.Exception.Message)" 'ERROR' }
    $anyRotate = [bool](@($Defs | Where-Object { [string]$_.Password -eq 'Rotate' }).Count -gt 0)
    try { Set-RotationTaskState -AnyRotate $anyRotate -AuditOnly } catch { Write-Log "Failed auditing the rotation task: $($_.Exception.Message)" 'ERROR' }
    if ($script:DriftCount -eq 0) { Write-Log 'Audit result: COMPLIANT' } else { Write-Log "Audit result: $($script:DriftCount) drift item(s) found" 'WARN' }
}

function Invoke-Discover {
    param([Parameter(Mandatory)]$Defs)
    Write-Log '=== DISCOVER: local account inventory (read-only) ==='
    $group    = Get-AdminGroupName
    $adminSid = @(Get-AdminGroupMemberSids)
    $created  = @(Get-StateList -Name 'CreatedAccounts')
    $listed   = @($Defs | ForEach-Object { ([string]$_.Name).ToLowerInvariant() })

    Write-Log "Administrators group : $group ($($adminSid.Count) member(s))"
    foreach ($u in Get-LocalUser | Sort-Object Name) {
        $flags = @()
        if ($adminSid -contains $u.SID.Value)         { $flags += 'ADMIN' }
        if ($u.SID.Value -like 'S-1-5-21-*-500')      { $flags += 'BUILT-IN' }
        if (Test-IsHidden -Name $u.Name)              { $flags += 'HIDDEN' }
        if ($created -contains $u.Name)               { $flags += 'CREATED-BY-SCRIPT' }
        if ($listed -contains $u.Name.ToLowerInvariant()) { $flags += 'LISTED' }
        $lastSet = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { 'never' }
        Write-Log ("  {0,-20} enabled={1,-5} pwdLastSet={2,-10} {3}" -f $u.Name, $u.Enabled, $lastSet, ($flags -join ' '))
    }
    $locals = @{}; foreach ($u in Get-LocalUser) { $locals[$u.SID.Value] = $true }
    $nonLocal = @($adminSid | Where-Object { -not $locals.ContainsKey($_) })
    Write-Log "Non-local Administrators members (cloud/domain): $($nonLocal.Count)"
    foreach ($s in $nonLocal) { Write-Log "  $s" }

    foreach ($d in $Defs) {
        if ($null -eq (Get-LocalAccount -Name ([string]$d.Name))) { Write-Log "Listed account '$($d.Name)' does not exist yet (Password = $($d.Password))." }
    }
    $prior = Get-StateValue -Name 'BuiltInAdminPriorState'
    if ($prior) { Write-Log "Built-in Administrator state before this script changed it: $prior" }
    foreach ($n in @(Get-StateList -Name 'CreatedAccounts')) {
        $lr = Get-StateValue -Name "LastRotation_$n"
        if ($lr) { Write-Log "Last rotation for ${n}: $lr" }
    }
    Write-Log "Rotation task installed : $($null -ne (Get-ScheduledTask -TaskName $RotationTaskName -ErrorAction SilentlyContinue))"
    Write-Log "Legacy IruLAPS task/dir : task=$($null -ne (Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue)) dir=$(Test-Path -Path $LegacyDir)"

    if (@($Defs | Where-Object { [string]$_.Password -eq 'Rotate' }).Count -gt 0) {
        try { Write-Log "Iru API check           : device_id $(Get-IruDeviceId) found for this serial number" }
        catch { Write-Log "Iru API check           : FAILED - $($_.Exception.Message)" 'WARN' }
    }
}

function Invoke-Revert {
    Write-Log '=== REVERT: undoing changes made by this script ==='
    foreach ($n in @(Get-StateList -Name 'HiddenAccounts')) {
        Remove-ItemProperty -Path $UserListKey -Name $n -Force -ErrorAction SilentlyContinue
        Write-Log "SHOWN   $n on the sign-in screen"
    }
    $prior = [string](Get-StateValue -Name 'BuiltInAdminPriorState')
    if ($prior) {
        $bi = Get-BuiltInAdministrator
        if ($null -ne $bi) {
            if ($prior -eq 'Enabled' -and -not $bi.Enabled) { Enable-LocalUser -Name $bi.Name -ErrorAction SilentlyContinue; Write-Log "ENABLED built-in Administrator (restored)" }
            elseif ($prior -eq 'Disabled' -and $bi.Enabled) {
                if (Test-WouldOrphanAdministrators -ExcludeSid $bi.SID.Value) { Write-Log 'REFUSED to re-disable the built-in Administrator - it is the last enabled administrator.' 'ERROR'; $script:SafetyRefusal = $true }
                else { Disable-LocalUser -Name $bi.Name -ErrorAction SilentlyContinue; Write-Log "DISABLED built-in Administrator (restored)" }
            }
        }
    }
    Remove-RotationTask
    Remove-LegacyArtifacts
    if ($RevertRemovesAccounts) {
        foreach ($n in @(Get-StateList -Name 'CreatedAccounts')) {
            $a = Get-LocalAccount -Name $n
            if ($null -eq $a) { continue }
            if ($a.Enabled -and (Test-IsAdminMember -Account $a) -and (Test-WouldOrphanAdministrators -ExcludeSid $a.SID.Value)) {
                Write-Log "REFUSED to delete $n - it is the last enabled administrator on this device." 'ERROR'; $script:SafetyRefusal = $true; continue
            }
            try { Remove-LocalUser -Name $n -ErrorAction Stop; Write-Log "DELETED $n (profile folder left on disk)" }
            catch { Write-Log "Could not delete ${n}: $($_.Exception.Message)" 'ERROR' }
        }
    } else {
        $c = @(Get-StateList -Name 'CreatedAccounts')
        if ($c.Count -gt 0) { Write-Log "Accounts created by this script were left in place ($($c -join ', ')). Set `$RevertRemovesAccounts = `$true to delete them." }
    }
    Remove-Item -Path $StateKey -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "REMOVED state key $StateKey"
    Write-Log 'Passwords were not changed by Revert.'
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Manage-LocalAdmin v$ScriptVersion starting in mode: $Mode"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}
if ($null -eq (Get-Command -Name Get-LocalUser -ErrorAction SilentlyContinue)) {
    Write-Log 'The LocalAccounts module is unavailable. Run this in the 64-bit Windows PowerShell 5.1 host.' 'ERROR'
    exit 2
}

$defs = Get-UserDefinitions
if ($Mode -ne 'Revert' -and -not (Test-Configuration -Defs $defs)) {
    Write-Log 'Configuration is not valid - nothing was changed.' 'ERROR'
    exit 2
}

switch ($Mode) {
    'Enforce'  { Invoke-Enforce  -Defs $defs }
    'Audit'    { Invoke-Audit    -Defs $defs }
    'Discover' { Invoke-Discover -Defs $defs }
    'Revert'   { Invoke-Revert }
    default    { Write-Log "Unknown mode '$Mode'. Valid: Enforce, Audit, Discover, Revert." 'ERROR'; exit 2 }
}

if ($script:SafetyRefusal) {
    Write-Log 'Completed with a refused action: the device would have been left with no enabled administrator.' 'ERROR'
    exit 2
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
