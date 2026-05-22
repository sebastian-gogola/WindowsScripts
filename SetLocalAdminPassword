# Iru LAPS — Local Admin Password Rotation for Iru MDM

A PowerShell-based LAPS (Local Administrator Password Solution) alternative for Windows devices managed by [Iru](https://www.iru.com) (formerly Kandji). Rotates the local admin password on a schedule and stores it in the device's notes via the Iru API.

## Why

Iru doesn't natively support Windows LAPS the way Intune does. This script fills that gap by handling the full lifecycle locally: password generation, account management, API reporting, and scheduled rotation — all deployable as a single script push from your Iru tenant.

## How It Works

```
┌──────────────────────────────────────────────────────────┐
│  First Run (pushed via Iru MDM)                          │
│                                                          │
│  1. Installs itself to %ProgramData%\IruLAPS\            │
│  2. Registers a scheduled task (runs every N days)       │
│  3. Generates a cryptographically random password        │
│  4. Sets the password on the local admin account         │
│  5. Looks up device_id via GET /v1/devices?serial_number │
│  6. Posts password to POST /v1/devices/{device_id}/notes │
├──────────────────────────────────────────────────────────┤
│  Subsequent Runs (via scheduled task)                    │
│                                                          │
│  • Skips task installation (already exists)              │
│  • Repeats steps 3–6                                     │
└──────────────────────────────────────────────────────────┘
```

Each rotation creates a **new note** on the device record in Iru, giving you a full audit trail of every password change.

## Requirements

- Windows 10/11 or Windows Server 2019+
- PowerShell 5.1 or later
- Network access to `*.api.kandji.io` from the endpoint
- An Iru API token with the following permissions:
  - **Device list** (to look up the device by serial number)
  - **Device notes — create** (to post the password)

## Setup

### 1. Generate an API Token

In your Iru tenant, go to **Settings → Access → API Tokens** and create a token scoped to device read and notes write permissions.

### 2. Configure the Script

Open `Set-LocalAdminPassword.ps1` and update the configuration block at the top:

```powershell
$IruSubdomain    = "YOUR_SUBDOMAIN"     # e.g., "acme" from acme.api.kandji.io
$IruRegion       = "us"                 # "us" or "eu"
$IruApiToken     = "YOUR_API_TOKEN"     # Bearer token from step 1
$LocalAdminUser  = "localadmin"         # Local admin account name
$PasswordLength  = 24                   # Password length (default: 24)
$RotationDays    = 30                   # Rotation interval in days
```

### 3. Deploy via Iru

Upload the script to your Iru tenant as a **Custom Script** and assign it to the relevant Blueprint. The script will:

- Execute immediately on the first run (rotates the password right away)
- Install a scheduled task (`IruLAPS-PasswordRotation`) for recurring rotation
- All subsequent rotations happen locally via Task Scheduler — no dependency on Iru check-in timing

### 4. Retrieve a Password

Open the device record in Iru and check the **Notes** tab. Each rotation posts a note in this format:

```
[LAPS] HOSTNAME | Account: localadmin | Password: Ab7$kNx... | Rotated: 2026-05-22 14:00:00 UTC
```

## Configuration Reference

| Variable | Default | Description |
|---|---|---|
| `$IruSubdomain` | — | Your Iru tenant subdomain |
| `$IruRegion` | `us` | `us` or `eu` |
| `$IruApiToken` | — | API bearer token |
| `$LocalAdminUser` | `localadmin` | Local admin account to manage |
| `$PasswordLength` | `24` | Length of generated passwords |
| `$RotationDays` | `30` | Days between rotations |
| `$TaskName` | `IruLAPS-PasswordRotation` | Name of the scheduled task |
| `$ScriptInstallPath` | `%ProgramData%\IruLAPS\Set-LocalAdminPassword.ps1` | Where the script copies itself |

## Scheduled Task Details

| Setting | Value |
|---|---|
| Name | `IruLAPS-PasswordRotation` |
| Runs as | `NT AUTHORITY\SYSTEM` |
| Privilege | Highest |
| Schedule | Every `$RotationDays` days at 2:00 AM |
| Battery | Runs on battery, doesn't stop if switching to battery |
| Missed run | Runs at next opportunity (`StartWhenAvailable`) |
| Wake | Wakes the device if asleep |
| Retry | 3 retries, 15-minute intervals |

## Logging

All activity is logged to:

```
%ProgramData%\IruLAPS\password-rotation.log
```

Example output:

```
[2026-05-22 02:00:01] [INFO] ===== Iru LAPS Password Rotation Starting =====
[2026-05-22 02:00:01] [INFO] Scheduled task 'IruLAPS-PasswordRotation' already exists — skipping install.
[2026-05-22 02:00:01] [INFO] Generated new password (24 chars).
[2026-05-22 02:00:01] [INFO] Found existing local account: localadmin
[2026-05-22 02:00:02] [INFO] Password updated for localadmin
[2026-05-22 02:00:02] [INFO] Looking up device in Iru: serial=ABC123DEF456
[2026-05-22 02:00:02] [INFO] Found device_id: 1a2b3c4d-...
[2026-05-22 02:00:03] [INFO] Device note posted successfully.
[2026-05-22 02:00:03] [INFO] ===== Password rotation complete =====
```

## Password Generation

Passwords are generated using `System.Security.Cryptography.RNGCryptoServiceProvider` and meet the following criteria:

- Configurable length (default 24 characters)
- At least one uppercase, one lowercase, one digit, and one special character
- Ambiguous characters excluded (`O`, `0`, `l`, `1`, `I`)
- Character pool: `ABCDEFGHJKLMNPQRSTUVWXYZ` `abcdefghjkmnpqrstuvwxyz` `23456789` `!@#$%^&*()-_=+`
- Shuffled after generation so required characters aren't in predictable positions

## Security Considerations

- **API token is embedded in the script.** Scope the token to the minimum permissions needed (device list + notes create). The script is stored in `%ProgramData%` which is only writable by administrators.
- **Passwords are stored in device notes as plaintext.** Restrict access to device notes in Iru to authorized IT staff. Each rotation posts a new note, so previous passwords remain visible in the note history.
- **The log file does NOT contain passwords.** Only metadata (success/failure, device ID, timestamps) is logged.
- **Account creation:** If the specified local admin account doesn't exist, the script creates it and adds it to the local Administrators group.

## Uninstall

To remove the scheduled task and local files from a device:

```powershell
Unregister-ScheduledTask -TaskName "IruLAPS-PasswordRotation" -Confirm:$false
Remove-Item -Path "$env:ProgramData\IruLAPS" -Recurse -Force
```

This does **not** remove the local admin account or reset its password.

## API Endpoints Used

| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/api/v1/devices?serial_number={serial}` | Look up device by serial number |
| `POST` | `/api/v1/devices/{device_id}/notes` | Post password to device notes |

Refer to the [Iru API documentation](https://api-docs.iru.com) for full details.

## License

MIT
