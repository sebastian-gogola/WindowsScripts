<#
.SYNOPSIS
    Iru Custom App install wrapper for Make Me Admin: installs the bundled MSI
    per-machine, applies organization policy to the registry, and writes the
    detection marker the Iru Library Item reads.

.DESCRIPTION
    Runs from the root of the Custom App package as NT AUTHORITY\SYSTEM. Locates
    the single Make Me Admin x64 MSI beside itself, installs it silently
    (ALLUSERS=1 is set by the package itself), confirms the product registered
    in the machine-wide uninstall hive, writes the configured policy values to
    the enforced key

        HKLM\SOFTWARE\Policies\Sinclair Community College\Make Me Admin

    and only then writes HKLM\SOFTWARE\Iru\Apps\MakeMeAdmin = $AppVersion, so
    the Library Item's detection rule goes green only after policy is in place,
    not merely after files land.

    Pair with Uninstall-MakeMeAdmin.ps1 in the same package. See README.md for
    the Library Item configuration and the full Make Me Admin settings table.

.NOTES
    File     : Install-MakeMeAdmin.ps1
    Version  : 1.0.0 (2026-09-14)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Target   : Windows 11 24H2 or later, x64
    Runs as  : SYSTEM (Iru Custom App install command)
    PS       : Windows PowerShell 5.1 (no external modules)
    Status   : UNTESTED - not yet validated on a device or tenant

    Exit codes:
      0 = installed and configured (MSI 3010/1641, reboot pending, count as success)
      1 = MSI install failed, product not registered after install, or a
          registry write failed
      2 = precondition failure (not elevated, or no x64 MSI beside the script)
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

# Four-part version string written to the detection marker. Must equal the
# Library Item's Detection -> String value; bump both together on every release.
# PLACEHOLDER - read the real DisplayVersion off a test install first (README §8).
$AppVersion = '2.4.1.0'

# Who may elevate. Prefer SIDs on Entra-joined / sometimes-offline devices so
# the entity resolves without a directory connection. Names must be DOMAIN\Name
# (UPNs do NOT work); for a LOCAL group use '.' or %COMPUTERNAME% as DOMAIN.
# Default allows all interactive users (well-known SID S-1-5-4).
$AllowedEntities = @('S-1-5-4')

# Default elevation window, in MINUTES. Make Me Admin's own default is 10.
$AdminRightsTimeout = 15

# Prompt for a reason: 0 = None, 1 = Optional, 2 = Required
$PromptForReason = 1

# Require the user to (re)enter Windows credentials before elevating: 0/1
$RequireAuthentication = 1

# How many times a user may renew their elevation before it must lapse.
$RenewalsAllowed = 1

# Remove admin rights immediately if the user logs off: 0/1
$RemoveAdminRightsOnLogout = 1

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Install-MakeMeAdmin.log'
$MsiLog       = Join-Path $LogDirectory 'Install-MakeMeAdmin-msi.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '1.0.0'
$PolicyKey     = 'HKLM:\SOFTWARE\Policies\Sinclair Community College\Make Me Admin'
$MarkerKey     = 'HKLM:\SOFTWARE\Iru\Apps'
$MarkerName    = 'MakeMeAdmin'
$MsiExe        = Join-Path $env:SystemRoot 'System32\msiexec.exe'
$UninstallHives = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

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
}

function Test-IsElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "Install-MakeMeAdmin v$ScriptVersion starting as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

# The package must contain exactly one x64 MSI. Releases ship one MSI per
# language and this takes the first match, so bundling two installs an
# arbitrary one - see README §2.
$msi = Get-ChildItem -Path $PSScriptRoot -Filter '*x64*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $msi) {
    Write-Log "No x64 MSI found beside this script in $PSScriptRoot. The package is incomplete." 'ERROR'
    exit 2
}
Write-Log "Found MSI: $($msi.Name)"

try {
    # 1. Install silently, per-machine. Not $args - that is an automatic variable.
    $msiArgs = @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart', '/l*v', "`"$MsiLog`"")
    Write-Log "Running: msiexec.exe $($msiArgs -join ' ')"
    $p = Start-Process -FilePath $MsiExe -ArgumentList $msiArgs -Wait -PassThru -ErrorAction Stop
    Write-Log "msiexec exit code: $($p.ExitCode)"
    if ($p.ExitCode -notin 0, 3010, 1641) {
        throw "MSI install failed with exit code $($p.ExitCode). See $MsiLog."
    }
    if ($p.ExitCode -ne 0) {
        Write-Log 'MSI reports a reboot is pending; the install itself succeeded.' 'WARN'
    }

    # 2. Confirm the product registered in the machine-wide uninstall hive.
    $installed = Get-ItemProperty -Path $UninstallHives -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like '*Make Me Admin*' } |
                 Select-Object -First 1
    if (-not $installed) {
        throw "MSI reported success but no 'Make Me Admin' uninstall entry was found."
    }
    Write-Log "Confirmed installed: $($installed.DisplayName) $($installed.DisplayVersion)" 'OK'

    # 3. Apply organization policy to the enforced (Policies) key, which takes
    #    precedence over the plain settings key.
    if (-not (Test-Path -Path $PolicyKey)) { New-Item -Path $PolicyKey -Force | Out-Null }
    New-ItemProperty -Path $PolicyKey -Name 'Allowed Entities'                      -Value $AllowedEntities           -PropertyType MultiString -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Admin Rights Timeout'                  -Value $AdminRightsTimeout        -PropertyType DWord       -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Prompt For Reason'                     -Value $PromptForReason           -PropertyType DWord       -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Require Authentication For Privileges' -Value $RequireAuthentication     -PropertyType DWord       -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Renewals Allowed'                      -Value $RenewalsAllowed           -PropertyType DWord       -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $PolicyKey -Name 'Remove Admin Rights On Logout'         -Value $RemoveAdminRightsOnLogout -PropertyType DWord       -Force -ErrorAction Stop | Out-Null
    Write-Log "Policy written to $PolicyKey" 'OK'

    # 4. Write the detection marker only after everything else succeeded.
    if (-not (Test-Path -Path $MarkerKey)) { New-Item -Path $MarkerKey -Force | Out-Null }
    New-ItemProperty -Path $MarkerKey -Name $MarkerName -Value $AppVersion -PropertyType String -Force -ErrorAction Stop | Out-Null
    Write-Log "Marker written: $MarkerKey\$MarkerName = $AppVersion" 'OK'

    Write-Log 'Completed successfully.'
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log 'Install failed. The detection marker was not written, so Iru will retry on its next enforcement cycle.' 'ERROR'
    exit 1
}
