#Requires -Version 5.1
<#
.SYNOPSIS
    Blocks or restores manual MDM unenrollment from Settings > Accounts > Access work or school.

.DESCRIPTION
    Applies the Policy CSP setting Experience/AllowManualMDMUnenrollment locally on a
    Windows device, for environments where the MDM does not expose this node natively,
    or where a script-based guardrail that can be re-applied on a schedule is wanted.

    Write methods, in order (Enforce and Revert):
      1. MDM Bridge WMI Provider (root\cimv2\mdm\dmmap, class MDM_Policy_Config01_Experience02).
         Microsoft's documented route for applying CSP settings locally. Requires SYSTEM.
      2. Direct REG_DWORD write to HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Experience.
         Community-observed fallback. Requires local admin.

    Modes (set $Mode in the CONFIG block):
      Audit     Read only. Exit 0 if the effective value is 0 (REG_DWORD), else 1.
      Enforce   Set the value to 0, verify, exit 0 on success.
      Discover  Print join state, MDM enrollments, effective value and winning provider.
      Revert    Set the value back to the documented default of 1, verify.

    Exit codes:
      0  Success or compliant
      1  Non-compliant (Audit) or desired state not reached after writing (Enforce, Revert)
      2  Script error, unsupported edition, insufficient privilege, or no usable write method

.NOTES
    Version  : 1.0.0
    Repo     : sebastian-gogola/WindowsScripts
    Encoding : ASCII. No external modules. Config block instead of parameters.
    Logs     : %ProgramData%\IruScripts\Logs\Manage-ManualMdmUnenrollment.log
    State    : HKLM:\SOFTWARE\IruScripts\ManualMdmUnenrollment

    Microsoft documents that this policy has no effect when the device is Microsoft
    Entra joined and MDM enrolled (for example auto-enrolled). It also does not stop
    a local administrator from reversing the setting or tearing down the enrollment
    by other means. Read README.md before relying on it as a control.

.LINK
    https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience
.LINK
    https://learn.microsoft.com/en-us/windows/win32/dmwmibridgeprov/mdm-policy-config01-experience02
#>

# =============================================================================
# CONFIG - edit these values, then deploy. No parameters by design.
# =============================================================================
$Mode           = 'Enforce'   # Audit | Enforce | Discover | Revert
$TryWmiBridge   = $true       # Attempt the MDM Bridge WMI Provider first (SYSTEM only)
$TryRegistry    = $true       # Fall back to a direct PolicyManager registry write
$VerifyRetries  = 3           # Re-read attempts after a write
$VerifyDelaySec = 2           # Seconds between verification attempts
$LogDirectory   = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile        = Join-Path $LogDirectory 'Manage-ManualMdmUnenrollment.log'
$LogMaxBytes    = 1048576     # Rotate the log once it passes 1 MB
$StateKey       = 'HKLM:\SOFTWARE\IruScripts\ManualMdmUnenrollment'

# =============================================================================
# CONSTANTS - do not edit
# =============================================================================
$ScriptVersion    = '1.0.0'
$PolicyName       = 'AllowManualMDMUnenrollment'
$PolicyRegPath    = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Experience'
$EnrollmentsPath  = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$BridgeNamespace  = 'root\cimv2\mdm\dmmap'
$BridgeConfigCls  = 'MDM_Policy_Config01_Experience02'
$BridgeResultCls  = 'MDM_Policy_Result01_Experience02'
$BridgeParentId   = './Vendor/MSFT/Policy/Config'
$BridgeInstanceId = 'Experience'
$BlockedValue     = 0    # Not allowed
$DefaultValue     = 1    # Allowed (documented default)
$ValidModes       = @('Audit', 'Enforce', 'Discover', 'Revert')

