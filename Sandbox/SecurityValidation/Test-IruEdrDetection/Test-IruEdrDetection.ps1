<#
.SYNOPSIS
    Generates AV/EDR test artifacts in a Defender-excluded path so Iru EDR can be
    observed detecting them, rather than losing the race to Microsoft Defender.

.DESCRIPTION
    On Windows, Microsoft Defender owns the filesystem minifilter and gets first
    look at every write. Unless a third-party AV registers with Windows Security
    Center (which makes Defender step aside - disabled mode on devices that are
    not onboarded to Defender for Endpoint, passive mode when they are), Defender
    wins every commodity-signature race and Iru EDR never gets to report the
    detection.

    This script scopes a narrow Defender exclusion to a single test directory,
    writes EICAR test artifacts into it, waits, and reports which artifacts were
    removed. Because Defender is excluded from that path, any quarantine that
    occurs there is attributable to Iru EDR.

    EICAR is a 68-byte industry-standard test string with no payload. It is
    assembled at runtime from fragments so this script file does not itself
    match the signature and get quarantined before it can run.

    Modes:
      Audit    - Report whether today's test has run. Exit 1 signals Iru to run
                 the remediation slot.
      Enforce  - Set the exclusion, generate artifacts, wait, report results.
      Discover - Read-only inventory of the AV stack. Changes nothing.
      Revert   - Remove the exclusion, the artifacts, and the stored state.

    LAB USE ONLY. This deliberately weakens Defender on the target path. Scope
    it to isolated test devices and run Revert when finished.

    Designed for deployment as an Iru Windows Custom Script Library Item running
    as NT AUTHORITY\SYSTEM. Pair the same script in the Audit slot
    ($Mode = 'Audit') and Remediation slot ($Mode = 'Enforce').

.NOTES
    File     : Test-IruEdrDetection.ps1
    Version  : 2.0.0 (2026-09-15) - consolidated from the former 'audit' and
               'remediation' copies, which differed only in the Mode default
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Target   : Windows 11 24H2 or later
    Runs as  : SYSTEM or local Administrator (elevation required)
    PS       : Windows PowerShell 5.1 (in-box Defender and Archive modules only)

    ENCODING: this file is deliberately pure ASCII. Non-ASCII punctuation such
    as em dashes and curly quotes gets mangled when the agent writes the script
    to its cache without a BOM, and Windows PowerShell 5.1 treats curly quotes
    as valid string delimiters, which produces an unterminated-string parser
    error. Keep any edits ASCII-only.

    Exit codes:
      0 = compliant (Audit) / operation succeeded
      1 = non-compliant (Audit: today's test has not run) or a runtime failure
      2 = precondition failure (not elevated, invalid configuration)

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
# Defaults to Audit because this script weakens Defender on purpose; pasting it
# unmodified must never change a device. Set 'Enforce' in the Remediation slot.
$Mode = 'Audit'

# Directory that receives the test artifacts and is excluded from Defender.
$TestPath = Join-Path $env:ProgramData 'IruScripts\EdrTest\badfiles'

# Seconds to wait after writing artifacts before evaluating what survived.
# Allowed range 5-600.
$SettleSeconds = 45

# $true writes the artifacts WITHOUT adding a Defender exclusion. Use it to
# demonstrate that Defender wins the race when no exclusion is present.
$SkipExclusion = $false

# Service name patterns used only to report whether the Iru agent is present.
# Adjust if the agent service is named differently in your tenant.
$AgentServicePattern = @('*iru*', '*kandji*')

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Test-IruEdrDetection.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '2.0.0'

# Unchanged from the v1 copies so Revert still finds state they wrote.
$StateKey = 'HKLM:\SOFTWARE\IruScripts\EdrTestFiles'

$ExitSuccess      = 0
$ExitFailure      = 1   # also: Audit non-compliant
$ExitPrecondition = 2

$ErrorActionPreference = 'Stop'

# =============================================================================
# LOGGING
# =============================================================================

function Write-Log {
    # Uses Write-Host deliberately: the mode functions return their exit code
    # through the pipeline, so Write-Output here would corrupt those returns.
    # Write-Host still reaches stdout when powershell.exe runs non-interactively,
    # which is how the Iru agent captures it.
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never be the reason the script fails.
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

# =============================================================================
# PREFLIGHT
# =============================================================================

function Test-IsElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Configuration {
    $ok = $true
    if (@('Audit', 'Enforce', 'Discover', 'Revert') -notcontains $Mode) {
        Write-Log "Unknown Mode '$Mode'. Valid: Enforce, Audit, Discover, Revert." -Level ERROR
        $ok = $false
    }
    if ($SettleSeconds -lt 5 -or $SettleSeconds -gt 600) {
        Write-Log "SettleSeconds = $SettleSeconds is outside the allowed range 5-600." -Level ERROR
        $ok = $false
    }
    if ([string]::IsNullOrWhiteSpace($TestPath)) {
        Write-Log 'TestPath is empty.' -Level ERROR
        $ok = $false
    }
    return $ok
}

# =============================================================================
# STATE
# =============================================================================

function Get-State {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $StateKey)) { return $null }
        $item = Get-ItemProperty -LiteralPath $StateKey -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}

