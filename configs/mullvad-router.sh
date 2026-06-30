#!/bin/sh
# Activate Mullvad VPN router mode on GL-AR750S
#
# Result: {{ROUTER_IP}}/24, WAN port as DHCP uplink, NAT + firewall active,
# DHCP serving on LAN, visible SSIDs on both radios, all LAN TCP+UDP
# tunnelled through Mullvad WireGuard. Travelmate handles captive portals.
#
# Run via SSH. The script returns immediately; services restart in background.
# Router will be unreachable for ~15 seconds during the restart.

echo "[mullvad] Staging UCI changes..."

# ── LAN interface ──────────────────────────────────────────────────────
uci set network.lan.ipaddr='{{ROUTER_IP}}/24'
uci set network.lan.ip6assign='60'
uci delete network.lan.delegate               2>/dev/null; true
uci delete network.lan.netmask                2>/dev/null; true

# ── Switch: restore WAN port (port 1) to its own VLAN ─────────────────
uci set network.@switch_vlan[0].ports='2 3 0t'
uci set network.@switch_vlan[0].vlan='1'

# Add switch_vlan[1] (WAN VLAN) back if it was deleted
uci get network.@switch_vlan[1]               2>/dev/null || uci add network switch_vlan
uci set network.@switch_vlan[1].device='switch0'
uci set network.@switch_vlan[1].vlan='2'
uci set network.@switch_vlan[1].ports='1 0t'

# ── Restore WAN logical interfaces ────────────────────────────────────
uci set network.wan=interface
uci set network.wan.device='eth0.2'
uci set network.wan.proto='dhcp'

uci set network.wan6=interface
uci set network.wan6.device='eth0.2'
uci set network.wan6.proto='dhcpv6'

# ── WireGuard tunnel (Mullvad) ─────────────────────────────────────────
uci -q delete network.wg0
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key='{{MULLVAD_PRIVATE_KEY}}'
uci add_list network.wg0.addresses='{{MULLVAD_ADDRESS_IPV4}}'
[ -n '{{MULLVAD_ADDRESS_IPV6}}' ] && uci add_list network.wg0.addresses='{{MULLVAD_ADDRESS_IPV6}}'
uci set network.wg0.dns='{{MULLVAD_DNS}}'

# Peer — section type wireguard_wg0 associates it with the wg0 interface
uci -q delete network.mlvd
uci set network.mlvd=wireguard_wg0
uci set network.mlvd.description='Mullvad'
uci set network.mlvd.public_key='{{MULLVAD_SERVER_PUBKEY}}'
uci set network.mlvd.endpoint_host='{{MULLVAD_ENDPOINT_HOST}}'
uci set network.mlvd.endpoint_port='51820'
uci add_list network.mlvd.allowed_ips='0.0.0.0/0'
uci set network.mlvd.route_allowed_ips='1'
uci set network.mlvd.persistent_keepalive='25'

# ── DHCP: restore full serving on LAN ─────────────────────────────────
uci set dhcp.lan.ignore='0'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'
uci set dhcp.lan.dhcpv4='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_slaac='1'
uci delete dhcp.lan.ra_flags                  2>/dev/null; true
uci add_list dhcp.lan.ra_flags='managed-config'
uci add_list dhcp.lan.ra_flags='other-config'

# ── Wireless: restore visible SSIDs on both radios ────────────────────
uci set wireless.default_radio0.ssid='AR750S-Travel-5G'
uci set wireless.default_radio0.key='{{WIFI_PASSWORD}}'
uci set wireless.default_radio0.hidden='0'
uci set wireless.default_radio0.disabled='0'

uci set wireless.default_radio1.ssid='AR750S-Travel-2G'
uci set wireless.default_radio1.key='{{WIFI_PASSWORD}}'
uci set wireless.default_radio1.hidden='0'
uci set wireless.default_radio1.disabled='0'

# ── Travelmate: wireless uplink for hotel/cafe WiFi + captive portals ──
uci set network.trm_wwan=interface
uci set network.trm_wwan.proto='dhcp'

uci -q get wireless.trm_wwan > /dev/null || {
    uci set wireless.trm_wwan=wifi-iface
    uci set wireless.trm_wwan.device='radio1'
    uci set wireless.trm_wwan.mode='sta'
    uci set wireless.trm_wwan.network='trm_wwan'
    uci set wireless.trm_wwan.ssid=''
    uci set wireless.trm_wwan.disabled='1'
}

# Add trm_wwan to the WAN firewall zone (del_list first to keep it unique)
for i in $(seq 0 10); do
    _name=$(uci -q get "firewall.@zone[$i].name") || break
    if [ "$_name" = "wan" ]; then
        uci -q del_list "firewall.@zone[$i].network"='trm_wwan'
        uci add_list "firewall.@zone[$i].network"='trm_wwan'
        break
    fi
done

uci set travelmate.global=travelmate
uci set travelmate.global.trm_enabled='1'
uci set travelmate.global.trm_captive='1'
uci set travelmate.global.trm_iface='trm_wwan'

# ── Firewall: add wg0 to WAN zone ─────────────────────────────────────
for i in $(seq 0 10); do
    _name=$(uci -q get "firewall.@zone[$i].name") || break
    if [ "$_name" = "wan" ]; then
        uci -q del_list "firewall.@zone[$i].network"='wg0'
        uci add_list "firewall.@zone[$i].network"='wg0'
        break
    fi
done

# ── Disable sing-box (its nft PREROUTING redirect conflicts with WireGuard) ──
uci -q set sing-box.main.enabled='0'
uci -q commit sing-box

# ── Commit to disk ─────────────────────────────────────────────────────
echo "[mullvad] Committing..."
uci commit network
uci commit dhcp
uci commit wireless
uci commit firewall
uci commit travelmate

# ── Restart services in background ─────────────────────────────────────
# SSH session will stay alive; network moves to {{ROUTER_IP}} in ~15 seconds.
echo "[mullvad] Restarting services in background..."
(
    /etc/init.d/sing-box stop 2>/dev/null; true
    nft flush chain ip nat PREROUTING 2>/dev/null; true
    /etc/init.d/network restart
    sleep 5
    /sbin/wifi
    /etc/init.d/dnsmasq restart
    /etc/init.d/odhcpd restart
    /etc/init.d/firewall restart
    /etc/init.d/travelmate enable
    /etc/init.d/travelmate restart
    logger -t mode-switch "Mullvad VPN mode active ({{ROUTER_IP}})"
) > /tmp/mode-switch.log 2>&1 &

echo "[mullvad] Done. Router will be at {{ROUTER_IP}} in ~15 seconds."
