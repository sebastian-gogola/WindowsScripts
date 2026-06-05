# Browser Desktop Shortcuts for Iru (Windows)

Push browser shortcuts to the all-users desktop on Windows devices managed by Iru
(formerly Kandji), using the **Windows Custom Script** Library Item and its
audit-and-remediation model.

## Contents

| File | Role | Goes in the Iru field |
|------|------|-----------------------|
| `Audit-BrowserShortcuts.ps1` | Checks whether the expected shortcuts exist and point at the right target. | **Audit** |
| `Remediate-BrowserShortcuts.ps1` | Creates, repairs, or removes shortcuts. | **Remediation** |

## How it works

The Iru Windows agent runs the **audit** script on each check-in:

- Exit `0` → **compliant**, remediation does not run.
- Exit `1` → **non-compliant**, the agent runs the **remediation** script.

The remediation script:

- Auto-detects which of Chrome, Edge, and Firefox are installed (checks both
  `Program Files` and `Program Files (x86)`), and only creates shortcuts for
  browsers that are actually present.
- Writes `.lnk` files to the **Public** desktop (`C:\Users\Public\Desktop`). The
  agent runs as `SYSTEM`, so the Public desktop is the reliable target and the
  shortcuts appear for every current and future user automatically.
- Is **idempotent**: re-running fixes shortcuts pointing at the wrong path and
  removes shortcuts for browsers that have since been uninstalled.

## Prerequisites

- Windows devices enrolled in Iru with the Iru Agent installed.
- PowerShell 5.1 or later (built into Windows 10/11).
- Permission to create a Custom Script Library Item and assign it to a Blueprint.

## Deployment

1. In the Iru console, create a **Custom Script** Library Item and set the
   platform to **Windows**.
2. Paste the contents of `Audit-BrowserShortcuts.ps1` into the **Audit** field.
3. Paste the contents of `Remediate-BrowserShortcuts.ps1` into the
   **Remediation** field.
4. Set the script architecture to **64-bit PowerShell**.
5. Configure the item to run on an **enforced / recurring** cadence (not
   one-time) so shortcut drift is corrected automatically.
6. Assign the Library Item to the target Blueprint via your Assignment Map.

Online devices begin running the script at the next agent check-in (typically
within ~15 minutes).

## Customizing the shortcuts

Edit the `$Shortcuts` block at the top of **both** scripts. The audit script must
match what the remediation script produces, so keep the two blocks identical.

### Add an application (browser) shortcut

Copy an existing `App` entry and point `Targets` at the executable. List multiple
candidate paths; the first one that exists is used.

```powershell
@{ Name = 'Brave'; Type = 'App'; Targets = @(
    (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe'),
    (Join-Path $env:ProgramFiles        'BraveSoftware\Brave-Browser\Application\brave.exe')
)}
```

### Add a website shortcut

A `Url` entry creates a shortcut that launches the chosen browser straight to a
web address (and inherits that browser's icon). `Browser` is required.

```powershell
@{ Name = 'Company Portal'; Type = 'Url'; Url = 'https://portal.example.com';
   Browser = (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
```

## Exit codes

| Script | Exit `0` | Exit `1` |
|--------|----------|----------|
| Audit | All expected shortcuts present and correct. | At least one shortcut is missing, wrong, or stale. |
| Remediation | All shortcuts created/updated successfully. | One or more shortcuts failed to create. |

## Verifying

After a check-in, confirm the `.lnk` files appear under `C:\Users\Public\Desktop`.
Script `stdout` (the `OK:` / `MISSING:` / `DRIFT:` lines) is captured in the
Library Item's run history in the Iru console for troubleshooting.

## Notes

- Iru has a native website-shortcut Library Item, but it targets Apple Web Clips.
  For pushing desktop `.lnk` files on Windows, this Custom Script approach is the
  correct route.
- Shortcuts are scoped to the all-users Public desktop. If you need per-user
  shortcuts instead, that requires a different approach (the agent's `SYSTEM`
  context does not map cleanly to individual user desktops).
