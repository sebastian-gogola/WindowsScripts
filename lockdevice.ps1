################################################################################################
# Created by Lance Crandall | support@iru.com | Iru, Inc.
################################################################################################
#
#   Created - 2026/01/16
#   Updated - 2026/01/16
#
################################################################################################
# Script Information
################################################################################################
#
# This script quarantines (locks) a Windows device by blocking ALL interactive and RDP logons for
# all users (current and future). It applies the lock by assigning local security user-rights
# directly via the Windows LSA policy APIs (no `secedit` dependency), and creates a scheduled
# task that re-applies the lock at startup and every 5 minutes to prevent drift. The script also
# logs off any currently signed-in sessions after applying the lock.
#
# All actions are logged to disk; only the last 450 characters are emitted to stdout/stderr to
# keep device management consoles readable. The script is designed to run from an elevated
# context (Administrator/SYSTEM).
#
################################################################################################
# License Information
################################################################################################
#
# Copyright 2026 Iru, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
# to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
################################################################################################

# Script version
$VERSION = "1.0.0"

$ErrorActionPreference = "Stop"

# ------------------------------
# Config
# ------------------------------
$LockDirPreferred = "C:\ProgramData\IruDeviceLock"
$LockDirLegacy    = "C:\ProgramData\IRUDeviceLock"

$TaskNamePreferred = "IruDeviceQuarantineEnforce"
$TaskNameLegacy    = "IRUDeviceQuarantineEnforce"

# Prefer new naming, but keep backwards compatibility for devices previously locked with legacy paths.
$preferredState = Join-Path $LockDirPreferred "LOCKED.txt"
$legacyState    = Join-Path $LockDirLegacy "LOCKED.txt"

if (Test-Path $preferredState) {
    $LockDir = $LockDirPreferred
} elseif (Test-Path $legacyState) {
    $LockDir = $LockDirLegacy
} elseif ((Test-Path $LockDirLegacy) -and -not (Test-Path $LockDirPreferred)) {
    $LockDir = $LockDirLegacy
} else {
    $LockDir = $LockDirPreferred
}

$BaselineInf     = Join-Path $LockDir "baseline.inf"
$LockInf         = Join-Path $LockDir "lock.inf"
$LockDb          = Join-Path $LockDir "lock.sdb"
$ExportInf       = Join-Path $LockDir "export.inf"
$VerifyInf       = Join-Path $LockDir "verify.inf"
$EnforceScript   = Join-Path $LockDir "enforce.ps1"
$StateFile       = Join-Path $LockDir "LOCKED.txt"
$ManifestFile    = Join-Path $LockDir "manifest.json"

# Logs live under %ProgramData%\Iru\... for consistency across scripts
$IruProgramData  = Join-Path ([Environment]::GetFolderPath("CommonApplicationData")) "Iru"
$LogDir          = Join-Path $IruProgramData "DeviceLock"
$LogFile         = Join-Path $LogDir "lock.log"
$TaskName        = $TaskNamePreferred
$ConsoleLimit    = 450
$LsaRightsAdded  = @("SeDenyInteractiveLogonRight", "SeDenyRemoteInteractiveLogonRight")

# ------------------------------
# Logging helpers
# ------------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Tail-Text {
    param([string]$Text, [int]$Limit = 450)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le $Limit) { return $Text }
    return $Text.Substring($Text.Length - $Limit)
}

function Success-Out {
    param([string]$Message)
    $msg = Tail-Text $Message $ConsoleLimit
    Write-Output $msg
}

