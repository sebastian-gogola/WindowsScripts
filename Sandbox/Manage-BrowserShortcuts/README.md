# Manage-BrowserShortcuts.ps1

Pushes browser and website shortcuts to the all-users (**Public**) desktop on Windows devices managed by Iru — creating missing shortcuts, repairing mismatched ones, and removing managed shortcuts whose browser has since been uninstalled. Because the Iru agent runs as `SYSTEM`, the Public desktop (`C:\Users\Public\Desktop`) is the reliable target: the shortcuts appear for every current and future user automatically.

- **Script:** `Manage-BrowserShortcuts.ps1` (v1.0.0)
- **Target OS:** Windows 10 / Windows 11
- **Runs as:** SYSTEM (Iru Custom Script) or elevated admin shell
- **PowerShell:** 5.1, no external modules (`WScript.Shell` COM, in-box)

---

## What this touches

This is a file-drop script, not a policy script, so the usual Intune-setting → CSP → registry mapping does not apply. What it reads and writes:

| Surface | Detail |
|---|---|
| `C:\Users\Public\Desktop\<Name>.lnk` | One `.lnk` per configured shortcut — the only files the script creates, modifies, or deletes. Resolved via `%PUBLIC%\Desktop`, **never** via `HKCU` or `[Environment]::GetFolderPath('Desktop')`, which under `SYSTEM` point at SYSTEM's own profile (inferred from how Windows resolves known folders per-profile; the `%PUBLIC%` default location is vendor-documented). |
| `WScript.Shell` COM (`CreateShortcut`) | In-box Windows Script Host interface used to create and read `.lnk` files — target, arguments, icon, working directory (vendor-documented COM interface, PS 5.1-safe, no modules). |
| `HKLM\SOFTWARE\IruScripts\BrowserShortcuts` | Last-run metadata stamp (version, timestamp, managed names). Removed by Revert. |
| Browser executables under `Program Files` / `Program Files (x86)` | Read-only existence checks to auto-detect installed browsers. |

**Intune near-equivalent:** there is no CSP for desktop shortcuts. In Intune this is done with a Win32 app or a Platform Script that drops `.lnk` files — the same file operations this script performs, minus the recurring audit/remediate convergence. Iru's native website-shortcut Library Item targets Apple Web Clips, so on Windows this Custom Script approach is the correct route (community-observed platform behavior).

---

## How it works

Two shortcut types are supported, defined once in the `$Shortcuts` config block:

- **App** — a shortcut to a browser executable. `Targets` lists candidate paths; the first one that exists is used, so a single entry covers both `Program Files` locations. The default set auto-detects Chrome, Edge, and Firefox.
- **Url** — a shortcut that launches a chosen browser straight to a web address: the `.lnk` targets the browser executable with the URL as its argument, and inherits that browser's icon. `Browser` is required.

Desired state is **conditional on browser presence**: a managed shortcut whose executable is not installed should be *absent*. Enforce skips creating it (a shortcut to a missing exe is worse than no shortcut) and removes it if it lingers from before an uninstall. The script is idempotent — re-running fixes shortcuts pointing at the wrong path and removes stale ones.

Shortcuts on the Public desktop that are **not** in `$Shortcuts` are never touched by any mode, including Revert; Discover lists them for visibility.

### Configuration reference

