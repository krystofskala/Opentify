#!/usr/bin/env python3
"""Cizí Docker obrazy (slskd, qBittorrent, gluetun, tailscale, redis, nginx):
připnuté verze, upozornění na nové a aktualizace jedním příkazem.

Připnutí žije v `docker-compose.override.yml` na serveru jako
`image: repo:tag@sha256:...` -- Docker pak pouští přesně tu verzi, i když
se tag mezitím posune. Nic se neaktualizuje samo.

    image_updates.py pin           # připnout, co teď běží (jednou)
    image_updates.py check         # nové verze? -> upozornění do ntfy (časovač 1×/den)
    image_updates.py update NAME…  # stáhnout novou, přepnout, ověřit, jinak vrátit
    image_updates.py update all

Spouští se na hostiteli VM (potřebuje `docker`), standardní knihovna Pythonu.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(os.environ.get("OPENTIFY_DIR", "/opt/opentify"))
OVERRIDE = ROOT / "docker-compose.override.yml"
STATE = Path(os.environ.get("IMAGE_STATE", "/var/lib/opentify-images/notified.json"))
# Služba -> obraz (tag, který se sleduje).
IMAGES = {
    "gluetun": "qmcgaw/gluetun:latest",
    "slskd": "slskd/slskd:latest",
    "qbittorrent": "lscr.io/linuxserver/qbittorrent:latest",
    "redis": "redis:7-alpine",
    "web": "nginx:1.27-alpine",
    "tailscale": "tailscale/tailscale:stable",
}
_ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
])
_PIN = re.compile(r"^(\s*image:\s*)(\S+?)@(sha256:[0-9a-f]{64})\s*$", re.M)


def _split(ref: str) -> tuple[str, str, str]:
    """"redis:7-alpine" -> ("docker.io", "library/redis", "7-alpine")."""
    name, _, tag = ref.rpartition(":") if ":" in ref.split("/")[-1] else (ref, "", "latest")
    parts = name.split("/")
    if "." in parts[0]:
        registry, repo = parts[0], "/".join(parts[1:])
    else:
        registry, repo = "docker.io", name if "/" in name else f"library/{name}"
    return registry, repo, tag or "latest"


def remote_digest(ref: str) -> str:
    registry, repo, tag = _split(ref)
    if registry == "docker.io":
        token_url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
        api = f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}"
    else:  # lscr.io je ghcr.io
        host = "ghcr.io" if registry in ("lscr.io", "ghcr.io") else registry
        token_url = f"https://{host}/token?service={host}&scope=repository:{repo}:pull"
        api = f"https://{host}/v2/{repo}/manifests/{tag}"
    with urllib.request.urlopen(token_url, timeout=20) as r:
        token = json.load(r).get("token")
    req = urllib.request.Request(api, method="HEAD", headers={"Authorization": f"Bearer {token}", "Accept": _ACCEPT})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.headers["Docker-Content-Digest"]


def local_digest(ref: str) -> str | None:
    out = subprocess.run(
        ["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", ref], capture_output=True, text=True
    )
    if out.returncode != 0:
        return None
    digests = json.loads(out.stdout or "[]") or []
    return digests[0].split("@", 1)[1] if digests else None


def pins() -> dict[str, tuple[str, str]]:
    """Služba -> (obraz s tagem, připnutý digest) z override souboru."""
    text = OVERRIDE.read_text(encoding="utf-8")
    found = {ref: digest for _p, ref, digest in _PIN.findall(text)}
    return {svc: (ref, found[ref]) for svc, ref in IMAGES.items() if ref in found}


def _set_pin(svc: str, ref: str, digest: str) -> None:
    text = OVERRIDE.read_text(encoding="utf-8")
    line = f"    image: {ref}@{digest}"
    if re.search(rf"^\s*image:\s*{re.escape(ref)}@sha256:[0-9a-f]+\s*$", text, re.M):
        text = re.sub(rf"^\s*image:\s*{re.escape(ref)}@sha256:[0-9a-f]+\s*$", line, text, flags=re.M)
    elif re.search(rf"^  {svc}:\s*$", text, re.M):
        text = re.sub(rf"^(  {svc}:\s*)$", rf"\1\n{line}", text, count=1, flags=re.M)
    else:
        text = text.rstrip("\n") + f"\n  {svc}:\n{line}\n"
    OVERRIDE.write_text(text, encoding="utf-8")


def _notify(title: str, message: str, priority: int = 3) -> None:
    url = ""
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith("NTFY_URL="):
            url = line.split("=", 1)[1].strip()
    if not url:
        print(f"[bez ntfy] {title}: {message}")
        return
    base, topic = url.rstrip("/").rsplit("/", 1)
    body = json.dumps({"topic": topic, "title": title, "message": message, "priority": priority, "tags": ["package"]})
    req = urllib.request.Request(base + "/", data=body.encode(), headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=20).read()


def _compose(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["docker", "compose", *args], cwd=ROOT, capture_output=True, text=True)


def cmd_pin() -> None:
    for svc, ref in IMAGES.items():
        digest = local_digest(ref)
        if digest:
            _set_pin(svc, ref, digest)
            print(f"{svc}: {ref}@{digest[:19]}…")
    if _compose("config", "-q").returncode != 0:
        sys.exit("docker compose config selhal -- zkontroluj override")


def cmd_check() -> None:
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    new, errors = [], []
    for svc, (ref, pinned) in pins().items():
        try:
            latest = remote_digest(ref)
        except Exception as e:  # noqa: BLE001
            errors.append(f"{svc}: {e}")
            continue
        if latest != pinned:
            print(f"{svc}: nová verze {ref} ({latest[:19]}…)")
            if state.get(svc) != latest:
                new.append(svc)
                state[svc] = latest
        else:
            print(f"{svc}: aktuální")
    if new:
        _notify(
            "📦 Nové verze na serveru",
            f"{', '.join(new)}. Aktualizace: napiš Claudovi „aktualizuj obrazy“, nebo ve VM "
            f"`sudo opentify-update {' '.join(new)}` (při chybě se vrátí zpět samo).",
        )
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state))
    for e in errors:
        print("chyba:", e, file=sys.stderr)


def _ps_rows(svc: str) -> list[dict]:
    """`docker compose ps --format json`: novější Compose dává řádek na
    kontejner (NDJSON), starší jedno pole -- obojí."""
    out = _compose("ps", "--format", "json", svc).stdout.strip()
    rows: list = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        rows += value if isinstance(value, list) else [value]
    return [r for r in rows if isinstance(r, dict)]


def _healthy(svc: str, wait_s: int = 90, stable_s: int = 25) -> bool:
    """Běží (a je zdravý, má-li healthcheck) souvisle `stable_s` sekund --
    kontejner, který spadne po pár sekundách, neprojde."""
    deadline = time.time() + wait_s
    ok_since: float | None = None
    while time.time() < deadline:
        rows = _ps_rows(svc)
        ok = bool(rows) and all(r.get("State") == "running" and r.get("Health") in ("", None, "healthy") for r in rows)
        if not ok:
            ok_since = None
        elif ok_since is None:
            ok_since = time.time()
        elif time.time() - ok_since >= stable_s:
            return True
        time.sleep(5)
    return False


def cmd_update(names: list[str], force: bool) -> None:
    current = pins()
    names = list(current) if names == ["all"] else names
    activity = _compose("exec", "-T", "api", "python", "-m", "app.tools.activity").stdout.strip()
    if activity and activity.splitlines()[-1] != "volno" and not force:
        sys.exit(f"Někdo poslouchá ({activity.splitlines()[-1]}) -- zkus později, nebo --force.")
    for svc in names:
        if svc not in current:
            print(f"{svc}: není připnutý, přeskakuju")
            continue
        ref, old = current[svc]
        if subprocess.run(["docker", "pull", "-q", ref]).returncode != 0:
            print(f"{svc}: stažení selhalo")
            continue
        new = local_digest(ref)
        if not new or new == old:
            print(f"{svc}: už je nejnovější")
            continue
        backup = OVERRIDE.with_suffix(".yml.pred-aktualizaci")
        shutil.copy2(OVERRIDE, backup)
        healthy = False
        try:
            _set_pin(svc, ref, new)
            _compose("up", "-d")
            healthy = _healthy(svc)
        finally:
            # Cokoli selže (i sám skript) -> zpět na předchozí verzi.
            if not healthy:
                shutil.copy2(backup, OVERRIDE)
                _compose("up", "-d")
                print(f"{svc}: nová verze nenaběhla, VRÁCENO zpět")
                _notify("⚠️ Aktualizace vrácena", f"{svc}: nová verze nenaběhla, běží zase ta předchozí.", priority=4)
        if healthy:
            print(f"{svc}: aktualizováno {old[:19]}… -> {new[:19]}…")
            _notify("📦 Aktualizováno", f"{svc} běží v nové verzi.", priority=2)


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["pin"]:
        cmd_pin()
    elif args[:1] == ["check"]:
        cmd_check()
    elif args[:1] == ["update"] and len(args) > 1:
        cmd_update([a for a in args[1:] if a != "--force"], "--force" in args)
    else:
        sys.exit(__doc__)
