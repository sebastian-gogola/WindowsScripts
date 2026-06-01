<#
.SYNOPSIS
    Blocks (or unblocks) access to removable storage on Windows endpoints.

.DESCRIPTION
    Applies the machine-level "Removable Storage Access" policies to deny access
    to all removable storage classes (USB removable disks, CD/DVD, floppy, tape,
    and Windows Portable Devices). Optionally disables the USBSTOR driver service
    for defense in depth.

    Designed for deployment via an MDM / RMM / configuration tool. Writes a log to
    %ProgramData% and returns standard exit codes for deployment reporting:
        0  = success
        1  = not running elevated
        2  = one or more operations failed

.PARAMETER Revert
    Removes the blocking policies and re-enables the USBSTOR driver, restoring
    normal removable storage access.

.PARAMETER DisableUSBSTOR
    Also sets the USBSTOR driver service Start value to disabled (4). This is
    USB-mass-storage-specific and complements the policy-based block. Ignored
    when -Revert is used (revert always restores USBSTOR to its default).

.PARAMETER ReadOnly
    Instead of a full block, denies write access only (read still permitted).
    Useful when you want to prevent data exfiltration to USB but still allow
    reading from vendor media. Cannot be combined with -Revert.

.EXAMPLE
    .\Block-RemovableStorage.ps1
    Blocks all read/write access to all removable storage classes.

.EXAMPLE
    .\Block-RemovableStorage.ps1 -DisableUSBSTOR
    Blocks all access AND disables the USB mass storage driver.

.EXAMPLE
    .\Block-RemovableStorage.ps1 -ReadOnly
    Allows reading from removable storage but blocks all writes.

.EXAMPLE
    .\Block-RemovableStorage.ps1 -Revert
    Removes all blocking and restores normal access.

.NOTES
    A reboot (or user logoff/logon) is recommended for the policy to fully apply
    to in-session devices. New device connections are blocked immediately.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Revert,
    [switch]$DisableUSBSTOR,
    [switch]$ReadOnly
)

# --- Configuration ---------------------------------------------------------

$LogDir  = Join-Path $env:ProgramData 'EndpointSecurity'
$LogFile = Join-Path $LogDir 'Block-RemovableStorage.log'

# Root policy key for Removable Storage Access (Computer Configuration)
$PolicyRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices'

# USB mass storage driver service
$UsbStorKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR'

# Device setup class GUIDs for each removable storage class
$StorageClasses = @{
    'Removable Disks'         = '{53f56307-b6bf-11d0-94f2-00a0c91efb8b}'
    'CD and DVD'              = '{53f56308-b6bf-11d0-94f2-00a0c91efb8b}'
    'Floppy Drives'           = '{53f56311-b6bf-11d0-94f2-00a0c91efb8b}'
    'Tape Drives'             = '{53f5630b-b6bf-11d0-94f2-00a0c91efb8b}'
    'WPD Devices (handheld)'  = '{6AC27878-A6FA-4155-BA85-F98F491D4F33}'
    'WPD Devices (media)'     = '{F33FDC04-D1AC-4E8E-9A30-19BBD4B108AE}'
}

$script:HadError = $false

# --- Helpers ---------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "$stamp [$Level] $Message"
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $line -ErrorAction Stop
    } catch {
        # If logging to disk fails, still surface to the console/transcript
    }
    Write-Output $line
}

function Test-IsElevated {
    $id        = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value `
            -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-Log "Set $Path\$Name = $Value"
    } catch {
        Write-Log "Failed to set $Path\$Name : $($_.Exception.Message)" 'ERROR'
        $script:HadError = $true
    }
}

function Remove-RegValue {
    param(
        [string]$Path,
        [string]$Name
    )
    try {
        if (Test-Path $Path) {
            if ($null -ne (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)) {
                Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop
                Write-Log "Removed $Path\$Name"
            }
        }
    } catch {
        Write-Log "Failed to remove $Path\$Name : $($_.Exception.Message)" 'ERROR'
        $script:HadError = $true
    }
}

# --- Actions ---------------------------------------------------------------

function Invoke-Block {
    if ($ReadOnly) {
        Write-Log 'Applying READ-ONLY policy (writes denied, reads allowed).'
        # Per-class Deny_Write blocks writes while leaving reads intact.
        foreach ($class in $StorageClasses.GetEnumerator()) {
            $classPath = Join-Path $PolicyRoot $class.Value
            Write-Log "Configuring class '$($class.Key)'"
            Set-RegValue -Path $classPath -Name 'Deny_Write' -Value 1
        }
        # Make sure a prior full block isn't lingering.
        Remove-RegValue -Path $PolicyRoot -Name 'Deny_All'
    }
    else {
        Write-Log 'Applying FULL block (all read/write/execute denied).'
        # Deny_All at the root covers every removable storage class at once.
        Set-RegValue -Path $PolicyRoot -Name 'Deny_All' -Value 1
    }

    if ($DisableUSBSTOR) {
        Write-Log 'Disabling USBSTOR driver service (Start = 4).'
        Set-RegValue -Path $UsbStorKey -Name 'Start' -Value 4
    }
}

function Invoke-Revert {
    Write-Log 'Reverting: removing block policies and restoring USBSTOR.'

    Remove-RegValue -Path $PolicyRoot -Name 'Deny_All'

    foreach ($class in $StorageClasses.GetEnumerator()) {
        $classPath = Join-Path $PolicyRoot $class.Value
        Remove-RegValue -Path $classPath -Name 'Deny_Write'
        Remove-RegValue -Path $classPath -Name 'Deny_Read'
        Remove-RegValue -Path $classPath -Name 'Deny_Execute'
    }

    # Restore USBSTOR to its default manual-start state (3).
    Set-RegValue -Path $UsbStorKey -Name 'Start' -Value 3
}

# --- Main ------------------------------------------------------------------

Write-Log '==============================================================='
Write-Log "Block-RemovableStorage starting on $env:COMPUTERNAME"

if (-not (Test-IsElevated)) {
    Write-Log 'Script must run with administrator privileges. Aborting.' 'ERROR'
    exit 1
}

if ($Revert -and ($DisableUSBSTOR -or $ReadOnly)) {
    Write-Log '-Revert cannot be combined with -DisableUSBSTOR or -ReadOnly. Proceeding with full revert.' 'WARN'
}

if ($Revert) {
    Invoke-Revert
} else {
    Invoke-Block
}

# Refresh policy so currently-connected devices are re-evaluated promptly.
try {
    Write-Log 'Triggering group policy refresh.'
    & gpupdate.exe /target:computer /force | Out-Null
} catch {
    Write-Log "gpupdate refresh failed (non-fatal): $($_.Exception.Message)" 'WARN'
}

if ($script:HadError) {
    Write-Log 'Completed WITH ERRORS. See log above.' 'ERROR'
    exit 2
}

Write-Log 'Completed successfully. A reboot or user re-logon is recommended.'
exit 0
