# Samsung Galaxy Book5 (960XHA) — Fingerprint Sensor on Linux

Get the **Egis ETU906Axx-E** fingerprint reader (`1c7a:05a5`) working under Linux
(tested on **Ubuntu 26.04 / KDE Plasma 6 / SDDM**, kernel `7.0.9`).

## TL;DR

The sensor is an Egis **Match-on-Chip (MoC)** device that requires the **SDCP**
(Secure Device Connection Protocol) handshake. Mainline `libfprint` 1.95.1 ships
the `egismoc` driver but (a) doesn't list USB id `1c7a:05a5`, and (b) its `egismoc`
driver doesn't perform the SDCP handshake this variant needs. The fix is to build
and install the **SDCP-capable `egismoc` fork** (which already lists `05a5`).

## Hardware / software this was verified on

| Item | Value |
|------|-------|
| Laptop | Samsung Galaxy Book5 — `960XHA`, board `NP964XHA-KG2DE` |
| Sensor | Egis Technology (LighTuning) ETU906Axx-E, USB `1c7a:05a5` |
| OS | Ubuntu 26.04 LTS (resolute) |
| Desktop / DM | KDE Plasma 6 / SDDM |
| Kernel | 7.0.9 |
| Distro libfprint | `1:1.95.1+tod1-0ubuntu1` |
| Working driver | `TenSeventy7/libfprint-egismoc-sdcp` (base 1.94.9, HEAD `4d128d4`) |

## Why the distro driver isn't enough

1. **USB id not listed.** `egismoc_id_table` in stock 1.95.1 lists
   `0582–0588, 05a1, 05ae` but **not `05a5`**, so libfprint never claims the device
   (`fprintd-list` → "No devices available").
2. **SDCP required.** Even after adding `05a5`, the stock `egismoc` driver derives
   from `FP_TYPE_DEVICE` (no SDCP). The ETU906 returns SDCP-framed responses, so
   identify/enroll fails with *"Unrecognized response from device"* /
   `enroll-disconnected`. The fork derives from `FPI_TYPE_SDCP_DEVICE` and performs
   the ConnectResponse handshake, and flags `05a5` with
   `EGISMOC_DRIVER_CHECK_PREFIX_TYPE2 | EGISMOC_DRIVER_MAX_ENROLL_STAGES_15`.

## Step-by-step

### 0. Confirm your sensor

```bash
lsusb | grep -i 1c7a
# Bus ... ID 1c7a:05a5 LighTuning Technology Inc. ETU906Axx-E
```

If your id is **not** `1c7a:05a5`, this exact recipe may not apply — check the
fork's `egismoc_id_table` for your id first.

### 1. Build dependencies

```bash
sudo apt-get install -y --no-install-recommends \
  meson ninja-build build-essential pkg-config \
  libglib2.0-dev libgusb-dev libgudev-1.0-dev \
  libpixman-1-dev libcairo2-dev libssl-dev libnss3-dev systemd-dev
```

### 2. Build the SDCP fork

Clone this repo, then clone + build the SDCP fork **inside the repo root**
(the scripts expect it at `./libfprint-egismoc-sdcp`):

```bash
git clone https://github.com/gkrost/galaxybook5-fingerprint-linux.git
cd galaxybook5-fingerprint-linux

git clone --depth 1 https://github.com/TenSeventy7/libfprint-egismoc-sdcp.git
cd libfprint-egismoc-sdcp
meson setup builddir \
  --prefix=/usr --libdir=lib/x86_64-linux-gnu --buildtype=plain \
  -Ddoc=false -Dgtk-examples=false -Dintrospection=false -Ddrivers=all
ninja -C builddir
cd ..
```

Verify the build contains the device id:

```bash
objdump -s builddir/libfprint/libfprint-2.so.2.0.0 | grep -i "a5050000 7a1c0000" \
  && echo "OK: 05a5 present"
```

### 3. Install over the system library (ABI-compatible)

The fork's `.so` exports all symbols `fprintd` needs and uses SONAME
`libfprint-2.so.2`, so it's a drop-in replacement. Use the provided script
(it verifies the `05a5` marker, backs up the original **outside** the library
dir, and sets the symlinks explicitly):

```bash
sudo ./scripts/install-sdcp.sh
```

> **Why the backup goes outside `/usr/lib/.../`:** if a `*.bak` file sits in the
> library dir, `ldconfig` may repoint the `.so.2` symlink to the backup instead
> of your build. (This bit us during development — the script avoids it.)

<details><summary>Manual equivalent (if you prefer not to use the script)</summary>

```bash
sudo install -d /root/libfprint-backups
sudo cp -av /usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0 \
            /root/libfprint-backups/libfprint-2.so.2.0.0.orig
sudo install -m0644 libfprint-egismoc-sdcp/builddir/libfprint/libfprint-2.so.2.0.0 \
            /usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0
sudo ln -sf libfprint-2.so.2.0.0 /usr/lib/x86_64-linux-gnu/libfprint-2.so.2
sudo ln -sf libfprint-2.so.2     /usr/lib/x86_64-linux-gnu/libfprint-2.so
sudo ldconfig
sudo systemctl restart fprintd
```
</details>

### 4. Enroll

