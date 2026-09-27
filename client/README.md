# Opentify — Flutter klient

Multiplatformní klient (iOS/Android/Windows/Linux/Web) nad backendem v
`../backend`. Vyvíjeno a testováno primárně přes `flutter run -d chrome`.

## Než poprvé spustíš: vygeneruj platformní boilerplate

Tenhle adresář obsahuje jen `lib/` a `pubspec.yaml` (napsané ručně, bez
přístupu k Flutter SDK v prostředí, kde vznikly — nebylo možné je provizovat
`flutter create` ani ověřit `flutter analyze`/`flutter run`). Chybí
platformní složky (`web/`, `android/`, `ios/`, `linux/`, `windows/`), které
normálně generuje Flutter tooling. Doplň je **jednou**, z tohoto adresáře:

```bash
cd client
flutter create --platforms=web,windows,linux,android,ios --org com.opentify .
```

Tenhle příkaz na existujícím projektu (pubspec.yaml + lib/ už existují)
nepřepíše `lib/main.dart` ani závislosti v `pubspec.yaml` — jen doplní
chybějící platformní scaffolding.

## Spuštění proti lokálnímu backendu

```bash
# 1. Backend (z repo rootu)
docker compose up -d redis
cd backend && uvicorn app.main:app --reload

# 2. Klient
cd client
flutter pub get
flutter run -d chrome \
  --dart-define=API_BASE_URL=http://localhost:8000/api/v1 \
  --dart-define=WS_BASE_URL=ws://localhost:8000/ws
```

Bez `--dart-define` se použijí stejné výchozí hodnoty (`lib/core/config.dart`),
takže pro lokální dev proti výchozímu portu 8000 lze `flutter run -d chrome`
spustit i bez parametrů.

## Multi-device sync v devu

Backend rozlišuje uživatele/zařízení podle hlaviček `X-User-Id`/`X-Device-Id`
(zjednodušená auth, viz `backend/app/auth.py`). Pro test synchronizace mezi
"dvěma zařízeními" ve dvou Chrome tabech spusť druhou instanci s jiným
`VAULT_DEVICE_ID`:

```bash
flutter run -d chrome --dart-define=VAULT_DEVICE_ID=chrome-tab-2
```

## Struktura

```
lib/
  main.dart               # vstupní bod
  app.dart                # MaterialApp.router + téma
  core/                   # API klient, WS klient, konfigurace
  models/                 # DTO 1:1 s docs/openapi.yaml a docs/asyncapi.yaml
  data/                   # repository vrstva (HTTP volání) nad core/api_client.dart
  state/                  # Riverpod providery + controllery (playback, provisioning)
  routing/                # go_router konfigurace + bottom-nav shell
  features/
    home/                 # Discover + Daily Jams
    search/               # /catalog/search — hlavní proklikávací obrazovka
    artist/                # detail interpreta + diskografie
    release/               # detail alba + tracklist s provisioningem
  widgets/                # sdílené widgety (availability badge, recording tile)
```

## Co chybí (mimo scope tohoto sketche)

- Skutečný audio playback engine (např. `just_audio`) — `RecordingTile`/
  `PlaybackController` řeší jen řízení stavu a síťovou stránku (provisioning,
  stream URL, WS eventy), samotné přehrání zvuku z `streamUrl` je další krok.
- Reálná device-scoped JWT autentizace — čeká na `backend/app/auth.py`.
- Server-side `playback.*`/`queue.*` zpracování (`backend/app/realtime.py` má
  jen TODO) — `PlaybackController` je na plný protokol připraven, ale dokud
  ho backend nedoplní, frontu/pozici mezi zařízeními fakticky nesynchronizuje.
