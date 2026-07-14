<#
.SYNOPSIS
    Manages browser and website shortcuts on the all-users (Public) desktop:
    creates missing shortcuts, repairs mismatched ones, and removes managed
    shortcuts whose browser is no longer installed.

.DESCRIPTION
    Writes .lnk files to the Public desktop (C:\Users\Public\Desktop) so the
    shortcuts appear for every current and future user. Runs as SYSTEM via
    the Iru Custom Script Library, which is why the Public desktop is the
    target - a per-user desktop is not cleanly reachable from SYSTEM.

    Two shortcut types are supported in the $Shortcuts config block:

      App - a shortcut to a browser executable. 'Targets' lists candidate
            paths; the first one that exists is used, so one entry covers
            both Program Files locations.
      Url - a shortcut that launches a specific browser straight to a web
            address (browser exe as target, URL as argument), inheriting
            that browser's icon.

    Desired state is conditional on browser presence: a shortcut whose
    executable is not installed should be ABSENT. Enforce removes such
    stale shortcuts and skips creation with a warning; Audit treats a
    missing browser as a skipped item (not drift), but a lingering
    shortcut to a missing browser as drift. Shortcuts on the Public
    desktop that are not in the config are never touched and never count
    as drift; Discover reports them.

    Modes:
      Enforce  - creates/repairs configured shortcuts, removes stale
                 managed ones, verifies the result (default)
      Audit    - reports compliance/drift without changing anything
      Discover - reports every managed shortcut's state plus any
                 unmanaged .lnk/.url files on the Public desktop
      Revert   - removes every config-defined shortcut and the state key;
                 unmanaged files are left untouched

    Designed for deployment as an Iru (formerly Kandji) Windows Custom
    Script Library Item running as NT AUTHORITY\SYSTEM. Pair the same
    script in the Audit slot ($Mode = 'Audit') and Remediation slot
    ($Mode = 'Enforce') with an identical $Shortcuts block.

.NOTES
    File     : Manage-BrowserShortcuts.ps1
    Version  : 1.0.0 (2026-07-14)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Runs as  : SYSTEM or local Administrator (elevation required to write
               the Public desktop and HKLM state)
    PS       : Windows PowerShell 5.1 (no external modules; WScript.Shell
               COM for .lnk handling)

    Exit codes:
      0 = success (Enforce/Revert/Discover) or compliant (Audit)
      1 = drift detected (Audit) or one or more runtime operations failed
      2 = precondition failure (not elevated, empty/malformed $Shortcuts
          config, Public desktop not resolvable, or invalid $Mode)

    History: this folder originally specced an Audit/Remediate script
    pair; the committed pair was content-less and was reimplemented from
    the README spec as this single dual-slot script. See README.md.
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

# The managed shortcut set - the single source of truth for every mode.
# Entry shapes:
#   App entries: @{ Name = <shortcut name>; Type = 'App'; Targets = @(<candidate exe paths - first that exists wins>) }
#   Url entries: @{ Name = <shortcut name>; Type = 'Url'; Url = <address>; Browser = <exe path> }
# Optional on either shape: Icon = '<path.exe|.ico>,<index>' to override the
# default icon (the resolved executable's own icon, index 0).
$Shortcuts = @(
    @{ Name = 'Google Chrome'; Type = 'App'; Targets = @(
        (Join-Path $env:ProgramFiles        'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
    )}
    @{ Name = 'Microsoft Edge'; Type = 'App'; Targets = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles        'Microsoft\Edge\Application\msedge.exe')
    )}
    @{ Name = 'Mozilla Firefox'; Type = 'App'; Targets = @(
        (Join-Path $env:ProgramFiles        'Mozilla Firefox\firefox.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
    )}
    # @{ Name = 'Company Portal'; Type = 'Url'; Url = 'https://portal.example.com';
    #    Browser = (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
)

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Manage-BrowserShortcuts.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '1.0.0'
$StateKey      = 'HKLM:\SOFTWARE\IruScripts\BrowserShortcuts'

$script:FailureCount = 0
$script:DriftCount   = 0
$script:WScriptShell = $null

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

function Get-PublicDesktopPath {
    # SYSTEM-context correctness: the all-users desktop is %PUBLIC%\Desktop.
    # Never resolve the desktop via HKCU or GetFolderPath('Desktop'), which
    # under SYSTEM point at SYSTEM's own profile.
    $publicRoot = $env:PUBLIC
    if (-not $publicRoot) { $publicRoot = Join-Path $env:SystemDrive 'Users\Public' }
    $desktop = Join-Path $publicRoot 'Desktop'
    if (Test-Path -Path $desktop) { return $desktop }
    return $null
}