function Fail-Out {
    param([string]$Message)
    $msg = Tail-Text $Message $ConsoleLimit
    Write-Error $msg
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$TimeoutSeconds = 120,
        [switch]$ThrowOnNonZero
    )

    function Quote-Arg {
        param([string]$Arg)
        if ($null -eq $Arg) { return "" }
        if ($Arg -match '\s') { return '"' + ($Arg -replace '"', '""') + '"' }
        return $Arg
    }

    $outFile = Join-Path $LockDir ("proc-" + [Guid]::NewGuid().ToString("N") + ".out.txt")
    $errFile = Join-Path $LockDir ("proc-" + [Guid]::NewGuid().ToString("N") + ".err.txt")
    $argString = ($Arguments | ForEach-Object { Quote-Arg $_ }) -join " "

    Write-Log ("START: {0} (timeout={1}s)" -f $Description, $TimeoutSeconds)

    $p = Start-Process -FilePath $FilePath -ArgumentList $argString -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $exited = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { $p.Kill() } catch {}
        Write-Log ("TIMEOUT: {0} exceeded {1}s" -f $Description, $TimeoutSeconds)
        throw ("{0} timed out after {1}s (possible MMC policy lock). See {2} / {3}" -f $Description, $TimeoutSeconds, $outFile, $errFile)
    }

    $exitCode = $p.ExitCode
    $stdout = ""
    $stderr = ""
    try { if (Test-Path $outFile) { $stdout = (Get-Content -Path $outFile -Raw).Trim() } } catch {}
    try { if (Test-Path $errFile) { $stderr = (Get-Content -Path $errFile -Raw).Trim() } } catch {}

    Write-Log ("{0} exitCode={1}" -f $Description, $exitCode)
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $oneLine = ($stdout -replace "\r?\n", " | ")
        Write-Log ("{0} stdout: {1}" -f $Description, $oneLine)
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $oneLine = ($stderr -replace "\r?\n", " | ")
        Write-Log ("{0} stderr: {1}" -f $Description, $oneLine)
    }

    if ($ThrowOnNonZero -and $exitCode -ne 0) {
        throw ("{0} failed with exit code {1}" -f $Description, $exitCode)
    }
}

