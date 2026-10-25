# Router-side setup for a freshly flashed GL-AR750S (OpenWrt 25.12).
#
# Not run directly: provision.sh prepends the variables below (from .env) and
# pipes the result to `sh -s` on the router. Expects the WAN port to be
# plugged into a network with internet access.
#
#   ROUTER_PW  ROUTER_HOSTNAME  LAN_IP  SSH_PUBKEY
#   WIFI_SSID_2G  WIFI_SSID_5G  WIFI_PASSWORD

set -e

# ── Packages ──────────────────────────────────────────────────────────────────

echo "Waiting for internet on WAN..."
i=0
until ping -c1 -W2 downloads.openwrt.org >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -ge 30 ] && { echo "No internet on WAN after 60s, is the cable plugged in?"; exit 1; }
	sleep 2
done

apk update
apk add travelmate luci-app-travelmate

# ── Access ────────────────────────────────────────────────────────────────────

printf '%s\n%s\n' "$ROUTER_PW" "$ROUTER_PW" | passwd root >/dev/null
printf '%s\n' "$SSH_PUBKEY" > /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
# Dropbear keeps its defaults: key auth preferred, password login as fallback.

# Upstream DHCP servers see this, so make it look like an HP printer too.
uci set system.@system[0].hostname="$ROUTER_HOSTNAME"

# ── LAN ───────────────────────────────────────────────────────────────────────

uci set network.lan.ipaddr="$LAN_IP/24"
uci -q delete network.lan.netmask || true

# ── Wi-Fi uplink interface used by travelmate ─────────────────────────────────

uci set network.trm_wwan=interface
uci set network.trm_wwan.proto='dhcp'
uci set network.trm_wwan.metric='100'	# a wired WAN, when present, wins

wan_zone=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p")
uci -q del_list firewall."$wan_zone".network='trm_wwan' || true
uci add_list firewall."$wan_zone".network='trm_wwan'

# ── Wireless ──────────────────────────────────────────────────────────────────

for r in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p"); do
	case "$(uci -q get wireless."$r".band)" in
		2g) radio_2g=$r ;;
		5g) radio_5g=$r ;;
	esac
done

for s in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
	uci delete wireless."$s"
done

ap() {	# section radio ssid
	uci set wireless."$1"=wifi-iface
	uci set wireless."$1".device="$2"
	uci set wireless."$1".network='lan'
	uci set wireless."$1".mode='ap'
	uci set wireless."$1".ssid="$3"
	uci set wireless."$1".encryption='sae-mixed'
	uci set wireless."$1".key="$WIFI_PASSWORD"
	uci set wireless."$2".disabled='0'
}
ap ap_2g "$radio_2g" "$WIFI_SSID_2G"
ap ap_5g "$radio_5g" "$WIFI_SSID_5G"

# Placeholder station; travelmate swaps in the saved uplink networks.
uci set wireless.trm_wwan=wifi-iface
uci set wireless.trm_wwan.device="$radio_2g"
uci set wireless.trm_wwan.mode='sta'
uci set wireless.trm_wwan.network='trm_wwan'
uci set wireless.trm_wwan.disabled='1'

# ── Travelmate ────────────────────────────────────────────────────────────────

uci set travelmate.global.trm_enabled='1'
uci set travelmate.global.trm_captive='1'
uci set travelmate.global.trm_iface='trm_wwan'
/etc/init.d/travelmate enable

uci commit
echo "Setup done. Rebooting; the router will come back at $LAN_IP."
(sleep 2; reboot) >/dev/null 2>&1 &
