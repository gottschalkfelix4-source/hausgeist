<p align="center">
  <img src="docs/assets/banner.png" alt="Hausgeist – Dein Smart Home an der Wand" width="100%">
</p>

<p align="center">
  <a href="https://github.com/gottschalkfelix4-source/hausgeist/actions/workflows/docker.yml"><img src="https://github.com/gottschalkfelix4-source/hausgeist/actions/workflows/docker.yml/badge.svg" alt="Docker"></a>
  <a href="https://github.com/gottschalkfelix4-source/hausgeist/actions/workflows/app.yml"><img src="https://github.com/gottschalkfelix4-source/hausgeist/actions/workflows/app.yml/badge.svg" alt="App"></a>
  <a href="https://github.com/gottschalkfelix4-source/hausgeist/releases/latest"><img src="https://img.shields.io/github/v/release/gottschalkfelix4-source/hausgeist?label=APK&color=FFB340" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/Lizenz-MIT-5FD17A" alt="MIT"></a>
</p>

**Hausgeist** macht günstige Android-Tablets zu Wand-Bedienfeldern für **Home Assistant**.
Jedes Tablet gehört zu einem Raum und zeigt nur dessen Geräte, im Stil von Apple Home.
Ein Sprachassistent steuert per Sprache, ebenfalls nur im eigenen Raum.
Das Display bleibt immer bereit. Es wird hell, sobald jemand davor steht, und dunkel, wenn niemand im Raum ist.

<p align="center">
  <img src="docs/screenshots/02-raum.png" alt="Raumansicht" width="100%">
</p>

