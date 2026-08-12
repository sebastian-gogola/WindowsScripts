# Manage-CisHardening (HardeningKitty)

> **EXPERIMENTAL - SANDBOX TIER**
> This script has not completed validation for the official Iru WindowsScripts tier.
> Test thoroughly in an isolated environment before deploying to production devices.
> Deploy to a pilot Blueprint first. Do not assign to production Blueprints without
> completing the rollout plan described below.

Deploys and orchestrates [HardeningKitty](https://github.com/scipag/HardeningKitty)
via Iru Custom Script Library Items to audit and enforce CIS Microsoft Windows 11
Enterprise benchmark controls across a managed Windows fleet.

---

## What This Is

HardeningKitty is an open-source (MIT-licensed) PowerShell module that audits a
Windows system against a security baseline defined in a CSV "finding list" and can
optionally enforce the recommended values ("HailMary" mode). This Library Item wraps
HardeningKitty in the standard Iru Audit/Remediation pattern:

| Iru Slot | HardeningKitty Mode | Behavior |
|---|---|---|
| Audit | `-Mode Audit` | Read-only compliance check against the finding list. Exits 0 (compliant) or 1 (non-compliant, triggers remediation). |
| Remediation | `-Mode HailMary` | Applies recommended values from the same finding list. |

The finding list -- not the script -- defines what gets enforced. Changing the
baseline means changing a data file, which keeps the enforcement logic stable and
reviewable.

## Sourcing

| Component | Source Tier | Notes |
|---|---|---|
| CIS Windows 11 Enterprise Benchmark | Vendor-documented | Authoritative PDF from CIS (cisecurity.org). Requires free account to download. |
| HardeningKitty module (`HardeningKitty.psm1`) | Community-maintained | scipag/HardeningKitty, MIT license. Widely used; not affiliated with CIS. |
| Finding list CSV (`finding_list_cis_microsoft_windows_11_enterprise_24h2_machine.csv`) | Community-maintained | A translation of the CIS Win11 24H2 benchmark into HardeningKitty's CSV format. **Not official CIS content.** |
| Pruned finding list (`finding_list_iru_cis_win11_machine.csv`) | Internal / inferred | Our fork of the above with fleet-breaking controls removed or adjusted. Deltas documented in `PRUNING.md`. |

**Customer-facing statement:** Organizations that require certified CIS remediation
content (e.g. for formal compliance attestation) should use CIS SecureSuite Build
Kits. This tooling provides CIS-*derived* hardening and compliance visibility, not
CIS-certified content.

## Repository Contents

```
Manage-CisHardening/
  README.md                                  <- this file
  PRUNING.md                                 <- documented deltas from upstream CSV
  Manage-CisHardening.ps1                    <- single script, both Iru slots
                                                (Audit slot: $Mode='Audit',
                                                 Remediation slot: $Mode='Enforce')
  payload/
    HardeningKitty.psm1                      <- pinned module (see PINNED VERSION)
    HardeningKitty.psd1
    finding_list_iru_cis_win11_machine.csv   <- pruned baseline (deploy this one)
    finding_list_upstream_reference.csv      <- unmodified upstream copy, reference only
```

## Pinned Version

| Item | Value |
|---|---|
| HardeningKitty release | `v.0.9.4` (pinned tag; raw URLs verified byte-identical to tag archive) |
| Module SHA256 (psm1) | `01EBA5F0F4F11FA21616946BD9EA7ECCD56079ABB9CAFDC7B8E7C60C75F63AEE` |
| Manifest SHA256 (psd1) | `9789FF549F0E9D4FFF0D1DD31620459B9AF3BB47968D202A83C24B0EA5641BDE` |
| Finding list base | CIS Microsoft Windows 11 Enterprise 24H2 (machine), HardeningKitty v.0.9.4, 647 controls |
| Pruned baseline | 450 L1 controls (L2 and BitLocker profiles removed -- see PRUNING.md) |
| Finding list SHA256 (pruned) | `88FEB973A6DDAE84D0AA5A0AF0B090B3649E446B185CD2D621FEB19240D5C478` |

The staging logic verifies these hashes before importing the module. A hash mismatch
is treated as a hard failure (exit 2) -- the script will not execute unverified code
as SYSTEM.

## Requirements

- Windows 11 (build 22000+ enforced by the script; baseline targets 24H2, controls carry forward -- see Known Limitations)
- Windows PowerShell 5.1 (not PowerShell 7)
- Execution as SYSTEM via Iru Custom Script Library Item
- English-language OS (HardeningKitty's secedit/User Rights parsing assumes English strings)
- Network access to the staging URL on first run (staging pattern), or none (embedded pattern)

## Script Conventions

Both scripts follow the standard WindowsScripts conventions:

- **Execution context:** SYSTEM, via Iru Custom Script Library Item
- **Encoding:** Pure ASCII (verify with `grep -P '[^\x00-\x7F]'`)
- **Exit codes:** `0` = compliant / success, `1` = non-compliant / remediation needed, `2` = script error (staging failure, hash mismatch, module import failure)
- **Logging:** `%ProgramData%\IruScripts\Logs\Manage-CisHardening_<timestamp>.log`
- **State registry:** `HKLM:\SOFTWARE\IruScripts\ManageCisHardening\`
  - `LastAuditTime`, `LastAuditScore`, `LastAuditPassRate`, `FailedControlIds`, `LastRemediationTime`, `PayloadHash`

## How It Works

### Payload staging

Iru deploys a single script file per slot, but HardeningKitty is three files. The
wrapper handles this with a stage-and-verify pattern:

1. Check for payload at `%ProgramData%\IruScripts\HardeningKitty\`
2. If missing, or if SHA256 does not match the pinned hash, download from the pinned
   release URL (or fail closed with exit 2 if network is unavailable)
3. Import module, run the requested mode against the pruned finding list

An alternative fully self-contained variant (payload base64-embedded in the script,
~600 KB) exists for environments where endpoints cannot reach the staging URL.

### Audit slot (`$Mode = 'Audit'`)

1. Stage/verify payload
2. `Invoke-HardeningKitty -Mode Audit -FileFindingList <pruned CSV>`
3. Parse results: count Passed vs Low/Medium/High findings
4. Compute pass rate; write score, pass rate, and failing control IDs to log and registry
5. Exit `0` if pass rate >= threshold (default **95%**), else exit `1`

The threshold is deliberately below 100%. A small number of controls can flap due to
timing, pending reboots, or values managed by overlapping profiles. Requiring 100%
causes remediation churn without a security benefit. Adjust `$PassRateThreshold` at
the top of the script if a customer requires a stricter posture.

### Remediation slot (`$Mode = 'Enforce'`)

1. Stage/verify payload
2. Snapshot current values: `Invoke-HardeningKitty -Mode Config -Backup` (best-effort
   rollback data -- **not** a substitute for a device backup)
3. `Invoke-HardeningKitty -Mode HailMary -FileFindingList <pruned CSV> -SkipRestorePoint`
4. Exit `0` on success, `2` on error

Audit re-runs on the next agent check-in and confirms convergence. Some controls only
take effect after reboot; expect one audit cycle of residual findings on freshly
remediated devices.

### Discover mode (`$Mode = 'Discover'`)

Read-only dump of the device's current values for every control in the finding list
(HardeningKitty Config mode), written to `Reports\discover_<timestamp>.csv`. No
comparison, no changes, always exits 0 on success. Useful for the Ring 1 audit-only
phase and for capturing before-state evidence per device.

## Deployment Steps

### 1. Validate manually first

On an isolated test VM (snapshot it first):

```powershell
Import-Module .\payload\HardeningKitty.psm1
Invoke-HardeningKitty -Mode Audit -Log -Report -FileFindingList .\payload\finding_list_iru_cis_win11_machine.csv
```

Record the before-state report. Then apply, reboot, re-audit, and live on the device:
verify Iru agent check-in, RDP, browser SSO, VPN, printing, and anything else the
target fleet depends on. Any breakage gets resolved by editing the CSV, not the script
-- document every removed/modified control in `PRUNING.md` with the CIS control ID and
the reason.

### 2. Create the Library Item

- Iru console -> Library -> Custom Script
- Paste `Manage-CisHardening.ps1` into the **Audit** slot with `$Mode = 'Audit'`
- Paste the identical file into the **Remediation** slot with `$Mode = 'Enforce'`
  (the mode line is the only difference between the two slots)
- Populate the pinned URLs and SHA256 hashes in the config block first -- the
  script fails closed (exit 2) if placeholders remain
- Execution frequency: daily is sufficient; the audit is read-heavy but not free
  (a full CIS pass takes a few minutes per device)

### 3. Ring the rollout

| Ring | Scope | Duration | Remediation |
|---|---|---|---|
| 0 | Test VMs | Until clean | On |
| 1 | Whole fleet | 1-2 weeks | **Off (audit-only)** |
| 2 | Pilot Blueprint (~5-10 real devices) | 1+ week | On |
| 3 | Production Blueprints, staged | Ongoing | On |

Ring 1 (fleet-wide audit-only) is the highest-value step for customer conversations:
it produces a compliance heat map of the entire estate before anything is enforced.
To run audit-only, deploy with the remediation script stubbed to exit 0, or simply
review audit results without acting on them.

### 4. Ongoing operations

- Compliance evidence per device: registry state keys + log files; aggregate via
  Iru device status on the Library Item
- Benchmark updates: diff the new upstream finding list against
  `finding_list_upstream_reference.csv`, apply relevant deltas to the pruned CSV,
  update pinned hashes, re-run Ring 0
- Exceptions: per-Blueprint scoping. A Blueprint that needs a control relaxed gets
  its own CSV variant -- never edit enforcement logic per customer

## Known Limitations

- **Benchmark version lag (community-observed):** The upstream CSV tracks CIS Win11
  v2.x (22H2 era). CIS has published newer benchmark versions. In practice the
  overwhelming majority of controls are registry/GPO-backed and carry forward
  unchanged to 23H2/24H2/25H2, but formal attestation against a specific benchmark
  version requires diffing against the current CIS PDF.
- **Machine list only.** The CIS user-level list (HKCU policies) is intentionally out
  of scope for v1. SYSTEM-context execution would require active-user hive loading;
  revisit if a customer requires user-level controls.
- **No true Revert mode.** HardeningKitty's backup restores registry values
  best-effort but is not a snapshot. The standard four-mode convention
  (Audit/Enforce/Discover/Revert) is intentionally reduced to Audit/Enforce here;
  rollback is "restore from device backup or re-provision."
- **English OS assumption (vendor-documented, HardeningKitty README):** secedit and
  User Rights Assignment parsing can misread localized systems.
- **Overlap with existing Library Items:** several CIS controls touch settings also
  managed by other scripts in this repo (removable storage, WHfB-adjacent policies)
  and by Iru profile-based Library Items. The pruned CSV must exclude any control
  already owned by another Library Item -- two enforcement sources fighting over one
  value causes remediation loops. Ownership decisions are documented in `PRUNING.md`.
- **Expect breakage from full L1 (community-observed):** common casualties include
  WinRM-dependent tooling, cached-credential logon for off-network laptops, and
  consumer features. This is why Ring 1 is audit-only and why the pruned CSV exists.

## License / Attribution

HardeningKitty is (c) scipag / Michael Schneider, MIT license. This repository
redistributes a pinned copy of the module and a modified finding list under the
terms of that license. CIS Benchmarks are the property of the Center for Internet
Security; the finding list is a community translation and is not certified CIS
content.
