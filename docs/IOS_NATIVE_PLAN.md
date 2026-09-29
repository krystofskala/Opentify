# Plán: nativní aplikace pro iPhone

Stav: **odloženo**. Tohle je finální plán, podle kterého se pojede, až se
vývoj webové aplikace (PWA) ustálí. Do té doby zůstává Opentify PWA na ploše
iPhonu (Safari, Tailscale).

## Proč nativní aplikace

- **Offline poslech na víkend** (místo bez signálu). V PWA by znamenal
  service worker, audio v IndexedDB a slepování playlistu do jednoho souboru
  na serveru, aby iOS při zamčeném displeji navazoval skladby. To je příliš
  náročné a zatěžuje to celý systém.
- **Přehrávání na pozadí.** Nativně iOS přechází mezi skladbami při
  zamčeném displeji běžně, takže odpadá rádiový režim (HLS stream ze
  serveru).

## Postup

1. **Sestavení bez Macu:** workflow v GitHub Actions na macOS runneru
   spustí `flutter build ios --release --no-codesign` a zabalí výsledek do
   `Payload/Runner.app` → nepodepsaný `.ipa` jako artefakt buildu.
2. **Instalace a podpis: SideStore.** Podepíše `.ipa` bezplatným Apple ID
   přímo v telefonu. Podpis platí 7 dní a SideStore ho obnovuje
   automaticky na zařízení, bez počítače.
   - Záloha: AltStore + AltServer na Windows PC (obnova na stejné Wi-Fi).
   - Bezplatné Apple ID: max. 3 sideloadované aplikace.
   - Placený Apple Developer účet (99 USD ročně) by dal podpis na rok a
     TestFlight.
3. **Náhrada webových částí klienta:**
   - rádiový režim (`core/radio_mode*`, HLS/MP3 stream) → není potřeba,
   - `core/media_session_web.dart` → `audio_service` (zamčená obrazovka,
     Ovládací centrum, sluchátka),
   - `core/share_link_web.dart` (Web Share přes js_interop) →
     `share_plus`,
   - obnovení přehrávače (SharedPreferences) funguje i nativně.
4. **Offline stahování** (až po bodech 1–3):
   - tlačítko „Stáhnout do zařízení" u playlistu/alba,
   - server při stahování převede FLAC do AAC (~8 MB na skladbu, víkend
     o 200 skladbách ≈ 1,6 GB),
   - soubory v úložišti aplikace, metadata v lokální DB,
   - přehled obsazeného místa v Profilu.

## Co zůstává stejné

Backend (FastAPI v Dockeru), přístup přes Tailscale (HTTPS),
Soulseek jen přes VPN, všechny endpointy. Nativní aplikace je jen jiný
klient nad stejným API.
