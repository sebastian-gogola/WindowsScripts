<#
.SYNOPSIS
    Provisioning-time wrapper around Iru's official mdmmigration.ps1, so Iru
    enrollment can be dropped into an existing Windows provisioning package
    (ProvisioningCommands) or OSDCloud post-install flow without modifying the
    official script.

.DESCRIPTION
    The official migration script (Iru WindowsScripts\mdmmigration.ps1) already
    does the enrollment work: it fetches a token from the Iru gateway, removes
    any foreign MDM enrollment and registers the device with Iru through the
    Windows MDM registration API. It assumes, however, that it runs on a device
    that is already set up and online. This wrapper adds what a provisioning
    context needs around it and nothing else:

      * Preconditions that make sense at OOBE: elevation, Windows 11 24H2 or
        later (Iru supports 24H2 and 25H2 only), the migration script present
        next to this file, all tenant values supplied.
      * A network wait. Provisioning commands fire before the user has had a
        chance to join Wi-Fi; the wrapper polls the tenant's Iru endpoints and
        only launches the migration script once they answer.
      * A time sync attempt. Fresh devices often boot with a skewed clock,
        which breaks TLS to the gateway.
      * A one-shot retry task. If the endpoints never answer inside the wait
        budget, the bundle is staged to ProgramData and a SYSTEM scheduled task
        retries at the next startup once the network is available.
      * Evidence. Setup phase, the identity Windows would report, existing MDM
        enrollments before and after, the migration script's own output and
        its exit code are all captured in one log for the proof of concept.

    The migration script is always launched as a child process. It calls
    'exit' internally, which would terminate a caller that dot-sourced it. For
    the same reason, call THIS script as a child process from an orchestrator
    (powershell.exe -File ...), never with '&' or '.'.

    Modes:
      Enroll   - waits for network, runs mdmmigration.ps1, records the outcome
      Probe    - changes nothing: reports preconditions, setup phase, identity,
                 endpoint reachability and existing enrollments, then runs
                 mdmmigration.ps1 -DiagnoseOnly (read-only). Use this for the
                 first run on the prospect's hardware.

    Where it runs:
      * Provisioning package: ProvisioningCommands run as SYSTEM during OOBE,
        before any user account exists, with the command files' temp folder as
        the working directory. Either make this file the package's single
        CommandLine, or call it from the orchestrator script the package
        already runs. See README.md.
      * OSDCloud: drop this file and mdmmigration.ps1 into the post-install
        script location the workspace already uses. See README.md.

    Settings come from the CONFIGURATION block. Command-line parameters, when
    supplied, override the block so an existing orchestrator can pass tenant
    values without editing this file. Iru Custom Script Library Items are not
    the intended runtime for this script; it belongs to the provisioning flow.

.NOTES
    File     : Invoke-IruEnrollment.ps1
    Version  : 1.0.0 (2026-09-17)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM (provisioning engine, OSDCloud SetupComplete, scheduled
               task) or an elevated administrator for manual testing
    PS       : Windows PowerShell 5.1 (no external modules)
    Requires : Iru WindowsScripts\mdmmigration.ps1 (unmodified) beside this file

    Exit codes:
      0 = enrolled, already enrolled, or handed off to the retry task
      1 = the migration script failed, timed out, or the network never came
          up and no retry could be scheduled
      2 = precondition failure (not elevated, OS below 24H2, script missing,
          incomplete configuration)

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

# Optional command-line overrides. Everything here has a default in the
# CONFIGURATION block; only supply what the calling orchestrator wants to
# override. -FromRetryTask is set by the scheduled task this script registers.
param(
    [string]$Mode,
    [string]$TenantName,
    [string]$BlueprintId,
    [string]$EnrollmentCode,
    [string]$TenantId,
    [string]$TenantLocation,
    [string]$RunSource,
    [switch]$FromRetryTask
)

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Mode: 'Enroll' | 'Probe'
$ConfigMode = 'Enroll'

# Iru tenant values. Same meaning as the mdmmigration.ps1 parameters; the
# official mdmmigration.md explains where each one lives in the Iru console.
#   TenantName     - sign-in URL prefix: https://contoso.iru.com  -> 'contoso'
#   BlueprintId    - GUID from the blueprint URL in the console
#   EnrollmentCode - Enrollment > Manual Enrollment code for that blueprint.
#                    The blueprint must NOT have Require Authentication on.
#   TenantId       - Device Domain prefix: 8134cc6c.web-api.kandji.io -> '8134cc6c'
#   TenantLocation - 'US' | 'EU'
$ConfigTenantName     = ''
$ConfigBlueprintId    = ''
$ConfigEnrollmentCode = ''
$ConfigTenantId       = ''
$ConfigTenantLocation = 'US'

# Label recorded in the log and state key so runs from different entry points
# can be told apart, e.g. 'PPKG', 'OSDCloud', 'Manual'. Overridable with
# -RunSource; the retry task always records 'RetryTask'.
$ConfigRunSource = 'PPKG'

# Path to the unmodified official migration script. Default: beside this file.
# A provisioning package copies every CommandFile into one folder and makes it
# the working directory, so the default holds there and for OSDCloud folders.
$MigrationScriptName = 'mdmmigration.ps1'

