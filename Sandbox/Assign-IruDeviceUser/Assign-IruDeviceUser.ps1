################################################################################
# Assign-IruDeviceUser.ps1
################################################################################
# Original concept by Craig Hinchliffe, Solutions Engineering, Iru, Inc.
# Revised 2026/08/26 (v2.0.0)
#
# Assigns the logged-in user to this device in Iru using the Iru API.
# Intended for fleets where user assignment was never performed, for
# migrations (which do not carry user assignment), and for Autopilot
# enrollments (which do not currently perform user assignment).
#
################################################################################
# Tested on
################################################################################
#   - Windows 11 24H2
#   - Windows PowerShell 5.1
################################################################################
# License
################################################################################
# Copyright 2026 Iru, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
################################################################################

#Requires -Version 5.1

# ============================================================
# CONFIGURATION
# ============================================================

# Iru API base URL for your tenant. US tenants use
# https://SubDomain.api.kandji.io and EU tenants use
# https://SubDomain.api.eu.kandji.io
$IRU_BASE_URL  = "https://subdomain.api.eu.kandji.io"

# API token. Scope this token to the minimum required permissions,
# which are Device list, Device details, Update device, and List users.
$IRU_API_TOKEN = "yourapitoken"

# When $true, an auto-detected UPN is shown to the user for confirmation
# instead of being applied silently. Recommended for shared devices.
$REQUIRE_UPN_CONFIRMATION = $false

# Maximum seconds the SYSTEM instance waits for the user session to finish.
$USER_TASK_TIMEOUT_SECONDS = 900

# API pagination page size.
$PAGE_LIMIT = 300

# Local accounts that are never treated as the device user.
$EXCLUDED_ACCOUNTS = @(
    "Administrator",
    "DefaultAccount",
    "Guest",
    "WDAGUtilityAccount",
    "SYSTEM",
    "LOCAL SERVICE",
    "NETWORK SERVICE"
)

# ============================================================
# CONSTANTS AND PATHS
# ============================================================

$SCRIPT_VERSION = "2.0.0"
$SCRIPT_NAME    = "Assign-IruDeviceUser"
$TASK_NAME      = "IruAssignUser"

$WORK_DIR    = Join-Path $env:ProgramData "IruScripts\UserAssignment"
$LOG_DIR     = Join-Path $env:ProgramData "IruScripts\Logs"
$RESULT_PATH = Join-Path $WORK_DIR "assignment_result.json"
$SCRIPT_COPY = Join-Path $WORK_DIR ($SCRIPT_NAME + ".ps1")
$STATE_KEY   = "HKLM:\SOFTWARE\IruScripts\UserAssignment"

$IS_SYSTEM = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -eq "NT AUTHORITY\SYSTEM")

foreach ($dir in @($WORK_DIR, $LOG_DIR)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

if ($IS_SYSTEM) {
    $LOG_FILE = Join-Path $LOG_DIR ($SCRIPT_NAME + "_SYSTEM.log")
} else {
    # Per-user log file avoids ACL conflicts with files created by SYSTEM
    # or by a different previous user.
    $LOG_FILE = Join-Path $LOG_DIR ($SCRIPT_NAME + "_User_" + $env:USERNAME + ".log")
}

# Enforce TLS 1.2 for API calls on Windows PowerShell 5.1.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ============================================================
# LOGGING
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + " [" + $Level + "] " + $Message
    try {
        $line | Out-File -FilePath $LOG_FILE -Append -Encoding ASCII -ErrorAction Stop
    } catch {
        # Logging must never break the workflow.
    }
    if ($Level -eq "ERROR") { Write-Host ("ERROR - " + $Message) } else { Write-Host $Message }
}

