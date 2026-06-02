#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Gernot Krost <gernot@krost.org>
#
# Test-drive the repo end-to-end in a vanilla Ubuntu 26.04 container.
#
# Validates the hardware-INDEPENDENT plumbing:
#   - build deps install on a clean distro
#   - the SDCP fork builds and the result carries the 1c7a:05a5 id
#   - scripts/install-sdcp.sh installs it (portable, repo-relative paths)
#   - scripts/setup-persistence.sh caches the lib + installs the APT hook
#   - the APT hook self-heals after `apt reinstall libfprint-2-2`
#
# The physical sensor (enroll/verify) cannot be tested in a container and is
# skipped.
#
# Usage:
#   test/container-testdrive.sh                # tests the current checkout
#   IMAGE=ubuntu:24.04 test/container-testdrive.sh
set -euo pipefail

IMAGE="${IMAGE:-ubuntu:26.04}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "### Test-driving repo at $REPO_ROOT in $IMAGE"
docker pull "$IMAGE" >/dev/null

# Mount the working tree read-only at /src; the container copies it to /opt/fp so
# it can build/clone inside without dirtying the host checkout.
docker run --rm -i \
  -v "$REPO_ROOT":/src:ro \
  "$IMAGE" bash -euo pipefail <<'CEOF'
export DEBIAN_FRONTEND=noninteractive

echo "=== install deps + the runtime package we later 'reinstall' ==="
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates git \
  meson ninja-build build-essential pkg-config \
  libglib2.0-dev libgusb-dev libgudev-1.0-dev \
  libpixman-1-dev libcairo2-dev libssl-dev libnss3-dev systemd-dev \
  libfprint-2-2 binutils >/dev/null

# Work on a copy of the checked-out repo (not the GitHub main branch).
cp -a /src /opt/fp
cd /opt/fp

has_marker() { local d; d="$(objdump -s "$1")"; grep -qiE "a5050000 7a1c0000" <<<"$d"; }

echo "=== STEP 1: build the SDCP fork into the repo root ==="
git clone --depth 1 https://github.com/TenSeventy7/libfprint-egismoc-sdcp.git
( cd libfprint-egismoc-sdcp
  meson setup builddir \
    --prefix=/usr --libdir=lib/x86_64-linux-gnu --buildtype=plain \
    -Ddoc=false -Dgtk-examples=false -Dintrospection=false -Ddrivers=all >/dev/null
  ninja -C builddir >/dev/null )
has_marker libfprint-egismoc-sdcp/builddir/libfprint/libfprint-2.so.2.0.0 \
  && echo "PASS: built lib has 05a5" || { echo "FAIL: 05a5 missing in build"; exit 1; }

echo "=== STEP 2: scripts/install-sdcp.sh ==="
bash scripts/install-sdcp.sh
ACTIVE="$(readlink -f /usr/lib/x86_64-linux-gnu/libfprint-2.so.2)"
has_marker "$ACTIVE" && echo "PASS: active lib has 05a5 ($ACTIVE)" || { echo "FAIL"; exit 1; }

echo "=== STEP 3: scripts/setup-persistence.sh ==="
bash scripts/setup-persistence.sh >/dev/null
[ -f /opt/libfprint-sdcp/libfprint-2.so.2.0.0 ] && echo "PASS: cache present" || { echo "FAIL: no cache"; exit 1; }
[ -f /etc/apt/apt.conf.d/99-libfprint-sdcp ]    && echo "PASS: apt hook installed" || { echo "FAIL: no hook"; exit 1; }
[ -x /usr/local/sbin/libfprint-sdcp-reinstall ] && echo "PASS: reinstall script installed" || { echo "FAIL"; exit 1; }

echo "=== STEP 4: simulate distro overwrite -> hook must self-heal ==="
apt-get install --reinstall -y libfprint-2-2 >/tmp/reinstall.log 2>&1 || true
grep -i "libfprint-sdcp" /tmp/reinstall.log || true
ACTIVE2="$(readlink -f /usr/lib/x86_64-linux-gnu/libfprint-2.so.2)"
has_marker "$ACTIVE2" \
  && echo "PASS: hook restored SDCP lib after apt reinstall ($ACTIVE2)" \
  || { echo "FAIL: hook did NOT restore ($ACTIVE2)"; exit 1; }

echo
echo "=== HARDWARE STEPS SKIPPED (no 1c7a:05a5 USB device in container) ==="
echo "######################################################"
echo "### CONTAINER TEST-DRIVE: ALL PLUMBING CHECKS PASSED ###"
echo "######################################################"
CEOF