function Set-State {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    if (-not (Test-Path -LiteralPath $StateKey)) {
        New-Item -Path $StateKey -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $StateKey -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Remove-State {
    try {
        if (Test-Path -LiteralPath $StateKey) {
            Remove-Item -LiteralPath $StateKey -Recurse -Force
            Write-Log "Removed state key $StateKey"
        }
    }
    catch {
        Write-Log "Could not remove state key: $($_.Exception.Message)" -Level WARN
    }
}

# =============================================================================
# AV STACK INSPECTION
# =============================================================================

function Get-RegisteredAvProduct {
    # Products registered with Windows Security Center. If a third-party AV
    # appears here, Defender should have stepped aside on its own (disabled
    # mode, or passive mode when onboarded to Defender for Endpoint).
    try {
        $products = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop
        return @($products | Select-Object displayName, productState, pathToSignedProductExe)
    }
    catch {
        Write-Log "Could not query Security Center: $($_.Exception.Message)" -Level WARN
        return @()
    }
}

function Get-DefenderStatus {
    $present         = $false
    $realTimeEnabled = $null
    $runningMode     = 'Unknown'
    $tamperProtected = $null

    try {
        $status  = Get-MpComputerStatus -ErrorAction Stop
        $present = $true
        $props   = $status.PSObject.Properties.Name

        if ($props -contains 'RealTimeProtectionEnabled') { $realTimeEnabled = $status.RealTimeProtectionEnabled }
        # AMRunningMode and IsTamperProtected are absent on older builds.
        if ($props -contains 'AMRunningMode')     { $runningMode     = $status.AMRunningMode }
        if ($props -contains 'IsTamperProtected') { $tamperProtected = $status.IsTamperProtected }
    }
    catch {
        Write-Log "Defender cmdlets unavailable: $($_.Exception.Message)" -Level WARN
    }

    return [PSCustomObject]@{
        Present         = $present
        RealTimeEnabled = $realTimeEnabled
        RunningMode     = $runningMode
        TamperProtected = $tamperProtected
    }
}

function Test-ExclusionPresent {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $current = (Get-MpPreference -ErrorAction Stop).ExclusionPath
        if (-not $current) { return $false }
        foreach ($entry in $current) {
            if ($entry -eq $Path) { return $true }
        }
        return $false
    }
    catch {
        Write-Log "Could not read Defender exclusions: $($_.Exception.Message)" -Level WARN
        return $false
    }
}

function Add-TestExclusion {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-ExclusionPresent -Path $Path) {
        Write-Log "Defender exclusion already present for $Path"
        return $true
    }

    try {
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
    }
    catch {
        Write-Log "Add-MpPreference failed: $($_.Exception.Message)" -Level ERROR
        return $false
    }

    # Tamper Protection can reject the change without raising an error, so the
    # write is verified rather than assumed.
    Start-Sleep -Seconds 2

    if (Test-ExclusionPresent -Path $Path) {
        Write-Log "Added Defender exclusion for $Path"
        Set-State -Name 'ExclusionAdded' -Value '1'
        return $true
    }

    Write-Log 'Exclusion did not persist. Tamper Protection is likely enabled. Set the exclusion via policy instead.' -Level ERROR
    return $false
}

