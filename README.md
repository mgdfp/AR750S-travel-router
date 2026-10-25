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
  portal detection, so all devices share one authenticated session. Wi-Fi is
  the only uplink: all three ethernet ports, including the blue WAN port, are
  LAN ports. See [Wired internet](#wired-internet) to change that.
- **Uplink card** at the top of LuCI's Status → Overview: online / captive
  portal (with a link to its login page) / no internet, uplink SSID, signal and
  address. The internet check (`/usr/libexec/uplink-check`) runs every 30 s
  while the page is open.
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
├── files/         Extra files copied to the router as-is (same paths), e.g.
│                  the LuCI Uplink card and its rpcd ACL
└── .cache/        Downloaded firmware images (gitignored)
```

---

## Rebuilding the router

The laptop must be on a **LAN port** (a fresh OpenWrt has Wi-Fi off), and the
blue **WAN port** must be plugged into a network with internet so `travelmate`
can be installed. `setup.sh` turns the WAN port into a LAN port at the end.

```bash
./provision.sh backup            # optional: save the current config first
./provision.sh flash             # wipes everything; asks you to type 'flash'
# wait ~3 minutes; the router comes back at 10.90.91.1
./provision.sh configure         # installs travelmate, applies setup.sh, reboots
```

`flash` downloads the sysupgrade image into `.cache/`, checks it against the
official `sha256sums`, uploads it, checks it again on the router and runs
`sysupgrade -f` with a config archive holding a single first-boot script that
sets the LAN IP. Nothing else is kept. The new LAN IP avoids OpenWrt's default
`192.168.1.1/24`, which often clashes with the network on the WAN port. The host
argument defaults to `router-ip` from `.env`; pass the router's current IP if it
is somewhere else.

`configure` waits for the router at `10.90.91.1`, pipes `setup.sh` (with the
`.env` values prepended) to it over SSH, and reboots it. Renew DHCP on the
laptop if needed.

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

## Wired internet

By default there is no WAN. The WAN port sits behind the router's internal
switch chip, so Linux never sees its cable being unplugged. A wired WAN would
keep a stale default route after unplugging and silently blackhole all traffic,
even with a working Wi-Fi uplink.

To use the blue port as a wired uplink, for example a hotel room with an
ethernet socket:

```sh
ssh root@10.90.91.1 '
uci set network.@switch_vlan[0].ports="2 3 0t"
s=$(uci add network switch_vlan)
uci set network.$s.device=switch0; uci set network.$s.vlan=2; uci set network.$s.ports="1 0t"
uci set network.wan=interface; uci set network.wan.device=eth0.2; uci set network.wan.proto=dhcp
uci add_list firewall.@zone[1].network=wan
uci commit; reload_config'
```

To make it a LAN port again (do this before unplugging, or the stale route
problem above applies):

```sh
ssh root@10.90.91.1 '
uci delete network.@switch_vlan[1]
uci set network.@switch_vlan[0].ports="1 2 3 0t"
uci delete network.wan
uci del_list firewall.@zone[1].network=wan
uci commit; reload_config'
```

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
