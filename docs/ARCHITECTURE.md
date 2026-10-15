# Hausgeist – Architektur

```
Geräte (Zigbee, Hue, Klima, ...) -> Home Assistant (Unraid)
                                         |  REST + WebSocket
                                  Hausgeist-Server (FastAPI, Docker)
                                  - Räume, Tablets, Geräte-Zuordnung (SQLite)
                                  - Live-Updates raumgefiltert (/ws)
                                  - Sprachassistent: STT -> LLM (Tool-Calling) -> TTS
                                         |  HTTPS/WS im WLAN
                     Flutter-App (Android-Wandtablets, je einem Raum zugewiesen)
```

## Kernideen
- **Home Assistant** liefert die Geräte-Integrationen, das Backend ist Raum-/Rechte-/Sprachschicht.
- **Raum-Zuordnung**: Admin legt Räume an und weist Entities zu; jedes Tablet hat einen Token und
  einen Raum. `/api/me`, `/ws` und `/api/entities/*/command` liefern/erlauben nur Geräte des Raums.
- **Sprache**: Provider per `.env` wählbar. LLM: OpenAI oder xAI/Grok (gleiches Protokoll),
  TTS: ElevenLabs oder OpenAI, STT: OpenAI. Der Assistent darf nur Geräte des Tablet-Raums steuern.
- **Design (Apple Home)**: Kachel-Grid mit großen Rundungen, Frosted-Glass, aktive Kacheln hell/gelb,
  lange Druck = Detailansicht (Helligkeit-Slider, Thermostat-Ring), Raum-Titel oben, Sprach-Button.

## Display aufwecken bei Annäherung
- **Kamera (in der App):** Die Frontkamera läuft im Ruhezustand mit kleiner Auflösung und wenigen
  Bildern pro Sekunde. Ändert sich das Bild deutlich, wird das Display hell. Die Bilder bleiben auf
  dem Tablet und werden nicht gespeichert oder gesendet.
- **Präsenzmelder (über Home Assistant):** Pro Raum kann ein Melder hinterlegt werden
  (`PUT /api/rooms/{id}/presence`). Meldet er Anwesenheit, schickt das Backend `{"type":"wake"}`
  an alle Tablets im Raum.
- Pro Tablet einstellbar: `wake_mode` = `camera` | `sensor` | `both` (`PUT /api/tablets/{id}/display`).

## Display-Verhalten (Dauer-wach, dimmen, Nacht)
Das Tablet bleibt **immer wach** (Wakelock, Kiosk). „Aus“ heißt: Fensterhelligkeit 0 + schwarzes
Overlay. Echtes Abschalten würde die Kamera stoppen. Die Logik steckt in
`app/lib/display/display_controller.dart` (reines Dart, getestet in `app/test/`).

| Zustand | Wann | Helligkeit |
|---|---|---|
| `active` | Berührung, Annäherung oder gerade aufgewacht | Umgebungshelligkeit (Nachtdeckel) |
| `idle` | `dim_after` s nicht bedient | Zielhelligkeit × `idle_factor` |
| `off` | **Raum leer** und `sleep_after` s nicht bedient | 0, schwarz |

**Gegen Flackern, wenn Leute im Raum sind:**
1. Solange der Raum besetzt ist, wird **nur gedimmt, nie ausgeschaltet**. Besetzt heißt: Der Melder
   meldet Anwesenheit oder die letzte Bewegung ist weniger als `presence_hold` s her.
2. Aufwachen braucht mehrere Bewegungs-Frames innerhalb von 1,5 s. Ein einzelner Lichtwechsel
   (TV, Autoscheinwerfer) reicht nicht.
3. Nach jedem Zustandswechsel ignoriert die Kamera 3 s lang alles, damit das eigene Display-Licht
   das Tablet nicht wieder aufweckt.
4. Nach dem Aufwachen bleibt das Display mindestens 20 s an.
5. Im gedimmten Zustand wird das Display ohne Antippen wieder hell, sobald jemand nah ans Tablet
   kommt. Das erkennt die Kamera daran, dass sich mindestens `near_motion_area` (20 %) des Bildes
   ändert. Wer nur hinten durch den Raum läuft, ändert wenig vom Bild, dann bleibt es gedimmt.
   Solange jemand davor steht und sich bewegt, bleibt es hell.

**Nacht und dunkle Räume:**
- Zwischen `night_start` und `night_end` ist die Helligkeit auf `night_max_brightness` begrenzt.
- Der Lichtsensor (Lux) wird geglättet. Die Kurve ist logarithmisch: 0 lx → min, 10 lx ≈ 35 %,
  100 lx ≈ 67 %, ab 1000 lx 100 %. Übernommen wird ein Wert erst ab 5 % Unterschied.