function Remove-TestExclusion {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-ExclusionPresent -Path $Path)) { return }

    try {
        Remove-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Write-Log "Removed Defender exclusion for $Path"
    }
    catch {
        Write-Log "Could not remove exclusion: $($_.Exception.Message)" -Level WARN
    }
}

function Get-RecentDefenderDetection {
    param([int]$MinutesBack = 10)
    try {
        $since  = (Get-Date).AddMinutes(-$MinutesBack)
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-Windows Defender/Operational'
            Id        = 1116, 1117
            StartTime = $since
        } -ErrorAction Stop
        return @($events | Select-Object TimeCreated, Id)
    }
    catch {
        return @()
    }
}

function Get-AgentPresence {
    $found = @()
    foreach ($pattern in $AgentServicePattern) {
        $svc = Get-Service -Name $pattern -ErrorAction SilentlyContinue
        if ($svc) { $found += $svc }
    }
    return @($found | Sort-Object -Property Name -Unique)
}

# =============================================================================
# TEST ARTIFACTS
# =============================================================================

function New-EicarArtifact {
    # Writes the 68-byte EICAR string with no BOM and no trailing newline.
    # Assembled from fragments so this script does not match the signature.
    # Returns $false if a scanner removed the file before it could be verified.
    param([Parameter(Mandatory = $true)][string]$Path)

    $p1 = 'X5O!P%@AP[4\PZX54(P^)7CC)7}'
    $p2 = '$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!'
    $p3 = '$H+H*'

    $encoding = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText($Path, ($p1 + $p2 + $p3), $encoding)

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if ($item.Length -ne 68) {
        throw "EICAR artifact is $($item.Length) bytes, expected 68. Encoding problem."
    }
    return $true
}

function Copy-StagedArtifact {
    # A scanner may remove a staged file between steps. That is a detection,
    # not an error, so a vanished source is reported and skipped.
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $leaf = Split-Path -Path $Destination -Leaf
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log "  $leaf : source removed during staging (counts as detected)"
        return
    }
    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
    catch {
        Write-Log "  $leaf : copy failed - $($_.Exception.Message)" -Level WARN
    }
}

