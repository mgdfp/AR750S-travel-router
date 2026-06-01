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

### Travel router (`activate-travel.sh`)
- IP: `192.168.8.1/24`
- WAN port: DHCP uplink to internet
- DHCP, NAT, and firewall active
- Both Wi-Fi radios broadcasting visible SSIDs

### Industrial dumb switch (`activate-industrial.sh`)
- IP: `192.168.10.89/24`
- All three physical ports and both Wi-Fi radios on one flat L2 bridge
- No DHCP, no routing, no firewall
- Both Wi-Fi radios broadcasting a hidden SSID (`drillingcontrolnetwork`)

---

## Project structure

```
AR750S-travel-router/
├── .env                    SSH credentials (username, password)
├── configs/                All mode configuration scripts
│   ├── activate-travel.sh
│   └── activate-industrial.sh
├── 10-mode-switch          Source copy of the hotplug script on the router
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
# From travel mode (192.168.8.1):
ssh root@192.168.8.1 < configs/activate-industrial.sh

# From industrial mode (192.168.10.89):
ssh root@192.168.10.89 < configs/activate-travel.sh
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

---

## `.env` format

```
username: root
password: yourpassword
```

---

## Physical hardware notes

- **Switch GPIO:** The slide switch is wired to GPIO 8 (`gpio-520` in sysfs),
  labelled `mode` in the kernel device tree. The standard `gpio-keys` input
  subsystem does not create input events on this firmware — `slide-switch`
  reads the switch state directly from `/sys/kernel/debug/gpio` instead.
- **Switch positions:** `dot` (one side) and `clear` (other side). Run
  `slide-switch position mode` on the router to check the current position.
