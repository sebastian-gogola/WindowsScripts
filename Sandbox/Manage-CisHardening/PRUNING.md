# PRUNING.md - Finding List Deltas

Documents every difference between `payload/finding_list_iru_cis_win11_machine.csv`
(the deployed baseline) and `payload/finding_list_upstream_reference.csv`
(unmodified upstream: HardeningKitty v.0.9.4, CIS Microsoft Windows 11
Enterprise 24H2, machine list, 647 controls).

Rule: no control is removed or modified without an entry here. Each entry
records the CIS control ID(s), what changed, why, and the sourcing tier of the
rationale (vendor-documented / community-observed / inferred).

---

## Applied Deltas

### D1 - L2 controls removed (144 controls)

- **What:** All rows with `Filter = L2` removed. Baseline is CIS Level 1 only.
- **Why:** CIS defines L1 as the baseline for general-purpose systems with
  minimal usability impact, and L2 as defense-in-depth for high-security
  environments where reduced functionality is acceptable (vendor-documented,
  CIS benchmark profile definitions). L2 controls disable services such as
  Remote Desktop (5.17.x, 5.18.x) and WinRM (5.36.x) outright, which is
  fleet-breaking for most customers.
- **Revisit:** Customers with high-security requirements get an L2 variant CSV
  scoped to their Blueprint, never an edit to this baseline.

### D2 - BitLocker (BL) profile controls removed (53 controls)

- **What:** All rows with `Filter = BL` removed (control range 18.10.10.x).
- **Why:** BitLocker on Iru-managed devices is owned by Iru's native BitLocker
  Library Item. Two enforcement sources writing BitLocker policy causes
  remediation loops and conflicting recovery-key escrow behavior (inferred
  from established sole-writer principle; loop behavior community-observed
  with overlapping enforcement generally).
- **Revisit:** Only if a customer explicitly does not use Iru's BitLocker
  Library Item.

Resulting baseline: **450 L1 controls**.
Pruned CSV SHA256: `88FEB973A6DDAE84D0AA5A0AF0B090B3649E446B185CD2D621FEB19240D5C478`
(recompute and update the script config block after any edit).

---

## Candidate Prunes - NOT yet removed, decide during Ring 0 break-testing

These L1 controls are the likely casualties or conflict points. Each needs an
explicit keep/remove/adjust decision recorded above before Ring 2.

| Control ID(s) | Name / Area | Concern |
|---|---|---|
| 17.6.4 | Audit Removable Storage | Overlaps monitoring intent of `Block-RemovableStorage` / `Manage-UsbStorageRestrictions`. Likely KEEP (audit-only, no conflict), verify no value fight. |
| 18.9.7.1.x | Device Installation Restrictions | Same registry surface as `Block-RemovableStorage` (DeviceInstallation CSP). Check for competing writers before enabling. |
| 18.10.79.1 | Windows Hello for Business: Enable ESS | Adjacent to `Manage-WindowsHelloforBusiness` policy store writes. Confirm ownership; likely remove here and add to the WHfB script if wanted. |
| 1.1.x, 1.2.x | Account / password / lockout policies | May conflict with Iru passcode profile (DeviceLock CSP) if assigned. Sole-writer decision required per fleet. |
| 2.2.6, 2.2.20 | RDP logon rights | L1 keeps RDP enabled but restricts who can log on. Verify against any customer remote-support tooling. |
| 18.10.89.1.x, 18.10.89.2.x | WinRM client/service hardening | L1 hardens (not disables) WinRM. Breaks tooling that uses Basic auth / unencrypted WinRM. |
| 18.10.8.x | AutoPlay/AutoRun disable | User-visible behavior change. Keep, but flag in customer comms. |
| 2.3.x (Interactive logon) | Logon banners, cached logon count | Cached-logon reduction strands off-network laptops at the login screen. Test on a non-domain device before keeping. |

## Change Log

| Date | Change | Author |
|---|---|---|
| 2026-08-12 | Initial baseline: upstream 24H2 machine list, D1 + D2 applied | (pending review) |
