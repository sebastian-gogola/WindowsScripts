# Test-IruEdrDetection.ps1

Generates EICAR anti-malware test artifacts inside a Microsoft Defender exclusion so that **Iru EDR's** file detection and quarantine can be observed on a lab device, instead of Defender winning the race and leaving nothing for Iru to report.

- **Script:** `Test-IruEdrDetection.ps1` (v2.0.0)
- **Target OS:** Windows 11 24H2 or later
- **Runs as:** SYSTEM (Iru Custom Script) or elevated admin shell
- **PowerShell:** 5.1; uses only the in-box `Defender` and `Microsoft.PowerShell.Archive` modules
- **Scope:** **Lab / isolated test devices only.** This script deliberately weakens Defender on one directory.

> **Status: untested in this form.** v2.0.0 consolidates the former `audit` and `remediation` files (which differed only in the `$Mode` default) into one dual-slot script, converts the parameters to a configuration block, aligns exit codes with the rest of Sandbox, and hardens artifact staging. The consolidated script has not been executed on a device. Run `Discover`, then a single `Enforce`, on a lab machine before relying on it.

---

## Why this exists

Iru EDR and Microsoft Defender both watch the filesystem. Defender holds the antimalware minifilter and sees every write first. On a device where Defender is the registered antivirus, any commodity-signature file — EICAR included — is quarantined by Defender before a second agent gets a look. From the Iru console that reads as "nothing detected", which is the wrong conclusion: Iru never got the chance.

Windows resolves this contest through Windows Security Center: when a non-Microsoft antivirus registers as the primary product, Defender steps aside on its own — **disabled mode** on client devices that are not onboarded to Microsoft Defender for Endpoint, **passive mode** when they are (or when Smart App Control is on). An EDR agent that does *not* register with Security Center leaves Defender active and loses every race.

This script sidesteps the question for a controlled test. It:

1. Adds a **Defender path exclusion** scoped to one test directory — and verifies the exclusion actually persisted, because Tamper Protection can reject the change without raising an error.
2. Writes the four standard **EICAR** variants into that directory. EICAR is a 68-byte, printable-ASCII string that every AV vendor detects by agreement; it has no payload. The script assembles it from fragments at run time so that the script file itself never contains the signature and cannot be quarantined before it runs.
3. Waits `$SettleSeconds`, then reports which artifacts **survived** and which were **removed**.
4. Checks the Defender operational log for detection events (`1116`, `1117`) in the same window. Removals with **no** Defender events are attributable to Iru EDR; removals **with** Defender events are ambiguous.

Because Defender is excluded from the path, a quarantine inside it can only have come from something else — on an Iru-managed lab device, that is Iru EDR.

### Why not simply disable Defender?

Turning Defender off device-wide is a bigger change with a bigger blast radius, is blocked by Tamper Protection on most Windows 11 installs, and proves nothing about coexistence. A one-directory exclusion is the smallest change that gives Iru an uncontested look at a file, and `Revert` removes it cleanly.

### Why the daily gate

`Enforce` stamps today's date into the state key **before** writing artifacts. If Iru EDR's response is aggressive enough to kill the PowerShell process mid-run, the stamp still exists, so the Audit slot reports compliant for the rest of the day and the test does not re-fire on every agent check-in.

---

## Configuration reference

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `'Audit'` | `Enforce` \| `Audit` \| `Discover` \| `Revert`. Defaults to `Audit` — the only mode that cannot change a device — because pasting this script unmodified must be harmless. |
| `$TestPath` | `%ProgramData%\IruScripts\EdrTest\badfiles` | Directory that receives the artifacts and is excluded from Defender. |
| `$SettleSeconds` | `45` | Wait after writing before evaluating what survived. Range 5–600, validated. |
| `$SkipExclusion` | `$false` | `$true` writes the artifacts **without** adding an exclusion — a control run that demonstrates Defender winning. |
| `$AgentServicePattern` | `@('*iru*', '*kandji*')` | Service-name wildcards used only to report whether the Iru agent is present. |
| `$LogDirectory` / `$LogFile` | `%ProgramData%\IruScripts\Logs\Test-IruEdrDetection.log` | Timestamped log, appended per run, mirrored to stdout. |

State lives at `HKLM\SOFTWARE\IruScripts\EdrTestFiles` (`LastRun`, `TestPath`, `ExclusionAdded`). The key name is unchanged from v1 so `Revert` still cleans up after devices that ran the old copies.

### Capturing environment-specific values

Run `Discover` first. It is read-only and prints everything the test depends on:

