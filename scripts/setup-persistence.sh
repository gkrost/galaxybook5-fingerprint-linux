#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Gernot Krost <gernot@krost.org>
#
# setup-persistence.sh  (run once, as root)
#
# Makes the SDCP libfprint survive apt upgrades automatically:
#   1. Caches the currently-built SDCP libfprint .so into /opt/libfprint-sdcp
#      (with the upstream version it was built against).
#   2. Installs /usr/local/sbin/libfprint-sdcp-reinstall (the self-healing
#      restore script).
#   3. Installs the APT Post-Invoke hook /etc/apt/apt.conf.d/99-libfprint-sdcp.
#
# After this, normal `apt upgrade` keeps working; if it ever replaces libfprint
# with the distro build, the hook restores the SDCP build (and warns you if a
# newer upstream shipped). Idempotent: safe to re-run to refresh the cache.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
# The SDCP fork is expected at <repo>/libfprint-egismoc-sdcp (see README).
# Override by exporting FORK=/path/to/libfprint-egismoc-sdcp before running.
FORK="${FORK:-$REPO_ROOT/libfprint-egismoc-sdcp}"
FORK_BUILT="$FORK/builddir/libfprint/libfprint-2.so.2.0.0"
CACHE_DIR=/opt/libfprint-sdcp
MARKER="a5050000 7a1c0000"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo $0)" >&2
  exit 1
fi

echo "==> 1/4 Locating built SDCP library"
if [ ! -f "$FORK_BUILT" ]; then
  echo "ERROR: built fork lib not found at $FORK_BUILT" >&2
  echo "       Build it first: ninja -C $FORK/builddir" >&2
  exit 1
fi
DUMP="$(objdump -s "$FORK_BUILT")"
grep -qiE "$MARKER" <<<"$DUMP" || { echo "ERROR: built lib lacks 05a5" >&2; exit 1; }
echo "    OK: $FORK_BUILT (has 05a5)"

echo "==> 2/4 Caching artifact + version into $CACHE_DIR"
install -d -m0755 "$CACHE_DIR"
install -m0644 "$FORK_BUILT" "$CACHE_DIR/libfprint-2.so.2.0.0"
# Record the upstream libfprint version this build is meant to shadow, so the
# reinstall script can warn on drift.
INSTALLED_VER="$(dpkg-query -W -f='${Version}' libfprint-2-2 2>/dev/null || echo unknown)"
echo "$INSTALLED_VER" > "$CACHE_DIR/built-against-version"
echo "    cached lib + built-against-version=$INSTALLED_VER"

echo "==> 3/4 Installing reinstall script -> /usr/local/sbin/libfprint-sdcp-reinstall"
install -m0755 "$SELF_DIR/libfprint-sdcp-reinstall" /usr/local/sbin/libfprint-sdcp-reinstall

echo "==> 4/4 Installing APT hook -> /etc/apt/apt.conf.d/99-libfprint-sdcp"
install -m0644 "$REPO_ROOT/apt/99-libfprint-sdcp" /etc/apt/apt.conf.d/99-libfprint-sdcp

echo
echo "==> Done. Verifying hook config parses:"
apt-config dump >/dev/null 2>&1 && echo "    apt config OK" || echo "    WARN: apt-config reported an issue"

echo
echo "Running the reinstall script once now (should be a no-op if SDCP lib is active):"
/usr/local/sbin/libfprint-sdcp-reinstall || true

echo
echo "Persistence is active. Test it any time with:"
echo "  sudo /usr/local/sbin/libfprint-sdcp-reinstall   # manual self-heal"
echo "To remove persistence:"
echo "  sudo rm -f /etc/apt/apt.conf.d/99-libfprint-sdcp /usr/local/sbin/libfprint-sdcp-reinstall"
echo "  sudo rm -rf /opt/libfprint-sdcp"