# Pass -Debug to mdmmigration.ps1 (verbose API logging in its own log file).
$MigrationDebug = $false

# Skip the network wait and the migration script when a Kandji/Iru primary
# enrollment is already present. The migration script would reach the same
# conclusion, but this avoids waiting for network on a device that is done.
$SkipWhenAlreadyEnrolled = $true

# Network wait. The provisioning engine allows 30 minutes for ALL commands in
# a package, so keep wait + run comfortably below that.
$NetworkWaitSeconds     = 300
$NetworkPollSeconds     = 10
$TcpConnectTimeoutMs    = 5000

# Hard limit for the migration script child process. On timeout it is killed
# and the run is reported as failed. A fresh device without a prior MDM
# enrollment normally finishes in well under two minutes.
$MigrationTimeoutSeconds = 1200

# Try to sync the clock before contacting the gateway (starts W32Time if
# needed). Failures are logged, never fatal.
$ForceTimeSync = $true

# Minimum Windows build. 26100 = Windows 11 24H2. Iru supports 24H2 and 25H2.
$RequiredOsBuild = 26100

# Retry task when the endpoints never answer inside $NetworkWaitSeconds.
# Stages this script, the migration script and the tenant values (including
# the enrollment code) under $RetryStagingDirectory, registers a SYSTEM task
# at startup with a network-available condition, and removes everything again
# after success or after $RetryMaxAttempts.
$RegisterRetryTask     = $true
# Also schedule the retry when the migration script itself fails (any exit
# code other than 0 or 3). Off by default so a real failure is visible at
# provisioning time; useful during the proof of concept when the first attempt
# may fire in a setup phase where MDM registration is not yet possible.
$RetryOnMigrationFailure = $false
$RetryMaxAttempts      = 5
$RetryTaskName         = 'IruScripts-EnrollmentRetry'
$RetryStartupDelay     = 'PT2M'     # ISO 8601 duration after boot
$RetryStagingDirectory = Join-Path $env:ProgramData 'IruScripts\Enrollment'

# Exit code to return when the retry task was scheduled successfully. 0 lets
# an orchestrator that aborts on non-zero continue; use 1 if the orchestrator
# should treat "not enrolled yet" as a failure.
$ExitCodeWhenRetryScheduled = 0

# Probe mode only: also request an enrollment token from the gateway to prove
# the tenant values are accepted. The token is never written to the log. Off
# by default because it exercises the gateway with the real enrollment code.
$ProbeFetchToken = $false

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Invoke-IruEnrollment.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion   = '1.0.0'
$StateKey        = 'HKLM:\SOFTWARE\IruScripts\Enrollment'
$EnrollmentsRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$SetupKey        = 'HKLM:\SYSTEM\Setup'
$SessionDataKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\SessionData'
$RetryConfigName = 'enrollment.json'
$WrapperFileName = 'Invoke-IruEnrollment.ps1'

# Exit codes documented for mdmmigration.ps1 (see its header and mdmmigration.md)
$MigrationExitSuccess         = 0
$MigrationExitResidualBlocked = 3

# Subkeys under HKLM\SOFTWARE\Microsoft\Enrollments that are not enrollments
$EnrollmentsNonEnrollmentKeys = @('Status', 'Ownership', 'ValidNodePaths', 'Context')

$script:FailureCount = 0

# =============================================================================
# LOGGING
# =============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
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
}

# =============================================================================
# STATE
# =============================================================================

function Set-StateValue {
    param([string]$Name, $Value)
    try {
        if (-not (Test-Path -Path $StateKey)) {
            New-Item -Path $StateKey -Force | Out-Null
        }
        New-ItemProperty -Path $StateKey -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    } catch {
        Write-Log "Could not write state value '$Name': $($_.Exception.Message)" 'WARN'
    }
}