- every product registered with Windows Security Center and its `productState`, so you can see whether Iru EDR registers as an antivirus (if it does, Defender should already have stepped aside and the exclusion is belt-and-braces);
- Defender's presence, real-time protection state, `AMRunningMode`, and whether **Tamper Protection** is on — the one value that decides whether a local exclusion will stick;
- which Iru/Kandji agent services matched `$AgentServicePattern` (fix the pattern if none did);
- whether `$TestPath` exists, whether the exclusion is already present, and the last recorded run date.

The only value you might need to change per tenant is `$AgentServicePattern`, and only if `Discover` reports no matching service.

---

## Deploying via Iru

Deploy as a **Custom Script** Library Item scoped to a **lab blueprint only**:

1. **Audit slot:** the script with `$Mode = 'Audit'`. Exit 0 = today's test already ran, exit 1 = not yet → remediation.
2. **Remediation slot:** the identical script with `$Mode = 'Enforce'`.
3. **Execute in:** 64-bit. Runs as `NT AUTHORITY\SYSTEM`.
4. Per Iru's current documentation, Windows Custom Scripts execute **once per device**, so the daily gate mostly matters for manual re-runs; to repeat the test on a device, re-scope the Library Item or run the script by hand from an elevated shell.
5. **When finished, deploy a one-off run with `$Mode = 'Revert'`** (or run it manually) so the exclusion does not outlive the test.

A control run is worth doing once: set `$SkipExclusion = $true` on a device, run `Enforce`, and confirm Defender removes everything and logs `1116`/`1117`. That is the baseline the real test is measured against.

---

## Verification & troubleshooting

**Read the log** — `%ProgramData%\IruScripts\Logs\Test-IruEdrDetection.log`. A successful `Enforce` ends with a `--- Results ---` block listing each artifact as `SURVIVED` or `REMOVED`, followed by the Defender event count and an attribution line.

**Confirm in the Iru console.** The script can only see what disappeared from disk. The proof is the corresponding detections in Iru's threat view — the log says so at the end of every `Enforce`, and it means it.

```powershell
# Exclusion currently in place?
(Get-MpPreference).ExclusionPath

# Defender detections in the last 10 minutes (1116 = detected, 1117 = action taken)
Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117
    StartTime = (Get-Date).AddMinutes(-10) } -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id

# State
Get-ItemProperty 'HKLM:\SOFTWARE\IruScripts\EdrTestFiles'
```

| Log line | Meaning |
|---|---|
| `Exclusion did not persist. Tamper Protection is likely enabled.` | `Add-MpPreference` returned without error but the path is not in the exclusion list. Local changes are being rejected; the exclusion has to come from whatever manages Defender policy in your tenant. The run continues, but results reflect Defender, not Iru. |
| Every artifact `REMOVED`, Defender events **present** | Defender saw the writes — the exclusion was missing or rejected. Attribution is ambiguous. |
| Every artifact `REMOVED`, **no** Defender events | The intended outcome: Iru EDR quarantined the artifacts. Confirm in the Iru console. |
| Every artifact `SURVIVED`, no Defender events | Iru EDR either did not detect EICAR or is configured to alert without quarantining. Check the Iru console for alerts before concluding it missed. |
| `source removed during staging (counts as detected)` | A scanner removed the raw EICAR file before it could be copied or zipped. That is a fast detection, not a failure; the affected variants are reported as `REMOVED`. |
| `No Iru/Kandji agent service matched.` | Presence check only. Fix `$AgentServicePattern` if the agent is installed under another service name. |

**Behavior matrix (recommended acceptance tests)** — none run yet; this is the plan.

| Test | Expected |
|---|---|
| `Discover` on a lab device | Inventory printed, nothing changed, exit 0 |
| `Audit` before any run | "not yet run for today", exit 1 |
| `Enforce`, Tamper Protection off, Iru EDR quarantining | Exclusion added and verified; 4 artifacts written; 4 `REMOVED`; no Defender events; "Attributable to Iru EDR"; exit 0 |
| `Audit` immediately after | "already ran today; compliant", exit 0 |
| `Enforce` with `$SkipExclusion = $true` (control) | Artifacts `REMOVED`; Defender `1116`/`1117` present; "Attribution is ambiguous"; exit 0 |
| `Enforce`, Tamper Protection on | "Exclusion did not persist" error line; run continues with a warning; exit 0 |
| Iru EDR removes `eicar.com` before zipping | Staging warnings, zip variants reported `REMOVED`, exit 0 — not exit 1 |
| `$SettleSeconds = 2` | Exit 2, nothing changed |
| Non-elevated shell | Exit 2 |
| `Revert` | Exclusion removed, directory deleted, state key gone, exit 0 |

---

## Limitations & operational notes

**It weakens Defender.** A path exclusion is a real hole for as long as it exists. Everything about this script assumes a disposable lab device; `Revert` when done, and never scope the Library Item to a blueprint with production devices in it.

