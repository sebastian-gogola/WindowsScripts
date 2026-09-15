# SecurityValidation

Lab harnesses that **deliberately provoke Iru's security features** so their detections can be observed and verified on a known device. Nothing in this folder manages a device. Everything in it changes a device's security posture on purpose.

> **Isolated test devices only.** These scripts create Microsoft Defender exclusions, drop antivirus test artifacts, or install software with known CVEs. Never scope them to a production blueprint. Run the script's cleanup/`Revert` path when the test is finished.

Like the rest of Sandbox: experimental, provided as-is, without warranty or official Iru support.

## Index

| Folder | Platform | What it validates | How |
|---|---|---|---|
| [`Test-IruEdrDetection/`](./Test-IruEdrDetection/) | Windows (PowerShell 5.1) | Iru EDR detects and quarantines malware | Scopes a narrow Defender exclusion to a single test directory and writes EICAR test artifacts into it. Defender owns the filesystem minifilter and normally wins every commodity-signature race, so without the exclusion Iru EDR never gets to report. Any quarantine inside the excluded path is attributable to Iru EDR. Single dual-slot script `Test-IruEdrDetection.ps1`, Audit / Enforce / Discover / Revert. |
| [`Vuln-Brew-Core/`](./Vuln-Brew-Core/) | **macOS** (bash) | Iru vulnerability detection reports known-CVE packages | Installs pinned **old** Homebrew formulae from a `homebrew/core` checkout at fixed commits, so each keg's `INSTALL_RECEIPT.json` records normal `homebrew/core` provenance — the provenance the Iru agent reports on. Two variants: `vuln-brew-core.sh` (run by hand as your user) and `vuln-brew-core-iru.sh` (Library Item; detects root and re-executes as the console user, since Homebrew refuses to run as root). |

## Why these live apart from the management scripts

The `Manage-*` scripts in Sandbox replicate Intune or CSP settings and are meant to be scoped to production. These do the opposite: they weaken a device so a security control has something to catch. Keeping them in their own folder makes that difference visible at a glance, gives the warning above one place to live, and keeps a lab harness from being mistaken for a hardening script when someone is building a blueprint.

## A note on platform

This repository is Windows-focused. `Vuln-Brew-Core/` is its only macOS content and sits here because it validates the same family of Iru features as the Windows harness beside it. If macOS content grows beyond one or two items, it should move to its own repository rather than gaining a platform layer inside this one.

## Conventions

Windows harnesses follow the Sandbox script conventions: configuration block at the top, `Enforce` / `Audit` / `Discover` / `Revert` modes, exit codes `0` / `1` / `2`, logging to `%ProgramData%\IruScripts\Logs\`, the standard experimental disclaimer in the header, and a `README.md` per folder. The macOS script is bash and documents its own conventions in its README.