function Get-StateValue {
    param([string]$Name)
    try {
        $item = Get-ItemProperty -Path $StateKey -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch {
        return $null
    }
}

function Write-RunState {
    param([string]$Result, [string]$Detail)
    Set-StateValue -Name 'LastRun'        -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Set-StateValue -Name 'LastMode'       -Value $script:ResolvedMode
    Set-StateValue -Name 'LastSource'     -Value $script:ResolvedRunSource
    Set-StateValue -Name 'LastResult'     -Value $Result
    Set-StateValue -Name 'LastDetail'     -Value $Detail
    Set-StateValue -Name 'WrapperVersion' -Value $ScriptVersion
}

# =============================================================================
# PREFLIGHT
# =============================================================================

function Test-IsElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsInfo {
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = 0
    if ($cv -and $cv.CurrentBuildNumber) { $build = [int]$cv.CurrentBuildNumber }
    $ubr = ''
    if ($cv -and ($cv.PSObject.Properties.Match('UBR').Count -gt 0)) { $ubr = [string]$cv.UBR }
    $display = ''
    if ($cv -and ($cv.PSObject.Properties.Match('DisplayVersion').Count -gt 0)) { $display = [string]$cv.DisplayVersion }
    $edition = ''
    if ($cv -and $cv.EditionID) { $edition = [string]$cv.EditionID }
    [pscustomobject]@{
        Build          = $build
        Ubr            = $ubr
        DisplayVersion = $display
        Edition        = $edition
        Is64BitOs      = [Environment]::Is64BitOperatingSystem
        Is64BitProcess = [Environment]::Is64BitProcess
    }
}

function Get-SetupState {
    # Values under HKLM\SYSTEM\Setup that Windows flips during OOBE. Read for
    # evidence only; nothing here gates the run. Community-observed names.
    $result = [ordered]@{}
    foreach ($name in @('OOBEInProgress', 'SystemSetupInProgress', 'SetupPhase', 'SetupType')) {
        try {
            $item = Get-ItemProperty -Path $SetupKey -Name $name -ErrorAction Stop
            $result[$name] = [string]$item.$name
        } catch {
            $result[$name] = '(absent)'
        }
    }
    return $result
}

function Get-SessionIdentitySummary {
    # Mirrors the first step of Get-InteractiveUserUpn in mdmmigration.ps1 so
    # the log shows which identity the migration script will attach to the
    # enrollment. During OOBE this is typically the temporary defaultuser0
    # account, which is cosmetic for an MDM-only enrollment.
    $entries = @()
    try {
        if (Test-Path -Path $SessionDataKey) {
            foreach ($key in (Get-ChildItem -Path $SessionDataKey -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                $sid = ''
                $user = ''
                if ($props) {
                    if ($props.PSObject.Properties.Match('LoggedOnUserSID').Count -gt 0) { $sid = [string]$props.LoggedOnUserSID }
                    if ($props.PSObject.Properties.Match('LoggedOnUser').Count -gt 0)    { $user = [string]$props.LoggedOnUser }
                }
                $entries += ('Session {0}: user={1} sid={2}' -f $key.PSChildName, $user, $sid)
            }
        }
    } catch {
        $entries += ('SessionData unreadable: {0}' -f $_.Exception.Message)
    }
    if ($entries.Count -eq 0) { $entries += 'no SessionData entries (no interactive session yet)' }
    return $entries
}

function Get-EnrollmentSummary {
    # Lists MDM enrollments the way mdmmigration.ps1 sees them. ProviderID is
    # what identifies the MDM; the Kandji/Iru match below is the same rule the
    # migration script uses to decide a device is already on the target stack.
    $list = @()
    try {
        if (-not (Test-Path -Path $EnrollmentsRoot)) { return $list }
        foreach ($key in (Get-ChildItem -Path $EnrollmentsRoot -ErrorAction SilentlyContinue)) {
            if ($EnrollmentsNonEnrollmentKeys -contains $key.PSChildName) { continue }
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            $provider = ''
            $enrollType = ''
            $enrollState = ''
            $discovery = ''
            $upn = ''
            if ($props) {
                if ($props.PSObject.Properties.Match('ProviderID').Count -gt 0)               { $provider    = [string]$props.ProviderID }
                if ($props.PSObject.Properties.Match('EnrollmentType').Count -gt 0)           { $enrollType  = [string]$props.EnrollmentType }
                if ($props.PSObject.Properties.Match('EnrollmentState').Count -gt 0)          { $enrollState = [string]$props.EnrollmentState }
                if ($props.PSObject.Properties.Match('DiscoveryServiceFullURL').Count -gt 0)  { $discovery   = [string]$props.DiscoveryServiceFullURL }
                if ($props.PSObject.Properties.Match('UPN').Count -gt 0)                      { $upn         = [string]$props.UPN }
            }
            if ([string]::IsNullOrEmpty($provider) -and [string]::IsNullOrEmpty($discovery)) { continue }
            $list += [pscustomobject]@{
                Id              = $key.PSChildName
                ProviderId      = $provider
                EnrollmentType  = $enrollType
                EnrollmentState = $enrollState
                DiscoveryUrl    = $discovery
                Upn             = $upn
                IsKandjiOrIru   = (Test-IsKandjiOrIruProviderId -ProviderId $provider)
            }
        }
    } catch {
        Write-Log "Could not enumerate enrollments: $($_.Exception.Message)" 'WARN'
    }
    return $list
}

function Test-IsKandjiOrIruProviderId {
    # Same rule as mdmmigration.ps1: 'kandji' or 'iru' at a word boundary.
    param([string]$ProviderId)
    if ([string]::IsNullOrWhiteSpace($ProviderId)) { return $false }
    return ($ProviderId.ToLowerInvariant() -match '(^|[^a-z0-9])(kandji|iru)')
}

function Write-EnrollmentSummary {
    param([string]$Label)
    $enrollments = @(Get-EnrollmentSummary)
    Write-Log ("{0}: {1} MDM enrollment(s) present" -f $Label, $enrollments.Count)
    foreach ($e in $enrollments) {
        Write-Log ("  {0}  ProviderID='{1}' Type={2} State={3} UPN='{4}' Discovery='{5}'" -f $e.Id, $e.ProviderId, $e.EnrollmentType, $e.EnrollmentState, $e.Upn, $e.DiscoveryUrl)
    }
    return $enrollments
}

# =============================================================================
# TENANT VALUES AND ENDPOINTS
# =============================================================================

function Get-IruEndpointHosts {
    # The two hosts mdmmigration.ps1 talks to, derived exactly the way its
    # Build-EnrollmentUrl and Build-ManagementUrl functions derive them.
    param([string]$TenantName, [string]$TenantId, [string]$TenantLocation)
    $loc = $TenantLocation.Trim().ToUpperInvariant()
    if ($loc -eq 'EU') {
        return @(
            ('{0}.gateway.eu.iru.com' -f $TenantName),
            ('{0}.web-api.eu.kandji.io' -f $TenantId.ToLowerInvariant())
        )
    }
    return @(
        ('{0}.gateway.iru.com' -f $TenantName),
        ('{0}.web-api.kandji.io' -f $TenantId.ToLowerInvariant())
    )
}

function Get-IruEnrollmentUrl {
    param([string]$TenantName, [string]$BlueprintId, [string]$EnrollmentCode, [string]$TenantLocation)
    $loc = $TenantLocation.Trim().ToUpperInvariant()
    if ($loc -eq 'EU') {
        return ('https://{0}.gateway.eu.iru.com/main-backend/app/v1/mdm/enroll-ota/{1}?code={2}&platform=windows' -f $TenantName, $BlueprintId, $EnrollmentCode)
    }
    return ('https://{0}.gateway.iru.com/main-backend/app/v1/mdm/enroll-ota/{1}?code={2}&platform=windows' -f $TenantName, $BlueprintId, $EnrollmentCode)
}

function Test-TenantValues {
    param([hashtable]$Values)
    $ok = $true
    if ([string]::IsNullOrWhiteSpace($Values.TenantName)) {
        Write-Log 'TenantName is empty.' 'ERROR'; $ok = $false
    } elseif ($Values.TenantName.Contains('.')) {
        Write-Log "TenantName must be the URL prefix only ('contoso', not 'contoso.iru.com')." 'ERROR'; $ok = $false
    }
    if ([string]::IsNullOrWhiteSpace($Values.BlueprintId) -or $Values.BlueprintId.Length -lt 5) {
        Write-Log 'BlueprintId is empty or too short.' 'ERROR'; $ok = $false
    }
    if ([string]::IsNullOrWhiteSpace($Values.EnrollmentCode)) {
        Write-Log 'EnrollmentCode is empty.' 'ERROR'; $ok = $false
    }
    if ([string]::IsNullOrWhiteSpace($Values.TenantId) -or ($Values.TenantId -match '\s')) {
        Write-Log 'TenantId is empty or contains whitespace.' 'ERROR'; $ok = $false
    }
    $loc = ''
    if ($Values.TenantLocation) { $loc = $Values.TenantLocation.Trim().ToUpperInvariant() }
    if ($loc -ne 'US' -and $loc -ne 'EU') {
        Write-Log "TenantLocation must be 'US' or 'EU'." 'ERROR'; $ok = $false
    }
    return $ok
}

function Test-TcpEndpoint {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Wait-ForIruEndpoints {
    param([string[]]$Hosts, [int]$MaxSeconds)
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    $attempt = 0
    do {
        $attempt++
        $allUp = $true
        $status = @()
        foreach ($h in $Hosts) {
            $up = Test-TcpEndpoint -HostName $h -Port 443 -TimeoutMs $TcpConnectTimeoutMs
            if (-not $up) { $allUp = $false }
            $status += ('{0}:443={1}' -f $h, $(if ($up) { 'reachable' } else { 'unreachable' }))
        }
        Write-Log ("Network check {0}: {1}" -f $attempt, ($status -join ', '))
        if ($allUp) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds $NetworkPollSeconds
    } while ($true)
}

function Invoke-TimeSync {
    try {
        $svc = Get-Service -Name 'W32Time' -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Start-Service -Name 'W32Time' -ErrorAction Stop
            Write-Log 'Started W32Time service.'
        }
        $out = & w32tm.exe /resync /nowait 2>&1
        Write-Log ("w32tm /resync: {0}" -f (($out | Out-String).Trim() -replace '\s+', ' '))
    } catch {
        Write-Log "Time sync attempt failed (continuing): $($_.Exception.Message)" 'WARN'
    }
    Write-Log ("System time (UTC): {0}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
}

function Test-GatewayToken {
    # Probe only. Same GET the migration script performs; reports whether an
    # access token came back without ever logging it.
    param([string]$Url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $content = [string]$response.Content
        $hasToken = ($content -match 'accesstoken' -or $content -match 'access_token')
        Write-Log ("Gateway responded HTTP {0}, {1} chars, token present: {2}" -f [int]$response.StatusCode, $content.Length, $hasToken)
        return $hasToken
    } catch {
        Write-Log "Gateway token request failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# =============================================================================
# MIGRATION SCRIPT LAUNCH
# =============================================================================

function Get-PowerShellHostPath {
    # Prefer the 64-bit host. Under a 32-bit process on 64-bit Windows,
    # Sysnative reaches the real System32.
    $sysnative = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem -and (Test-Path -Path $sysnative)) {
        return $sysnative
    }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Invoke-MigrationScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Values,
        [switch]$DiagnoseOnly
    )

    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outLog = Join-Path $LogDirectory ("Invoke-IruEnrollment-mdmmigration_{0}.out.log" -f $stamp)
    $errLog = Join-Path $LogDirectory ("Invoke-IruEnrollment-mdmmigration_{0}.err.log" -f $stamp)

    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $ScriptPath)
    )
    if ($DiagnoseOnly) {
        $argList += '-DiagnoseOnly'
    } else {
        $argList += @(
            '-TenantName',     ('"{0}"' -f $Values.TenantName),
            '-BlueprintId',    ('"{0}"' -f $Values.BlueprintId),
            '-EnrollmentCode', ('"{0}"' -f $Values.EnrollmentCode),
            '-TenantId',       ('"{0}"' -f $Values.TenantId),
            '-TenantLocation', ('"{0}"' -f $Values.TenantLocation),
            '-Silent'
        )
        if ($MigrationDebug) { $argList += '-Debug' }
    }

    $hostPath = Get-PowerShellHostPath
    Write-Log ("Launching migration script: {0} {1}" -f $hostPath, (($argList -join ' ') -replace '-EnrollmentCode "[^"]*"', '-EnrollmentCode "***"'))

    $proc = $null
    try {
        $proc = Start-Process -FilePath $hostPath -ArgumentList $argList -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog -ErrorAction Stop
    } catch {
        Write-Log "Failed to start the migration script: $($_.Exception.Message)" 'ERROR'
        return $null
    }

    $finished = $proc.WaitForExit($MigrationTimeoutSeconds * 1000)
    if (-not $finished) {
        Write-Log ("Migration script still running after {0} seconds; terminating it." -f $MigrationTimeoutSeconds) 'ERROR'
        try { $proc.Kill() } catch { }
        $exit = $null
    } else {
        $exit = $proc.ExitCode
    }

    # Fold the child's output into this log so the evidence is in one place.
    foreach ($f in @($outLog, $errLog)) {
        if (Test-Path -Path $f) {
            $lines = @(Get-Content -Path $f -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($lines.Count -gt 0) {
                Write-Log ("---- mdmmigration.ps1 {0} ({1} lines) ----" -f (Split-Path $f -Leaf), $lines.Count)
                foreach ($l in $lines) { Write-Log ("  | {0}" -f $l) }
                Write-Log '---- end ----'
            }
            Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
        }
    }

    return $exit
}

function Format-ExitCode {
    param($Code)
    if ($null -eq $Code) { return 'none (timed out)' }
    return ('{0} (0x{1:X8})' -f $Code, ([int]$Code -band 0xFFFFFFFF))
}

# =============================================================================
# RETRY TASK
# =============================================================================

function Save-RetryBundle {
    param([string]$WrapperPath, [string]$MigrationPath, [hashtable]$Values)
    try {
        if (-not (Test-Path -Path $RetryStagingDirectory)) {
            New-Item -Path $RetryStagingDirectory -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $WrapperPath   -Destination (Join-Path $RetryStagingDirectory $WrapperFileName)     -Force -ErrorAction Stop
        Copy-Item -Path $MigrationPath -Destination (Join-Path $RetryStagingDirectory $MigrationScriptName) -Force -ErrorAction Stop
        $config = [ordered]@{
            TenantName     = $Values.TenantName
            BlueprintId    = $Values.BlueprintId
            EnrollmentCode = $Values.EnrollmentCode
            TenantId       = $Values.TenantId
            TenantLocation = $Values.TenantLocation
            StagedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            StagedBy       = $script:ResolvedRunSource
        }
        ($config | ConvertTo-Json) | Set-Content -Path (Join-Path $RetryStagingDirectory $RetryConfigName) -Encoding ASCII -Force
        return $true
    } catch {
        Write-Log "Could not stage the retry bundle: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Register-RetryTask {
    $stagedWrapper = Join-Path $RetryStagingDirectory $WrapperFileName
    $arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -FromRetryTask' -f $stagedWrapper)
    try {
        $action    = New-ScheduledTaskAction -Execute (Get-PowerShellHostPath) -Argument $arguments
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = $RetryStartupDelay
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $RetryTaskName -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Description 'Retries Iru MDM enrollment (Invoke-IruEnrollment.ps1) once the network is available. Self-removing.' `
            -Force -ErrorAction Stop | Out-Null
        Write-Log ("Registered retry task '{0}' (at startup, delay {1}, network required)." -f $RetryTaskName, $RetryStartupDelay) 'OK'
        return $true
    } catch {
        Write-Log "Could not register the retry task: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Remove-RetryArtifacts {
    param([string]$Reason)
    try {
        $task = Get-ScheduledTask -TaskName $RetryTaskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $RetryTaskName -Confirm:$false -ErrorAction Stop
            Write-Log ("Removed retry task '{0}' ({1})." -f $RetryTaskName, $Reason)
        }
    } catch {
        Write-Log "Could not remove the retry task: $($_.Exception.Message)" 'WARN'
    }
    # The staged copy holds the enrollment code; do not leave it behind. When
    # this very run was started from the staged copy, the file cannot be
    # deleted while it executes, so the folder is scheduled for removal at
    # the next start of the wrapper instead.
    try {
        if (Test-Path -Path $RetryStagingDirectory) {
            $self = $PSCommandPath
            $runningFromStage = $false
            if ($self) {
                $runningFromStage = ((Split-Path $self -Parent).TrimEnd('\') -ieq $RetryStagingDirectory.TrimEnd('\'))
            }
            Remove-Item -Path (Join-Path $RetryStagingDirectory $RetryConfigName)     -Force -ErrorAction SilentlyContinue
            Remove-Item -Path (Join-Path $RetryStagingDirectory $MigrationScriptName) -Force -ErrorAction SilentlyContinue
            if (-not $runningFromStage) {
                Remove-Item -Path $RetryStagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log 'Removed the staged retry bundle.'
            } else {
                Set-StateValue -Name 'StagePendingCleanup' -Value '1'
                Write-Log 'Staged wrapper copy left in place (currently executing); config and migration script removed.'
            }
        }
    } catch {
        Write-Log "Could not remove the staged bundle: $($_.Exception.Message)" 'WARN'
    }
}

function Complete-PendingStageCleanup {
    # A previous run flagged the staging folder for removal but was executing
    # from it. Finish that now if we are running from somewhere else.
    if ((Get-StateValue -Name 'StagePendingCleanup') -ne '1') { return }
    $self = $PSCommandPath
    if ($self -and ((Split-Path $self -Parent).TrimEnd('\') -ieq $RetryStagingDirectory.TrimEnd('\'))) { return }
    Remove-Item -Path $RetryStagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Set-StateValue -Name 'StagePendingCleanup' -Value '0'
    Write-Log 'Completed deferred cleanup of the staged retry bundle.'
}

# =============================================================================
# MAIN
# =============================================================================

# ---- Resolve mode, source and tenant values -------------------------------
$script:ResolvedMode = $ConfigMode
if (-not [string]::IsNullOrWhiteSpace($Mode)) { $script:ResolvedMode = $Mode }
$script:ResolvedMode = $script:ResolvedMode.Trim()

$script:ResolvedRunSource = $ConfigRunSource
if (-not [string]::IsNullOrWhiteSpace($RunSource)) { $script:ResolvedRunSource = $RunSource }
if ($FromRetryTask) { $script:ResolvedRunSource = 'RetryTask' }

$values = @{
    TenantName     = $ConfigTenantName
    BlueprintId    = $ConfigBlueprintId
    EnrollmentCode = $ConfigEnrollmentCode
    TenantId       = $ConfigTenantId
    TenantLocation = $ConfigTenantLocation
}
if (-not [string]::IsNullOrWhiteSpace($TenantName))     { $values.TenantName     = $TenantName }
if (-not [string]::IsNullOrWhiteSpace($BlueprintId))    { $values.BlueprintId    = $BlueprintId }
if (-not [string]::IsNullOrWhiteSpace($EnrollmentCode)) { $values.EnrollmentCode = $EnrollmentCode }
if (-not [string]::IsNullOrWhiteSpace($TenantId))       { $values.TenantId       = $TenantId }
if (-not [string]::IsNullOrWhiteSpace($TenantLocation)) { $values.TenantLocation = $TenantLocation }

# The retry task runs the staged copy; its tenant values come from the staged
# config file written at staging time.
if ($FromRetryTask) {
    $cfgPath = Join-Path $RetryStagingDirectory $RetryConfigName
    if (Test-Path -Path $cfgPath) {
        try {
            $cfg = Get-Content -Path $cfgPath -Raw | ConvertFrom-Json
            foreach ($name in @('TenantName', 'BlueprintId', 'EnrollmentCode', 'TenantId', 'TenantLocation')) {
                if ($cfg.PSObject.Properties.Match($name).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$cfg.$name)) {
                    $values[$name] = [string]$cfg.$name
                }
            }
        } catch {
            Write-Log "Could not read the staged configuration: $($_.Exception.Message)" 'ERROR'
        }
    }
    $script:ResolvedMode = 'Enroll'
}
foreach ($k in @($values.Keys)) { if ($values[$k]) { $values[$k] = ([string]$values[$k]).Trim() } }
if ($values.TenantLocation) { $values.TenantLocation = $values.TenantLocation.ToUpperInvariant() }

$scriptDirectory = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDirectory)) { $scriptDirectory = (Get-Location).Path }
$wrapperPath   = Join-Path $scriptDirectory $WrapperFileName
$migrationPath = Join-Path $scriptDirectory $MigrationScriptName

Write-Log ('==== Invoke-IruEnrollment v{0} | Mode={1} | Source={2} | Host={3} ====' -f $ScriptVersion, $script:ResolvedMode, $script:ResolvedRunSource, $env:COMPUTERNAME)
Write-Log ("Script directory: {0}" -f $scriptDirectory)
Write-Log ("Running as: {0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)

# ---- Preconditions (exit 2) ----------------------------------------------
if ($script:ResolvedMode -ne 'Enroll' -and $script:ResolvedMode -ne 'Probe') {
    Write-Log ("Invalid mode '{0}'. Use 'Enroll' or 'Probe'." -f $script:ResolvedMode) 'ERROR'
    exit 2
}

if (-not (Test-IsElevated)) {
    Write-Log 'Not running elevated. The migration script requires SYSTEM or an elevated administrator.' 'ERROR'
    Write-RunState -Result 'PreconditionFailed' -Detail 'not elevated'
    exit 2
}

$os = Get-OsInfo
Write-Log ("OS: build {0}.{1} ({2}) edition {3}; 64-bit OS={4}, 64-bit process={5}" -f $os.Build, $os.Ubr, $os.DisplayVersion, $os.Edition, $os.Is64BitOs, $os.Is64BitProcess)
if ($os.Build -lt $RequiredOsBuild) {
    Write-Log ("Windows build {0} is below the required {1} (Windows 11 24H2). Iru supports 24H2 and 25H2 only." -f $os.Build, $RequiredOsBuild) 'ERROR'
    Write-RunState -Result 'PreconditionFailed' -Detail ('build ' + $os.Build)
    exit 2
}

if (-not (Test-Path -Path $migrationPath)) {
    Write-Log ("Migration script not found at '{0}'. Place an unmodified copy of Iru WindowsScripts\mdmmigration.ps1 beside this file." -f $migrationPath) 'ERROR'
    Write-RunState -Result 'PreconditionFailed' -Detail 'mdmmigration.ps1 missing'
    exit 2
}

if (-not (Test-TenantValues -Values $values)) {
    Write-Log 'Tenant values incomplete. Fill the CONFIGURATION block or pass them as parameters.' 'ERROR'
    Write-RunState -Result 'PreconditionFailed' -Detail 'tenant values'
    exit 2
}

$hosts = Get-IruEndpointHosts -TenantName $values.TenantName -TenantId $values.TenantId -TenantLocation $values.TenantLocation
Write-Log ("Tenant: name={0} blueprint={1} tenantId={2} region={3}" -f $values.TenantName, $values.BlueprintId, $values.TenantId, $values.TenantLocation)
Write-Log ("Endpoints: {0}" -f ($hosts -join ', '))

Complete-PendingStageCleanup

# ---- Evidence common to both modes ----------------------------------------
$setup = Get-SetupState
Write-Log ("Setup state: {0}" -f (($setup.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ', '))
foreach ($line in (Get-SessionIdentitySummary)) { Write-Log ("Identity: {0}" -f $line) }
$mdmDll = Join-Path $env:SystemRoot 'System32\MDMRegistration.dll'
Write-Log ("MDMRegistration.dll present: {0}" -f (Test-Path -Path $mdmDll))
$before = @(Write-EnrollmentSummary -Label 'Enrollments before')
$alreadyOnIru = @($before | Where-Object { $_.IsKandjiOrIru }).Count -gt 0

# =============================================================================
# PROBE
# =============================================================================
if ($script:ResolvedMode -eq 'Probe') {
    Write-Log 'Probe mode: nothing will be changed on this device.'
    if ($ForceTimeSync) { Invoke-TimeSync }

    $reachable = Wait-ForIruEndpoints -Hosts $hosts -MaxSeconds ([Math]::Min($NetworkWaitSeconds, 60))
    $tokenOk = $null
    if ($reachable -and $ProbeFetchToken) {
        $tokenOk = Test-GatewayToken -Url (Get-IruEnrollmentUrl -TenantName $values.TenantName -BlueprintId $values.BlueprintId -EnrollmentCode $values.EnrollmentCode -TenantLocation $values.TenantLocation)
    }

    Write-Log 'Running mdmmigration.ps1 -DiagnoseOnly (read-only inventory of MDM state)...'
    $diagExit = Invoke-MigrationScript -ScriptPath $migrationPath -Values $values -DiagnoseOnly
    Write-Log ("mdmmigration.ps1 -DiagnoseOnly exit code: {0}" -f (Format-ExitCode $diagExit))

    $verdict = 'ReadyToEnroll'
    if (-not $reachable) { $verdict = 'EndpointsUnreachable' }
    elseif ($tokenOk -eq $false) { $verdict = 'GatewayRejectedTenantValues' }
    elseif ($alreadyOnIru) { $verdict = 'AlreadyEnrolled' }
    Write-Log ("Probe verdict: {0}" -f $verdict) $(if ($verdict -eq 'ReadyToEnroll' -or $verdict -eq 'AlreadyEnrolled') { 'OK' } else { 'ERROR' })
    Write-RunState -Result ('Probe:' + $verdict) -Detail ('reachable=' + $reachable + '; token=' + $tokenOk)

    if ($verdict -eq 'ReadyToEnroll' -or $verdict -eq 'AlreadyEnrolled') { exit 0 }
    exit 1
}

# =============================================================================
# ENROLL
# =============================================================================
if ($alreadyOnIru -and $SkipWhenAlreadyEnrolled) {
    Write-Log 'A Kandji/Iru enrollment is already present. Nothing to do.' 'OK'
    Write-RunState -Result 'AlreadyEnrolled' -Detail ((@($before | Where-Object { $_.IsKandjiOrIru } | ForEach-Object { $_.Id })) -join ',')
    Remove-RetryArtifacts -Reason 'already enrolled'
    exit 0
}

if ($FromRetryTask) {
    $attempts = 0
    $stored = Get-StateValue -Name 'RetryAttempts'
    if ($stored) { $attempts = [int]$stored }
    $attempts++
    Set-StateValue -Name 'RetryAttempts' -Value $attempts
    Write-Log ("Retry attempt {0} of {1}." -f $attempts, $RetryMaxAttempts)
    if ($attempts -gt $RetryMaxAttempts) {
        Write-Log 'Retry attempts exhausted. Removing the retry task; enroll this device manually.' 'ERROR'
        Write-RunState -Result 'RetryExhausted' -Detail ('attempts=' + $attempts)
        Remove-RetryArtifacts -Reason 'attempts exhausted'
        exit 1
    }
}

if ($ForceTimeSync) { Invoke-TimeSync }

Write-Log ("Waiting up to {0} seconds for the Iru endpoints..." -f $NetworkWaitSeconds)
$reachable = Wait-ForIruEndpoints -Hosts $hosts -MaxSeconds $NetworkWaitSeconds
if (-not $reachable) {
    Write-Log 'Iru endpoints did not become reachable inside the wait budget.' 'WARN'
    if ($RegisterRetryTask -and -not $FromRetryTask) {
        if ((Save-RetryBundle -WrapperPath $wrapperPath -MigrationPath $migrationPath -Values $values) -and (Register-RetryTask)) {
            Set-StateValue -Name 'RetryAttempts' -Value 0
            Write-RunState -Result 'RetryScheduled' -Detail 'endpoints unreachable at provisioning time'
            Write-Log ("Enrollment deferred to the retry task. Exit code {0}." -f $ExitCodeWhenRetryScheduled) 'OK'
            exit $ExitCodeWhenRetryScheduled
        }
        Write-Log 'Retry could not be scheduled.' 'ERROR'
        Write-RunState -Result 'Failed' -Detail 'endpoints unreachable; retry not scheduled'
        exit 1
    }
    if ($FromRetryTask) {
        Write-Log 'Still no network at this retry; the task stays registered for the next startup.' 'WARN'
        Write-RunState -Result 'RetryPending' -Detail 'endpoints unreachable'
        exit 1
    }
    Write-Log 'Retry task disabled by configuration.' 'ERROR'
    Write-RunState -Result 'Failed' -Detail 'endpoints unreachable; retry disabled'
    exit 1
}

$migrationExit = Invoke-MigrationScript -ScriptPath $migrationPath -Values $values
Write-Log ("mdmmigration.ps1 exit code: {0}" -f (Format-ExitCode $migrationExit))
Set-StateValue -Name 'LastMigrationExitCode' -Value $(if ($null -eq $migrationExit) { 'timeout' } else { [string]$migrationExit })
Set-StateValue -Name 'MigrationLogDirectory' -Value (Join-Path $env:ProgramData 'Iru\MDMMigration\Logs')

$after = @(Write-EnrollmentSummary -Label 'Enrollments after')
$onIruAfter = @($after | Where-Object { $_.IsKandjiOrIru }).Count -gt 0

if ($migrationExit -eq $MigrationExitSuccess) {
    if ($onIruAfter) {
        Write-Log 'Enrollment succeeded and a Kandji/Iru enrollment record is present.' 'OK'
    } else {
        Write-Log 'Migration script reported success but no Kandji/Iru ProviderID is visible yet; Windows may still be finalizing. Verify in the Iru console.' 'WARN'
    }
    Write-RunState -Result 'Enrolled' -Detail ('migration exit 0; provider visible=' + $onIruAfter)
    Remove-RetryArtifacts -Reason 'enrolled'
    exit 0
}

if ($migrationExit -eq $MigrationExitResidualBlocked) {
    Write-Log 'Migration script stopped before registration: residual state from a previous MDM would block enrollment. Device left on its prior state. Re-run mdmmigration.ps1 -DiagnoseOnly and see mdmmigration.md.' 'ERROR'
    Write-RunState -Result 'BlockedByResidualState' -Detail 'migration exit 3'
    exit 1
}

if ($null -eq $migrationExit) {
    Write-RunState -Result 'TimedOut' -Detail ('migration exceeded ' + $MigrationTimeoutSeconds + 's')
    exit 1
}

Write-Log ("Migration script failed. Its own log is under %ProgramData%\Iru\MDMMigration\Logs; the HRESULT above maps to the MDM registration error values." ) 'ERROR'
if ($RetryOnMigrationFailure -and $RegisterRetryTask -and -not $FromRetryTask) {
    if ((Save-RetryBundle -WrapperPath $wrapperPath -MigrationPath $migrationPath -Values $values) -and (Register-RetryTask)) {
        Set-StateValue -Name 'RetryAttempts' -Value 0
        Write-RunState -Result 'RetryScheduled' -Detail ('migration exit ' + (Format-ExitCode $migrationExit) + '; retry at next startup')
        Write-Log ("Enrollment deferred to the retry task after a failed attempt. Exit code {0}." -f $ExitCodeWhenRetryScheduled) 'WARN'
        exit $ExitCodeWhenRetryScheduled
    }
}
if ($FromRetryTask) {
    Write-Log 'Failed attempt from the retry task; the task stays registered until attempts are exhausted.' 'WARN'
}
Write-RunState -Result 'Failed' -Detail ('migration exit ' + (Format-ExitCode $migrationExit))
exit 1