```bash
fprintd-list "$USER"          # -> "found 1 devices ... Egis ... Match-on-Chip"
# If the chip has a leftover print (e.g. from Windows), wipe it first:
sudo systemctl stop fprintd
sudo ./libfprint-egismoc-sdcp/builddir/examples/clear-storage
sudo systemctl start fprintd

fprintd-enroll                # touch the sensor through all 15 stages -> enroll-completed
fprintd-verify               # touch once -> verify-match
```

### 5. Enable PAM (login / sudo / unlock)

```bash
sudo pam-auth-update          # enable "Fingerprint authentication"
```

This edits `/etc/pam.d/common-auth`, which is `@include`d by **SDDM**
(graphical login) and **sudo**. Test:

```bash
sudo -k && sudo -v            # prompts "Place your finger on the fingerprint reader"
```

**Graphical login (SDDM):** works automatically via `common-auth`. At the login
screen, start typing nothing and touch the sensor — or it prompts after a moment.

**KDE Plasma lock screen:** Plasma's locker uses the `kde` PAM service, which may
not exist by default. If fingerprint doesn't work on the lock screen, create
`/etc/pam.d/kde`:

```
auth     include        common-auth
account  include        common-account
password include        common-password
session  include        common-session
```

then log out/in. (Login via SDDM and `sudo` already work without this.)

## Persistence: surviving apt upgrades

The custom library is **overwritten** whenever `libfprint-2-2` is updated by apt.
This repo includes an **APT hook** that auto-restores it — no pinning, no manual
reruns, and you keep getting distro security updates.

### Recommended: automatic self-heal (APT hook)

```bash
sudo ./scripts/setup-persistence.sh
```

This:
1. caches your built SDCP `.so` in `/opt/libfprint-sdcp/` (with the upstream
   version it shadows),
2. installs `/usr/local/sbin/libfprint-sdcp-reinstall` (restores the lib only if
   the active one lost `05a5` support — otherwise a no-op),
3. installs an APT `Post-Invoke` hook (`apt/99-libfprint-sdcp`).

After this, `apt upgrade` works normally. If an update replaces libfprint, the
hook restores the SDCP build and restarts `fprintd` automatically. If a **newer**
upstream libfprint ships, it still restores your sensor and prints a one-time
hint to rebuild the fork.

Verify it works:
```bash
sudo apt-get install --reinstall -y libfprint-2-2   # clobbers the lib
fprintd-list "$USER"                                 # hook restored it; device still listed
```

### Alternatives

- **Pin** (blocks libfprint security updates): `sudo apt-mark hold libfprint-2-2 libfprint-2-tod1`
- **Manual rebuild** after each update: re-run `scripts/install-sdcp.sh`.

To remove the persistence hook:
```bash
sudo rm -f /etc/apt/apt.conf.d/99-libfprint-sdcp /usr/local/sbin/libfprint-sdcp-reinstall
sudo rm -rf /opt/libfprint-sdcp
```

To restore the distro library at any time:

```bash
sudo cp /root/libfprint-backups/libfprint-2.so.2.0.0.orig \
        /usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0
sudo ln -sf libfprint-2.so.2.0.0 /usr/lib/x86_64-linux-gnu/libfprint-2.so.2
sudo ldconfig && sudo systemctl restart fprintd
```

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `No devices available` | `.so.2` symlink points at the wrong file. `readlink -f /usr/lib/x86_64-linux-gnu/libfprint-2.so.2` — it must resolve to the fork `.so.2.0.0` containing `05a5`. Re-run `ln -sf` + `ldconfig`. |
| `Access denied (insufficient permissions)` running `examples/enroll` | You ran it non-root; libusb needs write access to the USB node. Use `fprintd-*` (daemon is root) or `sudo`. |
| `enroll-duplicate` | A print is already stored on-chip. Run `examples/clear-storage` (stop `fprintd` first). |
| `enroll-disconnected` / `Unrecognized response` | You're still on the stock (non-SDCP) driver. Confirm the active lib is the fork build. |
| Driver debug | `sudo systemctl stop fprintd; sudo G_MESSAGES_DEBUG=all /usr/libexec/fprintd` (driver logs live in the daemon, not the `fprintd-*` clients). |

## Credits

- `egismoc` driver: Joshua Grisham (upstream libfprint).
- SDCP fork with `05a5`/ETU906 support: **TenSeventy7/libfprint-egismoc-sdcp**.

## License

Licensed under **LGPL-2.1-or-later**, matching upstream `libfprint`.

- `patches/0001-egismoc-add-ETU906-1c7a-05a5-Galaxy-Book5.patch` derives from
  libfprint's `egismoc.c` (LGPL-2.1-or-later) and is therefore LGPL-2.1-or-later.
- The scripts and APT hook in this repo are original work, also released under
  LGPL-2.1-or-later for consistency.

See [`LICENSE`](LICENSE) for the full text. This repository does **not** vendor
libfprint or the SDCP fork; those are cloned from upstream at build time and
remain under their own (LGPL-2.1-or-later) license.

## Disclaimer

This replaces a system library with a locally built one. It worked on the exact
configuration above; your mileage may vary. Back up your data and understand the
restore procedure before running. Provided as-is, without warranty.
