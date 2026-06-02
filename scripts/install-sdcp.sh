#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Gernot Krost <gernot@krost.org>
set -euo pipefail

# Install the TenSeventy7 SDCP-fork libfprint (with egismoc 1c7a:05a5 / ETU906
# SDCP support) over the system library. Backup is stored OUTSIDE the library
# directory so ldconfig cannot pick it as the soname target (the bug that bit
# us with the previous in-dir .bak file).

# Repo root = parent of this scripts/ directory. The SDCP fork is expected to be
# cloned/built at <repo>/libfprint-egismoc-sdcp (see README "Build" step).
# Override by exporting FORK=/path/to/libfprint-egismoc-sdcp before running.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORK="${FORK:-$REPO_ROOT/libfprint-egismoc-sdcp}"
BUILDDIR="$FORK/builddir"
LIBDIR=/usr/lib/x86_64-linux-gnu
NEWLIB="$BUILDDIR/libfprint/libfprint-2.so.2.0.0"
BACKUP_DIR=/root/libfprint-backups
TS="$(date +%Y%m%d-%H%M%S)"

echo "==> Pre-checks"
[ -f "$NEWLIB" ] || { echo "ERROR: built lib not found at $NEWLIB"; exit 1; }
# Note: avoid `objdump | grep -q` under `set -o pipefail` -- grep -q closes the
# pipe early, objdump gets SIGPIPE (141), and pipefail turns that into a false
# failure. Capture to a var first, then grep without a pipe.
DUMP="$(objdump -s "$NEWLIB")"
grep -qiE "a5050000 7a1c0000" <<<"$DUMP" || { echo "ERROR: 05a5 missing"; exit 1; }
echo "    OK: built fork lib has 05a5"

echo "==> Backing up current libfprint to $BACKUP_DIR (outside libdir)"
mkdir -p "$BACKUP_DIR"
# The current real file (resolve symlink). Could already be a patched build.
CUR_REAL="$(readlink -f "$LIBDIR/libfprint-2.so.2" || true)"
echo "    current libfprint-2.so.2 -> $CUR_REAL"
cp -av "$LIBDIR/libfprint-2.so.2.0.0" "$BACKUP_DIR/libfprint-2.so.2.0.0.preSDCP-$TS"

echo "==> Installing fork lib as the canonical .so.2.0.0"
install -m0644 "$NEWLIB" "$LIBDIR/libfprint-2.so.2.0.0"

echo "==> Setting symlinks explicitly (do NOT rely on ldconfig to choose target)"
ln -sf libfprint-2.so.2.0.0 "$LIBDIR/libfprint-2.so.2"
ln -sf libfprint-2.so.2     "$LIBDIR/libfprint-2.so"
ldconfig
echo "    libfprint-2.so.2 -> $(readlink -f "$LIBDIR/libfprint-2.so.2")"

echo "==> Verify the ACTIVE (post-ldconfig) lib still resolves to fork + 05a5"
ACTIVE="$(readlink -f "$LIBDIR/libfprint-2.so.2")"
DUMP_ACTIVE="$(objdump -s "$ACTIVE")"
grep -qiE "a5050000 7a1c0000" <<<"$DUMP_ACTIVE" \
  || { echo "ERROR: active lib lost 05a5 (ldconfig repointed it). Active=$ACTIVE"; exit 1; }
echo "    OK: active lib = $ACTIVE has 05a5"

echo "==> Restart fprintd"
systemctl restart fprintd 2>/dev/null || true
sleep 1

echo
echo "==> Done. Backup: $BACKUP_DIR/libfprint-2.so.2.0.0.preSDCP-$TS"
echo "    Restore with:"
echo "      cp $BACKUP_DIR/libfprint-2.so.2.0.0.preSDCP-$TS $LIBDIR/libfprint-2.so.2.0.0 && ldconfig"
echo
echo "Now test:  fprintd-list \$USER  &&  fprintd-enroll"