function Test-ShortcutConfig {
    # Returns $true when $Shortcuts is well-formed; logs specifics otherwise.
    if (-not $Shortcuts -or @($Shortcuts).Count -eq 0) {
        Write-Log 'The $Shortcuts config block is empty - nothing to manage. Populate it before deploying.' 'ERROR'
        return $false
    }
    $valid = $true
    $seenNames = @{}
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($entry in $Shortcuts) {
        $name = [string]$entry.Name
        if (-not $name) {
            Write-Log 'A $Shortcuts entry has no Name.' 'ERROR'; $valid = $false; continue
        }
        if ($seenNames.ContainsKey($name.ToLowerInvariant())) {
            Write-Log "Duplicate shortcut Name '$name' in `$Shortcuts." 'ERROR'; $valid = $false
        }
        $seenNames[$name.ToLowerInvariant()] = $true
        foreach ($ch in $invalidChars) {
            if ($name.IndexOf($ch) -ge 0) {
                Write-Log "Shortcut Name '$name' contains a character that is invalid in file names." 'ERROR'; $valid = $false; break
            }
        }
        switch ([string]$entry.Type) {
            'App' {
                if (-not $entry.Targets -or @($entry.Targets).Count -eq 0) {
                    Write-Log "App entry '$name' has no Targets." 'ERROR'; $valid = $false
                }
            }
            'Url' {
                if (-not $entry.Url) {
                    Write-Log "Url entry '$name' has no Url." 'ERROR'; $valid = $false
                }
                if (-not $entry.Browser) {
                    Write-Log "Url entry '$name' has no Browser (required - see README)." 'ERROR'; $valid = $false
                }
            }
            default {
                Write-Log "Entry '$name' has invalid Type '$($entry.Type)'. Valid: App, Url." 'ERROR'; $valid = $false
            }
        }
    }
    return $valid
}

# =============================================================================
# SHORTCUT HELPERS
# =============================================================================

function Get-WScriptShell {
    if ($null -eq $script:WScriptShell) {
        $script:WScriptShell = New-Object -ComObject WScript.Shell
    }
    return $script:WScriptShell
}

function Get-DesiredShortcuts {
    # Resolves the config into concrete desired states. Exe = $null means
    # the browser is not installed, so the desired state is 'absent'.
    param([Parameter(Mandatory)][string]$DesktopPath)
    $desired = @()
    foreach ($entry in $Shortcuts) {
        $exe = $null
        $arguments = ''
        if ($entry.Type -eq 'App') {
            foreach ($candidate in @($entry.Targets)) {
                if ($candidate -and (Test-Path -Path $candidate)) { $exe = $candidate; break }
            }
        } else {
            if ($entry.Browser -and (Test-Path -Path $entry.Browser)) { $exe = [string]$entry.Browser }
            $arguments = [string]$entry.Url
        }
        $icon = $null
        if ($entry.Icon) { $icon = [string]$entry.Icon }
        elseif ($exe)    { $icon = "$exe,0" }
        $desired += [pscustomobject]@{
            Name      = [string]$entry.Name
            Type      = [string]$entry.Type
            LnkPath   = Join-Path $DesktopPath ("{0}.lnk" -f $entry.Name)
            Exe       = $exe
            Arguments = $arguments
            Icon      = $icon
        }
    }
    return @($desired)
}

function Get-ShortcutState {
    # Reads an existing .lnk; $null if the file does not exist.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -Path $Path)) { return $null }
    $lnk = (Get-WScriptShell).CreateShortcut($Path)
    return [pscustomobject]@{
        Target    = [string]$lnk.TargetPath
        Arguments = [string]$lnk.Arguments
        Icon      = [string]$lnk.IconLocation
    }
}

function Test-ShortcutMatch {
    # Target and icon paths compare case-insensitively (NTFS), the argument
    # string (the URL) compares exactly.
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)]$Actual
    )
    if ([string]$Actual.Target -ne '' -and [string]$Desired.Exe -ne '' -and
        ([string]$Actual.Target).ToLowerInvariant() -ne ([string]$Desired.Exe).ToLowerInvariant()) { return $false }
    if (([string]$Actual.Target) -eq '' -and ([string]$Desired.Exe) -ne '') { return $false }
    if ([string]$Actual.Arguments -cne [string]$Desired.Arguments) { return $false }
    if (([string]$Actual.Icon).ToLowerInvariant() -ne ([string]$Desired.Icon).ToLowerInvariant()) { return $false }
    return $true
}

