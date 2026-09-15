# Vuln-Brew-Core

Installs pinned **old** Homebrew formulae under their canonical names so that each
keg's `INSTALL_RECEIPT.json` records `source.tap = homebrew/core`. This is the
provenance the Iru agent reports on, which makes the resulting known-CVE package
versions visible to Iru's vulnerability detection.

Built for STAR-1344 lab validation on isolated test devices.

---

## Why the tap matters

An earlier approach used `brew extract` into a local tap, which produced
`source.tap = malware/local`. The agent reports local-tap installs differently
and they may not generate detection events at all. Installing from a git checkout
of `homebrew/core` at a pinned revision keeps the canonical formula name **and**
normal provenance, which is the entire point of this method.

Verify with the provenance block printed at the end of every run:

```
  libpng 1.6.50        tap=homebrew/core
  libpcap 1.10.4       tap=homebrew/core
  ...
```

Anything showing `tap=` something else, or `MISSING`, did not land correctly.

---

## Pinned versions

| Formula       | Version  | homebrew-core commit |
|---------------|----------|----------------------|
| libpng        | 1.6.50   | `f0c1d45`            |
| libpcap       | 1.10.4   | `20bc25d`            |
| git           | 2.45.0   | `31c9c87`            |
| openssl@3     | 3.6.0    | `94108d2`            |
| python@3.13   | 3.13.10  | `e63f4c4`            |
| gradle        | 8.14.2   | `dfb86557fa8`        |

**Install order is load-bearing.** `openssl@3` must precede `python@3.13`,
otherwise python resolves its dependency against the current patched openssl and
you lose the vulnerable version you were trying to plant.

---

## The two scripts

Both scripts install the same six formulae with identical pinning logic. They
differ only in how they handle execution context.

### `vuln-brew-core.sh` — local / manual

Run by hand as your normal console user on the test device.

```bash
chmod +x vuln-brew-core.sh
./vuln-brew-core.sh
```

Exits immediately if run as root, because Homebrew refuses to run as root.

### `vuln-brew-core-iru.sh` — MDM deployment via Iru

Paste into an Iru library item script. The Iru agent runs library items as
**root**, but Homebrew refuses to run as root, so the local script fails
instantly with `ERROR: run as your user, not root.`

This version handles that. When it detects a root context it:

1. Reads the logged-in console user from `/dev/console`.
2. Re-executes itself as that user via `sudo -u "$CONSOLE_USER" -H`, feeding the
   script over stdin (the fd is opened while still root, so this works even if
   the agent's temp copy of the script is not readable by the console user).
3. Explicitly sets `PATH` to include the Homebrew prefix. The re-exec lands in a
   non-login shell, which never sources `.zprofile`, so `brew shellenv` never
   runs and `brew` would otherwise not be on `PATH`.

Run by hand as a normal user it skips the drop and behaves identically to the
local script, so it is effectively a superset.

**Requires an active console session.** If the device is sitting at the login
window on check-in, the script exits 1 by design and retries on the next
check-in rather than doing anything as root. Log the test user in before
triggering the item.

---

## Prerequisites

- **Homebrew** installed for the console user.
- **Xcode Command Line Tools** (`xcode-select --install`). The scripts depend on
  `git` and `python3`, and any formula whose old bottle has aged out of ghcr will
  build from source. `git 2.45.0` and `gradle 8.14.2` are known to source-build.
- **homebrew/core git clone** (~1.4 GB). Modern Homebrew runs in API mode and does
  not keep this checkout. Both scripts set `HOMEBREW_NO_INSTALL_FROM_API=1` and
  run `brew tap homebrew/core --force` if `Formula/` is missing, since the
  version-pinning trick reads git history. On a fresh machine the first run is
  slow because of this clone.

---

## Environment flags and what each one prevents

| Flag | Prevents |
|------|----------|
| `HOMEBREW_NO_AUTO_UPDATE=1` | brew auto-updating mid-run and resetting the git checkout |
| `HOMEBREW_NO_INSTALL_FROM_API=1` | brew ignoring the checked-out old formula in favor of the API |
| `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1` | silent dependent upgrades (this is what replaced gradle 8.14.2 with 9.6.1) |
| `HOMEBREW_NO_INSTALL_CLEANUP=1` | cleanup removing the old kegs you just planted |
| `HOMEBREW_NO_ENV_HINTS=1` | noise in the log output |

---

## Iru library item wiring

Deploy as a script library item using `vuln-brew-core-iru.sh`.

Notes on the Iru side:

- **Timeout.** First run on a fresh machine does the ~1.4 GB clone plus any
  source builds. Confirm this is not bumping the library item's script timeout,
  or you get a truncated run that looks like a failure.
- **Exit codes.** The script exits 0 on any completed run, even when individual
  formulae land in the `FAILED` list. It exits 1 only when no console user is
  logged in. If you want Iru to re-fire until all six are present, use an
  audit + remediation item where the audit tests for the six kegs on disk rather
  than trusting the install exit code.
- **Idempotent.** Re-running skips anything already installed, so repeated
  check-ins are safe.

---

## Troubleshooting

**`ERROR: run as your user, not root.`**
You deployed the local script through Iru. Use `vuln-brew-core-iru.sh`.

**`ERROR: no console user is logged in`**
Device is at the login window. Log the test user in and re-run.

**`ERROR: brew not on PATH`**
Homebrew is not installed for the console user, or is installed under a prefix
other than `/opt/homebrew` (Apple silicon) or `/usr/local` (Intel).

**`could not resolve a unique formula path`**
The homebrew/core clone is missing or shallow. Confirm
`$(brew --repository homebrew/core)/Formula` exists and the clone has full
history.

**A formula silently no-ops on install**
Check for a leftover hand-built keg in the Cellar from earlier spoofing attempts.
`brew list --versions <name>` returning a result causes the script to skip it.
Remove the keg directory and re-run.

**Version drift after a later `brew upgrade`**
Anything that upgrades dependents will undo these pins. These are lab devices;
do not run general `brew upgrade` on them.

---

## Cleanup

There is no revert script. To remove a planted version:

```bash
brew uninstall --force <name>
```

Then confirm the Cellar directory is gone before re-running the installer.