function New-TestArtifactSet {
    # Four escalating variants:
    #   eicar.com       raw
    #   eicar.com.txt   benign extension, identical bytes
    #   eicar_com.zip   one archive layer
    #   eicar_com2.zip  two archive layers
    param([Parameter(Mandatory = $true)][string]$Directory)

    $staging = Join-Path $Directory 'staging'
    New-Item -Path $staging -ItemType Directory -Force | Out-Null

    $artifacts = [ordered]@{
        'eicar.com'      = Join-Path $Directory 'eicar.com'
        'eicar.com.txt'  = Join-Path $Directory 'eicar.com.txt'
        'eicar_com.zip'  = Join-Path $Directory 'eicar_com.zip'
        'eicar_com2.zip' = Join-Path $Directory 'eicar_com2.zip'
    }

    $rawCom = Join-Path $staging 'eicar.com'
    $zip1   = Join-Path $staging 'eicar_com.zip'
    $zip2   = Join-Path $staging 'eicar_com2.zip'

    if (-not (New-EicarArtifact -Path $rawCom)) {
        Write-Log 'Raw EICAR file was removed during staging before any copies could be made.' -Level WARN
    }
    Copy-StagedArtifact -Source $rawCom -Destination $artifacts['eicar.com']
    Copy-StagedArtifact -Source $rawCom -Destination $artifacts['eicar.com.txt']

    if (Test-Path -LiteralPath $rawCom) {
        try   { Compress-Archive -LiteralPath $rawCom -DestinationPath $zip1 -Force -ErrorAction Stop }
        catch { Write-Log "Could not build eicar_com.zip: $($_.Exception.Message)" -Level WARN }
    }
    Copy-StagedArtifact -Source $zip1 -Destination $artifacts['eicar_com.zip']

    if (Test-Path -LiteralPath $zip1) {
        try   { Compress-Archive -LiteralPath $zip1 -DestinationPath $zip2 -Force -ErrorAction Stop }
        catch { Write-Log "Could not build eicar_com2.zip: $($_.Exception.Message)" -Level WARN }
    }
    Copy-StagedArtifact -Source $zip2 -Destination $artifacts['eicar_com2.zip']

    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    return $artifacts
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-DiscoverMode {
    Write-Log '=== DISCOVER: AV stack inventory (read-only) ==='

    $registered = Get-RegisteredAvProduct
    if ($registered.Count -eq 0) {
        Write-Log 'No products registered with Windows Security Center.' -Level WARN
    }
    else {
        foreach ($p in $registered) {
            $stateHex = '{0:X}' -f $p.productState
            Write-Log "Registered AV: $($p.displayName) (productState 0x$stateHex)"
        }
    }

    $thirdParty = @($registered | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' })
    if ($thirdParty.Count -gt 0) {
        $names = ($thirdParty | ForEach-Object { $_.displayName }) -join ', '
        Write-Log "Third-party AV registered: $names. Defender should have stepped aside (disabled or passive mode)."
    }
    else {
        Write-Log 'Only Defender is registered with Security Center. Defender will win commodity-signature races against any agent that does not register.' -Level WARN
    }

    $defender = Get-DefenderStatus
    Write-Log "Defender present: $($defender.Present) | RealTime: $($defender.RealTimeEnabled) | RunningMode: $($defender.RunningMode) | TamperProtected: $($defender.TamperProtected)"
    if ($defender.TamperProtected -eq $true) {
        Write-Log 'Tamper Protection is ON. Local exclusion writes may be silently rejected; push the exclusion via policy instead.' -Level WARN
    }

    $agents = Get-AgentPresence
    if ($agents.Count -gt 0) {
        foreach ($a in $agents) { Write-Log "Agent service: $($a.Name) [$($a.Status)]" }
    }
    else {
        Write-Log 'No Iru/Kandji agent service matched. Update AgentServicePattern if the service name differs.' -Level WARN
    }

    Write-Log "Test path: $TestPath (exists: $(Test-Path -LiteralPath $TestPath))"
    Write-Log "Exclusion in place: $(Test-ExclusionPresent -Path $TestPath)"
    Write-Log "Last run: $(Get-State -Name 'LastRun')"

    return $ExitSuccess
}

function Invoke-AuditMode {
    $today   = (Get-Date).ToString('yyyy-MM-dd')
    $lastRun = Get-State -Name 'LastRun'

    if ($lastRun -eq $today) {
        Write-Log "EDR file-detection test already ran $today; compliant."
        return $ExitSuccess
    }

    Write-Log "EDR file-detection test not yet run for $today; remediation required."
    return $ExitFailure
}

function Invoke-EnforceMode {
    Write-Log '=== ENFORCE: generating EDR test artifacts ==='
    $today = (Get-Date).ToString('yyyy-MM-dd')

    # Stamped before the artifacts are written. If the EDR response is aggressive
    # enough to terminate this process, the daily gate still holds and the test
    # does not re-fire on every check-in.
    Set-State -Name 'LastRun' -Value $today
    Write-Log "Stamped run date: $today"

    New-Item -Path $TestPath -ItemType Directory -Force | Out-Null
    Set-State -Name 'TestPath' -Value $TestPath

    if ($SkipExclusion) {
        Write-Log 'SkipExclusion is set. Defender will see these writes. Expect Defender to win.' -Level WARN
    }
    elseif (-not (Add-TestExclusion -Path $TestPath)) {
        Write-Log 'Proceeding without an exclusion. Results will reflect Defender, not Iru.' -Level WARN
    }

    Write-Log 'Generating test artifacts'
    $artifacts = New-TestArtifactSet -Directory $TestPath

    foreach ($name in $artifacts.Keys) {
        if (Test-Path -LiteralPath $artifacts[$name]) {
            $size = (Get-Item -LiteralPath $artifacts[$name]).Length
            Write-Log "  wrote $name ($size bytes)"
        }
        else {
            Write-Log "  wrote $name (already removed)"
        }
    }

    Write-Log "Waiting $SettleSeconds seconds for scanners to act"
    Start-Sleep -Seconds $SettleSeconds

    Write-Log '--- Results ---'
    $quarantined = 0
    foreach ($name in $artifacts.Keys) {
        if (Test-Path -LiteralPath $artifacts[$name]) {
            Write-Log "  SURVIVED  $name"
        }
        else {
            Write-Log "  REMOVED   $name"
            $quarantined++
        }
    }

    $defenderEvents = Get-RecentDefenderDetection -MinutesBack 10
    if ($defenderEvents.Count -gt 0) {
        Write-Log "Defender logged $($defenderEvents.Count) detection event(s) in the last 10 minutes. Attribution is ambiguous." -Level WARN
        foreach ($e in $defenderEvents) { Write-Log "  Defender event $($e.Id) at $($e.TimeCreated)" }
    }
    else {
        Write-Log 'No Defender detection events in the last 10 minutes.'
    }

    if ($quarantined -eq 0) {
        Write-Log 'Nothing was removed. Either Iru EDR did not detect these artifacts, or its response posture is alert-only rather than quarantine.' -Level WARN
    }
    elseif ($defenderEvents.Count -eq 0) {
        Write-Log "$quarantined of $($artifacts.Count) artifacts removed with no Defender activity. Attributable to Iru EDR."
    }

    Write-Log 'Confirm the corresponding detections in the Iru console before treating this as a pass.'
    return $ExitSuccess
}

function Invoke-RevertMode {
    Write-Log '=== REVERT: removing exclusion, artifacts, and state ==='

    $recorded = Get-State -Name 'TestPath'
    if ($recorded) { $target = $recorded } else { $target = $TestPath }

    Remove-TestExclusion -Path $target

    if (Test-Path -LiteralPath $target) {
        try {
            Remove-Item -LiteralPath $target -Recurse -Force
            Write-Log "Removed test directory $target"
        }
        catch {
            Write-Log "Could not fully remove $target - $($_.Exception.Message)" -Level WARN
        }
    }

    Remove-State
    return $ExitSuccess
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Test-IruEdrDetection v$ScriptVersion starting in mode: $Mode (as $env:USERNAME)"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' -Level ERROR
    exit $ExitPrecondition
}

if (-not (Test-Configuration)) {
    Write-Log 'Configuration is not valid - nothing was changed.' -Level ERROR
    exit $ExitPrecondition
}

try {
    $code = $ExitFailure
    switch ($Mode) {
        'Audit'    { $code = Invoke-AuditMode }
        'Enforce'  { $code = Invoke-EnforceMode }
        'Discover' { $code = Invoke-DiscoverMode }
        'Revert'   { $code = Invoke-RevertMode }
    }
    Write-Log "Completed. Exit code: $code"
    exit $code
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level ERROR
    Write-Log "$($_.ScriptStackTrace)" -Level ERROR
    exit $ExitFailure
}
