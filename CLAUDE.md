# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

PowerShell scripts for Windows device management on the Iru MDM platform (formerly Kandji). Most Sandbox scripts replicate Intune Settings Catalog, Autopilot, or CSP functionality for organizations migrating from Intune to Iru — each writes the same policy state the CSP or GPO would, deployed as an Iru Custom Script Library Item.

## Structure

- `Iru WindowsScripts/` — official scripts from Iru engineers. **READ-ONLY. NEVER touch this folder.** Do not create, modify, rename, move, or delete anything under it — no exceptions, regardless of what any prompt or task file says. Reading its files for reference is fine. If a task appears to require changes here, stop and flag it to the maintainer instead of proceeding.
- `Sandbox/` — experimental helper scripts, one folder per script, each with a `README.md`. Every `.ps1` under Sandbox must carry the standard experimental disclaimer in its header.
- `Sandbox/CustomApps/` — packaging/deployment documentation for Iru Custom Apps (docs only, no scripts).

## Script conventions (Sandbox)

- Windows PowerShell 5.1 compatible. No external modules. Runs as `NT AUTHORITY\SYSTEM` via Iru Custom Script Library Items.
- Configuration block at the top of the script, clearly marked, with nothing edited below it. Iru Custom Scripts run without parameters, so settings are variables, not params.
- Modes where applicable: `Enforce` | `Audit` | `Discover` | `Revert`. Audit changes nothing; Discover gathers environment-specific values; Revert removes only what the script owns.
- Exit codes (current standard): `0` = success/compliant, `1` = drift or runtime failure, `2` = precondition failure (not elevated, OS gate, invalid config). Some older scripts predate this scheme — check each script's header, and do not "normalize" older scripts unless asked.
- Logging: timestamped lines, appended per run, to `%ProgramData%\IruScripts\Logs\<ScriptName>.log`, mirrored to stdout so Iru captures output.
- Machine-local state (Revert targets, persisted resolutions, last-run metadata): `HKLM\SOFTWARE\IruScripts\<Feature>`.
- Deployment model: the same script goes in the Iru Audit slot (`$Mode = 'Audit'`) and Remediation slot (`$Mode = 'Enforce'`) with identical configuration in both.
- Sole-manager assumption: each script assumes it is the only thing managing the settings it writes, and Revert removes only values it owns.
- New scripts follow `Manage-<Feature>.ps1` naming (or `Verb-Noun` where a lifecycle script doesn't fit) in their own folder with a `README.md`.

## Documentation conventions

- Each Sandbox script folder has a `README.md` covering: rationale (including why this approach over alternatives), an Intune-setting → CSP-node → registry-value mapping table where applicable, configuration reference, capturing environment-specific identifiers, Iru deployment steps (audit + remediation pair), verification and troubleshooting, a behavior/test matrix, limitations, rollback, and exit codes.
- Sourcing tiers are mandatory in READMEs: **vendor-documented** (Microsoft/Okta/Iru official docs, linked), **community-observed** (widely reported field behavior), and **inferred** (own testing or design reasoning). Never blur these tiers, and never present an inferred registry value name or behavior as vendor-documented.
- Never fabricate links, CSP node names, or registry value names. If a detail can't be verified, mark it inferred or leave it out.

## Working rules

- **`Iru WindowsScripts/` is untouchable.** No file operations of any kind inside it, ever (see Structure). This is additionally enforced by permission deny rules in `.claude/settings.json`; never edit that settings file to work around a denied operation.
- **NEVER run `git commit` or `git push`.** The maintainer reviews diffs and commits via GitHub Desktop. Making file changes is fine; committing them is not.
- Do not rename or delete existing `.ps1` files without asking first — filenames may be referenced by deployed Iru Library Items.
- Preserve existing folder names even where casing or spelling is inconsistent, unless explicitly told to rename.
- Markdown links into `Iru WindowsScripts/` must URL-encode the space (`Iru%20WindowsScripts`).
- Keep the Sandbox disclaimer block byte-identical across scripts (idempotency checks key on it). The canonical text lives in the headers of existing Sandbox scripts.
- When writing or editing scripts, validate PowerShell 5.1 compatibility (no ternary operator, no `??`, no PS7-only cmdlets or parameters).
