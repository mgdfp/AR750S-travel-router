# GL-AR750S Travel Router — Dual-Mode Configuration

Configuration and deployment tooling for a GL.iNet GL-AR750S (Slate) running
OpenWrt 25.12.4, set up to switch between two operating modes via the physical
slide switch on the side of the device.

---

## How it works

The router has a physical slide switch with two positions: **dot** and **clear**.
The `slide-switch` OpenWrt package (installed on the router) monitors this switch
and fires a hotplug event whenever it moves. A hotplug script on the router
(`/etc/hotplug.d/button/10-mode-switch`) responds by executing whichever
configuration script is currently assigned to that position.

```
You flip the switch
      │
      ▼
slide-switch (OpenWrt package) detects position change
      │
      ▼
/etc/hotplug.d/button/10-mode-switch fires
      │
      ├─ dot   position → runs /usr/sbin/dot-active/*.sh
      └─ clear position → runs /usr/sbin/clear-active/*.sh
```

Each active script applies its configuration using `uci` commands and restarts
the relevant services in the background. The router is unreachable for roughly
15 seconds during the transition.

---

## Modes

### Normal router (`normal-router.sh`)
- IP: `192.168.8.1/24`
- WAN port: DHCP uplink to internet (ethernet cable)
- DHCP, NAT, and firewall active
- Both Wi-Fi radios broadcasting visible SSIDs
- **Travelmate** installed: connects the router itself to a hotel/cafe WiFi network
  and handles captive portal login, so all your devices share one authenticated session.
  Add uplink networks via LuCI → Services → Travelmate. Saved networks survive mode switches.

### Mullvad router (`mullvad-router.sh`)
- IP: `192.168.8.1/24`
- Same as normal router mode, but all LAN traffic is tunnelled through Mullvad
  WireGuard (`wg0`) instead of the sing-box home VPN.
- `wg0` is held disabled until `30-mullvad-gate` (hotplug) confirms the uplink
  has real, non-captive-portal internet — and drops it again if that
  connectivity is later lost — so devices can always reach a captive portal
  to log in, even on networks that force repeated re-logins. See
  [Mullvad WireGuard VPN](#mullvad-wireguard-vpn) below.

### Simple switch (`simple-switch.sh`)
- IP: `192.168.10.89/24`
- All three physical ports and both Wi-Fi radios on one flat L2 bridge
- No DHCP, no routing, no firewall
- Both Wi-Fi radios broadcasting a hidden SSID (`drillingcontrolnetwork`)

---

## Project structure

```
AR750S-travel-router/
├── .env                    SSH credentials, IPs, and Wi-Fi secrets
├── configs/                All mode configuration scripts
│   ├── normal-router.sh    Travel/hotel mode with travelmate + sing-box
│   ├── mullvad-router.sh   Travel/hotel mode with travelmate + Mullvad WireGuard
│   └── simple-switch.sh    Industrial flat-bridge mode
├── sing-box/               Sing-box config + its hotplug gate script (30-sing-box-nat)
├── 10-mode-switch          Source copy of the mode-switch hotplug script on the router
├── 30-mullvad-gate         Source copy of the Mullvad wg0 hotplug gate on the router
└── deploy.py               Deployment tool (see below)
```

---

## Deploying a configuration

Run the deploy tool and follow the prompts:

```bash
uv run deploy.py
# or: ./deploy.py
```

It will:
1. Auto-detect the router on the network by trying all IPs found in the config scripts
2. List the available scripts from `configs/`
3. Ask which script to assign to the **dot** position
4. Ask which script to assign to the **clear** position
5. Deploy both to the router

You can also override connection details:

```bash
uv run deploy.py --host 192.168.8.1 --user root --password yourpassword
```

### Manually activating a mode over SSH

Without touching the physical switch, you can apply a mode directly:

```bash
# From normal-router mode (192.168.8.1):
ssh root@192.168.8.1 < configs/simple-switch.sh

# From simple-switch mode (192.168.10.89):
ssh root@192.168.10.89 < configs/normal-router.sh
```

---

## Adding a new configuration

1. Create a new script in `configs/`, e.g. `activate-work-network.sh`
2. Follow the same structure as the existing scripts (UCI commands + background restart)
3. Optionally add metadata comments so the deploy tool can find the router automatically:

```sh
# router-password: yourpassword       ← SSH password for this router
uci set network.lan.ipaddr='192.168.32.89/24'
...
```

The deploy tool scans all scripts in `configs/` for `network.lan.ipaddr` lines
(to find IPs) and `# router-password:` comments (to find passwords). No manual
configuration required.

4. Run `./deploy.py` and assign the new script to a switch position.

---

## Prerequisites

**On your laptop:**
- [`uv`](https://docs.astral.sh/uv/) — used to run `deploy.py` and manage the `paramiko` dependency automatically

**On the router:**
- OpenWrt 25.12.4 (ath79/nand, mips_24kc)
- `slide-switch` package installed (`apk add slide-switch`)
- `/etc/hotplug.d/button/10-mode-switch` deployed (source: `10-mode-switch` in this repo)
- `/usr/sbin/dot-active/` and `/usr/sbin/clear-active/` folders created
- For `normal-router.sh`: `travelmate`, `luci-app-travelmate`, `curl`, `libcurl4`,
  `libnghttp2-14`, and `iwinfo` installed (sideload from OpenWrt feeds if no internet —
  see commit history for the procedure)

---

## `.env` format

```
username: root
current-password: yourpassword
new-password: yourpassword
router-static-ip-1: 192.168.8.1
router-static-ip-2: 192.168.10.89
wifi-ssid: yourssid
wifi-password: yourwifipassword
vpn-uuid: your-vless-uuid-here
mullvad-private-key: your-wireguard-private-key
mullvad-server-pubkey: server-public-key
mullvad-endpoint-host: 1.2.3.4
mullvad-address: 10.x.x.x/32
```

The four `mullvad-*` keys are only needed if you use `mullvad-router.sh`. Generate
them from the [Mullvad account portal](https://mullvad.net/en/account/wireguard-config)
— pick a server, download the WireGuard config, and copy the values across.

`current-password` is what the router has now. Set `new-password` to something
different to rotate the password on next deploy — `deploy.py` will change it on
the router and update `current-password` in this file automatically.

---

## Sing-box VPN

All LAN TCP traffic is transparently tunnelled through a VLESS+WS+TLS proxy on port 8443.
Devices need no configuration — they just get internet that bypasses DPI.

### How it works

An nft PREROUTING rule redirects all TCP from `br-lan` (except traffic to the router itself)
to port 7895. Sing-box listens there with a `redirect` inbound, reads the original destination
via `SO_ORIGINAL_DST`, and forwards through VLESS. UDP and private-IP traffic go direct.

A hotplug script (`30-sing-box-nat`) manages the nft rule dynamically, and runs a
continuous background monitor (checking every 15 seconds) rather than a one-shot
check: whenever the VPN server becomes unreachable — at boot behind a captive
portal, or later if a network re-locks and forces a re-login — it flushes the
redirect so devices can reach the portal, then re-adds it automatically as soon
as the VPN is reachable again.

The reachability check mirrors sing-box's real outbound as closely as possible:
it spoofs TLS SNI to `www.microsoft.com` (some networks reset the TLS handshake
outright when they see the real VPN hostname as SNI — this is the same spoof
the outbound itself uses to get through) and accepts the server's self-signed
cert, but requires the exact `404` the VLESS+WS server returns for a bare GET —
so a captive portal's own content, or a TLS-bumping proxy, can't produce a false
positive. A single failed check doesn't flip the state; it takes 2 consecutive
failures (~30 seconds) before the redirect is flushed, since one-off timeouts
are expected under normal background load from other connected devices sharing
the tunnel and shouldn't be treated as a captive portal.

### Fresh install (requires internet on router)

```sh
apk add sing-box
```

Then copy the files from `sing-box/` in this repo. `config.json` contains
a `{{VPN_UUID}}` placeholder — substitute your VLESS UUID (from `.env`) before copying:

```sh
UUID=$(grep "^vpn-uuid:" .env | cut -d: -f2 | tr -d ' ')
sed "s/{{VPN_UUID}}/$UUID/" sing-box/config.json \
    | ssh root@192.168.8.1 'tee /etc/sing-box/config.json > /dev/null'
```

The other files copy as-is:

| Repo file | Router destination | Notes |
|---|---|---|
| `sing-box.uci` | `/etc/config/sing-box` | |
| `30-sing-box.nft` | `/etc/nftables.d/30-sing-box.nft` | |
| `30-sing-box-nat` | `/etc/hotplug.d/iface/30-sing-box-nat` | `chmod +x` |

Then enable and start the service:

```sh
/etc/init.d/sing-box enable
/etc/init.d/sing-box start
fw4 reload
```

The hotplug script fires automatically on next interface up/down. To trigger it immediately
without rebooting, bounce the LAN interface or just add the nft rule by hand:

```sh
nft add table ip nat
nft add chain ip nat PREROUTING '{ type nat hook prerouting priority -100; }'
nft add rule ip nat PREROUTING iif br-lan ip protocol tcp ip daddr != 192.168.8.1 redirect to :7895
```

### Recovery (if VPN breaks routing)

```sh
# From laptop — flushes the redirect rule so plain internet works again
sshpass -p 'YOUR_PASSWORD' ssh root@192.168.8.1 "nft flush chain ip nat PREROUTING"

# To disable sing-box entirely until next reboot:
sshpass -p 'YOUR_PASSWORD' ssh root@192.168.8.1 "killall sing-box; nft flush chain ip nat PREROUTING"
```

---

## Mullvad WireGuard VPN

All LAN traffic is tunnelled through Mullvad WireGuard (`wg0`) instead of the
sing-box home VPN when `mullvad-router.sh` is active.

### How it works

`wg0` is configured with `disabled='1'` and stays that way until a hotplug script,
`30-mullvad-gate`, confirms the uplink (`trm_wwan` or `wan`) has real internet —
checked via a certificate-validated HTTPS request to a `generate_204` endpoint
expecting an exact `204` response, so a captive portal can't fake it. Once
confirmed, the script enables and brings up `wg0`.

`trm_wwan` and `wan` carry an explicit metric of `10`, while `wg0` uses the
default metric `0`. Whenever both are up, `wg0` wins the default route
automatically — no manual route juggling needed. When `30-mullvad-gate` disables
`wg0` again, the plain uplink's own (never-touched) default route is simply what's
left, so devices behind the router can immediately reach a captive portal.

Like `30-sing-box-nat`, this runs a continuous background monitor (every 15
seconds), not a one-shot check — so on networks that force repeated re-logins
throughout the day, the tunnel drops automatically as soon as connectivity is
lost and re-establishes itself once you're back online, with no manual steps.

### Deploying `30-mullvad-gate`

```sh
ssh root@192.168.8.1 'tee /etc/hotplug.d/iface/30-mullvad-gate > /dev/null' < 30-mullvad-gate
ssh root@192.168.8.1 'chmod 755 /etc/hotplug.d/iface/30-mullvad-gate'
```

### Recovery (if the portal still isn't reachable)

```sh
# From laptop — force wg0 off and fall back to the plain uplink immediately
ssh root@192.168.8.1 "uci set network.wg0.disabled=1; uci commit network; ifdown wg0"
```

---

## Physical hardware notes

- **Switch GPIO:** The slide switch is wired to GPIO 8 (`gpio-520` in sysfs),
  labelled `mode` in the kernel device tree. The standard `gpio-keys` input
  subsystem does not create input events on this firmware — `slide-switch`
  reads the switch state directly from `/sys/kernel/debug/gpio` instead.
- **Switch positions:** `dot` (one side) and `clear` (other side). Run
  `slide-switch position mode` on the router to check the current position.
