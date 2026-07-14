<#
.SYNOPSIS
    Enrolls Google Chrome on Windows into Chrome Browser Cloud Management
    (CBCM) by writing the Chrome Enterprise Core enrollment token to the
    machine-level Chrome policy key.

.DESCRIPTION
    Replicates the ADMX-backed Chrome policy "CloudManagementEnrollmentToken"
    by writing directly to the machine-level Chrome policy store:

        HKLM\SOFTWARE\Policies\Google\Chrome
            CloudManagementEnrollmentToken (REG_SZ)

    On its next launch, a system-level Chrome install reads the token,
    registers with Google's Device Management server, and receives a device
    management token (DM token). From then on Chrome pulls all policies from
    Google Admin. The enrollment token is only used at enrollment time;
    removing it later does NOT unenroll an already-enrolled browser (the
    browser keeps its DM token). Unenrollment is performed from Google Admin
    (Chrome browser -> Managed Browsers -> select browser -> Delete).

    CBCM enrollment has no native CSP; on Windows it is registry/ADMX-backed
    only, and Google documents that the token must be set at machine level
    (HKLM) for system-level Chrome installs - user-level (HKCU) placement is
    not supported.

    Modes:
      Enforce  - writes the enrollment token and verifies the write (default)
      Audit    - reports compliance/drift without changing anything
      Discover - reports Chrome install state, current token value, and
                 whether a DM token (enrollment-success signal) is present
      Revert   - removes the CloudManagementEnrollmentToken value only.
                 This does NOT unenroll an already-enrolled browser.

    Designed for deployment as an Iru (formerly Kandji) Windows Custom Script
    Library Item running as NT AUTHORITY\SYSTEM. Because the token is only
    consumed once at enrollment, an Enforce-only single-slot deployment is a
    reasonable alternative to the usual Audit + Enforce pair - see README.md.

.NOTES
    File     : Manage-ChromeCBCMEnrollment.ps1
    Version  : 1.0.0 (2026-07-14)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM or local Administrator (elevation required)
    PS       : Windows PowerShell 5.1 (no external modules)

    Exit codes:
      0 = success (Enforce/Revert/Discover) or compliant (Audit)
      1 = drift detected (Audit) or one or more runtime operations failed
      2 = precondition failure (not elevated, placeholder token in
          Enforce/Audit, or invalid $Mode)

    A missing system-level Chrome install is a logged WARNING, not a
    precondition failure: pre-staging the token before Chrome is installed
    is a valid deployment order (Chrome reads the token on first launch).
    See README.md for the full rationale.

    Sources: see the accompanying README.md (Sourcing notes section).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

# =============================================================================
# CONFIGURATION - edit this block, nothing below it
# =============================================================================

# Mode: 'Enforce' | 'Audit' | 'Discover' | 'Revert'
$Mode = 'Enforce'

# Chrome Enterprise Core enrollment token, generated in Google Admin under
# Chrome browser -> Managed Browsers -> Enroll. Replace the placeholder with
# your organization's token before deploying Enforce or Audit.
$EnrollmentToken = 'YOUR_TOKEN_HERE'

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Manage-ChromeCBCMEnrollment.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion    = '1.0.0'
$PlaceholderToken = 'YOUR_TOKEN_HERE'
$PolicyKey        = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$TokenValueName   = 'CloudManagementEnrollmentToken'
$StateKey         = 'HKLM:\SOFTWARE\IruScripts\ChromeCBCM'

# DM token locations documented by Google for Windows (value name: dmtoken).
# Presence of a dmtoken indicates the browser completed CBCM registration.
$DmTokenKeys = @(
    'HKLM:\SOFTWARE\Google\Chrome\Enrollment'
    'HKLM:\SOFTWARE\WOW6432Node\Google\Enrollment'
)

# System-level (per-machine) Chrome install locations. Per-user installs
# under %LOCALAPPDATA% are NOT supported for CBCM enrollment on Windows.
$ChromeExePaths = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
)
$ChromeAppPathsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'

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

# =============================================================================
# HELPERS
# =============================================================================