function New-ManagedShortcut {
    # Creates (or overwrites) a .lnk from a desired-state record.
    param([Parameter(Mandatory)]$Desired)
    try {
        if (Test-Path -Path $Desired.LnkPath) {
            Remove-Item -Path $Desired.LnkPath -Force -ErrorAction Stop
        }
        $lnk = (Get-WScriptShell).CreateShortcut($Desired.LnkPath)
        $lnk.TargetPath = $Desired.Exe
        $lnk.Arguments = $Desired.Arguments
        $lnk.IconLocation = $Desired.Icon
        $lnk.WorkingDirectory = (Split-Path -Path $Desired.Exe -Parent)
        $lnk.Save()
        return $true
    } catch {
        Write-Log "Failed to create shortcut '$($Desired.Name)': $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Remove-ManagedShortcut {
    param([Parameter(Mandatory)]$Desired, [string]$Reason = '')
    try {
        if (Test-Path -Path $Desired.LnkPath) {
            Remove-Item -Path $Desired.LnkPath -Force -ErrorAction Stop
            Write-Log "REMOVED '$($Desired.Name)'$(if ($Reason) { " ($Reason)" })"
        }
    } catch {
        Write-Log "Failed to remove shortcut '$($Desired.Name)': $($_.Exception.Message)" 'ERROR'
    }
}

# =============================================================================
# MODES
# =============================================================================

function Invoke-Enforce {
    param([Parameter(Mandatory)][string]$DesktopPath)
    Write-Log "=== ENFORCE: converging Public desktop shortcuts ($DesktopPath) ==="

    $desiredSet = Get-DesiredShortcuts -DesktopPath $DesktopPath
    foreach ($desired in $desiredSet) {
        $actual = Get-ShortcutState -Path $desired.LnkPath

        if ($null -eq $desired.Exe) {
            # Browser not installed: desired state is 'absent'.
            $what = if ($desired.Type -eq 'App') { 'no candidate Targets path exists' } else { 'the configured Browser executable does not exist' }
            Write-Log "'$($desired.Name)': browser not installed ($what) - skipping creation; a shortcut to a missing executable is worse than no shortcut." 'WARN'
            if ($null -ne $actual) {
                Remove-ManagedShortcut -Desired $desired -Reason 'stale: browser uninstalled'
            }
            continue
        }

        if ($null -eq $actual) {
            if (New-ManagedShortcut -Desired $desired) {
                Write-Log "CREATED '$($desired.Name)' -> $($desired.Exe)$(if ($desired.Arguments) { " $($desired.Arguments)" })"
            }
        } elseif (-not (Test-ShortcutMatch -Desired $desired -Actual $actual)) {
            if (New-ManagedShortcut -Desired $desired) {
                Write-Log "REPAIRED '$($desired.Name)' (was: target='$($actual.Target)' args='$($actual.Arguments)' icon='$($actual.Icon)')"
            }
        } else {
            Write-Log "OK      '$($desired.Name)' already correct" 'OK'
        }
    }

    # Verify every shortcut that should exist reads back correctly.
    foreach ($desired in $desiredSet) {
        if ($null -eq $desired.Exe) { continue }
        $actual = Get-ShortcutState -Path $desired.LnkPath
        if ($null -eq $actual -or -not (Test-ShortcutMatch -Desired $desired -Actual $actual)) {
            Write-Log "Verification failed for '$($desired.Name)' after enforcement." 'ERROR'
        }
    }

    # State stamp (informational only; Audit reads the live desktop).
    try {
        if (-not (Test-Path -Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
        New-ItemProperty -Path $StateKey -Name 'ScriptVersion'  -PropertyType String -Value $ScriptVersion -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'LastEnforceUtc' -PropertyType String -Value (Get-Date).ToUniversalTime().ToString('o') -Force | Out-Null
        New-ItemProperty -Path $StateKey -Name 'ManagedNames'   -PropertyType String -Value (($desiredSet | ForEach-Object { $_.Name }) -join '; ') -Force | Out-Null
    } catch {
        Write-Log "Could not write state stamp: $($_.Exception.Message)" 'WARN'
    }

    Write-Log 'Enforcement pass complete.'
}

function Invoke-Audit {
    param([Parameter(Mandatory)][string]$DesktopPath)
    Write-Log "=== AUDIT: comparing Public desktop shortcuts to configuration ==="

    foreach ($desired in Get-DesiredShortcuts -DesktopPath $DesktopPath) {
        $actual = Get-ShortcutState -Path $desired.LnkPath

        if ($null -eq $desired.Exe) {
            # Browser absent: not drift (remediation could not converge it) -
            # unless a stale shortcut lingers, which Enforce CAN fix.
            if ($null -ne $actual) {
                Write-Log "DRIFT   '$($desired.Name)' present but its browser is not installed (stale shortcut)" 'DRIFT'
            } else {
                Write-Log "SKIP    '$($desired.Name)': browser not installed - item skipped, not counted as drift" 'WARN'
            }
            continue
        }

        if ($null -eq $actual) {
            Write-Log "DRIFT   '$($desired.Name)' missing (expected -> $($desired.Exe))" 'DRIFT'
        } elseif (-not (Test-ShortcutMatch -Desired $desired -Actual $actual)) {
            Write-Log "DRIFT   '$($desired.Name)' mismatched. Expected target='$($desired.Exe)' args='$($desired.Arguments)' icon='$($desired.Icon)'; actual target='$($actual.Target)' args='$($actual.Arguments)' icon='$($actual.Icon)'" 'DRIFT'
        } else {
            Write-Log "OK      '$($desired.Name)' present and correct" 'OK'
        }
    }

    if ($script:DriftCount -eq 0) {
        Write-Log 'Audit result: COMPLIANT'
    } else {
        Write-Log "Audit result: $($script:DriftCount) drift item(s) found" 'WARN'
    }
}

function Invoke-Discover {
    param([Parameter(Mandatory)][string]$DesktopPath)
    Write-Log "=== DISCOVER: reporting Public desktop shortcut state ($DesktopPath) ==="

    $desiredSet = Get-DesiredShortcuts -DesktopPath $DesktopPath
    foreach ($desired in $desiredSet) {
        $actual = Get-ShortcutState -Path $desired.LnkPath
        if ($null -eq $desired.Exe) {
            $state = if ($null -ne $actual) { 'STALE (present, browser not installed)' } else { 'absent (browser not installed - expected)' }
            Write-Log "[managed] '$($desired.Name)': $state"
            continue
        }
        if ($null -eq $actual) {
            Write-Log "[managed] '$($desired.Name)': ABSENT (expected -> $($desired.Exe))"
        } else {
            $issues = @()
            if (([string]$actual.Target).ToLowerInvariant() -ne ([string]$desired.Exe).ToLowerInvariant()) { $issues += "wrong target ('$($actual.Target)')" }
            if ([string]$actual.Arguments -cne [string]$desired.Arguments) { $issues += "wrong arguments ('$($actual.Arguments)')" }
            if (([string]$actual.Icon).ToLowerInvariant() -ne ([string]$desired.Icon).ToLowerInvariant()) { $issues += "wrong icon ('$($actual.Icon)')" }
            if ($issues.Count -eq 0) {
                Write-Log "[managed] '$($desired.Name)': present and correct"
            } else {
                Write-Log "[managed] '$($desired.Name)': present, $($issues -join ', ')"
            }
        }
    }

    # Unmanaged shortcut files - report only, never touched by any mode.
    $managedPaths = @($desiredSet | ForEach-Object { $_.LnkPath.ToLowerInvariant() })
    $unmanaged = @(Get-ChildItem -Path $DesktopPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.lnk', '.url') -and $managedPaths -notcontains $_.FullName.ToLowerInvariant() })
    if ($unmanaged.Count -eq 0) {
        Write-Log 'No unmanaged .lnk/.url files on the Public desktop.'
    } else {
        foreach ($file in $unmanaged) {
            Write-Log "[unmanaged] '$($file.Name)' - not in `$Shortcuts, left alone by every mode"
        }
    }
}

function Invoke-Revert {
    param([Parameter(Mandatory)][string]$DesktopPath)
    Write-Log '=== REVERT: removing all managed shortcuts ==='

    foreach ($desired in Get-DesiredShortcuts -DesktopPath $DesktopPath) {
        if (Test-Path -Path $desired.LnkPath) {
            Remove-ManagedShortcut -Desired $desired -Reason 'revert'
        } else {
            Write-Log "OK      '$($desired.Name)' already absent" 'OK'
        }
    }

    if (Test-Path -Path $StateKey) {
        try {
            Remove-Item -Path $StateKey -Recurse -Force -ErrorAction Stop
            Write-Log "REMOVED state key $StateKey"
        } catch {
            Write-Log "Failed to remove state key ${StateKey}: $($_.Exception.Message)" 'ERROR'
        }
    }

    Write-Log 'Revert complete. Unmanaged shortcuts were not touched.'
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Manage-BrowserShortcuts v$ScriptVersion starting in mode: $Mode"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

if (-not (Test-ShortcutConfig)) {
    exit 2
}

$publicDesktop = Get-PublicDesktopPath
if ($null -eq $publicDesktop) {
    Write-Log 'Could not resolve the Public desktop path (%PUBLIC%\Desktop). Refusing to continue.' 'ERROR'
    exit 2
}

switch ($Mode) {
    'Enforce'  { Invoke-Enforce  -DesktopPath $publicDesktop }
    'Audit'    { Invoke-Audit    -DesktopPath $publicDesktop }
    'Discover' { Invoke-Discover -DesktopPath $publicDesktop }
    'Revert'   { Invoke-Revert   -DesktopPath $publicDesktop }
    default    {
        Write-Log "Unknown mode '$Mode'. Valid: Enforce, Audit, Discover, Revert." 'ERROR'
        exit 2
    }
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