## Inhalt
- [Funktionen](#funktionen)
- [Screenshots](#screenshots)
- [So funktioniert es](#so-funktioniert-es)
- [Installation](#installation)
  - [1. Server auf Unraid](#1-server-auf-unraid)
  - [2. Räume und Tablets anlegen](#2-räume-und-tablets-anlegen)
  - [3. Tablet einrichten](#3-tablet-einrichten)
  - [Updates](#updates)
- [Web-Verwaltung](#web-verwaltung)
- [Display-Verhalten](#display-verhalten)
- [Sprachassistent](#sprachassistent)
- [Konfiguration](#konfiguration)
- [Zugriff von außen / HTTPS](#zugriff-von-außen--https)
- [API](#api)
- [Entwicklung](#entwicklung)
- [Datenschutz](#datenschutz)
- [Roadmap](#roadmap)

## Funktionen

| | |
|---|---|
| 🏠 **Ein Tablet, ein Raum** | Jedes Tablet gehört zu einem Raum. Es sieht und steuert nur die Geräte dieses Raums. Mehrere Tablets pro Raum sind kein Problem. |
| 🖥️ **Web-Verwaltung** | Räume, Geräte, Präsenzmelder, Tablets und Display-Verhalten im Browser einstellen. Räume lassen sich mit einem Klick aus den Home-Assistant-Bereichen übernehmen. |
| 🔢 **Koppeln per Code** | Tablet anlegen, 6-stelligen Code in der App eintippen, fertig. Kein Token abtippen. |
| 💡 **Licht** | Ein/aus, Helligkeit per Wischen über die Kachel, Farbrad, Weißtöne in Kelvin, Favoriten. |
| ❄️ **Klima** | Drehregler für die Zieltemperatur, Modi (Kühlen, Heizen, Automatik, Entfeuchten, Lüften), Lüfterstufe, Lamellen, Eco. |
| 🪟 **Rollos, Musik, Szenen, Schlösser** | Position, Lautstärke und Titel, Szenen per Tipp, Türschloss. |
| 🗣️ **Sprachassistent** | Mikro halten und sprechen oder antippen und schreiben. Spracherkennung mit OpenAI, Sprachmodell OpenAI oder Grok (xAI), Antwortstimme mit ElevenLabs oder OpenAI. Er merkt sich die letzten Sätze, „und jetzt etwas dunkler“ funktioniert also. |
| 👋 **Wird hell bei Annäherung** | Die Frontkamera erkennt, wenn jemand vor das Tablet tritt. Antippen ist nicht nötig. Wer hinten im Raum vorbeigeht, weckt es nicht. |
| 🌙 **Blendet nicht** | Die Helligkeit folgt dem Raumlicht. Nachts gibt es eine Obergrenze und ein dunkles Design. |
| 🔁 **Live** | Änderungen aus Home Assistant erscheinen sofort, nach einem Verbindungsabbruch verbindet sich die App selbst neu. |
| ⬆️ **Update-Hinweis** | Gibt es ein neues Release, zeigt das Tablet einen Hinweis und lädt die neue APK auf Fingertipp. |
| 🧪 **Demo-Modus** | Die App lässt sich ohne Server mit Beispielgeräten ausprobieren. |

## Screenshots

| Licht mit Weißtönen | Farblicht |
|---|---|
| ![Licht](docs/screenshots/03-licht.png) | ![Farblicht](docs/screenshots/05-farblicht.png) |
| **Klimaanlage** | **Sprachassistent** |
| ![Klima](docs/screenshots/04-klima.png) | ![Sprache](docs/screenshots/06-sprache.png) |
| **Einrichtung mit Kopplungscode** | **Nachts** |
| ![Einrichtung](docs/screenshots/01-einrichtung.png) | ![Nacht](docs/screenshots/11-nacht.png) |
| **Hochformat** | |
| <img src="docs/screenshots/07-hochformat.png" alt="Hochformat" width="60%"> | |

## So funktioniert es

```
Geräte (Zigbee, Hue, Klima, …) ──► Home Assistant
                                       │  REST + WebSocket
                                       ▼
                              Hausgeist-Server (Docker, z. B. Unraid)
                              • Räume, Tablets, Zuordnung (SQLite), Web-Verwaltung
                              • Live-Zustände, nach Raum gefiltert
                              • Sprache: STT ─► LLM mit Tool-Calling ─► TTS
                                       │  WLAN, Token pro Tablet
                                       ▼
                     Hausgeist-App auf den Wandtablets (Android)
```

Home Assistant bleibt die Basis für alle Geräte. Hausgeist ist die Schicht darüber: Es weiß, welches
Tablet in welchem Raum hängt, filtert die Geräte und führt den Sprachassistenten aus. Details stehen in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Installation

Du brauchst:
- Home Assistant mit einem **Long-Lived Access Token** (in Home Assistant: Profil → Sicherheit → *Langlebige Zugriffstoken*)
- einen Docker-Host, zum Beispiel Unraid
- ein oder mehrere Android-Tablets (Android 7 oder neuer, Frontkamera empfohlen)
- für Sprache: einen OpenAI-API-Key, optional xAI- oder ElevenLabs-Keys

### 1. Server auf Unraid

**Mit dem Template:**

1. Unraid-Terminal öffnen und das Template herunterladen:
   ```bash
   wget -O /boot/config/plugins/dockerMan/templates-user/my-hausgeist.xml https://raw.githubusercontent.com/gottschalkfelix4-source/hausgeist/main/unraid/hausgeist.xml
   ```
2. **Docker → Add Container** → bei *Template* „Hausgeist“ auswählen.
3. Ausfüllen:
   - **Home Assistant URL**, z. B. `http://192.168.1.10:8123`
   - **Home Assistant Token**
   - **Admin-Key**: ein selbst gewähltes, langes Passwort
   - **OpenAI API-Key** und die Sprach-Provider (optional)
4. **Apply**. Die Verwaltung öffnest du über das Container-Icon → **WebUI** oder unter `http://<unraid-ip>:8080/admin/`.

**Mit Docker Compose (jeder Docker-Host):**

```bash
git clone https://github.com/gottschalkfelix4-source/hausgeist.git
cd hausgeist
cp backend/.env.example backend/.env   # Werte eintragen
docker compose up -d
```

Das Image `ghcr.io/gottschalkfelix4-source/hausgeist` gibt es für `amd64` und `arm64`.

### 2. Räume und Tablets anlegen

Öffne `http://<server>:8080/admin/` und melde dich mit dem **Admin-Key** an.

1. **Räume → Aus Home Assistant übernehmen.** Hausgeist legt für jeden Bereich (Area) aus Home Assistant
   einen Raum an und ordnet die Geräte zu. Gibt es im Bereich genau einen Präsenzmelder, wird er
   automatisch eingetragen. Du kannst auch einzelne Bereiche wählen oder Räume von Hand anlegen.
2. **Raum öffnen**, um Geräte an- oder abzuwählen, ihn umzubenennen oder den Präsenzmelder zu ändern.
3. **Tablets → Tablet hinzufügen**: Name und Raum wählen. Es erscheint ein **Kopplungscode**, der 15 Minuten gilt.

<p align="center">
  <img src="docs/screenshots/09-raum-geraete.png" alt="Geräte eines Raums in der Verwaltung" width="49%">
  <img src="docs/screenshots/10-kopplung.png" alt="Kopplungscode" width="49%">
</p>

### 3. Tablet einrichten

1. Die APK aus den [Releases](https://github.com/gottschalkfelix4-source/hausgeist/releases/latest) aufs Tablet laden und installieren (Installation aus unbekannten Quellen erlauben).
   Per USB geht es auch mit `adb install -r hausgeist.apk`.
2. App öffnen, **Server-Adresse** (`http://<server>:8080`) und den **Kopplungscode** eintragen und auf **Verbinden** tippen.
   Der Code gilt nur einmal. Abgelaufen? In der Verwaltung beim Tablet auf **Neuer Kopplungscode** klicken.
   Ohne Server kannst du auf **Ohne Server ausprobieren (Demo)** tippen.
3. Kamera und Mikrofon erlauben.
4. **Kiosk-Modus:** Einmal die Home-Taste drücken und *Hausgeist* als Startbildschirm mit **Immer** wählen.
   Das Tablet startet dann direkt in die App, Status- und Navigationsleiste sind ausgeblendet.
5. Die Einrichtung erreichst du später über **langes Drücken auf die Uhr**.

**Bedienung:**

| Geste | Wirkung |
|---|---|
| Symbol antippen | Gerät ein oder aus |
| Kachel antippen | Detailfenster (Farbe, Modus, Lüfter, …) |
| Waagerecht über die Kachel wischen | Helligkeit oder Rollo-Position |
| Mikro gedrückt halten | Sprechen |
| Mikro kurz antippen | Befehl eintippen |
| Lange auf die Uhr drücken | Einrichtung |

Raum, Geräte und Display-Einstellungen änderst du in der Verwaltung. Die Tablets übernehmen das sofort, ohne Neustart.

### Updates

**Server:** Unraid zeigt neue Images unter *Docker → Check for Updates*. Mit Compose: `docker compose pull && docker compose up -d`.

**App:** Gibt es auf GitHub ein neueres Release, zeigt das Tablet unten links **Update … verfügbar**. Antippen lädt
die APK im Browser, danach die Datei öffnen und installieren. Kopplung und Einstellungen bleiben erhalten.

> **Von 0.1.x auf 0.2.0:** Die App hat eine neue Paket-ID (`de.hausgeist.wall`) und ist jetzt mit einem
> festen Release-Schlüssel signiert. Sie wird deshalb **neben** der alten App installiert. Alte App
> deinstallieren, neue installieren und einmal koppeln. Ab 0.2.0 funktionieren Updates ganz normal.

## Web-Verwaltung

<p align="center">
  <img src="docs/screenshots/08-verwaltung.png" alt="Räume in der Verwaltung" width="100%">
</p>

| Bereich | Was du dort machst |
|---|---|
| **Übersicht** | Verbindung zu Home Assistant, Status der Sprach-Provider, welche Tablets online sind. Eine Checkliste führt durch die Ersteinrichtung. |
| **Räume** | Bereiche aus Home Assistant übernehmen, Räume anlegen, umbenennen, löschen. Geräte per Suche und Häkchen zuordnen. Präsenzmelder wählen. |
| **Tablets** | Tablets anlegen und einem Raum zuweisen, auch mehrere pro Raum. Kopplungscode erzeugen, Token erneuern, Tablet entfernen. Display-Verhalten pro Tablet einstellen. |

Die Verwaltung funktioniert auch auf dem Handy. Der Admin-Key bleibt nur in diesem Browser-Tab gespeichert,
außer du setzt das Häkchen bei **Angemeldet bleiben**.

## Display-Verhalten

Das Tablet bleibt **immer wach**. „Aus“ heißt: Helligkeit 0 und schwarzer Bildschirm. So läuft die
Kamera weiter und das Tablet reagiert sofort.

| Zustand | Wann | Helligkeit |
|---|---|---|
| **aktiv** | Berührung, Annäherung, gerade aufgewacht | passend zum Raumlicht |
| **gedimmt** | 30 s nicht bedient, aber jemand im Raum | ca. ein Drittel davon |
| **aus** | 120 s niemand bedient und niemand im Raum | 0 |

Damit es nicht flackert:
- Nach einer Bewegung gilt der Raum **90 s lang** als besetzt.
- Ein einzelnes verrauschtes Bild zählt nicht, es braucht mehrere Bilder mit Bewegung.
- Gleichmäßige Helligkeitsänderungen, etwa wenn das Licht angeht, gelten nicht als Bewegung.
- Nach dem Aufwachen bleibt das Display mindestens 20 s an.
- Aus dem gedimmten Zustand wird es nur hell, wenn sich jemand **nähert**, also mindestens 20 % des
  Kamerabilds sich ändern. Wer hinten im Raum vorbeigeht, ändert es nicht.
- Die Helligkeit folgt dem Lichtsensor gemittelt und mit Hysterese, damit sie nicht pumpt.

Nachts (standardmäßig 22–6 Uhr) oder in sehr dunklen Räumen gilt eine Obergrenze von 15 % und das Design
wird dunkel. Alle Werte lassen sich pro Tablet in der Verwaltung unter **Tablets** ändern, siehe
[ARCHITECTURE.md](docs/ARCHITECTURE.md#display-verhalten-dauer-wach-dimmen-nacht).

## Sprachassistent

```
Tablet ── Audio (m4a) ──► Server ── STT (OpenAI) ──► LLM (OpenAI | Grok) ──► Werkzeug control_device
                                                                     │
Tablet ◄── Antwort + Audio ◄── TTS (ElevenLabs | OpenAI) ◄───────────┘
```

Das Sprachmodell bekommt nur die Geräte des Tablet-Raums mit ihrem aktuellen Zustand und kann nur diese steuern.
Es kann auch Farben und Weißtöne setzen. Pro Tablet merkt es sich die letzten Sätze für zwei Minuten.
Beispiele: *„Mach das Licht gemütlich“*, *„Stell die Klima auf 21 Grad“*, *„Rollo halb runter“*, danach *„noch ein bisschen weiter“*.

Ob die Schlüssel der Provider gesetzt sind, zeigt die Übersicht in der Verwaltung.

## Konfiguration

Alle Einstellungen des Servers sind Umgebungsvariablen (Unraid-Template oder `backend/.env`):

| Variable | Standard | Bedeutung |
|---|---|---|
| `HA_URL` | `http://homeassistant.local:8123` | Adresse von Home Assistant |
| `HA_TOKEN` | – | Long-Lived Access Token |
| `ADMIN_KEY` | – | Passwort für die Verwaltung. Leer oder `change-me` sperrt die Admin-API. |
| `OPENAI_API_KEY` | – | OpenAI (STT, optional LLM und TTS) |
| `XAI_API_KEY` | – | xAI / Grok |
| `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID` | – | ElevenLabs-Stimme |
| `STT_PROVIDER` | `openai` | Spracherkennung |
| `LLM_PROVIDER` | `openai` | `openai` oder `xai` |
| `TTS_PROVIDER` | `elevenlabs` | `elevenlabs` oder `openai` |
| `OPENAI_LLM_MODEL` | `gpt-4o-mini` | Modell für `openai` |
| `XAI_LLM_MODEL` | `grok-3-mini` | Modell für `xai` |
| `DB_PATH` | `/data/hausgeist.db` | SQLite-Datenbank |
| `UPDATE_REPO` | `gottschalkfelix4-source/hausgeist` | GitHub-Repo für den Update-Hinweis der App. Leer schaltet ihn ab. |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` | IP des Reverse Proxys, dem Hausgeist `X-Forwarded-For` glaubt |

## Zugriff von außen / HTTPS

Im Heimnetz reicht `http://`. Wer Hausgeist über das Internet erreichbar machen will, sollte einen
Reverse Proxy mit HTTPS davorsetzen, zum Beispiel **Nginx Proxy Manager** (gibt es als Unraid-App):

1. Neuer *Proxy Host*: Domain eintragen, *Forward* auf `http://<unraid-ip>:8080`.
2. **Websockets Support** einschalten. Ohne ihn kommen keine Live-Updates an.
3. Unter *SSL* ein Let's-Encrypt-Zertifikat anfordern und *Force SSL* aktivieren.
4. Im Container `FORWARDED_ALLOW_IPS` auf die IP des Proxys setzen. So zählt die Sperre gegen das
   Durchprobieren von Kopplungscodes (10 Fehlversuche in 5 Minuten) pro echtem Gerät.
5. In der App als Server `https://deine-domain` eintragen.

Sicherheit im Überblick:
- Tablets melden sich mit einem eigenen Token an. Er geht im `Authorization`-Header mit, auch beim
  WebSocket, und landet so nicht in Proxy-Logs.
- Kopplungscodes gelten 15 Minuten und nur einmal.
- Die Verwaltung ist mit dem Admin-Key geschützt. Solange er leer oder `change-me` ist, ist sie gesperrt.
- Ein verlorenes Tablet entfernst du in der Verwaltung oder klickst dort **Token erneuern**.

## API

| Endpoint | Auth | Zweck |
|---|---|---|
| `GET /api/status` | `x-admin-key` | Version, Home Assistant, Sprach-Provider, Tablets online |
| `GET/POST /api/rooms`, `PATCH/DELETE /api/rooms/{id}` | `x-admin-key` | Räume |
| `PUT /api/rooms/{id}/entities`, `PUT /api/rooms/{id}/presence` | `x-admin-key` | Geräte und Präsenzmelder eines Raums |
| `GET /api/ha/areas`, `POST /api/rooms/import-areas` | `x-admin-key` | Bereiche aus Home Assistant übernehmen |
| `GET /api/entities` | `x-admin-key` | Alle Geräte aus Home Assistant |
| `GET/POST /api/tablets`, `PATCH/DELETE /api/tablets/{id}` | `x-admin-key` | Tablets anlegen, Raum zuweisen, entfernen |
| `POST /api/tablets/{id}/pair`, `POST /api/tablets/{id}/token` | `x-admin-key` | Neuer Kopplungscode, Token erneuern |
| `PUT /api/tablets/{id}/display` | `x-admin-key` | Display-Verhalten pro Tablet |
| `POST /api/pair` | Kopplungscode | Liefert den Token für die App |
| `GET /api/me` | Tablet-Token | Raum, Geräte und Display-Einstellungen |
| `POST /api/entities/{id}/command` | Tablet-Token | Gerät steuern (nur im eigenen Raum) |
| `WS /ws` | Tablet-Token im Header | Live-Zustände und Aufwecken |
| `POST /api/voice/text`, `/api/voice/audio` | Tablet-Token | Sprachassistent |
| `GET /api/app/update` | Tablet-Token | Neueste App-Version |
| `GET /health` | – | Status |

Die vollständige, interaktive Doku liegt auf jedem Server unter `/docs`.

## Entwicklung

```
backend/   FastAPI-Server (Python 3.12)
app/       Flutter-App für Android
unraid/    Unraid-Template
docs/      Architektur, Logo, Screenshots
```

**Server lokal:**
```bash
cd backend
python -m venv .venv && .venv/Scripts/activate   # Linux/macOS: source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
DB_PATH=./hausgeist.db uvicorn app.main:app --reload --port 8080
python -m pytest                     # API, Kopplung, Raum-Grenzen, Sprach-Werkzeuge, HA-Bereiche
```

Die Verwaltung (`backend/app/admin/`) ist reines HTML, CSS und JavaScript ohne Build-Schritt.

**App:**
```bash
cd app
flutter test                  # Display-Logik, Gerätemodell, Oberfläche
flutter build apk --release   # build/app/outputs/flutter-apk/app-release.apk
```

Die Display-Logik (`app/lib/display/display_controller.dart`) ist reines Dart und vollständig getestet.

**Signieren:** Ohne Schlüssel signiert Gradle mit dem Debug-Schlüssel, das reicht zum Ausprobieren.
Für Releases liest `app/android/app/build.gradle.kts` entweder `app/android/key.properties`
(`storeFile`, `storePassword`, `keyAlias`, `keyPassword`, nicht im Repo) oder die Umgebungsvariablen
`HAUSGEIST_KEYSTORE`, `HAUSGEIST_KEYSTORE_PASSWORD`, `HAUSGEIST_KEY_ALIAS` und `HAUSGEIST_KEY_PASSWORD`.

**Release:** Version in `app/pubspec.yaml` und `backend/app/__init__.py` erhöhen, dann einen Tag `vX.Y.Z` pushen.
Die CI testet Server und App, baut das Docker-Image und hängt die signierte `hausgeist-X.Y.Z.apk` ans Release.
Den Schlüssel bekommt sie aus den Secrets `HAUSGEIST_KEYSTORE_BASE64` und `HAUSGEIST_KEYSTORE_PASSWORD`.

## Datenschutz

- **Kamera:** Die Bilder werden nur im Arbeitsspeicher des Tablets auf ein 32×24-Raster verkleinert
  und verglichen. Sie werden nie gespeichert oder verschickt.
- **Sprache:** Aufnahmen gehen an deinen Server und von dort an die gewählten Anbieter (OpenAI, xAI, ElevenLabs).
  Ohne API-Keys ist der Sprachassistent aus.
- **Keine Cloud nötig** für die Gerätesteuerung: Tablets, Server und Home Assistant reden nur im Heimnetz.

## Roadmap

- [x] Server mit Räumen, Tablets, Live-Updates und Sprachassistent
- [x] Tablet-App mit Apple-Home-Design, Detailfenstern und Display-Logik
- [x] Unraid-Template und Docker-Image
- [x] Web-Oberfläche zur Verwaltung (Räume, Tablets, Präsenzmelder, Display-Einstellungen)
- [x] Bereiche aus Home Assistant automatisch als Räume übernehmen
- [x] Koppeln per Code, signierte Releases, Update-Hinweis in der App
- [x] Gesprächsgedächtnis für den Sprachassistenten
- [ ] Wake-Word („Hey Hausgeist“) und gestreamte Sprache

## Lizenz

[MIT](LICENSE) © 2026 Felix Gottschalk
