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
rm -f "$tmp"
chown abc:abc "$CONF" 2>/dev/null || true