function Get-MaskedToken {
    # Enrollment tokens allow enrolling browsers into the org - never log the
    # full value. Shows the first 8 characters, enough to tell tokens apart.
    param([string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return '<absent>' }
    if ($Token -eq $PlaceholderToken) { return $PlaceholderToken }
    if ($Token.Length -le 8) { return ('*' * $Token.Length) }
    return ($Token.Substring(0, 8) + '...' + ('({0} chars)' -f $Token.Length))
}

function Get-SystemChromeInstall {
    # Returns install info for a system-level (per-machine) Chrome, or $null.
    foreach ($path in $ChromeExePaths) {
        if ($path -and (Test-Path -Path $path)) {
            $version = ''
            try { $version = (Get-Item -Path $path).VersionInfo.ProductVersion } catch { }
            return [pscustomobject]@{ Path = $path; Version = $version; Source = 'file' }
        }
    }
    # Fallback: machine-level App Paths registration (covers non-default
    # install locations). Per-user Chrome registers under HKCU, not HKLM,
    # so a hit here still indicates a system-level install.
    try {
        $appPath = (Get-ItemProperty -Path $ChromeAppPathsKey -ErrorAction SilentlyContinue).'(default)'
        if (-not $appPath) {
            $appPath = (Get-Item -Path $ChromeAppPathsKey -ErrorAction SilentlyContinue).GetValue('')
        }
        if ($appPath -and (Test-Path -Path $appPath)) {
            $version = ''
            try { $version = (Get-Item -Path $appPath).VersionInfo.ProductVersion } catch { }
            return [pscustomobject]@{ Path = $appPath; Version = $version; Source = 'App Paths' }
        }
    } catch { }
    return $null
}

function Get-CurrentToken {
    return (Get-ItemProperty -Path $PolicyKey -Name $TokenValueName -ErrorAction SilentlyContinue).$TokenValueName
}

function Get-DmTokenState {
    # Reports presence (never the value) of the dmtoken at each documented
    # location. A present dmtoken means the browser completed registration.
    $found = @()
    foreach ($key in $DmTokenKeys) {
        $value = (Get-ItemProperty -Path $key -Name 'dmtoken' -ErrorAction SilentlyContinue).dmtoken
        if (-not [string]::IsNullOrEmpty($value)) { $found += $key }
    }
    return @($found)
}

function Test-ChromeInstallWarning {
    # Missing system Chrome is a warning, not a gate: the token can be
    # pre-staged and Chrome will consume it on first launch after install.
    $chrome = Get-SystemChromeInstall
    if ($null -eq $chrome) {
        Write-Log 'No system-level Chrome installation found. The token can be pre-staged; Chrome will read it on first launch after a per-machine install. Note that per-user Chrome installs cannot enroll in CBCM.' 'WARN'
    } else {
        Write-Log ('System-level Chrome found: {0} (version: {1})' -f $chrome.Path, $(if ($chrome.Version) { $chrome.Version } else { 'unknown' }))
    }
    return $chrome
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-Enforce {
    Write-Log '=== ENFORCE: writing CBCM enrollment token ==='
    Test-ChromeInstallWarning | Out-Null

    $dmKeys = Get-DmTokenState
    if ($dmKeys.Count -gt 0) {
        Write-Log 'A DM token is already present - this browser has completed CBCM registration. Enrollment tokens are only used at enrollment time, so writing the token keeps the policy state compliant but does not re-enroll or move the browser.'
    }

    $current = Get-CurrentToken
    if ($null -ne $current -and [string]$current -ceq $EnrollmentToken) {
        Write-Log ('OK      {0} already set to the configured token ({1})' -f $TokenValueName, (Get-MaskedToken $current)) 'OK'
    } else {
        try {
            if (-not (Test-Path -Path $PolicyKey)) {
                New-Item -Path $PolicyKey -Force | Out-Null
                Write-Log ('Created policy key {0}' -f $PolicyKey)
            }
            New-ItemProperty -Path $PolicyKey -Name $TokenValueName -PropertyType String -Value $EnrollmentToken -Force | Out-Null
            Write-Log ('SET     {0} = {1} (was: {2})' -f $TokenValueName, (Get-MaskedToken $EnrollmentToken), (Get-MaskedToken $current))
        } catch {
            Write-Log ('Failed to write {0}: {1}' -f $TokenValueName, $_.Exception.Message) 'ERROR'
            return
        }

        # Verify the write landed
        $verify = Get-CurrentToken
        if ($null -ne $verify -and [string]$verify -ceq $EnrollmentToken) {
            Write-Log ('OK      verified {0} matches the configured token' -f $TokenValueName) 'OK'
        } else {
            Write-Log ('Verification failed: {0} reads back as {1}' -f $TokenValueName, (Get-MaskedToken $verify)) 'ERROR'
            return
        }
    }

    # State stamp (informational only; Audit reads the live policy value).
    # The token itself is never stored here - only a masked preview.
    try {
        if (-not (Test-Path -Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        New-ItemProperty -Path $StateKey -Name 'ScriptVersion'  -PropertyType String -Value $ScriptVersion -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'LastEnforceUtc' -PropertyType String -Value (Get-Date).ToUniversalTime().ToString('o') -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'TokenPreview'   -PropertyType String -Value (Get-MaskedToken $EnrollmentToken) -Force | Out-Null
    } catch {
        Write-Log ('Could not write state stamp: {0}' -f $_.Exception.Message) 'WARN'
    }

    Write-Log 'Enforcement pass complete. Chrome reads the token on its next full launch (quit and relaunch); verify via chrome://management or Google Admin -> Managed Browsers.'
}

function Invoke-Audit {
    Write-Log '=== AUDIT: comparing live enrollment token to configuration ==='
    Test-ChromeInstallWarning | Out-Null

    $current = Get-CurrentToken
    if ($null -eq $current) {
        Write-Log ('DRIFT   {0} absent, expected {1}' -f $TokenValueName, (Get-MaskedToken $EnrollmentToken)) 'DRIFT'
    } elseif ([string]$current -cne $EnrollmentToken) {
        Write-Log ('DRIFT   {0} = {1}, expected {2}' -f $TokenValueName, (Get-MaskedToken $current), (Get-MaskedToken $EnrollmentToken)) 'DRIFT'
    } else {
        Write-Log ('OK      {0} matches the configured token ({1})' -f $TokenValueName, (Get-MaskedToken $current)) 'OK'
    }

    $dmKeys = Get-DmTokenState
    if ($dmKeys.Count -gt 0) {
        Write-Log 'DM token present - browser has completed CBCM registration (informational, not part of compliance).'
    } else {
        Write-Log 'No DM token found - browser has not (yet) completed CBCM registration. Chrome registers on its next full launch after the token lands (informational, not part of compliance).'
    }

    if ($script:DriftCount -eq 0) {
        Write-Log 'Audit result: COMPLIANT'
    } else {
        Write-Log ('Audit result: {0} drift item(s) found' -f $script:DriftCount) 'WARN'
    }
}

function Invoke-Discover {
    Write-Log '=== DISCOVER: reporting Chrome / CBCM enrollment state ==='

    $chrome = Get-SystemChromeInstall
    if ($null -eq $chrome) {
        Write-Log 'Chrome (system-level): NOT INSTALLED. Per-user installs, if any, are not detected here and cannot enroll in CBCM.' 'WARN'
    } else {
        Write-Log ('Chrome (system-level): installed at {0} (version: {1}, detected via {2})' -f $chrome.Path, $(if ($chrome.Version) { $chrome.Version } else { 'unknown' }), $chrome.Source)
    }

    $current = Get-CurrentToken
    Write-Log ('{0}: {1}' -f $TokenValueName, (Get-MaskedToken $current))
    if ($null -ne $current -and [string]$current -ceq $PlaceholderToken) {
        Write-Log 'The live registry value is the placeholder text - a previous deployment ran without setting a real token.' 'WARN'
    }

    $dmKeys = Get-DmTokenState
    if ($dmKeys.Count -gt 0) {
        foreach ($key in $dmKeys) {
            Write-Log ('DM token: PRESENT at {0} (value withheld from logs)' -f $key)
        }
        Write-Log 'A present DM token indicates this browser completed CBCM registration and appears (or will appear) in Google Admin -> Managed Browsers.'
    } else {
        Write-Log 'DM token: ABSENT at all documented locations - this browser has not completed CBCM registration.'
    }
}

function Invoke-Revert {
    Write-Log '=== REVERT: removing the CBCM enrollment token value ==='
    Write-Log 'NOTE: Revert does NOT unenroll an already-enrolled browser. The browser keeps its DM token and remains managed; unenrollment is performed from Google Admin (Chrome browser -> Managed Browsers -> select browser -> Delete).' 'WARN'

    $current = Get-CurrentToken
    if ($null -eq $current) {
        Write-Log ('OK      {0} already absent' -f $TokenValueName) 'OK'
    } else {
        try {
            Remove-ItemProperty -Path $PolicyKey -Name $TokenValueName -Force -ErrorAction Stop
            Write-Log ('REMOVED {0} (was: {1})' -f $TokenValueName, (Get-MaskedToken $current))
        } catch {
            Write-Log ('Failed to remove {0}: {1}' -f $TokenValueName, $_.Exception.Message) 'ERROR'
        }
    }

    # The policy key itself is left in place - other tooling may manage other
    # Chrome policies under it. Only the value this script owns is removed.
    if (Test-Path -Path $StateKey) {
        try {
            Remove-Item -Path $StateKey -Recurse -Force -ErrorAction Stop
            Write-Log ('REMOVED state key {0}' -f $StateKey)
        } catch {
            Write-Log ('Failed to remove state key {0}: {1}' -f $StateKey, $_.Exception.Message) 'ERROR'
        }
    }

    Write-Log 'Revert complete. Un-enrolled machines will no longer auto-enroll; enrolled browsers are unaffected (see note above).'
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log ('Manage-ChromeCBCMEnrollment v{0} starting in mode: {1}' -f $ScriptVersion, $Mode)

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

if ($Mode -in @('Enforce','Audit') -and $EnrollmentToken -ceq $PlaceholderToken) {
    Write-Log '$EnrollmentToken is still set to the placeholder. Generate a token in Google Admin (Chrome browser -> Managed Browsers -> Enroll) and set it in the CONFIGURATION block of BOTH Library Item slots. Refusing to write or audit against placeholder text.' 'ERROR'
    exit 2
}

switch ($Mode) {
    'Enforce'  { Invoke-Enforce }
    'Audit'    { Invoke-Audit }
    'Discover' { Invoke-Discover }
    'Revert'   { Invoke-Revert }
    default    {
        Write-Log ('Unknown mode ''{0}''. Valid: Enforce, Audit, Discover, Revert.' -f $Mode) 'ERROR'
        exit 2
    }
}

if ($script:FailureCount -gt 0) {
    Write-Log ('Completed with {0} error(s).' -f $script:FailureCount) 'WARN'
    exit 1
}
if ($Mode -eq 'Audit' -and $script:DriftCount -gt 0) {
    exit 1
}
Write-Log 'Completed successfully.'
exit 0
