## Application Installation Script (`appinstall.ps1`)

## Overview
`appinstall.ps1` downloads installers from **publicly accessible URLs** and installs them **sequentially** (one at a time). This is designed to reduce app-install race conditions when an MDM launches multiple scripts in parallel on the same device.

It also supports:
- Killing specified running processes before uninstalls/installs
- Running multiple uninstall commands (sequentially)
- ZIP downloads (extracts into the same folder and deletes the ZIP)
- Robust logging to `%ProgramData%\Iru\AppInstalls\Logs`

Each run creates a unique session folder under `%ProgramData%\Iru\AppInstalls\{GUID}` to prevent conflicts across runs.

## Configuration Options
You can configure via:

1) **Editable defaults** near the top of `appinstall.ps1`

```powershell
$DownloadUrlsDefault = @()          # REQUIRED: array of URLs
$InstallCommandLinesDefault = @()   # REQUIRED: array of install command lines
$DownloadDirectoryDefault = Join-Path $programDataPath "Iru\AppInstalls"
$UninstallCommandLinesDefault = @()
$ProcessNamesToKillDefault = @()
$UninstallTimeoutSecondsDefault = 600
$InstallationTimeoutSecondsDefault = 600
$UrlTestTimeoutSecondsDefault = 10
$CleanupAfterInstallDefault = $false
$EnableDebugDefault = $false
```

2) **Command-line parameters** (take precedence over defaults):
- `-DownloadUrls` (string array, required if no default) – URLs to download
- `-InstallCommandLines` (string array, required if no default) – install command lines to run sequentially
- `-DownloadDirectory` (string, optional) – default `%ProgramData%\Iru\AppInstalls`
- `-UninstallCommandLines` (string array, optional)
- `-ProcessNamesToKill` (string array, optional)
- `-UninstallTimeoutSeconds` (int, optional)
- `-InstallationTimeoutSeconds` (int, optional)
- `-UrlTestTimeoutSeconds` (int, optional)
- `-CleanupAfterInstall` (switch)
- `-Debug` (switch)

## Download URL Requirements
**Important:** URLs must be directly downloadable without auth/cookies/session tokens.

## Install Command Lines (as-is)
Each entry in `-InstallCommandLines` must be the **complete command line** you want executed. The script executes command lines **as-is** using `cmd.exe /c` from the designated working directory.

Examples:

```powershell
"setup.exe /S"
'"My Installer.exe" /S'
"msiexec.exe /i installer.msi /qn /norestart"
```

## Mapping rules (DownloadUrls ↔ InstallCommandLines)
The script supports:

- **1:1**: `DownloadUrls.Count == InstallCommandLines.Count`
  - Each install command runs from the folder containing its corresponding download.
- **1 URL + many installs**: `DownloadUrls.Count == 1` and `InstallCommandLines.Count >= 1`
  - Useful when the single URL is a ZIP bundle containing multiple installers; every install command runs from the same extracted folder.

Any other count mismatch fails fast.

## Download URL Requirements

**Important:** The download URL must be publicly accessible without authentication. The script does not support authenticated downloads or URLs that require cookies/session tokens.

**Supported URL Types:**
- Direct download URLs from file hosting services
- Any publicly accessible HTTP/HTTPS URL

**Unsupported:**
- URLs requiring authentication or login
- URLs that require cookies or session tokens
- Private OneDrive/Google Drive links that require sign-in or don't provide direct download links.

## Uninstall Command Lines
If provided, `-UninstallCommandLines` are executed **sequentially** before installs.

- Non-zero exit codes are logged as warnings and do not stop the script.
- Commands execute from the session folder (`%ProgramData%\Iru\AppInstalls\{GUID}`).

## Process Termination
If provided, `-ProcessNamesToKill` is evaluated before uninstalls/installs.

- Provide process EXE names with or without `.exe`.
- The script attempts to stop matching processes and waits for exit (no arbitrary sleeps).

## ZIP File Handling
If a downloaded file is a ZIP, the script:
1. Extracts the ZIP into the same folder where it was downloaded
2. Deletes the ZIP after successful extraction
3. Runs install commands from that folder

## Unique Download Sessions

Each script execution creates a unique GUID folder under the download directory (e.g., `%ProgramData%\Iru\AppInstalls\{GUID}`). This prevents:
- Overwriting existing installers when cleanup is disabled and the script is rerun
- Conflicts between multiple simultaneous runs
- File locking issues

**Folder Structure:**
```
%ProgramData%\Iru\AppInstalls\
  ├── {GUID-1}\
  │   └── installer.exe
  ├── {GUID-2}\
  │   ├── installer.zip (extracted contents)
  │   └── setup.exe
  └── {GUID-3}\
      └── installer.msi
```

When `CleanupAfterInstall` is enabled, the entire GUID folder is removed after successful installation or on failure (if cleanup is enabled).

## Usage Examples

### Example A: 1:1 mapping (two URLs, two installs)
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\appinstall.ps1 `
  -DownloadUrls @("https://example.com/app1.msi", "https://example.com/app2.exe") `
  -InstallCommandLines @(
    "msiexec.exe /i app1.msi /qn /norestart",
    "app2.exe /S"
  )