function Ensure-LsaInterop {
    if ("Iru.LsaInterop" -as [type]) { return }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Iru {
  public static class LsaInterop {
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING {
      public UInt16 Length;
      public UInt16 MaximumLength;
      public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES {
      public UInt32 Length;
      public IntPtr RootDirectory;
      public IntPtr ObjectName;
      public UInt32 Attributes;
      public IntPtr SecurityDescriptor;
      public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern UInt32 LsaOpenPolicy(
      IntPtr SystemName,
      ref LSA_OBJECT_ATTRIBUTES ObjectAttributes,
      Int32 DesiredAccess,
      out IntPtr PolicyHandle
    );

    [DllImport("advapi32.dll")]
    public static extern UInt32 LsaClose(IntPtr ObjectHandle);

    [DllImport("advapi32.dll")]
    public static extern UInt32 LsaNtStatusToWinError(UInt32 status);

    [DllImport("advapi32.dll")]
    public static extern UInt32 LsaAddAccountRights(
      IntPtr PolicyHandle,
      byte[] AccountSid,
      LSA_UNICODE_STRING[] UserRights,
      Int32 CountOfRights
    );

    [DllImport("advapi32.dll")]
    public static extern UInt32 LsaRemoveAccountRights(
      IntPtr PolicyHandle,
      byte[] AccountSid,
      bool AllRights,
      LSA_UNICODE_STRING[] UserRights,
      Int32 CountOfRights
    );

    [DllImport("advapi32.dll")]
    public static extern UInt32 LsaEnumerateAccountRights(
      IntPtr PolicyHandle,
      byte[] AccountSid,
      out IntPtr UserRights,
      out UInt32 CountOfRights
    );

    [DllImport("advapi32.dll")]
    public static extern UInt32 LsaFreeMemory(IntPtr Buffer);

    public const Int32 POLICY_LOOKUP_NAMES = 0x00000800;
    public const Int32 POLICY_CREATE_ACCOUNT = 0x00000010;
  }
}
"@ -Language CSharp
}

function Open-LsaPolicy {
    Ensure-LsaInterop
    $attrs = New-Object Iru.LsaInterop+LSA_OBJECT_ATTRIBUTES
    $attrs.Length = 0
    $handle = [IntPtr]::Zero
    $access = [Iru.LsaInterop]::POLICY_LOOKUP_NAMES -bor [Iru.LsaInterop]::POLICY_CREATE_ACCOUNT
    $status = [Iru.LsaInterop]::LsaOpenPolicy([IntPtr]::Zero, [ref]$attrs, $access, [ref]$handle)
    if ($status -ne 0) {
        $winErr = [Iru.LsaInterop]::LsaNtStatusToWinError($status)
        throw "LsaOpenPolicy failed: NTSTATUS=$status WinError=$winErr"
    }
    return $handle
}

function New-LsaUnicodeString {
    param([Parameter(Mandatory=$true)][string]$Value)
    $bytes = [Text.Encoding]::Unicode.GetBytes($Value)
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $bytes.Length)
    $lus = New-Object Iru.LsaInterop+LSA_UNICODE_STRING
    $lus.Length = [UInt16]$bytes.Length
    $lus.MaximumLength = [UInt16]$bytes.Length
    $lus.Buffer = $ptr
    return $lus
}

function Free-LsaUnicodeString {
    param([Parameter(Mandatory=$true)][ref]$LsaString)
    if ($LsaString.Value.Buffer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($LsaString.Value.Buffer)
        $LsaString.Value.Buffer = [IntPtr]::Zero
    }
}

function Get-SidBytes {
    param([Parameter(Mandatory=$true)][string]$SidString)
    $sid = New-Object System.Security.Principal.SecurityIdentifier($SidString)
    $bytes = New-Object byte[] ($sid.BinaryLength)
    $sid.GetBinaryForm($bytes, 0)
    return $bytes
}

function Add-AccountRights {
    param(
        [Parameter(Mandatory=$true)][byte[]]$AccountSid,
        [Parameter(Mandatory=$true)][string[]]$Rights
    )
    $policy = Open-LsaPolicy
    try {
        $lsaStrings = @()
        foreach ($r in $Rights) { $lsaStrings += (New-LsaUnicodeString -Value $r) }
        $status = [Iru.LsaInterop]::LsaAddAccountRights($policy, $AccountSid, $lsaStrings, $lsaStrings.Count)
        if ($status -ne 0) {
            $winErr = [Iru.LsaInterop]::LsaNtStatusToWinError($status)
            throw "LsaAddAccountRights failed: NTSTATUS=$status WinError=$winErr"
        }
    } finally {
        foreach ($s in $lsaStrings) { $tmp = $s; Free-LsaUnicodeString ([ref]$tmp) }
        [void][Iru.LsaInterop]::LsaClose($policy)
    }
}

function Remove-AccountRights {
    param(
        [Parameter(Mandatory=$true)][byte[]]$AccountSid,
        [Parameter(Mandatory=$true)][string[]]$Rights
    )
    $policy = Open-LsaPolicy
    try {
        $lsaStrings = @()
        foreach ($r in $Rights) { $lsaStrings += (New-LsaUnicodeString -Value $r) }
        $status = [Iru.LsaInterop]::LsaRemoveAccountRights($policy, $AccountSid, $false, $lsaStrings, $lsaStrings.Count)
        if ($status -ne 0) {
            $winErr = [Iru.LsaInterop]::LsaNtStatusToWinError($status)
            throw "LsaRemoveAccountRights failed: NTSTATUS=$status WinError=$winErr"
        }
    } finally {
        foreach ($s in $lsaStrings) { $tmp = $s; Free-LsaUnicodeString ([ref]$tmp) }
        [void][Iru.LsaInterop]::LsaClose($policy)
    }
}

function Get-AccountRights {
    param([Parameter(Mandatory=$true)][byte[]]$AccountSid)
    $policy = Open-LsaPolicy
    try {
        $ptr = [IntPtr]::Zero
        $count = [UInt32]0
        $status = [Iru.LsaInterop]::LsaEnumerateAccountRights($policy, $AccountSid, [ref]$ptr, [ref]$count)
        if ($status -ne 0) {
            $winErr = [Iru.LsaInterop]::LsaNtStatusToWinError($status)
            # 2 = ERROR_FILE_NOT_FOUND maps to "no rights" for that account
            if ($winErr -eq 2) { return @() }
            throw "LsaEnumerateAccountRights failed: NTSTATUS=$status WinError=$winErr"
        }

        $results = @()
        $size = [Runtime.InteropServices.Marshal]::SizeOf([type]([Iru.LsaInterop+LSA_UNICODE_STRING]))
        for ($i = 0; $i -lt $count; $i++) {
            $itemPtr = [IntPtr]::Add($ptr, $i * $size)
            $lus = [Runtime.InteropServices.Marshal]::PtrToStructure($itemPtr, [type]([Iru.LsaInterop+LSA_UNICODE_STRING]))
            $s = [Runtime.InteropServices.Marshal]::PtrToStringUni($lus.Buffer, $lus.Length / 2)
            if ($s) { $results += $s }
        }
        return $results
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [void][Iru.LsaInterop]::LsaFreeMemory($ptr) }
        [void][Iru.LsaInterop]::LsaClose($policy)
    }
}

