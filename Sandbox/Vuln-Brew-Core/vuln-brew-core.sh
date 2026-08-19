#!/bin/bash
#
# vuln-brew-core.sh  (LOCAL / MANUAL)
# Installs pinned OLD Homebrew formulae from homebrew/core under their
# CANONICAL names, so each keg's INSTALL_RECEIPT.json records
# source.tap = homebrew/core (normal provenance the Iru agent reports on).
#
# - Order-safe: openssl@3 installs before python@3.13 (python depends on it),
#   so python does NOT drag in the current patched openssl.
# - No version drift: dependents are not auto-upgraded (this is what silently
#   replaced gradle 8.14.2 with 9.6.1 before).
# - Non-interactive: no y/n prompts.
# - Idempotent: re-running skips what's already installed.
#
# Run as your normal user (NOT root). For MDM deployment use vuln-brew-core-iru.sh.

# -- pinned versions:  name|homebrew-core commit that set that version --
PINS=(
  "libpng|f0c1d45"
  "libpcap|20bc25d"
  "git|31c9c87"
  "openssl@3|94108d2"       # MUST come before python@3.13
  "python@3.13|e63f4c4"
  "gradle|dfb86557fa8"
)

# -- sanity --
if [ "$(id -u)" -eq 0 ]; then echo "ERROR: run as your user, not root." >&2; exit 1; fi
command -v brew >/dev/null 2>&1 || { echo "ERROR: brew not on PATH." >&2; exit 1; }

[ "$(uname -m)" = "arm64" ] && CELLAR="/opt/homebrew/Cellar" || CELLAR="/usr/local/Cellar"

# -- env: stop brew from resetting the tap, drifting versions, or prompting --
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_FROM_API=1          # use the checked-out old formula
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 # <- prevents the gradle-style drift
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

# -- ensure homebrew/core clone is present (checkout reads its git history) --
CORE="$(brew --repository homebrew/core)"
if [ ! -d "$CORE/Formula" ]; then
  echo "==> Cloning homebrew/core (one-time, ~1.4GB)..."
  brew tap homebrew/core --force
fi
git -C "$CORE" restore . 2>/dev/null || true    # start from a clean tap

install_pinned() {
  local name="$1" rev="$2" esc path count rc
  echo
  echo "==> $name  (rev $rev)"

  if brew list --versions "$name" >/dev/null 2>&1; then
    echo "    already installed - skipping"; return 0
  fi

  # resolve the sharded formula path AT that revision (unique match only)
  esc="${name//./\\.}"
  path=$(git -C "$CORE" ls-tree -r --name-only "$rev" 2>/dev/null | grep -E "^Formula/.*/${esc}\.rb$")
  count=$(printf '%s' "$path" | grep -c .)
  if [ "$count" -ne 1 ]; then
    echo "    !! could not resolve a unique formula path (got $count):"
    printf '       %s\n' $path
    return 1
  fi

  echo "    checkout $path"
  git -C "$CORE" checkout "$rev" -- "$path" || { echo "    !! checkout failed"; return 1; }

  echo "    installing (pours a bottle if one still exists, else builds)..."
  yes 2>/dev/null | brew install "$name"
  rc=${PIPESTATUS[1]}
  if [ "$rc" -eq 0 ]; then echo "    done"; else echo "    !! install failed (rc=$rc)"; fi
  return "$rc"
}

ok=(); bad=()
for entry in "${PINS[@]}"; do
  name="${entry%%|*}"; rev="${entry##*|}"
  if install_pinned "$name" "$rev"; then ok+=("$name"); else bad+=("$name"); fi
done

# leave the core tap clean, not sitting on old checkouts
git -C "$CORE" restore . 2>/dev/null || true

# -- summary + provenance (this is the part to show the dev team) --
echo
echo "------------ SUMMARY ------------"
echo "OK     : ${ok[*]:-none}"
echo "FAILED : ${bad[*]:-none}"
echo
echo "Installed version + provenance (source.tap):"
for n in libpng libpcap git openssl@3 python@3.13 gradle; do
  keg=$(ls -d "$CELLAR/$n"/*/ 2>/dev/null | head -1)
  if [ -n "$keg" ] && [ -f "${keg}INSTALL_RECEIPT.json" ]; then
    tap=$(python3 -c "import json;print(json.load(open('${keg}INSTALL_RECEIPT.json'))['source'].get('tap'))" 2>/dev/null)
    echo "  $n $(basename "$keg")   tap=$tap"
  else
    echo "  $n   MISSING"
  fi
done
echo "----------------------------------"