```

### Example B: 1 URL + multiple install commands (ZIP bundle)
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\appinstall.ps1 `
  -DownloadUrls @("https://example.com/bundle.zip") `
  -InstallCommandLines @(
    "installer1.exe /S",
    "msiexec.exe /i installer2.msi /qn /norestart"
  )
```

### Example C: With process termination + uninstalls + debug
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\appinstall.ps1 `
  -DownloadUrls @("https://example.com/app.zip") `
  -InstallCommandLines @("setup.exe /S") `
  -ProcessNamesToKill @("app.exe", "service.exe") `
  -UninstallCommandLines @("msiexec /x {GUID} /qn", '"C:\Program Files\OldApp\Uninstall.exe" /S') `
  -UrlTestTimeoutSeconds 15 `
  -UninstallTimeoutSeconds 600 `
  -InstallationTimeoutSeconds 1200 `
  -CleanupAfterInstall `
  -Debug
```

## Timeout Configuration

The script includes configurable timeouts for URL testing, uninstall, and installation operations:

- **URL Test Timeout**: Default is 10 seconds. Configure via `$UrlTestTimeoutSecondsDefault` in script defaults or `-UrlTestTimeoutSeconds` command-line parameter. This timeout applies to the initial URL accessibility test and filename detection from HTTP headers.
- **Uninstall Timeout**: Default is 600 seconds (10 minutes). Configure via `$UninstallTimeoutSecondsDefault` in script defaults or `-UninstallTimeoutSeconds` command-line parameter.
- **Installation Timeout**: Default is 600 seconds (10 minutes). Configure via `$InstallationTimeoutSecondsDefault` in script defaults or `-InstallationTimeoutSeconds` command-line parameter.

**Examples:**
```powershell
# Set timeouts in script defaults:
$UrlTestTimeoutSecondsDefault = 15         # 15 seconds for URL tests
$UninstallTimeoutSecondsDefault = 600     # 10 minutes for uninstalls
$InstallationTimeoutSecondsDefault = 1200  # 20 minutes for installations

# Or override via command line:
-UrlTestTimeoutSeconds 20 `
-UninstallTimeoutSeconds 900 `
-InstallationTimeoutSeconds 1800
```

**Important Notes:**
- Timeouts are specified in seconds
- URL test timeout is converted to milliseconds internally for HTTP request timeout
- Uninstall and installation timeouts are converted to milliseconds internally for process execution
- If a timeout is exceeded, the operation will fail and the script will exit with an error
- Adjust timeouts based on your application's typical installation/uninstallation duration and network conditions

## Deployment Guidance

- **Context**: Run as an elevated user or, preferably, as SYSTEM when deploying via MDM/remote management tools.
- **Reboots**: Not required, though some installers may request a reboot.
- **User Interaction**: The script runs fully unattended - no user interaction required.
- **Logging**: Output is written both to the console and to `C:\ProgramData\Iru\AppInstalls\Logs\AppInstall_<timestamp>.log`. Run with `-Debug` to capture verbose information for troubleshooting.
- **Cleanup**: By default, downloaded files are NOT cleaned up (`CleanupAfterInstallDefault = $false`). This prevents issues if the source URL becomes unavailable later. Enable cleanup with `-CleanupAfterInstall` switch if you want files removed after successful installation.

## Script Flow Summary
1. Validate required inputs and mapping rules.
2. Confirm elevation and initialize logging.
3. Create a unique download session folder.
4. **Step 1**: Download all URLs (and extract ZIPs).
5. **Step 2**: Kill specified processes (optional).
6. **Step 3**: Run uninstall commands sequentially (optional).
7. **Step 4**: Run install commands sequentially (always).
   - Continues on failure; records failures for stderr summary.
8. **Step 5**: Cleanup session folder (optional).

## Stdout/Stderr Summary and Exit Codes
- **Stdout (success, exit 0)**: one line per successful install command: `"<command> was successful"`
- **Stderr (failure, exit 1)**: one line per failed install command: `"<command> failed. (Error code: N)"`

Exit codes:
- `0` – all downloads + installs succeeded
- `1` – one or more downloads or installs failed (script still attempts remaining installs)

## Error Handling Notes
- URL accessibility checks are best-effort (warns but continues).
- Downloads retry and validate non-empty files.
- Install commands run sequentially; failures are logged and summarized on stderr.

## Troubleshooting

**Download fails:**
- Verify the URL is publicly accessible (no authentication required)
- Check network connectivity
- Review logs for specific error messages
- Try accessing the URL manually in a browser

**Installation fails:**
- Verify your `InstallCommandLine` is correct and complete
- Check that the installer file exists in the download directory
- Review installation logs (enable `-Debug` for verbose output)
- Test the install command manually from the download directory

**Process not killed:**
- Verify the process name matches exactly (case-insensitive)
- Check if the process is running before script execution
- Some processes may restart automatically - check logs

**ZIP extraction fails:**
- Verify the ZIP file downloaded completely (check file size)
- Ensure sufficient disk space in `%ProgramData%\Iru\AppInstalls`
- Check logs for specific extraction errors
