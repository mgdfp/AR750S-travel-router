# GL-AR750S Travel Router

Rebuild tooling for a GL.iNet GL-AR750S (Slate, `glinet,gl-ar750s-nor-nand`)
running plain OpenWrt 25.12.6, set up as a single-mode travel router.

---

## What you get

- **LAN:** `10.90.91.1/24`, DHCP for connected devices, NAT and firewall
- **Wi-Fi access points** that pass for an HP printer's Wi-Fi Direct networks:
  - 2.4 GHz: `DIRECT-24-HP OfficeJet Pro 9015`
  - 5 GHz: `DIRECT-5E-HP OfficeJet Pro 9015`
  - WPA2/WPA3 mixed (`sae-mixed`), password from `.env`
- **Hostname** `HP24A5E3`, which is what upstream hotel/cafe DHCP servers see
- **Travelmate:** the router joins hotel/cafe Wi-Fi itself and handles captive
  portal detection, so all devices share one authenticated session. A wired WAN
  connection, when plugged in, takes priority over the Wi-Fi uplink.
- **SSH:** key auth with `~/.ssh/id_ed25519.pub` (or `id_rsa.pub`), password
  login kept as a fallback. LuCI uses the same root password.

The physical slide switch is not used.

---

## Project structure

```
AR750S-travel-router/
├── .env           Credentials, IP, SSIDs, Wi-Fi password (gitignored)
├── provision.sh   Laptop-side tool: backup, flash, configure
├── setup.sh       Router-side configuration, piped over SSH by provision.sh
└── .cache/        Downloaded firmware images (gitignored)
```

---

## Rebuilding the router

The laptop must be on a **LAN port** (a fresh OpenWrt has Wi-Fi off), and the
**WAN port** must be plugged into a network with internet so `travelmate` can be
installed.

```bash
./provision.sh backup            # optional: save the current config first
./provision.sh flash 10.90.91.1  # wipes everything; asks you to type 'flash'
# wait ~3 minutes; the router comes back at 192.168.1.1
./provision.sh configure         # installs travelmate, applies setup.sh, reboots
```

`flash` downloads the sysupgrade image into `.cache/`, checks it against the
official `sha256sums`, uploads it, checks it again on the router and runs
`sysupgrade -n` (no settings kept). The host argument defaults to `router-ip`
from `.env`; pass the router's current IP if it is somewhere else.

`configure` waits for the router at `192.168.1.1`, pipes `setup.sh` (with the
`.env` values prepended) to it over SSH, and reboots it to `10.90.91.1`. Renew
DHCP on the laptop afterwards.

`setup.sh` can be reviewed or changed freely. It is plain `uci` and runs once on
a fresh router.

---

## Using it while travelling

1. Connect to one of the `DIRECT-…` networks.
2. Open LuCI at <http://10.90.91.1> → **Services → Travelmate** → scan and add
   the hotel/cafe network. Saved uplinks are tried automatically from then on.
3. If the network has a captive portal, open any http page from a device and log
   in. Travelmate detects when the portal has been passed.

---

## `.env` format

```
username: root
password: your-root-password
router-ip: 10.90.91.1
router-hostname: HP24A5E3
wifi-ssid-2g: DIRECT-24-HP OfficeJet Pro 9015
wifi-ssid-5g: DIRECT-5E-HP OfficeJet Pro 9015
wifi-password: at-least-8-chars
```

Other keys are ignored.

---

## Prerequisites

- **Laptop:** `bash`, `ssh` (OpenSSH 8.4+ for `SSH_ASKPASS_REQUIRE`), `curl`,
  `sha256sum`. Nothing else to install.
- **Router:** any firmware that accepts `sysupgrade` over SSH. For the very
  first install from GL.iNet stock firmware, use its web UI or U-Boot recovery
  to flash the OpenWrt image instead of `./provision.sh flash`.
