"""Zdroj pro SideStore/AltStore (source.json): appka Opentify s nejnovější
verzí. SideStore ho sleduje a novou verzi nabídne v Updates -- stačí klepnout,
nic se nestahuje ručně. Volá iOS workflow po vydání buildu.

  python altstore_source.py <verze> <url ipa> <velikost> <cesta k source.json>
"""

import datetime
import json
import sys

version, url, size, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
commit = sys.argv[5] if len(sys.argv) > 5 else ""
repo = "krystofskala/Opentify"
raw = f"https://raw.githubusercontent.com/{repo}"

source = {
    "name": "Opentify",
    "identifier": "app.opentify.source",
    "sourceURL": f"{raw}/altstore/source.json",
    "website": f"https://github.com/{repo}",
    "apps": [
        {
            "name": "Opentify",
            "bundleIdentifier": "app.opentify",
            "developerName": "Kryštof",
            "subtitle": "Tvoje hudba z domácího serveru",
            "localizedDescription": "Opentify -- přehrávač pro vlastní hudební server (přes Tailscale).",
            "iconURL": f"{raw}/main/client/ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            "tintColor": "6B3FD6",
            "versions": [
                {
                    "version": version,
                    # CFBundleVersion appky (= číslo běhu CI); SideStore podle
                    # verze + buildu pozná, že je update.
                    "buildVersion": version.rsplit(".", 1)[-1],
                    # Bez toho SideStore pod verzí ukazuje "nil".
                    "localizedDescription": f"Noční build Opentify {version}.",
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "size": size,
                    "downloadURL": url,
                    "minOSVersion": "15.0",
                }
            ],
            "appPermissions": {
                "entitlements": ["com.apple.security.application-groups"],
                "privacy": {
                    "NSMicrophoneUsageDescription": "Mikrofon slouží jen pro Open Shazam a ladičku. Zvuk se nikam neukládá."
                },
            },
        }
    ],
    "news": [],
    # Z čeho je verze postavená -- noční build podle toho pozná, jestli je
    # co vydávat (SideStore cizí klíče ignoruje).
    "opentifyCommit": commit,
}

with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print(f"source.json: {version} -> {url}")
