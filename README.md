# Opentify

A self-hosted personal music server with its own apps (web, iOS, Android, Windows).
It plays **your own music library**, organises it with metadata from MusicBrainz
and Deezer, and gives you a Spotify-like experience on your own hardware.

> Osobní hudební server pro vlastní hardware. Rozhraní appky je česky.

**Status:** a personal hobby project. The app's interface is in Czech, there is no
support, and things change without notice. Use it as a reference or a starting point.

## Important: legal notice

This repository contains **software only** — no music, no accounts, no keys.

Opentify can optionally fetch tracks that are missing from your library through
third-party tools (Soulseek via [slskd](https://github.com/slskd/slskd), and
[yt-dlp](https://github.com/yt-dlp/yt-dlp)). Downloading or sharing copyrighted
music without permission is illegal in many countries.

- These sources are **off by default** in the example configuration
  (`MEDIA_PROVIDER=none` in `.env.example`): only your own library is played.
- If you enable them, **you alone are responsible** for what you download and
  share, and for complying with the law where you live and with the terms of
  the services involved. Only use them for content you have the right to obtain.
- The authors do not endorse copyright infringement and provide no content.

## What it does

- Catalog from MusicBrainz / Deezer: artists, albums, editions, credits (who played what).
- Your library from a folder on disk (`MUSIC_DIR`), scanned and matched to the catalog.
- Home with personal mixes, styles and genres; Wrapped; lyrics; ListenBrainz / Last.fm scrobbling.
- Multiple profiles (family / friends) with per-device login and a one-time device code.
- Apps: web (PWA), iOS (sideloaded, unsigned build), Android (APK), Windows.

## How it fits together

```
 apps (Flutter, client/)  ──HTTPS──▶  Tailscale  ──▶  web (nginx) + API (FastAPI, backend/)
                                                       │
                                     worker(s), Redis, SQLite, optional slskd + VPN (gluetun)
```

- `backend/` — FastAPI API, background workers, catalog, library, recommendations.
- `client/` — Flutter app for all platforms.
- `docker-compose.yml` — the whole server.
- `docs/` — architecture notes and API descriptions.

## Running your own server

Requirements: Docker with Compose, a [Tailscale](https://tailscale.com) account,
and some disk space for your music.

1. Copy `.env.example` to `.env` and fill it in. Every value is explained there.
   Generate secrets with `openssl rand -base64 32`; `.env` is git-ignored — never commit it.
2. Point `MUSIC_DIR` at your music folder (mounted read-only).
3. Start it: `docker compose up -d`.
4. The `tailscale` service prints a login link in its log the first time
   (`docker compose logs tailscale`). Approve it; the server is then reachable at
   `https://opentify.<your-tailnet>.ts.net`.
5. Create your admin login: `docker compose exec api python -m app.tools.admin_invite`
   prints a one-time link (`https://<your server>/?join=…`). Open it and choose a
   username and password. Then scan your library (Profil › Knihovna).
   Lost all your devices? `docker compose exec api python -m app.tools.pair_code <username>`
   prints a one-time device code.

Set `CORS_ALLOWED_ORIGINS` in `.env` to your own addresses.

### Security basics

- The API listens on `127.0.0.1` only; reach it through Tailscale, not by opening ports.
- Do not expose the server publicly unless you understand the risks.
  Share only the `opentify` machine in Tailscale with people you trust, not your whole computer.
- New devices need a password **and** a one-time device code (Profil › Přidat zařízení).
- Keep Docker images and the host updated.

### Building the apps (GitHub Actions)

Fork the repository and add a repository **variable** `OPENTIFY_HOST` with your
server address (for example `opentify.<your-tailnet>.ts.net`). Then push a tag:

- `ios-*` → unsigned `.ipa` (install with SideStore / AltStore) and a SideStore source,
- `android-*` → APK (signing key setup: `client/android/tool/setup_signing.py`),
- `windows-*` → Windows build, `app-*` → all three.

Builds of a fork use the fork's own releases for app updates; nothing points back here.

For local development: `flutter run --dart-define=API_BASE_URL=http://localhost:8000/api/v1 --dart-define=WS_BASE_URL=ws://localhost:8000/ws`.

## License

[GNU AGPL-3.0](LICENSE). If you run a modified version for others, you must share
your changes under the same license.

Third-party services (MusicBrainz, Deezer, Last.fm, ListenBrainz, Wikipedia, …)
have their own terms; follow them, including rate limits and an identifying User-Agent.