**It tests one detection path.** EICAR exercises signature-based *file* detection on write. It says nothing about behavioral, memory, or network detection, and a pass here is not an EDR evaluation — it is a coexistence check that Iru gets to see files at all.

**Quarantine is a policy choice.** If Iru EDR is configured to alert rather than remediate, every artifact `SURVIVED` is the correct result. Read the Iru console, not just the log.

**Tamper Protection decides whether the exclusion sticks.** Windows 11 typically ships with it on. Where it is, `Add-MpPreference` is refused silently; the script detects this and says so, but cannot work around it — the exclusion then has to be delivered by the mechanism that manages Defender settings in your environment, or the device needs Tamper Protection off for the duration of the test.

**Agent detection is heuristic.** `*iru*` / `*kandji*` are name patterns, not an API. A false negative only affects the `Discover` report.

**Sole-manager assumption.** The script removes only the exclusion it added and only its own state key.

**Encoding.** The `.ps1` is deliberately pure ASCII: the agent writes scripts to its cache without a BOM, and Windows PowerShell 5.1 treats curly quotes as string delimiters — one pasted em dash or smart quote produces an unterminated-string parse error. Keep edits ASCII-only.

## Rollback

Set `$Mode = 'Revert'` and run once. It removes the Defender exclusion for the recorded `TestPath`, deletes that directory and everything in it, and deletes `HKLM\SOFTWARE\IruScripts\EdrTestFiles`. Artifacts already quarantined by Iru EDR stay in Iru's quarantine and are managed from the console. Exit 0 even when there is nothing left to remove.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Compliant (Audit) / operation succeeded (Enforce, Discover, Revert) |
| 1 | Non-compliant (Audit — today's test has not run) or an unhandled runtime failure |
| 2 | Precondition failure: not elevated, unknown `$Mode`, `$SettleSeconds` out of range, or empty `$TestPath` — nothing is changed |

v1 used `2` for both preconditions and runtime errors; v2 follows the Sandbox standard, where runtime failures are `1`.

---

## Sourcing notes

**Vendor-documented:**

- [EICAR anti-malware test file](https://www.eicar.org/download-anti-malware-testfile/) — the test file is exactly 68 printable-ASCII bytes, a legitimate DOS program with no payload, offered as `eicar.com`, `eicar.com.txt`, `eicar_com.zip`, and a doubly-zipped variant — the four artifacts this script produces.
- [Microsoft Defender Antivirus compatibility with other security products](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-compatibility) — that a registered non-Microsoft antivirus puts Defender into **disabled** mode on Windows 10/11 clients not onboarded to Defender for Endpoint, and **passive** mode when onboarded or when Smart App Control is on; that the Windows Security Center service must be enabled for Defender to detect a third-party product at all; and that `Get-MpComputerStatus | select AMRunningMode` reports the current mode.
- [Microsoft Defender Antivirus event IDs and error codes](https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-microsoft-defender-antivirus) — the `Microsoft-Windows-Windows Defender/Operational` channel; event `1116` "The antimalware platform detected malware or other potentially unwanted software"; event `1117` "The antimalware platform performed an action to protect your system from malware or other potentially unwanted software."
- [Iru — Custom Scripts overview](https://docs.iru.com/en/endpoint/library/library-items-profiles/custom-scripts-overview#windows) — Windows audit/remediation semantics (non-zero audit exit = non-compliant, remediation runs only then), 64-bit execution, and the once-per-device execution statement.

**Community-observed:**

- That Tamper Protection causes `Add-MpPreference -ExclusionPath` to return without error while the change does not persist is widely reported field behavior; the script verifies the write for exactly this reason rather than trusting the cmdlet's silence.
- That Windows PowerShell 5.1 fails to parse scripts containing curly quotes when the file is written without a BOM (treating them as string delimiters) is the failure mode the ASCII-only rule guards against.

**Inferred (own reasoning — verify in your environment):**

- The framing that Defender's minifilter gives it "first look" and therefore wins signature races against a non-registered agent is a reasoning about filter ordering, not a documented Defender guarantee. The `$SkipExclusion` control run exists so you can confirm it on your hardware rather than take it on faith.
- Attributing a removal with no Defender `1116`/`1117` events to Iru EDR assumes nothing else on the lab device quarantines files. On a clean lab image that holds; on anything else, check the Iru console.
- Treating a staged file that vanishes mid-run as "detected" rather than "error" is this script's design choice in v2, made because the v1 behaviour (throwing and exiting 2) would have reported the fastest possible detection as a failure.
- The v2 consolidation and the staging hardening have not been executed anywhere yet.