# ------------------------------
# Main
# ------------------------------
try {
    New-Item -Path $LockDir -ItemType Directory -Force | Out-Null
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
    Write-Log "=== LOCK script invoked ==="
    Write-Log ("Script version: {0}" -f $VERSION)

    $alreadyLocked = Test-Path $StateFile
    if ($alreadyLocked) {
        Write-Log "Device already locked (marker exists). Will re-apply lock policy and ensure enforcement task/script are present."
    }

    # Apply lock using LSA policy (no secedit dependency)
    Write-Log "Applying lock policy via LSA (user-rights assignment)"
    $everyoneSidBytes = Get-SidBytes -SidString "S-1-1-0"
    Add-AccountRights -AccountSid $everyoneSidBytes -Rights $LsaRightsAdded

    # Verify (enumerate rights for Everyone and log the relevant ones)
    $currentRights = Get-AccountRights -AccountSid $everyoneSidBytes
    foreach ($r in $LsaRightsAdded) {
        $present = $currentRights -contains $r
        Write-Log ("VERIFY: Everyone has {0}: {1}" -f $r, $present)
    }

    # Mark locked state (every run, refresh timestamp)
    "LOCKED $(Get-Date -Format o)" | Out-File -FilePath $StateFile -Force -Encoding utf8
    Write-Log "State marker written to $StateFile"

    # Write/update manifest so unlock can deterministically reverse changes
    $manifest = [ordered]@{
        product            = "Iru Device Quarantine"
        manifestVersion    = 1
        scriptVersion      = $VERSION
        createdAt          = (Get-Date).ToString("o")
        lockDir            = $LockDir
        method             = "lsa"
        rightsAddedToEveryone = $LsaRightsAdded
        paths              = [ordered]@{
            enforceScript = $EnforceScript
            stateFile     = $StateFile
            logFile       = $LogFile
            manifestFile  = $ManifestFile
        }
        scheduledTasks      = @($TaskNamePreferred, $TaskNameLegacy)
        notes               = "Unlock removes the deny-rights from Everyone and removes listed tasks/marker/enforcement artifacts."
    }

    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -Path $ManifestFile -Encoding utf8
    Write-Log "Manifest written/updated at $ManifestFile"

    # Always (re)write enforcement script so it stays current
    $enforceContent = @"
# ------------------------------
# Iru Quarantine Enforcement Script
# Re-applies lock policy if LOCKED marker exists
# Runs as SYSTEM via scheduled task
# ------------------------------

`$ErrorActionPreference = "Stop"

`$LockDir   = "$LockDir"
`$StateFile = "$StateFile"
`$LogDir    = "$LogDir"
`$LogFile   = "$LogFile"

function Write-Log {
    param([string]`$Message)
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "`$timestamp  `$Message" | Out-File -FilePath `$LogFile -Append -Encoding utf8
}

try {
    New-Item -Path `$LogDir -ItemType Directory -Force | Out-Null
    if (-not (Test-Path `$StateFile)) {
        Write-Log "Enforcement ran but device is not locked. Exiting."
        exit 0
    }

    # LSA-based enforcement: ensure deny rights are present on Everyone
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Iru {
  public static class LsaInterop {
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING { public UInt16 Length; public UInt16 MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES { public UInt32 Length; public IntPtr RootDirectory; public IntPtr ObjectName; public UInt32 Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll", SetLastError=true)] public static extern UInt32 LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, Int32 DesiredAccess, out IntPtr PolicyHandle);
    [DllImport("advapi32.dll")] public static extern UInt32 LsaClose(IntPtr ObjectHandle);
    [DllImport("advapi32.dll")] public static extern UInt32 LsaNtStatusToWinError(UInt32 status);
    [DllImport("advapi32.dll")] public static extern UInt32 LsaAddAccountRights(IntPtr PolicyHandle, byte[] AccountSid, LSA_UNICODE_STRING[] UserRights, Int32 CountOfRights);
    public const Int32 POLICY_LOOKUP_NAMES = 0x00000800;
    public const Int32 POLICY_CREATE_ACCOUNT = 0x00000010;
  }
}
'@ -Language CSharp -ErrorAction SilentlyContinue

    function Get-SidBytes([string]`$SidString) {
        `$sid = New-Object System.Security.Principal.SecurityIdentifier(`$SidString)
        `$bytes = New-Object byte[] (`$sid.BinaryLength)
        `$sid.GetBinaryForm(`$bytes, 0)
        return `$bytes
    }

    function New-LsaUnicodeString([string]`$Value) {
        `$bytes = [Text.Encoding]::Unicode.GetBytes(`$Value)
        `$ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(`$bytes.Length)
        [Runtime.InteropServices.Marshal]::Copy(`$bytes, 0, `$ptr, `$bytes.Length)
        `$lus = New-Object Iru.LsaInterop+LSA_UNICODE_STRING
        `$lus.Length = [UInt16]`$bytes.Length
        `$lus.MaximumLength = [UInt16]`$bytes.Length
        `$lus.Buffer = `$ptr
        return `$lus
    }

    function Free-LsaUnicodeString([ref]`$LsaString) {
        if (`$LsaString.Value.Buffer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeHGlobal(`$LsaString.Value.Buffer)
            `$LsaString.Value.Buffer = [IntPtr]::Zero
        }
    }

    function Add-AccountRights([byte[]]`$AccountSid, [string[]]`$Rights) {
        `$attrs = New-Object Iru.LsaInterop+LSA_OBJECT_ATTRIBUTES
        `$handle = [IntPtr]::Zero
        `$access = [Iru.LsaInterop]::POLICY_LOOKUP_NAMES -bor [Iru.LsaInterop]::POLICY_CREATE_ACCOUNT
        `$status = [Iru.LsaInterop]::LsaOpenPolicy([IntPtr]::Zero, [ref]`$attrs, `$access, [ref]`$handle)
        if (`$status -ne 0) {
            `$winErr = [Iru.LsaInterop]::LsaNtStatusToWinError(`$status)
            throw "LsaOpenPolicy failed: NTSTATUS=`$status WinError=`$winErr"
        }
        try {
            `$lsaStrings = @()
            foreach (`$r in `$Rights) { `$lsaStrings += (New-LsaUnicodeString `$r) }
            `$status2 = [Iru.LsaInterop]::LsaAddAccountRights(`$handle, `$AccountSid, `$lsaStrings, `$lsaStrings.Count)
            if (`$status2 -ne 0) {
                `$winErr2 = [Iru.LsaInterop]::LsaNtStatusToWinError(`$status2)
                throw "LsaAddAccountRights failed: NTSTATUS=`$status2 WinError=`$winErr2"
            }
        } finally {
            foreach (`$s in `$lsaStrings) { `$tmp = `$s; Free-LsaUnicodeString ([ref]`$tmp) }
            [void][Iru.LsaInterop]::LsaClose(`$handle)
        }
    }

    Write-Log "Enforcement running: ensuring deny rights on Everyone."
    `$everyone = Get-SidBytes "S-1-1-0"
    Add-AccountRights `$everyone @("SeDenyInteractiveLogonRight","SeDenyRemoteInteractiveLogonRight")
    Write-Log "Enforcement complete."
    exit 0
} catch {
    Write-Log ("ERROR in enforcement: " + `$_.Exception.Message)
    exit 1
}
"@

    Set-Content -Path $EnforceScript -Value $enforceContent -Encoding utf8
    Write-Log "Enforcement script written/updated at $EnforceScript"

    # Create/Update scheduled task to run enforcement at startup + every 5 minutes
    Write-Log "Ensuring scheduled task '$TaskName' exists (startup + every 5 minutes)"

    $action    = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$EnforceScript`""
    $trigger1  = New-ScheduledTaskTrigger -AtStartup
    $trigger2  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
                 -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    $task = New-ScheduledTask -Action $action -Trigger @($trigger1, $trigger2) -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    Write-Log "Scheduled task '$TaskName' registered/updated successfully."

    # Remove legacy task name if present (avoid duplicates)
    try {
        $legacyTask = Get-ScheduledTask -TaskName $TaskNameLegacy -ErrorAction SilentlyContinue
        if ($legacyTask) {
            Write-Log "Removing legacy scheduled task '$TaskNameLegacy'"
            Unregister-ScheduledTask -TaskName $TaskNameLegacy -Confirm:$false | Out-Null
            Write-Log "Legacy scheduled task removed."
        }
    } catch {
        Write-Log ("WARNING: Failed to remove legacy scheduled task: " + $_.Exception.Message)
    }

    # Log off all interactive sessions.
    # Note: When no users are logged on, `quser` often returns: "No User exists for *"
    # Treat that as a normal "nothing to do" condition, not a fatal error.
    try {
        Write-Log "Logging off all interactive sessions."

        $quserText = (& quser 2>&1 | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($quserText)) {
            Write-Log "quser returned no output; skipping logoff."
        }
        elseif ($quserText -match 'No User exists for \*') {
            Write-Log "No interactive sessions present; skipping logoff."
        }
        else {
            $lines = $quserText -split "\r?\n"
            # If a header exists, skip it. If not, parse all lines.
            if ($lines.Count -gt 0 -and $lines[0] -match 'USERNAME') {
                $lines = $lines | Select-Object -Skip 1
            }

            foreach ($line in $lines) {
                $lineTrimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($lineTrimmed)) { continue }

                $parts = $lineTrimmed -split '\s+'
                $sessionId = ($parts | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
                if ($sessionId) {
                    Write-Log "Logging off sessionId=$sessionId"
                    & logoff $sessionId 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Log ("WARNING: logoff failed for sessionId=$sessionId with exit code " + $LASTEXITCODE)
                    }
                }
            }
        }
    } catch {
        Write-Log ("WARNING: Failed during logoff step (non-fatal): " + $_.Exception.Message)
    }

    Write-Log "LOCK script complete. Device is quarantined."

    $summary = @"
SUCCESS: Iru quarantine lock applied.
- Interactive + RDP sign-in blocked for all users (current + future)
- Deny rights added to Everyone: SeDenyInteractiveLogonRight, SeDenyRemoteInteractiveLogonRight
- Enforcement task: $TaskName (startup + every 5 minutes)
"@
    Success-Out $summary
    exit 0
}
catch {
    $err = $_.Exception.Message
    Write-Log ("ERROR: " + $err)

    $summary = @"
FAILED: Iru quarantine lock failed.
Reason: $err
"@
    Fail-Out $summary
    exit 1
}
