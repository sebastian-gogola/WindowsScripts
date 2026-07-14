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
# This script reverses the Iru lock on a Windows device. It first removes the
# enforcement scheduled task (to prevent it from re-applying restrictions), then restores the
# baseline local security policy that was exported and saved during the lock operation. After a
# successful restore, it removes the lock state marker and deletes the enforcement script.
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

# Prefer whichever directory contains the baseline policy, but keep backwards compatibility.
$preferredBaseline = Join-Path $LockDirPreferred "baseline.inf"
$legacyBaseline    = Join-Path $LockDirLegacy "baseline.inf"
$preferredState    = Join-Path $LockDirPreferred "LOCKED.txt"
$legacyState       = Join-Path $LockDirLegacy "LOCKED.txt"

if (Test-Path $preferredBaseline) {
    $LockDir = $LockDirPreferred
} elseif (Test-Path $legacyBaseline) {
    $LockDir = $LockDirLegacy
} elseif (Test-Path $preferredState) {
    $LockDir = $LockDirPreferred
} elseif (Test-Path $legacyState) {
    $LockDir = $LockDirLegacy
} elseif ((Test-Path $LockDirLegacy) -and -not (Test-Path $LockDirPreferred)) {
    $LockDir = $LockDirLegacy
} else {
    $LockDir = $LockDirPreferred
}

$BaselineInf     = Join-Path $LockDir "baseline.inf"
$UnlockDb        = Join-Path $LockDir "unlock.sdb"
$StateFile       = Join-Path $LockDir "LOCKED.txt"
$EnforceScript   = Join-Path $LockDir "enforce.ps1"
$LockInf         = Join-Path $LockDir "lock.inf"
$LockDb          = Join-Path $LockDir "lock.sdb"
$ExportInf       = Join-Path $LockDir "export.inf"
$VerifyInf       = Join-Path $LockDir "verify.inf"
$ManifestFile    = Join-Path $LockDir "manifest.json"

# Logs live under %ProgramData%\Iru\... for consistency across scripts
$IruProgramData  = Join-Path ([Environment]::GetFolderPath("CommonApplicationData")) "Iru"
$LogDir          = Join-Path $IruProgramData "DeviceLock"
$LogFile         = Join-Path $LogDir "unlock.log"
$TaskName        = $TaskNamePreferred
$ConsoleLimit    = 450
$PolicyDb        = Join-Path $env:windir "security\\database\\secedit.sdb"
$LsaRightsToRemove = @("SeDenyInteractiveLogonRight", "SeDenyRemoteInteractiveLogonRight")

function Ensure-LsaInterop {
    if ("Iru.LsaInterop" -as [type]) { return }

    Add-Type -TypeDefinition @"
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
    [DllImport("advapi32.dll")] public static extern UInt32 LsaRemoveAccountRights(IntPtr PolicyHandle, byte[] AccountSid, bool AllRights, LSA_UNICODE_STRING[] UserRights, Int32 CountOfRights);
    public const Int32 POLICY_LOOKUP_NAMES = 0x00000800;
    public const Int32 POLICY_CREATE_ACCOUNT = 0x00000010;
  }
}
"@ -Language CSharp
}

function Open-LsaPolicy {
    Ensure-LsaInterop
    $attrs = New-Object Iru.LsaInterop+LSA_OBJECT_ATTRIBUTES
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

# ------------------------------
# Main
# ------------------------------
try {
    New-Item -Path $LockDir -ItemType Directory -Force | Out-Null
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
    Write-Log "=== UNLOCK script invoked ==="
    Write-Log ("Script version: {0}" -f $VERSION)

    # Load manifest if present (preferred source of truth for what to undo)
    $manifest = $null
    try {
        if (Test-Path $ManifestFile) {
            $manifest = Get-Content -Path $ManifestFile -Raw | ConvertFrom-Json
            Write-Log "Loaded manifest from $ManifestFile"
        } else {
            Write-Log "Manifest not present at $ManifestFile (will use defaults/legacy fallbacks)."
        }
    } catch {
        Write-Log ("WARNING: Failed to load manifest: " + $_.Exception.Message)
        $manifest = $null
    }

    # Remove scheduled task first (so it doesn't fight unlock restore)
    try {
        $taskNames = @($TaskNamePreferred, $TaskNameLegacy)
        if ($manifest -and $manifest.scheduledTasks) {
            $taskNames = @($manifest.scheduledTasks) + $taskNames
        }
        $taskNames = $taskNames | Select-Object -Unique

        foreach ($name in $taskNames) {
            $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Log "Removing scheduled task '$name'"
                Unregister-ScheduledTask -TaskName $name -Confirm:$false | Out-Null
                Write-Log "Scheduled task removed."
            } else {
                Write-Log "Scheduled task '$name' not present."
            }
        }
    } catch {
        # If task removal fails, still proceed, but log it
        Write-Log ("WARNING: Failed to remove scheduled task: " + $_.Exception.Message)
    }

    # Undo lock using LSA policy (no secedit dependency)
    Write-Log "Removing lock deny-rights via LSA (user-rights assignment)"
    $everyoneSidBytes = Get-SidBytes -SidString "S-1-1-0"
    $rightsToRemove = $LsaRightsToRemove
    if ($manifest -and $manifest.rightsAddedToEveryone) {
        $rightsToRemove = @($manifest.rightsAddedToEveryone) + $rightsToRemove
        $rightsToRemove = $rightsToRemove | Select-Object -Unique
    }
    Remove-AccountRights -AccountSid $everyoneSidBytes -Rights $rightsToRemove
    Write-Log ("Removed deny-rights from Everyone: " + ($rightsToRemove -join ", "))

    # Remove marker
    if (Test-Path $StateFile) {
        Remove-Item $StateFile -Force
        Write-Log "Removed lock state marker."
    } else {
        Write-Log "Lock state marker not present."
    }

    # Remove enforcement script (optional) – keep baseline + logs for audit
    if (Test-Path $EnforceScript) {
        Remove-Item $EnforceScript -Force
        Write-Log "Removed enforcement script."
    }

    # Remove lock artifacts (optional) – keep baseline + logs for audit
    foreach ($p in @($LockInf, $LockDb, $ExportInf, $VerifyInf, $UnlockDb)) {
        try {
            if ($p -and (Test-Path $p)) {
                Remove-Item $p -Force
                Write-Log ("Removed artifact: " + $p)
            }
        } catch {
            Write-Log ("WARNING: Failed removing artifact " + $p + ": " + $_.Exception.Message)
        }
    }

    # Remove manifest last
    try {
        if (Test-Path $ManifestFile) {
            Remove-Item $ManifestFile -Force
            Write-Log "Removed manifest."
        }
    } catch {
        Write-Log ("WARNING: Failed removing manifest: " + $_.Exception.Message)
    }

    Write-Log "UNLOCK script complete."

    $summary = @"
SUCCESS: Iru quarantine unlock applied.
- Deny-rights removed from Everyone
- Enforcement tasks removed: $TaskNamePreferred (and legacy if present)
- Lock marker removed: $StateFile
"@
    Success-Out $summary
    exit 0
}
catch {
    $err = $_.Exception.Message
    Write-Log ("ERROR: " + $err)

    $summary = @"
FAILED: Iru quarantine unlock failed.
Reason: $err
"@
    Fail-Out $summary
    exit 1
}
