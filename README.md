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
- [Display-Verhalten](#display-verhalten)
- [Sprachassistent](#sprachassistent)
- [Konfiguration](#konfiguration)
- [API](#api)
- [Entwicklung](#entwicklung)
- [Datenschutz](#datenschutz)
- [Roadmap](#roadmap)

## Funktionen

| | |
|---|---|
| 🏠 **Ein Tablet, ein Raum** | Jedes Tablet bekommt einen Token und einen Raum. Es sieht und steuert nur die Geräte dieses Raums. |
| 💡 **Licht** | Ein/aus, Helligkeit per Wischen über die Kachel, Farbrad, Weißtöne in Kelvin, Favoriten. |
| ❄️ **Klima** | Drehregler für die Zieltemperatur, Modi (Kühlen, Heizen, Automatik, Entfeuchten, Lüften), Lüfterstufe, Lamellen, Eco. |
| 🪟 **Rollos, Musik, Szenen, Schlösser** | Position, Lautstärke und Titel, Szenen per Tipp, Türschloss. |
| 🗣️ **Sprachassistent** | Mikro halten und sprechen oder antippen und schreiben. Spracherkennung mit OpenAI, Sprachmodell OpenAI oder Grok (xAI), Antwortstimme mit ElevenLabs oder OpenAI. |
| 👋 **Wird hell bei Annäherung** | Die Frontkamera erkennt, wenn jemand vor das Tablet tritt. Antippen ist nicht nötig. Wer hinten im Raum vorbeigeht, weckt es nicht. |
| 🌙 **Blendet nicht** | Die Helligkeit folgt dem Raumlicht. Nachts gibt es eine Obergrenze und ein dunkles Design. |
| 🔁 **Live** | Änderungen aus Home Assistant erscheinen sofort, nach einem Verbindungsabbruch verbindet sich die App selbst neu. |
| 🧪 **Demo-Modus** | Die App lässt sich ohne Server mit Beispielgeräten ausprobieren. |

## Screenshots

| Licht mit Weißtönen | Farblicht |
|---|---|
| ![Licht](docs/screenshots/03-licht.png) | ![Farblicht](docs/screenshots/05-farblicht.png) |
| **Klimaanlage** | **Sprachassistent** |
| ![Klima](docs/screenshots/04-klima.png) | ![Sprache](docs/screenshots/06-sprache.png) |
| **Einrichtung** | **Hochformat** |
| ![Einrichtung](docs/screenshots/01-einrichtung.png) | <img src="docs/screenshots/07-hochformat.png" alt="Hochformat" width="60%"> |

## So funktioniert es

```
Geräte (Zigbee, Hue, Klima, …) ──► Home Assistant
                                       │  REST + WebSocket
                                       ▼
                              Hausgeist-Server (Docker, z. B. Unraid)
                              • Räume, Tablets, Zuordnung (SQLite)
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
4. **Apply**. Unter `http://<unraid-ip>:8080/docs` siehst du die API, unter `/health` den Status.

**Mit Docker Compose (jeder Docker-Host):**

```bash
git clone https://github.com/gottschalkfelix4-source/hausgeist.git
cd hausgeist
cp backend/.env.example backend/.env   # Werte eintragen
docker compose up -d
```

Das Image `ghcr.io/gottschalkfelix4-source/hausgeist` gibt es für `amd64` und `arm64`.

### 2. Räume und Tablets anlegen

> Eine Web-Oberfläche zur Verwaltung ist in Arbeit. Bis dahin geht das über die API, entweder mit
> `curl` oder bequem im Browser unter `http://<server>:8080/docs` („Try it out“, Admin-Key ins Feld `x-admin-key`).

```bash
S=http://192.168.1.10:8080
K="dein-admin-key"

# Raum anlegen -> liefert die Raum-ID
curl -X POST $S/api/rooms -H "x-admin-key: $K" -H "Content-Type: application/json" -d '{"name":"Wohnzimmer"}'

# Alle Geräte aus Home Assistant ansehen
curl $S/api/entities -H "x-admin-key: $K"

# Geräte dem Raum zuordnen
curl -X PUT $S/api/rooms/<RAUM_ID>/entities -H "x-admin-key: $K" -H "Content-Type: application/json" \
  -d '{"entity_ids":["light.decke","climate.klima","cover.rollo"]}'

# Optional: Präsenzmelder des Raums (weckt alle Tablets im Raum)
curl -X PUT $S/api/rooms/<RAUM_ID>/presence -H "x-admin-key: $K" -H "Content-Type: application/json" \
  -d '{"entity_id":"binary_sensor.wohnzimmer_praesenz"}'

# Tablet registrieren -> liefert den Token für die App (nur einmal sichtbar!)
curl -X POST $S/api/tablets -H "x-admin-key: $K" -H "Content-Type: application/json" \
  -d '{"name":"Wohnzimmer-Tablet","room_id":"<RAUM_ID>"}'
```

### 3. Tablet einrichten

1. Die APK aus den [Releases](https://github.com/gottschalkfelix4-source/hausgeist/releases/latest) aufs Tablet laden und installieren (Installation aus unbekannten Quellen erlauben).
   Per USB geht es auch mit `adb install -r hausgeist.apk`.
2. App öffnen, **Server-Adresse** (`http://<server>:8080`) und **Tablet-Token** eintragen und auf **Verbinden** tippen.
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
wird dunkel. Alle Werte lassen sich pro Tablet über `PUT /api/tablets/{id}/display` ändern, siehe
[ARCHITECTURE.md](docs/ARCHITECTURE.md#display-verhalten-dauer-wach-dimmen-nacht).

## Sprachassistent

```
Tablet ── Audio (m4a) ──► Server ── STT (OpenAI) ──► LLM (OpenAI | Grok) ──► Werkzeug control_device
                                                                     │
Tablet ◄── Antwort + Audio ◄── TTS (ElevenLabs | OpenAI) ◄───────────┘
```

Das Sprachmodell bekommt nur die Geräte des Tablet-Raums und kann nur diese steuern.
Beispiele: *„Mach das Licht gemütlich“*, *„Stell die Klima auf 21 Grad“*, *„Rollo halb runter“*.

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

## API

| Endpoint | Auth | Zweck |
|---|---|---|
| `GET/POST/DELETE /api/rooms`, `PUT /api/rooms/{id}/entities` | `x-admin-key` | Räume und Geräte-Zuordnung |
| `PUT /api/rooms/{id}/presence` | `x-admin-key` | Präsenzmelder des Raums |
| `GET /api/entities` | `x-admin-key` | Alle Geräte aus Home Assistant |
| `GET/POST /api/tablets`, `PUT /api/tablets/{id}/room` | `x-admin-key` | Tablets registrieren und zuweisen |
| `PUT /api/tablets/{id}/display` | `x-admin-key` | Display-Verhalten pro Tablet |
| `GET /api/me` | Tablet-Token | Raum, Geräte und Display-Einstellungen |
| `POST /api/entities/{id}/command` | Tablet-Token | Gerät steuern (nur im eigenen Raum) |
| `WS /ws?token=` | Tablet-Token | Live-Zustände und Aufwecken |
| `POST /api/voice/text`, `/api/voice/audio` | Tablet-Token | Sprachassistent |
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
pip install -r requirements.txt
cp .env.example .env
DB_PATH=./hausgeist.db uvicorn app.main:app --reload --port 8080
```

**App:**
```bash
cd app
flutter test                  # Display-Logik, Gerätemodell, Oberfläche
flutter build apk --release   # build/app/outputs/flutter-apk/app-release.apk
```

Die Display-Logik (`app/lib/display/display_controller.dart`) ist reines Dart und vollständig getestet.

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
- [ ] Web-Oberfläche zur Verwaltung (Räume, Tablets, Präsenzmelder, Display-Einstellungen)
- [ ] Areas aus Home Assistant automatisch als Räume übernehmen
- [ ] Wake-Word („Hey Hausgeist“) und gestreamte Sprache

## Lizenz

[MIT](LICENSE) © 2026 Felix Gottschalk