# =============================================================================
# LOGGING
# =============================================================================
function Initialize-Logging {
    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $LogMaxBytes)) {
            $rotated = [System.IO.Path]::ChangeExtension($LogFile, '.1.log')
            Move-Item -LiteralPath $LogFile -Destination $rotated -Force
        }
    }
    catch {
        Write-Host "WARN: Logging setup failed: $($_.Exception.Message)"
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # Write-Host keeps log lines out of function return values while still reaching
    # the stdout that MDM and RMM agents capture from powershell.exe.
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding ASCII -ErrorAction Stop } catch { }
}

# =============================================================================
# ENVIRONMENT CHECKS
# =============================================================================
function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsSystem {
    return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
}

function Restart-InNativeProcess {
    # HKLM\SOFTWARE is redirected to WOW6432Node for 32-bit processes. Some agents still
    # launch 32-bit PowerShell, so relaunch through sysnative when that happens.
    if ([Environment]::Is64BitProcess -or -not [Environment]::Is64BitOperatingSystem) { return }

    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Write-Log 'Running as a 32-bit process on 64-bit Windows and no script path is available for relaunch. Registry writes may be redirected.' 'WARN'
        return
    }

    $native = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $native)) {
        Write-Log 'sysnative PowerShell not found; continuing in the 32-bit process.' 'WARN'
        return
    }

    Write-Log 'Relaunching in 64-bit PowerShell to avoid registry redirection.'
    & $native -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

