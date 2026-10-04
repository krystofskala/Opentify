"""Stálý podpisový klíč pro Android: vytvoří keystore (mimo git, .android-signing/),
heslo do .env a obojí nahraje jako GitHub Actions secrets ANDROID_KEYSTORE_*.
Nic tajného nevypisuje. Spustit jednou z kořene repa:

    pip install pynacl && python client/android/tool/setup_signing.py

Keystore si zálohuj -- bez něj by další verze nešla nainstalovat přes starou."""
import base64
import json
import os
import secrets
import subprocess
import urllib.request
from pathlib import Path

from nacl import encoding, public

ROOT = Path(__file__).resolve().parents[3]
KEYDIR = ROOT / ".android-signing"
KS = KEYDIR / "opentify-release.jks"
ENV = ROOT / ".env"
REPO = os.environ.get("GITHUB_REPOSITORY", "krystofskala/Opentify")

gi = (ROOT / ".gitignore").read_text(encoding="utf-8")
if ".android-signing/" not in gi:
    (ROOT / ".gitignore").write_text(gi.rstrip("\n") + "\n# Podpisový klíč Androidu -- NIKDY do gitu\n.android-signing/\n", encoding="utf-8")

env = ENV.read_text(encoding="utf-8")
if "ANDROID_KEYSTORE_PASSWORD=" in env:
    pw = [l.split("=", 1)[1].strip() for l in env.splitlines() if l.startswith("ANDROID_KEYSTORE_PASSWORD=")][0]
else:
    pw = secrets.token_urlsafe(24)
    ENV.write_text(env.rstrip("\n") + f"\n# Android podpis (keystore v .android-signing/)\nANDROID_KEYSTORE_PASSWORD={pw}\n", encoding="utf-8")

if not KS.exists():
    KEYDIR.mkdir(exist_ok=True)
    subprocess.run([
        "keytool", "-genkeypair", "-keystore", str(KS), "-storetype", "PKCS12",
        "-alias", "opentify", "-keyalg", "RSA", "-keysize", "4096", "-validity", "10000",
        "-storepass", pw, "-keypass", pw, "-dname", "CN=Opentify, O=Opentify, C=CZ",
    ], check=True, capture_output=True)
print("keystore:", KS.exists())

cred = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                      capture_output=True, text=True, check=True).stdout
token = [l.split("=", 1)[1] for l in cred.splitlines() if l.startswith("password=")][0]


def api(method, path, body=None):
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}{path}", method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req) as r:
        data = r.read()
        return r.status, (json.loads(data) if data else None)


_, key = api("GET", "/actions/secrets/public-key")
pk = public.PublicKey(key["key"].encode(), encoding.Base64Encoder())
box = public.SealedBox(pk)
for name, value in {
    "ANDROID_KEYSTORE_BASE64": base64.b64encode(KS.read_bytes()).decode(),
    "ANDROID_KEYSTORE_PASSWORD": pw,
}.items():
    enc = base64.b64encode(box.encrypt(value.encode())).decode()
    status, _ = api("PUT", f"/actions/secrets/{name}", {"encrypted_value": enc, "key_id": key["key_id"]})
    print(name, status)
