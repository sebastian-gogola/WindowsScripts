<#
.SYNOPSIS
    Local Admin Password Rotation for Iru (Kandji) MDM
    Mimics LAPS functionality by rotating the local admin password and storing it in Iru device notes.

.DESCRIPTION
    This script:
    1. Generates a cryptographically random password
    2. Sets it on the specified local admin account
    3. Looks up the device in Iru by serial number
    4. Posts the password (with timestamp) to the device notes via POST /v1/devices/{device_id}/notes

    Deploy via Iru MDM as a recurring script (e.g., every 30 days) for automatic rotation.

.NOTES
    Requires: PowerShell 5.1+, network access to your Iru API tenant
    API Docs: https://api-docs.iru.com
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

# ========================================================================================
# CONFIGURATION - Update these values before deploying
# ========================================================================================

# Iru API settings
$IruSubdomain    = "YOUR_SUBDOMAIN"          # e.g., "acme" from acme.api.kandji.io
$IruRegion       = "us"                      # "us" or "eu"
$IruApiToken     = "YOUR_API_TOKEN"          # Bearer token from Iru > Settings > Access

# Local admin account to manage
$LocalAdminUser  = "localadmin"              # Name of the local admin account

# Password policy
$PasswordLength  = 24                        # Length of generated password

# Scheduled task settings
$RotationDays    = 30                        # How often to rotate (in days)
$TaskName        = "IruLAPS-PasswordRotation"
$ScriptInstallPath = "$env:ProgramData\IruLAPS\Set-LocalAdminPassword.ps1"

# ========================================================================================
# FUNCTIONS
# ========================================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Output $entry

    $logDir = "$env:ProgramData\IruLAPS"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $entry | Out-File -Append -FilePath "$logDir\password-rotation.log" -Encoding UTF8
}

function New-SecurePassword {
    param([int]$Length = 24)

    $upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower   = "abcdefghjkmnpqrstuvwxyz"
    $digits  = "23456789"
    $special = "!@#$%^&*()-_=+"
    $all     = $upper + $lower + $digits + $special

    $rng   = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)

    # Guarantee at least one character from each class
    $password  = @()
    $password += $upper[$bytes[0] % $upper.Length]
    $password += $lower[$bytes[1] % $lower.Length]
    $password += $digits[$bytes[2] % $digits.Length]
    $password += $special[$bytes[3] % $special.Length]

    for ($i = 4; $i -lt $Length; $i++) {
        $password += $all[$bytes[$i] % $all.Length]
    }

    # Shuffle so guaranteed chars aren't always at the front
    $shuffled = $password | Sort-Object { Get-Random }

    $rng.Dispose()
    return -join $shuffled
}

function Get-DeviceSerialNumber {
    try {
        $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
        if ([string]::IsNullOrWhiteSpace($serial) -or $serial -eq "To Be Filled By O.E.M.") {
            throw "Invalid serial number retrieved: '$serial'"
        }
        return $serial.Trim()
    }
    catch {
        Write-Log "Failed to retrieve serial number: $_" -Level "ERROR"
        throw
    }
}

function Get-IruApiBaseUrl {
    if ($IruRegion -eq "eu") {
        return "https://$IruSubdomain.api.eu.kandji.io/api/v1"
    }
    else {
        return "https://$IruSubdomain.api.kandji.io/api/v1"
    }
}

function Get-IruHeaders {
    return @{
        "Authorization" = "Bearer $IruApiToken"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }
}

function Find-IruDeviceId {
    param([string]$SerialNumber)

    $baseUrl = Get-IruApiBaseUrl
    $headers = Get-IruHeaders
    $uri     = "$baseUrl/devices?serial_number=$SerialNumber"

    Write-Log "Looking up device in Iru: serial=$SerialNumber"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop

        if ($response -and $response.Count -gt 0) {
            $deviceId = $response[0].device_id
            Write-Log "Found device_id: $deviceId"
            return $deviceId
        }
        else {
            throw "No device found in Iru with serial number: $SerialNumber"
        }
    }
    catch {
        Write-Log "Device lookup failed: $_" -Level "ERROR"
        throw
    }
}

function Post-IruDeviceNote {
    <#
    .SYNOPSIS
        Posts a note to the device using POST /v1/devices/{device_id}/notes
        Body: { "content": "note text" }
    #>
    param(
        [string]$DeviceId,
        [string]$Password,
        [string]$AdminUser
    )

    $baseUrl   = Get-IruApiBaseUrl
    $headers   = Get-IruHeaders
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
    $hostname  = $env:COMPUTERNAME

    $noteContent = "[LAPS] $hostname | Account: $AdminUser | Password: $Password | Rotated: $timestamp"

    $body = @{ content = $noteContent } | ConvertTo-Json
    $uri  = "$baseUrl/devices/$DeviceId/notes"

    Write-Log "Posting password note to device_id: $DeviceId"

    try {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body -ErrorAction Stop
        Write-Log "Device note posted successfully."
        return $true
    }
    catch {
        Write-Log "Failed to post device note: $_" -Level "ERROR"
        throw
    }
}

function Set-LocalAdminPassword {
    param(
        [string]$Username,
        [string]$Password
    )

    $securePass = ConvertTo-SecureString -String $Password -AsPlainText -Force

    try {
        $null = Get-LocalUser -Name $Username -ErrorAction Stop
        Write-Log "Found existing local account: $Username"
        Set-LocalUser -Name $Username -Password $securePass -ErrorAction Stop
        Write-Log "Password updated for $Username"
    }
    catch [Microsoft.PowerShell.Commands.UserNotFoundException] {
        Write-Log "Account '$Username' not found - creating it." -Level "WARN"
        New-LocalUser -Name $Username `
                      -Password $securePass `
                      -Description "Iru LAPS managed admin" `
                      -PasswordNeverExpires `
                      -AccountNeverExpires `
                      -ErrorAction Stop
        Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction Stop
        Write-Log "Created local admin account: $Username"
    }
    catch {
        Write-Log "Failed to set password: $_" -Level "ERROR"
        throw
    }
}

function Install-LapsScheduledTask {
    <#
    .SYNOPSIS
        Copies this script to a permanent location and registers a scheduled task
        to run it every $RotationDays days as SYSTEM. Skips if the task already exists.
    #>

    # Check if task already exists
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Scheduled task '$TaskName' already exists - skipping install."
        return
    }

    # Copy the script to its permanent home
    $installDir = Split-Path $ScriptInstallPath -Parent
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    $currentScript = $MyInvocation.ScriptName
    if (-not [string]::IsNullOrWhiteSpace($currentScript)) {
        Copy-Item -Path $currentScript -Destination $ScriptInstallPath -Force
        Write-Log "Copied script to $ScriptInstallPath"
    }
    else {
        # If run interactively or via stdin, write the current file content
        # This handles Iru pushing the script without a file path
        Write-Log "No script path detected (MDM push). Writing script to $ScriptInstallPath" -Level "WARN"
        $scriptContent = Get-Content -Path $PSCommandPath -Raw -ErrorAction SilentlyContinue
        if ($scriptContent) {
            $scriptContent | Out-File -FilePath $ScriptInstallPath -Encoding UTF8 -Force
        }
        else {
            Write-Log "Cannot determine script source to copy. Task will point to $ScriptInstallPath - ensure the file exists." -Level "ERROR"
            return
        }
    }

    # Build the scheduled task
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptInstallPath`""

    # Trigger: run every X days, starting tomorrow at 2:00 AM (avoids user hours)
    $startTime = (Get-Date).Date.AddDays(1).AddHours(2)
    $trigger   = New-ScheduledTaskTrigger -Daily -DaysInterval $RotationDays -At $startTime

    # Run as SYSTEM so it works without a logged-in user
    $principal = New-ScheduledTaskPrincipal `
        -UserId "NT AUTHORITY\SYSTEM" `
        -RunLevel Highest `
        -LogonType ServiceAccount

    # Settings: retry on failure, run even on battery, wake to run
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 15) `
        -WakeToRun

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Iru LAPS: Rotates the local admin password every $RotationDays days and posts it to Iru device notes." `
        -Force | Out-Null

    Write-Log "Scheduled task '$TaskName' registered - runs every $RotationDays days at 2:00 AM as SYSTEM."
}

# ========================================================================================
# MAIN EXECUTION
# ========================================================================================

try {
    Write-Log "===== Iru LAPS Password Rotation Starting ====="

    # 1. Install/verify the scheduled task for recurring rotation
    Install-LapsScheduledTask

    # 2. Generate new password
    $newPassword = New-SecurePassword -Length $PasswordLength
    Write-Log "Generated new password ($PasswordLength chars)."

    # 3. Set password on the local admin account
    Set-LocalAdminPassword -Username $LocalAdminUser -Password $newPassword
    Write-Log "Local password set successfully."

    # 4. Look up device in Iru by serial number
    $serial   = Get-DeviceSerialNumber
    $deviceId = Find-IruDeviceId -SerialNumber $serial

    # 5. Post the password to the device notes
    Post-IruDeviceNote -DeviceId $deviceId -Password $newPassword -AdminUser $LocalAdminUser

    Write-Log "===== Password rotation complete ====="
    exit 0
}
catch {
    Write-Log "Password rotation FAILED: $_" -Level "ERROR"
    exit 1
}
