#!/usr/bin/env bash
# Rebuild the GL-AR750S travel router from a clean OpenWrt image.
#
#   ./provision.sh backup    [host]  Download a config backup (sysupgrade -b)
#   ./provision.sh flash     [host]  Reflash a clean image, wiping all settings
#   ./provision.sh configure         Apply setup.sh to the freshly flashed router
#
# [host] defaults to router-ip from .env. Reads credentials from .env.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=25.12.6
IMAGE=openwrt-$VERSION-ath79-nand-glinet_gl-ar750s-nor-nand-squashfs-sysupgrade.bin
IMAGE_URL=https://downloads.openwrt.org/releases/$VERSION/targets/ath79/nand

env_get() { sed -n "s/^$1: *//p" "$HERE/.env" | head -1; }

# Single-quote a value for the router's ash shell.
shq() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }

# ssh to root@host, answering the password prompt (if any) with $2.
router_ssh() {
	local host=$1 pw=$2; shift 2
	local askpass
	askpass=$(mktemp)
	printf '#!/bin/sh\nprintf "%%s\\n" "$ROUTER_PW"\n' > "$askpass"
	chmod 700 "$askpass"
	local rc=0
	ROUTER_PW=$pw SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
		ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$host" "$@" || rc=$?
	rm -f "$askpass"
	return $rc
}

cmd_backup() {
	local host=${1:-$(env_get router-ip)}
	local out=$HOME/ar750s-backup-$(date +%F-%H%M).tar.gz
	router_ssh "$host" "$(env_get password)" 'sysupgrade -b - 2>/dev/null' > "$out"
	echo "Backup saved to $out (contains secrets, keep it out of git)"
}

cmd_flash() {
	local host=${1:-$(env_get router-ip)}
	local pw
	pw=$(env_get password)

	mkdir -p "$HERE/.cache"
	cd "$HERE/.cache"
	[ -f "$IMAGE" ] || curl -fLO "$IMAGE_URL/$IMAGE"
	curl -fsS "$IMAGE_URL/sha256sums" | grep " \*$IMAGE\$" | sha256sum -c -
	local sum
	sum=$(sha256sum "$IMAGE" | cut -d' ' -f1)

	echo
	echo "About to flash OpenWrt $VERSION to $host and WIPE ALL SETTINGS."
	read -rp "Type 'flash' to continue: " answer
	[ "$answer" = flash ] || { echo "Aborted."; exit 1; }

	# The only setting carried over: a first-boot script moving the LAN off
	# OpenWrt's default 192.168.1.1, which often clashes with the WAN network.
	local lan_ip cfg
	lan_ip=$(env_get router-ip)
	cfg=$(mktemp -d)
	mkdir -p "$cfg/etc/uci-defaults"
	printf "uci set network.lan.ipaddr='%s/24'\nuci -q delete network.lan.netmask\nuci commit network\n" \
		"$lan_ip" > "$cfg/etc/uci-defaults/90-lan-ip"
	tar czf "$cfg/cfg.tar.gz" -C "$cfg" etc

	router_ssh "$host" "$pw" 'cat > /tmp/fw.bin' < "$IMAGE"
	router_ssh "$host" "$pw" 'cat > /tmp/cfg.tar.gz' < "$cfg/cfg.tar.gz"
	rm -rf "$cfg"
	router_ssh "$host" "$pw" "echo '$sum  /tmp/fw.bin' | sha256sum -c - && sysupgrade -T /tmp/fw.bin"
	router_ssh "$host" "$pw" 'sysupgrade -f /tmp/cfg.tar.gz /tmp/fw.bin' || true	# connection drops mid-flash

	cat <<-EOF

	Flashing. Do not unplug the router. It takes about 3 minutes.
	When it is back it will be at $lan_ip with no root password and Wi-Fi off.
	Keep the laptop on a LAN port, plug the WAN port into internet, then run:

	    ./provision.sh configure
	EOF
}

cmd_configure() {
	local lan_ip
	lan_ip=$(env_get router-ip)
	ssh-keygen -R "$lan_ip" >/dev/null 2>&1 || true	# fresh install, new host key

	echo "Waiting for $lan_ip..."
	until router_ssh "$lan_ip" "" true 2>/dev/null; do sleep 5; done

	# Extra files (e.g. the LuCI "Uplink" card), laid out as on the router.
	tar cf - --owner=0 --group=0 -C "$HERE/files" . | router_ssh "$lan_ip" "" 'tar xf - -C /'

	local pubkey
	pubkey=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub)

	{
		echo "ROUTER_PW=$(shq "$(env_get password)")"
		echo "ROUTER_HOSTNAME=$(shq "$(env_get router-hostname)")"
		echo "LAN_IP=$(shq "$lan_ip")"
		echo "SSH_PUBKEY=$(shq "$pubkey")"
		echo "WIFI_SSID_2G=$(shq "$(env_get wifi-ssid-2g)")"
		echo "WIFI_SSID_5G=$(shq "$(env_get wifi-ssid-5g)")"
		echo "WIFI_PASSWORD=$(shq "$(env_get wifi-password)")"
		cat "$HERE/setup.sh"
	} | router_ssh "$lan_ip" "" 'sh -s'

	cat <<-EOF

	The router is rebooting. Reconnect (or renew DHCP) and log in:
	    ssh root@$lan_ip        LuCI: http://$lan_ip
	Add uplink Wi-Fi networks in LuCI under Services → Travelmate.
	EOF
}

case "${1:-}" in
	backup | flash | configure) cmd="cmd_$1"; shift; "$cmd" "$@" ;;
	*) sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac
