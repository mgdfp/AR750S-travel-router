#!/bin/sh
# Activate travel-router mode on GL-AR750S
#
# Result: {{ROUTER_IP}}/24, WAN port as DHCP uplink, NAT + firewall active,
# DHCP serving on LAN, visible SSIDs on both radios.
#
# Run via SSH. The script returns immediately; services restart in background.
# Router will be unreachable for ~15 seconds during the restart.

echo "[travel] Staging UCI changes..."

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
# trm_wwan is a station-mode interface on radio1 (2.4GHz — most hotel WiFi).
# travelmate populates ssid/key/encryption at connect time via LuCI.
# The ethernet WAN above remains and is used when a cable is plugged in.
uci set network.trm_wwan=interface
uci set network.trm_wwan.proto='dhcp'

uci set wireless.trm_wwan=wifi-iface
uci set wireless.trm_wwan.device='radio1'
uci set wireless.trm_wwan.mode='sta'
uci set wireless.trm_wwan.network='trm_wwan'
uci set wireless.trm_wwan.ssid=''
uci set wireless.trm_wwan.disabled='1'

# Add trm_wwan to the WAN firewall zone so it gets NATted like ethernet WAN
for i in $(seq 0 10); do
    _name=$(uci -q get "firewall.@zone[$i].name") || break
    [ "$_name" = "wan" ] && { uci add_list "firewall.@zone[$i].network"='trm_wwan'; break; }
done

uci set travelmate.global=travelmate
uci set travelmate.global.trm_enabled='1'
uci set travelmate.global.trm_captive='1'
uci set travelmate.global.trm_iface='trm_wwan'

# ── Commit to disk ─────────────────────────────────────────────────────
echo "[travel] Committing..."
uci commit network
uci commit dhcp
uci commit wireless
uci commit firewall
uci commit travelmate

# ── Restart services in background ─────────────────────────────────────
# SSH session will stay alive; network moves to {{ROUTER_IP}} in ~15 seconds.
echo "[travel] Restarting services in background..."
(
    /etc/init.d/network restart
    sleep 5
    /sbin/wifi
    /etc/init.d/dnsmasq restart
    /etc/init.d/odhcpd restart
    /etc/init.d/firewall restart
    /etc/init.d/travelmate enable
    /etc/init.d/travelmate restart
    logger -t mode-switch "Travel router mode active ({{ROUTER_IP}})"
) > /tmp/mode-switch.log 2>&1 &

echo "[travel] Done. Router will be at {{ROUTER_IP}} in ~15 seconds."
