#!/bin/sh
# Activate industrial dumb-switch mode on GL-AR750S
#
# Result: {{ROUTER_IP}}/24, all 3 physical ports + both radios on one flat
# L2 bridge, hidden SSID '{{WIFI_SSID}}', no DHCP/RA serving.
#
# Run via SSH. The script returns immediately; services restart in background.
# Router will be unreachable for ~15 seconds during the restart.

echo "[industrial] Staging UCI changes..."

# ── LAN interface ──────────────────────────────────────────────────────
uci set network.lan.ipaddr='{{ROUTER_IP}}/24'
uci delete network.lan.ip6assign  2>/dev/null; true
uci set network.lan.delegate='0'

# ── Switch: merge WAN port (port 1) into the LAN VLAN ─────────────────
uci set network.@switch_vlan[0].ports='1 2 3 0t'
uci delete network.@switch_vlan[1]            2>/dev/null; true

# ── Remove WAN logical interfaces ─────────────────────────────────────
uci delete network.wan                        2>/dev/null; true
uci delete network.wan6                       2>/dev/null; true

# ── DHCP: suppress everything on LAN ──────────────────────────────────
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.start='0'
uci set dhcp.lan.limit='0'
uci set dhcp.lan.dhcpv4='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci delete dhcp.lan.ra_slaac                  2>/dev/null; true
uci delete dhcp.lan.ra_flags                  2>/dev/null; true

# ── Wireless: hidden SSID on both radios ──────────────────────────────
uci set wireless.default_radio0.ssid='{{WIFI_SSID}}'
uci set wireless.default_radio0.key='{{WIFI_PASSWORD}}'
uci set wireless.default_radio0.hidden='1'
uci set wireless.default_radio0.disabled='0'

uci set wireless.default_radio1.ssid='{{WIFI_SSID}}'
uci set wireless.default_radio1.key='{{WIFI_PASSWORD}}'
uci set wireless.default_radio1.hidden='1'
uci set wireless.default_radio1.disabled='0'

# ── Commit to disk ─────────────────────────────────────────────────────
echo "[industrial] Committing..."
uci commit network
uci commit dhcp
uci commit wireless

# ── Restart services in background ─────────────────────────────────────
# SSH session will stay alive; network moves to {{ROUTER_IP}} in ~15 seconds.
echo "[industrial] Restarting services in background..."
(
    /etc/init.d/network restart
    sleep 5
    /sbin/wifi
    /etc/init.d/dnsmasq restart
    /etc/init.d/odhcpd restart
    /etc/init.d/firewall restart
    logger -t mode-switch "Industrial mode active ({{ROUTER_IP}})"
) > /tmp/mode-switch.log 2>&1 &

echo "[industrial] Done. Router will be at {{ROUTER_IP}} in ~15 seconds."
