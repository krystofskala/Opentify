#!/usr/bin/with-contenv bash
# qBittorrent pro Opentify (app/spoken): API z Docker sítě bez hesla.
# Port 8080 není publikovaný na hostitele a kontejner sdílí síť s gluetun,
# takže na API se dostanou jen služby z docker-compose (172.28.0.0/16).
# Spouští se při každém startu kontejneru (linuxserver custom-cont-init.d).
CONF=/config/qBittorrent/qBittorrent.conf
mkdir -p /config/qBittorrent
touch "$CONF"
tmp=$(mktemp)
grep -v -F -e 'WebUI\AuthSubnetWhitelist' -e 'WebUI\HostHeaderValidation' "$CONF" > "$tmp" || true
if ! grep -q '^\[Preferences\]' "$tmp"; then printf '\n[Preferences]\n' >> "$tmp"; fi
awk '{print} /^\[Preferences\]$/ {
  print "WebUI\\AuthSubnetWhitelistEnabled=true"
  print "WebUI\\AuthSubnetWhitelist=172.28.0.0/16"
  print "WebUI\\HostHeaderValidation=false"
}' "$tmp" > "$CONF"
# Jen přes tunel VPN (tun0): po přepojení gluetun na jiný server se
# qBittorrent sám převáže na novou adresu. Bez toho zůstal viset na starém
# spojení -- trackery "timed out" / "Operation not permitted", 0 uzlů DHT,
# české knihy se nestahovaly (7. 10.).
grep -v -F -e 'Session\Interface=' -e 'Session\InterfaceName=' "$CONF" > "$tmp" || true
if ! grep -q '^\[BitTorrent\]' "$tmp"; then printf '\n[BitTorrent]\n' >> "$tmp"; fi
awk '{print} /^\[BitTorrent\]$/ {
  print "Session\\Interface=tun0"
  print "Session\\InterfaceName=tun0"
}' "$tmp" > "$CONF"
rm -f "$tmp"
chown abc:abc "$CONF" 2>/dev/null || true
