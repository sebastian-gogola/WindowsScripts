<#
.SYNOPSIS
    Iru Custom App uninstall wrapper for Make Me Admin: removes the product,
    clears its configuration keys, and clears the detection marker.

.DESCRIPTION
    Runs from the root of the Custom App package as NT AUTHORITY\SYSTEM. Hands
    the bundled MSI to msiexec /x, which reads the ProductCode out of that file -
    so no GUID is hardcoded. This works because Iru stages the same package for
    install and uninstall, meaning the bundled MSI is the one that was
    installed. It cannot remove a different build: if the installed product's
    ProductCode differs, msiexec returns 1605 (not installed), which is treated
    as "already removed".

    Afterwards it deletes both Make Me Admin registry keys (enforced policy and
    plain settings) and removes HKLM\SOFTWARE\Iru\Apps\MakeMeAdmin so the
    Library Item reads the device as not installed.

    It does NOT demote a user who is elevated at that moment - the service that
    would have removed them is gone. See README.md (Rollback).

.NOTES
    File     : Uninstall-MakeMeAdmin.ps1
    Version  : 1.0.0 (2026-09-14)
    Repo     : github.com/sebastian-gogola/WindowsScripts
    Target   : Windows 11 24H2 or later, x64
    Runs as  : SYSTEM (Iru Custom App uninstall command)
    PS       : Windows PowerShell 5.1 (no external modules)
    Status   : UNTESTED - not yet validated on a device or tenant

    Exit codes:
      0 = product removed (or already absent, 1605) and keys/marker cleared
      1 = MSI uninstall failed with a non-success code
      2 = precondition failure (not elevated, or no x64 MSI beside the script -
          nothing is changed in that case, so the failure is visible)
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

# Logging
$LogDirectory = Join-Path $env:ProgramData 'IruScripts\Logs'
$LogFile      = Join-Path $LogDirectory 'Uninstall-MakeMeAdmin.log'

# =============================================================================
# CONSTANTS
# =============================================================================

$ScriptVersion = '1.0.0'
$PolicyKey     = 'HKLM:\SOFTWARE\Policies\Sinclair Community College\Make Me Admin'
$SettingsKey   = 'HKLM:\SOFTWARE\Sinclair Community College\Make Me Admin'
$MarkerKey     = 'HKLM:\SOFTWARE\Iru\Apps'
$MarkerName    = 'MakeMeAdmin'
$MsiExe        = Join-Path $env:SystemRoot 'System32\msiexec.exe'

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

Write-Log "Uninstall-MakeMeAdmin v$ScriptVersion starting as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

if (-not (Test-IsElevated)) {
    Write-Log 'This script must run elevated (SYSTEM via Iru, or an elevated shell for testing).' 'ERROR'
    exit 2
}

$msi = Get-ChildItem -Path $PSScriptRoot -Filter '*x64*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $msi) {
    Write-Log "No x64 MSI found beside this script in $PSScriptRoot - cannot determine what to remove. Nothing was changed." 'ERROR'
    exit 2
}
Write-Log "Found MSI: $($msi.Name)"

try {
    # 1. Remove the product. Not $args - that is an automatic variable.
    $msiArgs = @('/x', "`"$($msi.FullName)`"", '/qn', '/norestart')
    Write-Log "Running: msiexec.exe $($msiArgs -join ' ')"
    $p = Start-Process -FilePath $MsiExe -ArgumentList $msiArgs -Wait -PassThru -ErrorAction Stop
    Write-Log "msiexec exit code: $($p.ExitCode)"
    if ($p.ExitCode -eq 1605) {
        # "This action is only valid for products that are currently installed."
        Write-Log 'Product was not installed (1605); treating as already removed.' 'WARN'
    }
    elseif ($p.ExitCode -notin 0, 3010, 1641) {
        throw "MSI uninstall failed with exit code $($p.ExitCode)."
    }
    else {
        Write-Log 'Product removed.' 'OK'
    }

    # 2. Clear configuration and the detection marker.
    Remove-Item -Path $PolicyKey   -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $SettingsKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $MarkerKey -Name $MarkerName -Force -ErrorAction SilentlyContinue
    Write-Log 'Cleared policy key, settings key, and detection marker.' 'OK'

    Write-Log 'Completed successfully.'
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log 'Uninstall failed. Keys and marker were left in place.' 'ERROR'
    exit 1
}