All settings are in the `CONFIGURATION` block at the top of the script — edit nothing below it. Iru Custom Scripts run without parameters, so settings are variables.

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `'Enforce'` | `Enforce` \| `Audit` \| `Discover` \| `Revert` |
| `$Shortcuts` | Chrome / Edge / Firefox App entries | The managed set — single source of truth for every mode. See entry shapes below. |
| `$LogDirectory` / `$LogFile` | `%ProgramData%\IruScripts\Logs\Manage-BrowserShortcuts.log` | Timestamped log, appended per run, mirrored to stdout (captured in the Library Item's run history) |

**Add an application (browser) shortcut** — list multiple candidate paths; the first that exists is used:

```powershell
@{ Name = 'Brave'; Type = 'App'; Targets = @(
    (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe'),
    (Join-Path $env:ProgramFiles        'BraveSoftware\Brave-Browser\Application\brave.exe')
)}
```

**Add a website shortcut** — launches the chosen browser straight to a web address and inherits that browser's icon; `Browser` is required:

```powershell
@{ Name = 'Company Portal'; Type = 'Url'; Url = 'https://portal.example.com';
   Browser = (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
```

Either shape also accepts an optional `Icon = '<path>,<index>'` to override the default icon (the resolved executable's own icon, index 0).

### Modes & exit codes

| Mode | Does | Exit 0 | Exit 1 | Exit 2 |
|---|---|---|---|---|
| `Enforce` | Creates missing shortcuts, repairs mismatched ones (delete-and-recreate), removes stale managed shortcuts (browser uninstalled), verifies | Converged | Create/verify failure | Not elevated / bad config / desktop unresolvable |
| `Audit` | Compares each managed shortcut (target, arguments, icon) to config; changes nothing | Compliant | Drift | Not elevated / bad config / desktop unresolvable |
| `Discover` | Reports every managed shortcut's state (present / absent / wrong target / wrong arguments / wrong icon / stale) plus all unmanaged `.lnk`/`.url` files on the Public desktop | Report produced | Runtime failure | Not elevated / bad config / desktop unresolvable |
| `Revert` | Removes every config-defined shortcut and the state key; unmanaged files untouched | Removed | Removal failure | Not elevated / bad config / desktop unresolvable |

Design decisions, for the record (the original spec was silent on these — see History):

- **Unmanaged shortcuts are never drift and never touched.** The original spec removed only *stale managed* shortcuts ("removes shortcuts for browsers that have since been uninstalled") and said nothing about foreign files; treating the Public desktop as exclusively script-owned would delete shortcuts installed by MSIs and other tooling. Discover reports them instead.
- **A missing browser is a logged skip, not drift.** Audit cannot reasonably flag drift that Enforce is unable to converge (it can't install the browser); flagging it would put the Library Item into a permanent audit-fail → remediate → audit-fail loop. A *lingering shortcut* to a missing browser IS drift — Enforce can and does fix that by removing it.
- **Audit compares target path, argument string, and icon location.** `WorkingDirectory` is set on creation (to the exe's folder) but not audited — it's cosmetic, and auditing it would add drift noise with no user-visible effect (inferred).
- **Repair is delete-and-recreate**, which converges every property at once rather than patching fields individually.

---

## Deploying via Iru

Deploy as a **Custom Script** Library Item using the audit-and-remediate pattern, same as the other `Manage-*.ps1` scripts in this repo:

1. **Audit script slot:** the full script with `$Mode = 'Audit'`. Exit 0 = compliant, exit 1 = drift → triggers remediation.
2. **Remediation script slot:** the identical script with `$Mode = 'Enforce'`.
3. `$Shortcuts` identical in both slots (the audit compares the live desktop against *its own* config).
4. Set the script architecture to **64-bit PowerShell** and run on an **enforced / recurring** cadence (not one-time) so shortcut drift is corrected automatically.

Online devices begin running the script at the next agent check-in (typically within ~15 minutes — community-observed cadence).

---

## Verification & troubleshooting

After a check-in, confirm the `.lnk` files appear under `C:\Users\Public\Desktop`. Script stdout (the `OK` / `DRIFT` / `CREATED` / `REPAIRED` / `REMOVED` lines) is captured in the Library Item's run history in the Iru console, and the same lines land in `%ProgramData%\IruScripts\Logs\Manage-BrowserShortcuts.log` on the device. Run `$Mode = 'Discover'` in an elevated shell for a one-shot state report including unmanaged files.

| Issue | Resolution |
|---|---|
| Exit 2 immediately | Not elevated, `$Shortcuts` empty/malformed (duplicate or invalid names, `Url` entry missing `Url`/`Browser`, bad `Type`), or the Public desktop path doesn't resolve |
| Shortcut never appears | Check the log for the browser-not-installed WARN — the entry's `Targets`/`Browser` paths don't exist on that device |
| Shortcut appears then vanishes | Expected if the browser was uninstalled (stale-shortcut removal); otherwise check for other tooling deleting Public-desktop files |
| Url shortcut opens the wrong browser | The `.lnk` targets the exe in `Browser` explicitly — verify the configured path; the OS default-browser setting is not involved |
| Audit keeps flagging drift after Enforce | Run Discover and compare the reported actual target/arguments/icon to your config — most often a config difference between the two Library Item slots |

### Behavior matrix (recommended acceptance tests)

| Test | Expected |
|---|---|
| Fresh machine, Enforce | Shortcuts created for each installed browser; `CREATED` lines; exit 0 |
| User deletes a managed shortcut → Audit | Exit 1 (`DRIFT … missing`) |
| … then Enforce | Shortcut recreated, exit 0 |
| Target URL changed in config → Enforce | `REPAIRED` line (delete-and-recreate), new argument string on the `.lnk` |
| Shortcut retargeted by hand (wrong exe) → Audit | Exit 1 (mismatch drift) |
| Browser not installed (e.g. Firefox absent) | Enforce: WARN + skip; Audit: `SKIP` line, **not** drift; exit 0 if nothing else drifts |
| Browser uninstalled after shortcut existed → Enforce | Stale shortcut removed (`REMOVED … stale`) |
| Same situation → Audit (before Enforce) | Exit 1 (stale-shortcut drift) |
| Unmanaged `.lnk`/`.url` on the Public desktop | Ignored by Audit/Enforce/Revert; listed by Discover |
| `Revert` | All config-named shortcuts and the state key removed; unmanaged files untouched |
| Empty `$Shortcuts` → any mode | Exit 2, nothing changed |

---

## Limitations

- **Public desktop only.** Per-user desktops are not cleanly reachable from the agent's `SYSTEM` context; if per-user shortcuts are a hard requirement, that needs a different approach (e.g. Active Setup or per-user scheduled tasks — out of scope here).
- **Users can delete the shortcuts.** Nothing pins them; the recurring audit/remediate cadence recreates them at the next check-in. If users deleting shortcuts should *stick*, don't deploy this on a recurring cadence.
- **Name is the identity.** A shortcut renamed by a user is, from the script's view, a missing managed shortcut (recreated on Enforce) plus an unmanaged file (left alone). That's by design — the config `Name` is the contract.
- **Icon index assumptions.** The default icon is `<exe>,0`. A browser that ships its badge at a different icon index can be accommodated with the per-entry `Icon` override (inferred; icon indexes are an application packaging detail).

## History

Originally specced (in this README's previous revision) as an Audit/Remediate script **pair** — `Audit-BrowserShortcuts.ps1` in the Iru Audit field, `Remediate-BrowserShortcuts.ps1` in the Remediation field — with the requirement that the `$Shortcuts` block "must match" between the two files. The committed pair turned out to be content-less (0-byte files, later disclaimer-only stubs) and the original content was unrecoverable. Reimplemented from this README's spec on 2026-07-14 as a single dual-slot script, `Manage-BrowserShortcuts.ps1`, preserving the pair's semantics: the same script now goes in both Iru fields with only `$Mode` differing, which makes the keep-the-blocks-identical requirement structural instead of a documentation warning — the shortcut set is defined exactly once. Discover and Revert modes are additions over the original spec, per current repo conventions.

## Rollback

Set `$Mode = 'Revert'` and run once (or push as a one-time Iru script). It removes every shortcut named in `$Shortcuts` (whether or not the browser is still installed) and the state key `HKLM\SOFTWARE\IruScripts\BrowserShortcuts`. Unmanaged files on the Public desktop are never touched.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (Enforce/Revert/Discover) or compliant (Audit) |
| 1 | Drift detected (Audit) or one or more runtime operations failed |
| 2 | Precondition failure: not elevated, empty/malformed `$Shortcuts`, Public desktop not resolvable, or invalid `$Mode` |

## Sourcing notes

**Vendor-documented:**

- [`WshShell.CreateShortcut`](https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/windows-scripting/xsy6k3ys(v=vs.84)) — the Windows Script Host COM interface used for all `.lnk` create/read operations (TargetPath, Arguments, IconLocation, WorkingDirectory, Save).
- [KNOWNFOLDERID / FOLDERID_PublicDesktop](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid) — `%PUBLIC%\Desktop` (`C:\Users\Public\Desktop`) as the shared all-users desktop location.

**Community-observed:**

- The ~15-minute Iru agent check-in cadence, and Iru's native website-shortcut Library Item being Apple-Web-Clip-only (from the original spec's notes).

**Inferred (design reasoning, flagged in the text):**

- Under `SYSTEM`, per-user desktop resolution (`HKCU`, `GetFolderPath('Desktop')`) points into SYSTEM's own profile, hence the hard `%PUBLIC%` rule.
- The drift-semantics decisions listed under Modes & exit codes (unmanaged files ignored; browser-absent = skip, not drift; `WorkingDirectory` not audited).
