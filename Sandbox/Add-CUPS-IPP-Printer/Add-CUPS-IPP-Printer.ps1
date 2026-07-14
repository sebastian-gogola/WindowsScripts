<#
.SYNOPSIS
    Adds an IPP Everywhere (driverless) printer that points at an onsite CUPS
    print server, using the in-box "Microsoft IPP Class Driver".
 
.NOTES
    Designed for deployment via Iru's Windows Custom Script Library Item.
    - Idempotent: safe to run on every check-in (audit-and-remediate).
    - Exit code 0 = success/compliant, non-zero = failure (triggers retry).
    - Runs in SYSTEM context, so the printer is installed machine-wide
      (available to all users on the device).
#>

# =============================================================================
# DISCLAIMER: Experimental helper script - provided as-is, without warranty or
# official Iru support. Sandbox scripts have not gone through the review and
# validation applied to the official Iru WindowsScripts. Review the code and
# validate on test hardware before any production use.
# =============================================================================

# --- Configuration --------------------------------------------------------
$PrinterName = 'Hall-A-Front'        # Name shown to users in Windows
$ServerHost  = '192.168.1.1'         # CUPS server (Raspberry Pi) LAN address
$Port        = 631                   # Standard IPP/CUPS port
$QueueName   = 'Hall-A-Front'        # CUPS queue name (the /printers/<name> part)
$SetDefault  = $false                # See note below before enabling
# --------------------------------------------------------------------------
 
$DriverName = 'Microsoft IPP Class Driver'
$PortUri    = "http://${ServerHost}:${Port}/printers/${QueueName}"
 
try {
    # --- Audit: is it already present and pointing at the right port? ---
    $existing = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if ($existing -and $existing.PortName -eq $PortUri) {
        Write-Output "Compliant: '$PrinterName' already configured -> $PortUri"
    }
    else {
        # --- Remediate ---
 
        # 1. Ensure the in-box IPP class driver is staged
        if (-not (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue)) {
            Add-PrinterDriver -Name $DriverName -ErrorAction Stop
        }
 
        # 2. Create the IPP port if it does not exist
        if (-not (Get-PrinterPort -Name $PortUri -ErrorAction SilentlyContinue)) {
            Add-PrinterPort -Name $PortUri -ErrorAction Stop
        }
 
        # 3. (Re)create the printer object
        if ($existing) {
            Remove-Printer -Name $PrinterName -ErrorAction SilentlyContinue
        }
        Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortUri -ErrorAction Stop
 
        Write-Output "Installed: '$PrinterName' -> $PortUri"
    }
 
    # --- Optional: set as default ---
    # NOTE: default printer is a PER-USER setting. From a SYSTEM-context MDM
    # script this will not reliably target the logged-in user. If you need a
    # default, prefer a user-context mechanism or leave this $false.
    if ($SetDefault) {
        (New-Object -ComObject WScript.Network).SetDefaultPrinter($PrinterName)
    }
 
    exit 0
}
catch {
    Write-Error "Failed to configure '$PrinterName': $_"
    exit 1
}