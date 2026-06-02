# Add-CUPS-IPP-Printer.ps1

PowerShell script that adds a driverless (IPP Everywhere) printer to managed Windows devices, pointing them at an onsite CUPS print server. Designed for deployment through Iru's Windows Library Items.

## What it does

The script configures a Windows printer that talks to a CUPS queue using the in-box **Microsoft IPP Class Driver**. This is the Windows equivalent of macOS's native IPP Everywhere support: no vendor-specific print drivers are shipped to the endpoint. Windows queries the CUPS queue over IPP and negotiates capabilities (paper sizes, duplex, color, trays) generically.

It is **idempotent** and follows an audit-and-remediate pattern:

1. Checks whether the printer already exists and points at the correct port URI.
2. If compliant, reports success and exits `0` without making changes.
3. If missing or misconfigured, stages the IPP class driver, creates the IPP port, and (re)creates the printer.

Because it self-heals, running it repeatedly is safe — if a user deletes the printer, the next run re-adds it.

## Environment

This script was written for the following setup:

- **Print server:** Raspberry Pi 5 running CUPS onsite
- **Drivers:** IPP Everywhere (driverless) drivers hosted on the Pi
- **Clients:** Local on the LAN (no VPN or tunneling)
- **Example queue path:** `http://192.168.1.1:631/printers/Hall-A-Front`

## Configuration

Edit the variables at the top of the script before deploying:

| Variable | Description | Example |
|----------|-------------|---------|
| `$PrinterName` | Name shown to users in Windows | `Hall-A-Front` |
| `$ServerHost` | CUPS server (Raspberry Pi) LAN address | `192.168.1.1` |
| `$Port` | IPP/CUPS port | `631` |
| `$QueueName` | CUPS queue name (the `/printers/<name>` segment) | `Hall-A-Front` |
| `$SetDefault` | Whether to set this as the default printer | `$false` |

The script builds the port URI as `http://<ServerHost>:<Port>/printers/<QueueName>`.

## Deployment via Iru

There are two Library Item paths. Pick based on the behavior you want.

### Option A — Custom App Library Item

Use this when you want the printer to behave like an installable unit — for example, surfacing it in Self Service for on-demand install, or pairing it with an uninstall command and app-style detection.

1. Zip `Add-CUPS-IPP-Printer.ps1` (plus any supporting files).
2. Upload the zip as a Windows Custom App.
3. Set the install command to reference the script (e.g. `Add-CUPS-IPP-Printer.ps1`).
4. Define **detection logic** so Iru knows whether the "app" is present — for a printer this typically means a registry key under `HKLM\...\Print\Printers\<PrinterName>`, or a marker key the script writes itself.
5. Assign to the appropriate Blueprint.

Note: a Custom App runs once and won't re-run unless detection reports it missing, so the self-healing behavior depends on your detection rule accurately representing "the printer exists."

### Option B — Custom Script Library Item

Use this when you want the printer present and continuously self-healing without app-style semantics.

1. Upload or paste the script into a Windows Custom Script Library Item.
2. Choose a run cadence (e.g. once per device, or recurring on check-in).
3. The script's built-in audit (exit `0` when compliant, non-zero on failure) drives Iru's remediation.
4. Assign to the appropriate Blueprint.

## Important notes

- **Runs as SYSTEM / machine-wide.** Iru's Windows scripts run in system context, so the printer installs for all users on the device. This is usually the desired behavior on shared/managed endpoints.
- **Default printer is per-user.** Setting a default reliably from SYSTEM context is not guaranteed. `$SetDefault` is off by default for this reason; if a default matters, handle it in user context.
- **Connection is unencrypted (`http://`).** Print jobs traverse the LAN in the clear. If that's a concern, CUPS can serve `ipps://` on port 631 with a certificate — swap the scheme in the port URI accordingly.
- **Pilot before broad rollout.** IPP capability negotiation (duplex, trays, color) depends on the CUPS queue advertising clean IPP attributes. Test on one device before assigning the Library Item to a full Blueprint.
- **Confirm the server IP.** If `192.168.1.1` is the Pi's real address (rather than a sanitized example), ensure the Pi has a static/reserved DHCP lease so the port URIs don't break after a reboot.

## Extending to multiple printers

For additional queues (Hall-B, Hall-C, etc.), either:

- Create one Library Item per queue (easy to scope to different Blueprints), or
- Loop an array of `@{ Name = ...; Queue = ... }` objects inside a single script if every targeted device should receive every printer.