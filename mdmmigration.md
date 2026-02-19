# MDM Migration Script (mdmmigration.ps1)

## Overview
`mdmmigration.ps1` automates the process of unenrolling Windows devices from their current management provider and enrolling them into Iru. It gathers enrollment parameters from your Iru gateway, removes existing MDM enrollments (when present), and registers the device with Kandji.

The script is designed to run from an elevated context (Administrator/SYSTEM). It can be executed interactively or fully unattended via the `-Silent` switch. Because it leverages native Windows APIs, it is safe to deploy to devices via your existing MDM solution or other remote execution tools.

## Configuration Options
You can supply required parameters via:

1. **Editable defaults** near the top of `mdmmigration.ps1`
   ```powershell
   $TenantNameDefault      = "contoso"
   $BlueprintIdDefault     = "447c8874-73f5-4b7a-9d55-18c58e673597"
   $EnrollmentCodeDefault  = "571537"
   $TenantIdDefault        = "8134cc6c"
   $TenantLocationDefault  = "US"    # or "EU"
   $UninstallAppDefault   = @()    # Example: @("msiexec /x {GUID} /qn /norestart", '"C:\Program Files\agent\Uninstall Agent.exe" /allusers /S')
   $EnableDebugDefault     = $false
   $EnableSilentDefault    = $true
   ```
   Updating these allows admins to "bake in" values without editing the rest of the script.

   **Where to find these values in the Iru console:**
   - **TenantName**: the first part of your tenant sign-in URL. Example: if your tenant URL is `https://contoso.iru.com`, your tenant name is `contoso`.
   - **BlueprintId**: Iru Console → **Blueprints** → open the target blueprint → copy the GUID from the URL.
     - Example URL: `https://contoso.iru.com/blueprints/maps/447c8874-73f5-4b7a-9d55-18c58e673597/assignments`
     - BlueprintId: `447c8874-73f5-4b7a-9d55-18c58e673597`
   - **EnrollmentCode**: Iru Console → **Enrollment** → **Manual Enrollment** → use the code for the target blueprint.
   - **TenantId**: Iru Console → **Organization** → **Device Domains**.
     - Example Device Domain: `8134cc6c.web-api.kandji.io` → TenantId: `8134cc6c`

2. **Named command-line parameters**, which take precedence over the defaults:
   - `-TenantName` (string, required if no default)
   - `-BlueprintId` (string, required if no default)
   - `-EnrollmentCode` (string, required if no default)
   - `-TenantId` (string, required if no default – prefix used to build the management URL)
   - `-TenantLocation` (`US` or `EU`, required if no default – selects the Kandji/Iru region endpoints)
   - `-UninstallApp` (string array, optional) – Array of full command lines for uninstalling applications before enrollment
   - `-Debug` (switch) enables verbose logging
   - `-Silent` (switch) suppresses the intro and completion dialogs

   When you specify `-TenantLocation EU`, the script automatically targets the Kandji/Iru EU endpoints (`*.gateway.eu.iru.com` and `*.web-api.eu.kandji.io`). Leaving it at `US` keeps the existing US URLs.

The script validates every required input (regardless of whether it came from a default or CLI) *before* displaying any UI. Missing or invalid values cause the script to log errors and exit with code `1`.

### Application Uninstall Parameters

The script supports uninstalling multiple applications before MDM enrollment using an array of uninstall commands. Uninstall commands are executed **after successful unenrollment** (or immediately if no enrollments are found). If any unenrollment fails, uninstalls are skipped to prevent partial migration states.

**Uninstall Command Format:**
- Provide the full command line, including the executable and all arguments
- For paths with spaces, quote the executable path: `"C:\Program Files\App\uninstall.exe" /S`
- MSI uninstalls: `msiexec /x {GUID} /qn /norestart`
- Setup executables: `"C:\Program Files\App\Uninstall App.exe" /allusers /S`

**Examples:**
```powershell
# In script defaults:
$UninstallAppDefault = @(
    "msiexec /x {51BA8D33-B914-4B0C-BF8E-4F768A731BE6} /qn /norestart",
    '"C:\Program Files\JumpCloud Remote Assist\Uninstall JumpCloud Remote Assist.exe" /allusers /S'
)

# Via command line:
-UninstallApp @("msiexec /x {GUID} /qn /norestart", '"C:\Program Files\App\uninstall.exe" /S')
```

**Important Notes:**
- Uninstalls only run if **all** unenrollments succeed (or if no enrollments are found)
- Each uninstall command has a 30-minute timeout
- Failures are logged but do not stop the script from proceeding to enrollment
- Commands are executed sequentially, waiting for each to complete before starting the next
- You can specify as many uninstall commands as needed in the array

## Usage Example
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\mdmmigration.ps1 `
    -TenantName "contoso" `
    -BlueprintId "447c8874-73f5-4b7a-9d55-18c58e673597" `
    -EnrollmentCode "571537" `
    -TenantId "8134cc66c" `
    -TenantLocation "US" `
    -UninstallApp @("msiexec /x {51BA8D33-B914-4B0C-BF8E-4F768A731BE6} /qn /norestart", '"C:\Program Files\App\uninstall.exe" /S') `
    -Silent `
    -Debug
```

## Deployment Guidance
- **Context**: run as an elevated user or, preferably, as SYSTEM when deploying via your current MDM/remote management stack.
- **Reboots**: not required, though a reboot after migration is recommended to ensure device policies are refreshed.
- **User Interaction**: for mass deployments use `-Silent` (or set `$EnableSilentDefault = $true`) so no dialogs are shown. This prevents the user from canceling the migration and avoids blocking unattended runs.
- **Logging**: output is written both to the console and to `C:\ProgramData\Iru\MDMMigration\Logs\MDM-Unenroll_<timestamp>.log`. Run with `-Debug` to capture verbose API responses for troubleshooting.
- **Require Authentication to Blueprint**: The script will fail if Require Authentication is set on the blueprint.

### Autopilot Deployment Requirements
When running this script as part of an Autopilot deployment, the following Intune configuration is required:

1. **Disable Enrollment Status Page (ESP)**: The Enrollment Status Page must be disabled in the Autopilot Deployment Profile. If ESP is enabled, the script may run before the user profile is fully created, which can cause the script to incorrectly identify the user (e.g., picking up `defaultuser0` instead of the actual Azure AD UPN).

2. **User-Driven Deployment**: The Autopilot Deployment Profile must be configured as **User-Driven** (not Self-Deploying or Pre-Provisioned). This ensures the user signs in before the script runs, allowing the script to correctly identify the logged-in user's UPN.

These settings ensure the script runs after the user has signed in and their profile is fully created, allowing for accurate user identification during the MDM migration process.

## Script Flow Summary
1. Validate required parameters (defaults/CLI combined).
2. (Optional) Show intro dialog unless `-Silent` is set. User cancellations exit with code `0`.
3. Confirm elevation and initialize logging.
4. Find the UPN of the user.
5. Retrieve the enrollment token from your Iru gateway.
6. Enumerate existing enrollments and attempt unenrollment when present.
7. **If unenrollments succeeded (or none found)**: Execute configured application uninstall commands.
8. Register the device with Kandji using `RegisterDeviceWithManagement`.
9. Write completion status to the log and (when not silent) display the completion dialog.

## Exit Codes
- `0` – Success (or the user cancelled from the intro dialog)
- `1` – Validation failure, token retrieval failure, unenroll/register failures without explicit HRESULTs
- `>1` – Specific HRESULT returned by the Windows registration API

Use these exit codes in your deployment tooling to detect success/failure conditions.