try {
    "========================================" | Out-File -FilePath $LOG_FILE -Encoding ASCII -ErrorAction Stop
} catch { }
Write-Log ("  " + $SCRIPT_NAME + " v" + $SCRIPT_VERSION)
Write-Log ("  Started " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Write-Log "========================================"
Write-Log ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
Write-Log ("Machine " + $env:COMPUTERNAME)
Write-Log ("PowerShell " + $PSVersionTable.PSVersion.ToString())

# ============================================================
# SHARED HELPERS
# ============================================================

function Write-ResultFile {
    param(
        [string]$Status,
        [string]$Message,
        [string]$UserEmail = "",
        [string]$UserName  = "",
        [string]$DeviceName = ""
    )
    $result = @{
        status      = $Status
        message     = $Message
        user_email  = $UserEmail
        user_name   = $UserName
        device_name = $DeviceName
        timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    try {
        $result | ConvertTo-Json | Out-File -FilePath $RESULT_PATH -Encoding ASCII -Force
        Write-Log ("[RESULT] Wrote result file with status " + $Status)
    } catch {
        Write-Log ("[RESULT] Failed to write result file. " + $_.Exception.Message) "ERROR"
    }
}

function Get-ExitCodeForStatus {
    param([string]$Status)
    # 0 = success or benign no-op
    # 1 = user-recoverable outcome, safe to re-run
    # 2 = fatal error requiring admin attention
    switch ($Status) {
        "assigned"         { return 0 }
        "already_assigned" { return 0 }
        "cancelled"        { return 1 }
        "user_not_found"   { return 1 }
        default            { return 2 }
    }
}

function Set-StateRegistry {
    param([string]$Status, [string]$UserEmail = "", [string]$DeviceName = "")
    try {
        if (-not (Test-Path $STATE_KEY)) {
            New-Item -Path $STATE_KEY -Force | Out-Null
        }
        Set-ItemProperty -Path $STATE_KEY -Name "LastRunTimestamp" -Value (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Set-ItemProperty -Path $STATE_KEY -Name "LastRunStatus"    -Value $Status
        Set-ItemProperty -Path $STATE_KEY -Name "AssignedUserEmail" -Value $UserEmail
        Set-ItemProperty -Path $STATE_KEY -Name "DeviceName"       -Value $DeviceName
        Set-ItemProperty -Path $STATE_KEY -Name "ScriptVersion"    -Value $SCRIPT_VERSION
        Write-Log ("[STATE] Registry state recorded as " + $Status)
    } catch {
        Write-Log ("[STATE] Failed to write registry state. " + $_.Exception.Message) "ERROR"
    }
}

# ============================================================
# SYSTEM CONTEXT - RELAUNCH IN USER SESSION AND COLLECT RESULT
# ============================================================

if ($IS_SYSTEM) {
    Write-Log "[SYSTEM] Running as SYSTEM. Detecting the logged-in user."

    $loggedInUser   = $null
    $loggedInDomain = $null

    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($explorer) {
            $owner          = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            $loggedInUser   = $owner.User
            $loggedInDomain = $owner.Domain
            Write-Log ("[SYSTEM] Detected interactive session for " + $loggedInDomain + "\" + $loggedInUser)
        }
    } catch {
        Write-Log ("[SYSTEM] WMI session detection failed. " + $_.Exception.Message) "ERROR"
    }

    if (-not $loggedInUser) {
        Write-Log "[SYSTEM] No logged-in user detected. A user session is required." "ERROR"
        Set-StateRegistry -Status "no_user_session"
        exit 2
    }

    if (-not $loggedInDomain -or $loggedInDomain.Trim() -eq "") {
        $loggedInDomain = $env:COMPUTERNAME
    }
    $fullUserName = $loggedInDomain + "\" + $loggedInUser

    # Copy this script into the working directory so the scheduled task has
    # a stable path. The copy is deleted during cleanup because it contains
    # the API token.
    try {
        Copy-Item -Path $PSCommandPath -Destination $SCRIPT_COPY -Force -ErrorAction Stop
        Write-Log ("[SYSTEM] Script copied to " + $SCRIPT_COPY)
    } catch {
        Write-Log ("[SYSTEM] Failed to stage script copy. " + $_.Exception.Message) "ERROR"
        Set-StateRegistry -Status "stage_failed"
        exit 2
    }

    # Remove any stale result file from a previous run.
    Remove-Item -Path $RESULT_PATH -Force -ErrorAction SilentlyContinue

    # Grant the interactive user Modify on the working and log directories so
    # a standard (non-admin) user session can write the result file and its
    # own log. The grant is removed during cleanup.
    foreach ($dir in @($WORK_DIR, $LOG_DIR)) {
        $grant = $fullUserName + ":(OI)(CI)M"
        $icaclsOut = & icacls $dir /grant $grant 2>&1
        Write-Log ("[SYSTEM] ACL grant on " + $dir + " -> " + ($icaclsOut -join " "))
    }

    $psPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $psArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -File """ + $SCRIPT_COPY + """"

    schtasks /Delete /TN $TASK_NAME /F 2>$null | Out-Null

    $createResult = schtasks /Create /TN $TASK_NAME /TR ($psPath + " " + $psArgs) /SC ONCE /ST 00:00 /RU ('"' + $fullUserName + '"') /IT /F 2>&1
    Write-Log ("[SYSTEM] schtasks create -> " + ($createResult -join " "))

    $runResult = schtasks /Run /TN $TASK_NAME 2>&1
    Write-Log ("[SYSTEM] schtasks run -> " + ($runResult -join " "))

    # Wait for the user session to write the result file. The result file is
    # the primary completion signal because schtasks status text is localized
    # and unreliable for parsing.
    $waited = 0
    while ($waited -lt $USER_TASK_TIMEOUT_SECONDS) {
        Start-Sleep -Seconds 3
        $waited += 3
        if (Test-Path $RESULT_PATH) {
            Write-Log ("[SYSTEM] Result file detected after " + $waited + " seconds.")
            # Small grace period in case the file write is still in flight.
            Start-Sleep -Seconds 2
            break
        }
    }

    # Read and evaluate the result.
    $status     = "timeout"
    $userEmail  = ""
    $deviceName = ""
    if (Test-Path $RESULT_PATH) {
        try {
            $resultJson = Get-Content -Path $RESULT_PATH -Raw -ErrorAction Stop
            $result     = ConvertFrom-Json -InputObject $resultJson
            $status     = [string]$result.status
            $userEmail  = [string]$result.user_email
            $deviceName = [string]$result.device_name
            Write-Log ("[SYSTEM] User session result -> " + $status + " (" + [string]$result.message + ")")
        } catch {
            $status = "result_parse_error"
            Write-Log ("[SYSTEM] Failed to parse result file. " + $_.Exception.Message) "ERROR"
        }
    } else {
        Write-Log ("[SYSTEM] No result file after " + $USER_TASK_TIMEOUT_SECONDS + " seconds. Treating as timeout.") "ERROR"
    }

    # Cleanup. The staged script copy contains the API token and must not
    # persist on disk.
    schtasks /End /TN $TASK_NAME 2>$null | Out-Null
    schtasks /Delete /TN $TASK_NAME /F 2>$null | Out-Null
    Remove-Item -Path $SCRIPT_COPY -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $RESULT_PATH -Force -ErrorAction SilentlyContinue
    foreach ($dir in @($WORK_DIR, $LOG_DIR)) {
        & icacls $dir /remove:g $fullUserName 2>&1 | Out-Null
    }
    Write-Log "[SYSTEM] Cleanup complete. Task, staged script, result file, and ACL grants removed."

    Set-StateRegistry -Status $status -UserEmail $userEmail -DeviceName $deviceName

    $exitCode = Get-ExitCodeForStatus -Status $status
    Write-Log ("[SYSTEM] Exiting with code " + $exitCode + ".")
    exit $exitCode
}

# ============================================================
# USER SESSION CONTEXT
# ============================================================

Write-Log "[USER] Running in user session context."

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$DIALOG_TITLE = "Device User Assignment"

function Show-Message {
    param([string]$Message, [string]$Type = "Information")
    $icon = [System.Windows.Forms.MessageBoxIcon]::Information
    if ($Type -eq "Error")   { $icon = [System.Windows.Forms.MessageBoxIcon]::Error }
    if ($Type -eq "Warning") { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
    [System.Windows.Forms.MessageBox]::Show($Message, $DIALOG_TITLE, [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
}

function Test-EmailFormat {
    param([string]$Email)
    return ($Email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

function Show-EmailDialog {
    param([string]$Prefill = "", [string]$DetectedLocalUser = "")

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $DIALOG_TITLE
    $form.Size            = New-Object System.Drawing.Size(440, 320)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.TopMost         = $true

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text     = "Enter your work email address to register this device to your account."
    $lblIntro.Location = New-Object System.Drawing.Point(20, 18)
    $lblIntro.Size     = New-Object System.Drawing.Size(390, 34)
    $form.Controls.Add($lblIntro)

    $y = 56
    if ($DetectedLocalUser -ne "") {
        $lblDetected = New-Object System.Windows.Forms.Label
        $lblDetected.Text      = "Detected local user " + $DetectedLocalUser
        $lblDetected.Location  = New-Object System.Drawing.Point(20, $y)
        $lblDetected.Size      = New-Object System.Drawing.Size(390, 18)
        $lblDetected.ForeColor = [System.Drawing.Color]::DimGray
        $form.Controls.Add($lblDetected)
        $y += 26
    }

    $lblEmail = New-Object System.Windows.Forms.Label
    $lblEmail.Text     = "Work email address"
    $lblEmail.Location = New-Object System.Drawing.Point(20, $y)
    $lblEmail.Size     = New-Object System.Drawing.Size(390, 16)
    $form.Controls.Add($lblEmail)
    $y += 20

    $txtEmail = New-Object System.Windows.Forms.TextBox
    $txtEmail.Location = New-Object System.Drawing.Point(20, $y)
    $txtEmail.Size     = New-Object System.Drawing.Size(385, 24)
    $txtEmail.Text     = $Prefill
    $form.Controls.Add($txtEmail)
    $y += 34

    $lblConfirm = New-Object System.Windows.Forms.Label
    $lblConfirm.Text     = "Confirm email address"
    $lblConfirm.Location = New-Object System.Drawing.Point(20, $y)
    $lblConfirm.Size     = New-Object System.Drawing.Size(390, 16)
    $form.Controls.Add($lblConfirm)
    $y += 20

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(20, $y)
    $txtConfirm.Size     = New-Object System.Drawing.Size(385, 24)
    $txtConfirm.Text     = $Prefill
    $form.Controls.Add($txtConfirm)
    $y += 32

    $lblError = New-Object System.Windows.Forms.Label
    $lblError.Text      = ""
    $lblError.Location  = New-Object System.Drawing.Point(20, $y)
    $lblError.Size      = New-Object System.Drawing.Size(390, 18)
    $lblError.ForeColor = [System.Drawing.Color]::Firebrick
    $form.Controls.Add($lblError)
    $y += 26

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = "Register Device"
    $btnOk.Location = New-Object System.Drawing.Point(275, $y)
    $btnOk.Size     = New-Object System.Drawing.Size(130, 30)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(160, $y)
    $btnCancel.Size     = New-Object System.Drawing.Size(105, 30)
    $form.Controls.Add($btnCancel)

    $btnOk.Add_Click({
        $email   = $txtEmail.Text.Trim().ToLower()
        $confirm = $txtConfirm.Text.Trim().ToLower()
        if (-not (Test-EmailFormat -Email $email)) {
            $lblError.Text = "Please enter a valid email address, for example you@company.com."
        } elseif ($confirm -eq "") {
            $lblError.Text = "Please confirm your email address."
        } elseif ($email -ne $confirm) {
            $lblError.Text = "Email addresses do not match. Please try again."
        } else {
            $form.Tag = $email
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })

    $btnCancel.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })

    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $dialogResult = $form.ShowDialog()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return [string]$form.Tag
    }
    return $null
}

# ============================================================
# API HELPERS
# ============================================================

function Invoke-IruApi {
    param([string]$Method = "GET", [string]$Path, [object]$BodyObject = $null)

    $uri = $IRU_BASE_URL + "/api/v1" + $Path
    Write-Log ("[API] " + $Method + " " + $uri)

    $headers = @{
        "Authorization" = "Bearer " + $IRU_API_TOKEN
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }

    $params = @{
        Method          = $Method
        Uri             = $uri
        Headers         = $headers
        UseBasicParsing = $true
    }

    if ($BodyObject -ne $null) {
        $params["Body"] = ($BodyObject | ConvertTo-Json -Compress)
    }

    try {
        $response = Invoke-WebRequest @params -ErrorAction Stop
        Write-Log ("[API] HTTP " + $response.StatusCode)
        return $response.Content
    } catch {
        $statusCode = "unknown"
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        Write-Log ("[API] FAILED " + $Method + " " + $Path + " HTTP " + $statusCode + " " + $_.Exception.Message) "ERROR"
        return $null
    }
}

# The [char]38 ampersand construction is preserved from the original script
# as a precaution against character handling in the Iru script editor.
$AMP = [char]38

function Get-IruDevice {
    param([string]$SerialNumber, [string]$MachineName)

    # Primary lookup by hardware serial number using the API-side filter.
    if ($SerialNumber -and $SerialNumber.Trim() -ne "") {
        $encodedSerial = [uri]::EscapeDataString($SerialNumber.Trim())
        $raw = Invoke-IruApi -Path ("/devices?serial_number=" + $encodedSerial)
        if ($raw -ne $null) {
            $items = @(ConvertFrom-Json -InputObject $raw)
            foreach ($d in $items) {
                if ($d.serial_number -and ($d.serial_number.Trim() -ieq $SerialNumber.Trim())) {
                    Write-Log ("[DEVICES] Matched by serial number " + $SerialNumber)
                    return $d
                }
            }
        }
        Write-Log ("[DEVICES] No serial match for " + $SerialNumber + ". Falling back to name lookup.")
    }

    # Fallback lookup by device name with pagination.
    $offset = 0
    while ($true) {
        $path = "/devices?limit=" + $PAGE_LIMIT + $AMP + "offset=" + $offset
        $raw  = Invoke-IruApi -Path $path
        if ($raw -eq $null) { return $null }

        $items = @(ConvertFrom-Json -InputObject $raw)
        if ($items.Count -eq 0) { break }

        foreach ($d in $items) {
            if ($d.device_name -ieq $MachineName) {
                Write-Log ("[DEVICES] Matched by device name " + $MachineName)
                return $d
            }
        }

        if ($items.Count -lt $PAGE_LIMIT) { break }
        $offset += $PAGE_LIMIT
    }

    Write-Log ("[DEVICES] Device not found by serial or name.") "ERROR"
    return $false
}

function Get-IruUserByEmail {
    param([string]$Email)

    # Primary lookup using the API-side email filter.
    $encodedEmail = [uri]::EscapeDataString($Email)
    $raw = Invoke-IruApi -Path ("/users?email=" + $encodedEmail)
    if ($raw -ne $null) {
        $parsed = ConvertFrom-Json -InputObject $raw
        $items  = @($parsed.results)
        foreach ($u in $items) {
            if ($u.email -ieq $Email) {
                Write-Log ("[USERS] Matched by email filter " + $Email)
                return $u
            }
        }
    } else {
        return $null
    }

    # Fallback lookup with pagination in case the filter behaves unexpectedly.
    $offset = 0
    while ($true) {
        $path = "/users?limit=" + $PAGE_LIMIT + $AMP + "offset=" + $offset
        $raw  = Invoke-IruApi -Path $path
        if ($raw -eq $null) { return $null }

        $parsed = ConvertFrom-Json -InputObject $raw
        $items  = @($parsed.results)
        if ($items.Count -eq 0) { break }

        foreach ($u in $items) {
            if ($u.email -ieq $Email) {
                Write-Log ("[USERS] Matched by pagination " + $Email)
                return $u
            }
        }

        if ($items.Count -lt $PAGE_LIMIT) { break }
        $offset += $PAGE_LIMIT
    }

    Write-Log ("[USERS] No user found for " + $Email)
    return $false
}

# ============================================================
# LOCAL DETECTION HELPERS
# ============================================================

function Get-LastLoggedInUser {
    $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LastUseTime -ne $null } |
        Sort-Object LastUseTime -Descending

    foreach ($profile in $profiles) {
        try {
            $sid      = New-Object System.Security.Principal.SecurityIdentifier($profile.SID)
            $ntName   = $sid.Translate([System.Security.Principal.NTAccount]).Value
            $username = $ntName -replace '^[^\\]+\\', ''
            if ($EXCLUDED_ACCOUNTS -icontains $username) { continue }
            Write-Log ("[USER-DETECT] Most recent local profile " + $username)
            return $username
        } catch {
            Write-Log ("[USER-DETECT] SID translation failed for " + $profile.SID)
        }
    }
    return $null
}

function Get-DetectedUPN {
    # Primary source is the LogonUI key populated on Entra joined devices.
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"
        $upnVal  = Get-ItemProperty -Path $regPath -Name "LastLoggedOnUPN" -ErrorAction Stop
        $candidate = $upnVal.LastLoggedOnUPN.Trim()
        if (Test-EmailFormat -Email $candidate) {
            Write-Log ("[UPN] Detected from LogonUI registry " + $candidate)
            return $candidate.ToLower()
        }
    } catch {
        Write-Log "[UPN] LogonUI UPN value not present."
    }

    # Fallback source is the Entra identity store cache.
    try {
        $idStore = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache"
        $subkeys = Get-ChildItem -Path $idStore -ErrorAction Stop
        foreach ($key in $subkeys) {
            $subkeys2 = Get-ChildItem -Path $key.PSPath -ErrorAction SilentlyContinue
            foreach ($key2 in $subkeys2) {
                $props = Get-ItemProperty -Path $key2.PSPath -ErrorAction SilentlyContinue
                if ($props.UserName -and (Test-EmailFormat -Email $props.UserName)) {
                    $candidate = $props.UserName.Trim().ToLower()
                    Write-Log ("[UPN] Detected from IdentityStore cache " + $candidate)
                    return $candidate
                }
            }
        }
    } catch {
        Write-Log "[UPN] IdentityStore lookup failed or not present."
    }

    return $null
}

# ============================================================
# MAIN - USER SESSION FLOW
# ============================================================

function Complete-Run {
    param(
        [string]$Status,
        [string]$Message,
        [string]$UserEmail = "",
        [string]$UserName = "",
        [string]$DeviceName = ""
    )
    Write-ResultFile -Status $Status -Message $Message -UserEmail $UserEmail -UserName $UserName -DeviceName $DeviceName
    $code = Get-ExitCodeForStatus -Status $Status
    Write-Log ("[MAIN] Completed with status " + $Status + " and exit code " + $code + ".")
    exit $code
}

$machineName = $env:COMPUTERNAME
$serialNumber = ""
try {
    $serialNumber = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    Write-Log ("[MAIN] Hardware serial number " + $serialNumber)
} catch {
    Write-Log "[MAIN] Could not read BIOS serial number. Name matching will be used."
}

$lastUser    = Get-LastLoggedInUser
$detectedUPN = Get-DetectedUPN

# Determine the email address to use.
$userEmail = ""
if ($detectedUPN -and -not $REQUIRE_UPN_CONFIRMATION) {
    Write-Log ("[MAIN] Using auto-detected UPN silently " + $detectedUPN)
    $userEmail = $detectedUPN
} else {
    $prefill = ""
    if ($detectedUPN) { $prefill = $detectedUPN }
    Write-Log "[MAIN] Prompting for email address."
    $userEmail = Show-EmailDialog -Prefill $prefill -DetectedLocalUser $lastUser
    if ($userEmail -eq $null -or $userEmail.Trim() -eq "") {
        Show-Message -Message "Device registration was cancelled." -Type "Warning"
        Complete-Run -Status "cancelled" -Message "User cancelled the dialog."
    }
    $userEmail = $userEmail.Trim().ToLower()
    Write-Log ("[MAIN] Email entered " + $userEmail)
}

# Look up this device.
$device = Get-IruDevice -SerialNumber $serialNumber -MachineName $machineName
if ($device -eq $null) {
    Show-Message -Message "Could not connect to Iru. Please contact IT support." -Type "Error"
    Complete-Run -Status "api_error" -Message "Device lookup API call failed." -UserEmail $userEmail -DeviceName $machineName
}
if ($device -eq $false) {
    Show-Message -Message ("This device (" + $machineName + ") was not found in Iru. Please contact IT support.") -Type "Error"
    Complete-Run -Status "device_not_found" -Message "No device matched by serial or name." -UserEmail $userEmail -DeviceName $machineName
}

$deviceId   = $device.device_id
$deviceName = $device.device_name
Write-Log ("[MAIN] Matched device " + $deviceName + " with id " + $deviceId)

# Check for an existing assignment. The user field is an object when set.
$existingEmail = ""
if ($device.user -ne $null) {
    if ($device.user.email) {
        $existingEmail = [string]$device.user.email
    } else {
        $existingEmail = [string]$device.user
    }
}
if ($existingEmail.Trim() -ne "") {
    Write-Log ("[MAIN] Device already assigned to " + $existingEmail)
    Show-Message -Message ("This device is already assigned to " + $existingEmail + ". No changes have been made.") -Type "Information"
    Complete-Run -Status "already_assigned" -Message ("Existing assignment " + $existingEmail) -UserEmail $existingEmail -DeviceName $deviceName
}

# Look up the Iru user record.
$iruUser = Get-IruUserByEmail -Email $userEmail
if ($iruUser -eq $null) {
    Show-Message -Message "Could not retrieve user information from Iru. Please contact IT support." -Type "Error"
    Complete-Run -Status "api_error" -Message "User lookup API call failed." -UserEmail $userEmail -DeviceName $deviceName
}
if ($iruUser -eq $false) {
    Show-Message -Message ("The email '" + $userEmail + "' was not found in Iru. Please check your email and try again, or contact IT support.") -Type "Warning"
    Complete-Run -Status "user_not_found" -Message "No Iru user matched the email." -UserEmail $userEmail -DeviceName $deviceName
}

$iruUserId   = $iruUser.id
$iruUserName = $iruUser.name
Write-Log ("[MAIN] Matched user " + $iruUserName + " with id " + $iruUserId)

# Assign the user to the device.
Write-Log ("[MAIN] Assigning " + $iruUserName + " to " + $deviceName)
$patchRaw = Invoke-IruApi -Method "PATCH" -Path ("/devices/" + $deviceId + "/") -BodyObject @{ user = "$iruUserId" }

if ($patchRaw -ne $null) {
    Write-Log ("[MAIN] SUCCESS. " + $iruUserName + " assigned to " + $deviceName + ".")
    # Show a confirmation only when the user typed or confirmed the email.
    # Silent auto-detected runs complete without interrupting the user.
    if (-not $detectedUPN -or $REQUIRE_UPN_CONFIRMATION) {
        Show-Message -Message ("This device has been successfully registered to " + $iruUserName + ".") -Type "Information"
    }
    Complete-Run -Status "assigned" -Message "Assignment succeeded." -UserEmail $userEmail -UserName $iruUserName -DeviceName $deviceName
} else {
    Show-Message -Message "The registration failed. Please contact IT support." -Type "Error"
    Complete-Run -Status "api_error" -Message "PATCH request failed." -UserEmail $userEmail -DeviceName $deviceName
}