- Hat das Tablet keinen Lichtsensor, dient die mittlere Helligkeit des Kamerabilds als Ersatz.
- Nachts oder unter 5 lx schaltet die App auf das dunkle Design.

**Einstellungen** (JSON pro Tablet, `PUT /api/tablets/{id}/display`, kommt über `/api/me` zur App):
`wake_mode`, `dim_after` (30), `sleep_after` (120), `presence_hold` (90), `near_motion_area` (0.2),
`min_brightness` (0.02),
`max_brightness` (1.0), `idle_factor` (0.35), `night_start` (22), `night_end` (6),
`night_max_brightness` (0.15).

**Android-Umsetzung** (`app/lib/display/`):
- `wakelock_plus` und Kiosk-Modus halten das Display an.
- `screen_brightness` setzt die Fensterhelligkeit (hoch schnell, runter langsam), für „aus" liegt
  zusätzlich ein schwarzes Overlay darüber. Der erste Tap darauf weckt nur, er schaltet nichts.
- `light` liefert den Umgebungslichtsensor.
- `camera` liefert ein kleines YUV-Bild der Frontkamera mit ca. 5 fps. Nur der Y-Kanal wird auf
  ein 32×24-Raster verkleinert und mit dem vorigen verglichen. Die Bilder bleiben im Speicher.
- Ein Ticker ruft jede Sekunde `tick()` auf.

## API (Kurzüberblick)
| Endpoint | Auth | Zweck |
|---|---|---|
| `GET/POST/DELETE /api/rooms`, `PUT /api/rooms/{id}/entities` | Admin-Key | Räume + Geräte-Zuordnung |
| `GET /api/entities` | Admin-Key | alle HA-Geräte |
| `POST /api/tablets`, `PUT /api/tablets/{id}/room` | Admin-Key | Tablet registrieren/zuweisen |
| `PUT /api/tablets/{id}/display`, `PUT /api/rooms/{id}/presence` | Admin-Key | Display-Verhalten, Präsenzmelder |
| `GET /api/me` | Tablet-Token | Raum + Geräte des Tablets |
| `POST /api/entities/{id}/command` | Tablet-Token | Gerät steuern (nur eigener Raum) |
| `WS /ws?token=` | Tablet-Token | Live-Zustände |
| `POST /api/voice/text`, `/api/voice/audio` | Tablet-Token | Sprachassistent |

## Starten
```
cd backend; copy .env.example .env   # HA_URL, HA_TOKEN, API-Keys eintragen
uvicorn app.main:app --reload --port 8080   # lokal (DB_PATH=./hausgeist.db)
docker compose up -d --build                 # Unraid
```

## Tablet-App (`app/`)
Flutter, nur Android. Aufbau:
- `lib/core/`: Gerätemodell (HA → Kachel), API-Client, `HomeStore` (Zustand, WebSocket,
  Befehle gedrosselt) und Demo-Daten.
- `lib/display/`: Display-Logik (reines Dart, getestet), Kamera-Bewegung und Android-Anbindung.
- `lib/ui/`: Design „Home Original“, Kacheln mit Wisch-Dimmen, Detail-Fenster (Licht, Klima,
  Rollo, Medien) und Setup.
- `lib/voice/`: Mikro halten = sprechen, Mikro tippen = schreiben.

```
cd app
flutter test                 # Display-Logik, Gerätemodell, Oberfläche
flutter build apk --release  # -> build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
```
Beim ersten Start gibt man Server-URL und Tablet-Token ein oder startet die Demo. Die Einstellungen
erreicht man später über langes Drücken auf die Uhr. Für den Kiosk-Betrieb wählt man unter
Android „Zuhause“ als Standard-Startbildschirm.

Hinweis Windows: `android/gradle.properties` setzt `kotlin.incremental=false`, weil Projekt (D:) und
Pub-Cache (C:) auf verschiedenen Laufwerken liegen.

## Roadmap
1. ✅ Backend-Grundgerüst
2. ✅ Flutter-Tablet-App (Kachel-UI im Apple-Home-Stil, Setup-Screen für URL+Token, Kiosk-Modus, Display-Logik, Sprache)
3. Admin-Weboberfläche (Räume/Tablets verwalten, HA-Areas importieren)
4. Wake-Word & Streaming-Sprache (niedrige Latenz), Szenen/Automationen
