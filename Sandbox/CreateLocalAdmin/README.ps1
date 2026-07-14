<#
.SYNOPSIS
    Creates a local administrator account on a Windows endpoint.
    Designed for deployment via MDM (Intune, Workspace ONE, etc.).

.DESCRIPTION
    This script is idempotent — safe to run multiple times on the same device.
    It creates a local admin account, adds it to the Administrators group using
    the well-known SID (S-1-5-32-544) for language-neutral compatibility, sets
    the password to never expire, optionally hides it from the login screen, and
    optionally disables the built-in Administrator account as a hardening step.

    All output is written to stdout/stderr for MDM capture. Local file logging
    is available as an optional backup but is disabled by default.

.NOTES
    Author  : MDM Deployment Script
    Version : 1.1
    Requires: PowerShell 5.1+, Windows 10/11
    Context : Must run as SYSTEM (MDM scripts run in this context by default)

    SECURITY NOTICE:
    The password is stored in cleartext in this script. This is a known and
    accepted tradeoff for MDM-pushed scripts (the transport is encrypted).
    If your MDM supports script parameters or encrypted variables, prefer
    those over hardcoding. Rotate this password periodically.
#>

# ============================================================================
# CONFIGURATION — Update these values before deploying
# ============================================================================

$AdminUsername    = "LocalITAdmin"                  # Name for the new local admin account
$AdminPassword    = "Ch@ngeM3!2026Dep10y"           # Static password — change before deploying
$AdminDescription = "MDM-managed local admin"       # Account description shown in lusrmgr.msc

# --- Optional Features ---
$HideFromLogin    = $true                           # $true  = hide from Windows login/lock screen
$DisableBuiltIn   = $true                           # $true  = disable the built-in Administrator (SID -500)

# --- Local Logging (Optional Backup) ---
# The MDM agent captures all stdout/stderr and reports it to the console.
# Enable local logging only if you want a backup log file on the endpoint.
$EnableLocalLog   = $false                          # $true  = write a log file to disk as backup
$LogPath          = "$env:ProgramData\MDM-Logs"     # Directory for the local log file
$LogFile          = "$LogPath\Create-LocalAdmin.log"

# ============================================================================
# LOGGING HELPER
# ============================================================================

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry     = "$timestamp [$Level] $Message"

    # Always write to stdout/stderr so the MDM agent captures it
    if ($Level -eq "ERROR") {
        Write-Error $entry
    }
    else {
        Write-Output $entry
    }

    # Optionally write to a local file as backup
    if ($EnableLocalLog) {
        if (-not (Test-Path $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {

    Write-Log "========== Script execution started =========="
    Write-Log "Target account : $AdminUsername"
    Write-Log "Hide from login: $HideFromLogin"
    Write-Log "Disable built-in Admin: $DisableBuiltIn"
    Write-Log "Local logging  : $EnableLocalLog"

    # ------------------------------------------------------------------
    # 1. Check if the account already exists (idempotency)
    # ------------------------------------------------------------------
    $existingUser = $null
    try {
        $existingUser = Get-LocalUser -Name $AdminUsername -ErrorAction Stop
    }
    catch {
        # Account does not exist — expected path on first run
    }

    if ($existingUser) {
        Write-Log "Account '$AdminUsername' already exists. Ensuring configuration is correct."

        # Reset password to the defined value (enforces consistency on re-run)
        $securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
        Set-LocalUser -Name $AdminUsername -Password $securePassword -ErrorAction Stop
        Write-Log "Password reset to defined value."

        # Ensure account is enabled (in case it was manually disabled)
        Enable-LocalUser -Name $AdminUsername -ErrorAction Stop
        Write-Log "Account enabled."
    }
    else {
        Write-Log "Account '$AdminUsername' does not exist. Creating..."

        $securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force

        $newUserParams = @{
            Name                     = $AdminUsername
            Password                 = $securePassword
            Description              = $AdminDescription
            PasswordNeverExpires     = $true
            AccountNeverExpires      = $true
            UserMayNotChangePassword = $false
        }

        New-LocalUser @newUserParams -ErrorAction Stop
        Write-Log "Account '$AdminUsername' created successfully."
    }

    # ------------------------------------------------------------------
    # 2. Ensure membership in the local Administrators group
    #
    #    Uses the well-known SID S-1-5-32-544 instead of the group name
    #    so this works on non-English Windows installations (e.g.,
    #    "Administrateurs" on French, "Administratoren" on German).
    # ------------------------------------------------------------------
    $adminGroup = Get-LocalGroup -SID "S-1-5-32-544"
    $isMember   = Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "*\$AdminUsername" }

    if ($isMember) {
        Write-Log "Account is already a member of '$($adminGroup.Name)'."
    }
    else {
        Add-LocalGroupMember -Group $adminGroup.Name -Member $AdminUsername -ErrorAction Stop
        Write-Log "Added '$AdminUsername' to '$($adminGroup.Name)' group."
    }

    # ------------------------------------------------------------------
    # 3. Hide from the login / lock screen (optional)
    #
    #    Creates a DWORD value of 0 under the SpecialAccounts\UserList
    #    registry key. The account can still be used via "Other user",
    #    runas, RDP, or PowerShell — it is only hidden from the UI.
    # ------------------------------------------------------------------
    if ($HideFromLogin) {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"

        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
            Write-Log "Created registry path for SpecialAccounts\UserList."
        }

        New-ItemProperty -Path $regPath `
                         -Name $AdminUsername `
                         -Value 0 `
                         -PropertyType DWord `
                         -Force | Out-Null

        Write-Log "Account hidden from login screen via registry."
    }
    else {
        Write-Log "HideFromLogin is disabled — account will be visible on the login screen."
    }

    # ------------------------------------------------------------------
    # 4. Disable the built-in Administrator account (optional hardening)
    #
    #    Finds the built-in Administrator by its SID (ends in -500)
    #    rather than by name, so it works even if the account has been
    #    renamed. This is a CIS Benchmark recommendation.
    # ------------------------------------------------------------------
    if ($DisableBuiltIn) {
        try {
            $builtInAdmin = Get-LocalUser | Where-Object { $_.SID -like "S-1-5-21-*-500" }

            if ($builtInAdmin.Enabled) {
                Disable-LocalUser -Name $builtInAdmin.Name -ErrorAction Stop
                Write-Log "Built-in Administrator ('$($builtInAdmin.Name)') has been disabled."
            }
            else {
                Write-Log "Built-in Administrator is already disabled."
            }
        }
        catch {
            Write-Log "Could not disable built-in Administrator: $_" -Level "WARN"
        }
    }
    else {
        Write-Log "DisableBuiltIn is disabled — built-in Administrator account left unchanged."
    }

    # ------------------------------------------------------------------
    # 5. Final validation
    # ------------------------------------------------------------------
    $validate   = Get-LocalUser -Name $AdminUsername -ErrorAction Stop
    $groupCheck = Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "*\$AdminUsername" }

    Write-Log "--- Validation ---"
    Write-Log "Account exists : $($validate -ne $null)"
    Write-Log "Enabled        : $($validate.Enabled)"
    Write-Log "Pwd expires    : $($validate.PasswordExpires)"
    Write-Log "In Admins group: $($groupCheck -ne $null)"
    Write-Log "========== Script completed successfully =========="

    exit 0
}
catch {
    Write-Log "FATAL — Unhandled exception: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Log "========== Script execution FAILED ==========" -Level "ERROR"

    # Exit with failure code so MDM reports the script as failed
    exit 1
}