function Get-OsInfo {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    return [pscustomobject]@{
        ProductName    = $cv.ProductName
        DisplayVersion = $cv.DisplayVersion
        Build          = ('{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR)
        EditionID      = $cv.EditionID
    }
}

# =============================================================================
# READ HELPERS
# =============================================================================
function Get-EffectivePolicy {
    # Reads the value PolicyManager exposes as the effective device policy, plus the
    # bookkeeping values that identify which provider set it. The registry layout is
    # not documented by Microsoft; treat these fields as observed behavior.
    $result = [ordered]@{
        Present         = $false
        Value           = $null
        Kind            = $null
        ProviderSet     = $null
        WinningProvider = $null
    }
    if (-not (Test-Path -LiteralPath $PolicyRegPath)) { return [pscustomobject]$result }

    $key   = Get-Item -LiteralPath $PolicyRegPath
    $names = $key.GetValueNames()

    if ($names -contains $PolicyName) {
        $result.Present = $true
        $result.Value   = $key.GetValue($PolicyName)
        $result.Kind    = $key.GetValueKind($PolicyName).ToString()
    }
    if ($names -contains ($PolicyName + '_ProviderSet')) {
        $result.ProviderSet = $key.GetValue($PolicyName + '_ProviderSet')
    }
    if ($names -contains ($PolicyName + '_WinningProvider')) {
        $result.WinningProvider = $key.GetValue($PolicyName + '_WinningProvider')
    }
    return [pscustomobject]$result
}

function Format-EffectivePolicy {
    param($Policy)
    if (-not $Policy.Present) { return 'NotConfigured' }
    return ('{0} ({1})' -f $Policy.Value, $Policy.Kind)
}

function Test-PolicyBlocked {
    param($Policy)
    # A REG_SZ "0" is deliberately treated as non-compliant. The CSP format is int and
    # PolicyManager stores it as REG_DWORD; a string value indicates a mis-typed write.
    return ($Policy.Present -and $Policy.Kind -eq 'DWord' -and [int]$Policy.Value -eq $BlockedValue)
}

function Test-PolicyDefault {
    param($Policy)
    if (-not $Policy.Present) { return $true }
    return ($Policy.Kind -eq 'DWord' -and [int]$Policy.Value -eq $DefaultValue)
}

function Get-BridgeResultValue {
    # MDM_Policy_Result01_Experience02 reports the resolved policy as seen by the CSP.
    try {
        $r = Get-CimInstance -Namespace $BridgeNamespace -ClassName $BridgeResultCls -ErrorAction Stop
        if ($null -eq $r) { return 'NoInstance' }
        $v = $r.$PolicyName
        if ($null -eq $v) { return 'NotSet' }
        return [string]$v
    }
    catch {
        return ('Unavailable: ' + $_.Exception.Message)
    }
}

function Get-JoinState {
    $out = [ordered]@{ AzureAdJoined = 'Unknown'; EnterpriseJoined = 'Unknown'; DomainJoined = 'Unknown' }
    try {
        $exe  = Join-Path $env:WINDIR 'System32\dsregcmd.exe'
        $text = & $exe /status 2>&1
        foreach ($name in @($out.Keys)) {
            $pattern = '^\s*{0}\s*:\s*(\S+)' -f $name
            $match = $text | Select-String -Pattern $pattern | Select-Object -First 1
            if ($match) { $out[$name] = $match.Matches[0].Groups[1].Value }
        }
    }
    catch { }
    return [pscustomobject]$out
}

function Get-MdmEnrollments {
    # Enumerates HKLM\SOFTWARE\Microsoft\Enrollments\<GUID>. Subkeys carrying a ProviderID
    # are enrollments; the rest (Context, Ownership, Status, ValidNodePaths) are skipped.
    # Layout is community-observed, not documented.
    $list = @()
    if (-not (Test-Path -LiteralPath $EnrollmentsPath)) { return $list }

    foreach ($sub in (Get-ChildItem -LiteralPath $EnrollmentsPath -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
        if ($null -ne $p -and -not [string]::IsNullOrEmpty($p.ProviderID)) {
            $list += [pscustomobject]@{
                EnrollmentId    = $sub.PSChildName
                ProviderID      = $p.ProviderID
                EnrollmentType  = $p.EnrollmentType
                EnrollmentState = $p.EnrollmentState
                UPN             = $p.UPN
                DiscoveryUrl    = $p.DiscoveryServiceFullURL
            }
        }
    }
    return $list
}

# =============================================================================
# WRITE HELPERS
# =============================================================================
function Set-PolicyViaBridge {
    param([Parameter(Mandatory = $true)][int]$Value)
    $inst = Get-CimInstance -Namespace $BridgeNamespace -ClassName $BridgeConfigCls -ErrorAction Stop
    if ($null -eq $inst) {
        $props = @{ ParentID = $BridgeParentId; InstanceID = $BridgeInstanceId }
        $props[$PolicyName] = $Value
        New-CimInstance -Namespace $BridgeNamespace -ClassName $BridgeConfigCls -Property $props -ErrorAction Stop | Out-Null
    }
    else {
        $inst.$PolicyName = $Value
        Set-CimInstance -CimInstance $inst -ErrorAction Stop
    }
}

function Set-PolicyViaRegistry {
    param([Parameter(Mandatory = $true)][int]$Value)
    if (-not (Test-Path -LiteralPath $PolicyRegPath)) {
        New-Item -Path $PolicyRegPath -Force -ErrorAction Stop | Out-Null
    }
    $key = Get-Item -LiteralPath $PolicyRegPath
    if (($key.GetValueNames() -contains $PolicyName) -and ($key.GetValueKind($PolicyName).ToString() -ne 'DWord')) {
        # Remove a mis-typed value (for example REG_SZ "0") so the DWORD is created cleanly.
        Remove-ItemProperty -LiteralPath $PolicyRegPath -Name $PolicyName -Force -ErrorAction Stop
    }
    New-ItemProperty -LiteralPath $PolicyRegPath -Name $PolicyName -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

function Invoke-PolicyWrite {
    # Returns the method that succeeded ('WmiBridge' or 'Registry') or $null.
    param([Parameter(Mandatory = $true)][int]$Value)

    if ($TryWmiBridge) {
        if (-not (Test-IsSystem)) {
            Write-Log 'Skipping MDM Bridge WMI Provider: it requires the SYSTEM context.' 'WARN'
        }
        else {
            try {
                Set-PolicyViaBridge -Value $Value
                Write-Log ('Applied {0}={1} via MDM Bridge WMI Provider ({2}).' -f $PolicyName, $Value, $BridgeConfigCls) 'OK'
                return 'WmiBridge'
            }
            catch {
                Write-Log ('MDM Bridge write failed: {0}' -f $_.Exception.Message) 'WARN'
            }
        }
    }

    if ($TryRegistry) {
        try {
            Set-PolicyViaRegistry -Value $Value
            Write-Log ('Applied {0}={1} via direct PolicyManager registry write (fallback).' -f $PolicyName, $Value) 'OK'
            return 'Registry'
        }
        catch {
            Write-Log ('Registry write failed: {0}' -f $_.Exception.Message) 'ERROR'
        }
    }

    Write-Log 'No write method succeeded, or all methods are disabled in CONFIG.' 'ERROR'
    return $null
}

function Wait-ForEffectivePolicy {
    param(
        [Parameter(Mandatory = $true)][int]$Expected,
        [switch]$AllowAbsent
    )
    for ($i = 1; $i -le $VerifyRetries; $i++) {
        $eff = Get-EffectivePolicy
        if ($AllowAbsent -and -not $eff.Present) { return $true }
        if ($eff.Present -and $eff.Kind -eq 'DWord' -and [int]$eff.Value -eq $Expected) { return $true }
        Write-Log ('Verification {0}/{1}: effective value is {2}, expected {3}.' -f $i, $VerifyRetries, (Format-EffectivePolicy $eff), $Expected)
        if ($i -lt $VerifyRetries) { Start-Sleep -Seconds $VerifyDelaySec }
    }
    return $false
}

# =============================================================================
# STATE
# =============================================================================
function Save-State {
    param([hashtable]$Values)
    try {
        if (-not (Test-Path -LiteralPath $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        foreach ($name in $Values.Keys) {
            New-ItemProperty -LiteralPath $StateKey -Name $name -Value ([string]$Values[$name]) -PropertyType String -Force | Out-Null
        }
    }
    catch {
        Write-Log ('Could not write state to {0}: {1}' -f $StateKey, $_.Exception.Message) 'WARN'
    }
}

function Complete-Run {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Method = 'None'
    )
    $effText = Format-EffectivePolicy (Get-EffectivePolicy)
    Save-State @{
        LastRun        = (Get-Date).ToString('o')
        LastMode       = $Mode
        Method         = $Method
        Result         = $Result
        EffectiveValue = $effText
        ScriptVersion  = $ScriptVersion
    }
    $level = if ($ExitCode -eq 0) { 'OK' } elseif ($ExitCode -eq 1) { 'WARN' } else { 'ERROR' }
    Write-Log ('Finished. Result={0} Method={1} Effective={2} ExitCode={3}' -f $Result, $Method, $effText, $ExitCode) $level
    exit $ExitCode
}

# =============================================================================
# MAIN
# =============================================================================
Initialize-Logging
Write-Log ('Manage-ManualMdmUnenrollment v{0} starting. Mode={1}' -f $ScriptVersion, $Mode)

try {
    if ($ValidModes -notcontains $Mode) {
        Write-Log ("Invalid Mode '{0}'. Use one of: {1}" -f $Mode, ($ValidModes -join ', ')) 'ERROR'
        exit 2
    }

    Restart-InNativeProcess

    if (-not (Test-IsAdministrator)) {
        Write-Log 'This script must run elevated. SYSTEM is recommended so the MDM Bridge path is available.' 'ERROR'
        exit 2
    }

    $isSystem = Test-IsSystem
    Write-Log ('Context: {0} ({1}), {2}-bit process, PowerShell {3}' -f `
        [Security.Principal.WindowsIdentity]::GetCurrent().Name, `
        $(if ($isSystem) { 'SYSTEM' } else { 'elevated user' }), `
        $(if ([Environment]::Is64BitProcess) { '64' } else { '32' }), `
        $PSVersionTable.PSVersion)

    $os = Get-OsInfo
    Write-Log ('OS: {0} {1} build {2}, EditionID={3}' -f $os.ProductName, $os.DisplayVersion, $os.Build, $os.EditionID)
    if ($os.EditionID -match '^Core') {
        Write-Log 'Home editions are not in the documented applicability list for Experience/AllowManualMDMUnenrollment.' 'ERROR'
        exit 2
    }

    switch ($Mode) {

        'Discover' {
            $join = Get-JoinState
            Write-Log ('Join state: AzureAdJoined={0} EnterpriseJoined={1} DomainJoined={2}' -f $join.AzureAdJoined, $join.EnterpriseJoined, $join.DomainJoined)
            if ($join.AzureAdJoined -eq 'YES') {
                Write-Log 'Device is Entra joined. Microsoft documents that this policy has no effect on Entra joined + MDM enrolled devices. Validate before relying on it.' 'WARN'
            }

            $enrollments = @(Get-MdmEnrollments)
            if ($enrollments.Count -eq 0) {
                Write-Log 'No MDM enrollments found under HKLM\SOFTWARE\Microsoft\Enrollments.' 'WARN'
            }
            foreach ($e in $enrollments) {
                Write-Log ('Enrollment {0}: ProviderID={1} Type={2} State={3} UPN={4} Discovery={5}' -f `
                    $e.EnrollmentId, $e.ProviderID, $e.EnrollmentType, $e.EnrollmentState, $e.UPN, $e.DiscoveryUrl)
            }

            $eff = Get-EffectivePolicy
            Write-Log ('Effective {0}: {1}; _ProviderSet={2}; _WinningProvider={3}' -f `
                $PolicyName, (Format-EffectivePolicy $eff), $eff.ProviderSet, $eff.WinningProvider)
            Write-Log ('Compliance: {0}' -f $(if (Test-PolicyBlocked $eff) { 'BLOCKED (compliant)' } else { 'NOT BLOCKED' }))

            if ($isSystem) {
                Write-Log ('MDM Bridge result value ({0}): {1}' -f $BridgeResultCls, (Get-BridgeResultValue))
            }
            else {
                Write-Log 'MDM Bridge result value: skipped (requires SYSTEM).'
            }

            $stateExists = Test-Path -LiteralPath $StateKey
            Write-Log ('State key {0}: {1}' -f $StateKey, $(if ($stateExists) { 'present' } else { 'absent' }))

            Complete-Run -ExitCode 0 -Result 'Discovered'
        }

        'Audit' {
            $eff = Get-EffectivePolicy
            if (Test-PolicyBlocked $eff) {
                Write-Log ('COMPLIANT: {0} is {1}.' -f $PolicyName, (Format-EffectivePolicy $eff)) 'OK'
                Complete-Run -ExitCode 0 -Result 'Compliant'
            }
            if ($eff.Present -and $eff.Kind -ne 'DWord') {
                Write-Log ('NON-COMPLIANT: {0} exists as {1}. The CSP format is int (REG_DWORD); a mis-typed value is not honored reliably.' -f $PolicyName, $eff.Kind) 'WARN'
            }
            else {
                Write-Log ('NON-COMPLIANT: {0} is {1}. Manual unenrollment is allowed.' -f $PolicyName, (Format-EffectivePolicy $eff)) 'WARN'
            }
            Complete-Run -ExitCode 1 -Result 'NonCompliant'
        }

        'Enforce' {
            $eff = Get-EffectivePolicy
            if (Test-PolicyBlocked $eff) {
                Write-Log ('Already compliant: {0} is {1}. No change made.' -f $PolicyName, (Format-EffectivePolicy $eff)) 'OK'
                Complete-Run -ExitCode 0 -Result 'AlreadyCompliant'
            }
            Write-Log ('Current effective value: {0}. Enforcing {1}={2}.' -f (Format-EffectivePolicy $eff), $PolicyName, $BlockedValue)

            $method = Invoke-PolicyWrite -Value $BlockedValue
            if (-not $method) { Complete-Run -ExitCode 2 -Result 'WriteFailed' }

            if (Wait-ForEffectivePolicy -Expected $BlockedValue) {
                Write-Log ('Verified: {0} is {1}.' -f $PolicyName, (Format-EffectivePolicy (Get-EffectivePolicy))) 'OK'
                Complete-Run -ExitCode 0 -Result 'Enforced' -Method $method
            }

            if ($method -eq 'WmiBridge' -and $TryRegistry) {
                Write-Log 'Bridge write did not materialize in PolicyManager\current. Applying the registry fallback as well.' 'WARN'
                try {
                    Set-PolicyViaRegistry -Value $BlockedValue
                    $method = 'WmiBridge+Registry'
                    if (Wait-ForEffectivePolicy -Expected $BlockedValue) {
                        Write-Log ('Verified: {0} is {1}.' -f $PolicyName, (Format-EffectivePolicy (Get-EffectivePolicy))) 'OK'
                        Complete-Run -ExitCode 0 -Result 'Enforced' -Method $method
                    }
                }
                catch {
                    Write-Log ('Registry fallback failed: {0}' -f $_.Exception.Message) 'ERROR'
                }
            }

            Write-Log 'Write succeeded but the effective value did not reach the desired state. Another provider may own this policy.' 'WARN'
            Complete-Run -ExitCode 1 -Result 'VerificationFailed' -Method $method
        }

        'Revert' {
            $eff = Get-EffectivePolicy
            if (Test-PolicyDefault $eff) {
                Write-Log ('Already at default: {0} is {1}. No change made.' -f $PolicyName, (Format-EffectivePolicy $eff)) 'OK'
                Complete-Run -ExitCode 0 -Result 'AlreadyDefault'
            }
            Write-Log ('Current effective value: {0}. Reverting {1} to {2}.' -f (Format-EffectivePolicy $eff), $PolicyName, $DefaultValue)

            $method = Invoke-PolicyWrite -Value $DefaultValue
            if (-not $method) { Complete-Run -ExitCode 2 -Result 'WriteFailed' }

            if (Wait-ForEffectivePolicy -Expected $DefaultValue -AllowAbsent) {
                Write-Log ('Verified: {0} is {1}.' -f $PolicyName, (Format-EffectivePolicy (Get-EffectivePolicy))) 'OK'
                Complete-Run -ExitCode 0 -Result 'Reverted' -Method $method
            }

            if ($method -eq 'WmiBridge' -and $TryRegistry) {
                Write-Log 'Bridge write did not materialize in PolicyManager\current. Applying the registry fallback as well.' 'WARN'
                try {
                    Set-PolicyViaRegistry -Value $DefaultValue
                    $method = 'WmiBridge+Registry'
                    if (Wait-ForEffectivePolicy -Expected $DefaultValue -AllowAbsent) {
                        Write-Log ('Verified: {0} is {1}.' -f $PolicyName, (Format-EffectivePolicy (Get-EffectivePolicy))) 'OK'
                        Complete-Run -ExitCode 0 -Result 'Reverted' -Method $method
                    }
                }
                catch {
                    Write-Log ('Registry fallback failed: {0}' -f $_.Exception.Message) 'ERROR'
                }
            }

            Write-Log 'Write succeeded but the effective value did not reach the default. Another provider (for example your MDM) may still enforce 0.' 'WARN'
            Complete-Run -ExitCode 1 -Result 'VerificationFailed' -Method $method
        }
    }
}
catch {
    Write-Log ('Unhandled error: {0}' -f $_.Exception.Message) 'ERROR'
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERROR' }
    exit 2
}
