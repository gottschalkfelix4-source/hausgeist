import 'dart:math' as math;

/// Zustand des Wanddisplays.
/// - [active]: jemand bedient das Tablet, volle (umgebungsabhängige) Helligkeit
/// - [idle]:   Raum besetzt, aber niemand tippt -> gedimmt, bleibt aber an
/// - [off]:    niemand da und nichts bedient -> Helligkeit 0, schwarzer Bildschirm
enum DisplayState { active, idle, off }

/// Einstellungen kommen vom Backend (`/api/me` -> `display`).
class DisplaySettings {
  const DisplaySettings({
    this.wakeMode = 'both',
    this.dimAfter = const Duration(seconds: 30),
    this.sleepAfter = const Duration(seconds: 120),
    this.presenceHold = const Duration(seconds: 90),
    this.minOnTime = const Duration(seconds: 20),
    this.cameraBlindTime = const Duration(seconds: 3),
    this.motionFramesToWake = 2,
    this.wakeWindow = const Duration(milliseconds: 1500),
    this.nearMotionArea = 0.2,
    this.idleFactor = 0.35,
    this.minBrightness = 0.02,
    this.maxBrightness = 1.0,
    this.nightStart = 22,
    this.nightEnd = 6,
    this.nightMaxBrightness = 0.15,
  });

  final String wakeMode; // camera | sensor | both
  final Duration dimAfter;
  final Duration sleepAfter;
  final Duration presenceHold;
  final Duration minOnTime;
  final Duration cameraBlindTime;
  final int motionFramesToWake;
  final Duration wakeWindow;
  final double nearMotionArea; // ab diesem Bildanteil gilt Bewegung als "kommt aufs Tablet zu"
  final double idleFactor;
  final double minBrightness;
  final double maxBrightness;
  final int nightStart;
  final int nightEnd;
  final double nightMaxBrightness;

  bool get useCamera => wakeMode != 'sensor';
  bool get useSensor => wakeMode != 'camera';

  factory DisplaySettings.fromJson(Map<String, dynamic> j) => DisplaySettings(
        wakeMode: j['wake_mode'] as String? ?? 'both',
        dimAfter: Duration(seconds: j['dim_after'] as int? ?? 30),
        sleepAfter: Duration(seconds: j['sleep_after'] as int? ?? 120),
        presenceHold: Duration(seconds: j['presence_hold'] as int? ?? 90),
        nearMotionArea: (j['near_motion_area'] as num? ?? 0.2).toDouble(),
        idleFactor: (j['idle_factor'] as num? ?? 0.35).toDouble(),
        minBrightness: (j['min_brightness'] as num? ?? 0.02).toDouble(),
        maxBrightness: (j['max_brightness'] as num? ?? 1.0).toDouble(),
        nightStart: j['night_start'] as int? ?? 22,
        nightEnd: j['night_end'] as int? ?? 6,
        nightMaxBrightness: (j['night_max_brightness'] as num? ?? 0.15).toDouble(),
      );
}

/// Reine Logik ohne Flutter-Abhängigkeit, damit sie mit einer Fake-Uhr testbar ist.
///
/// Gegen Flackern:
/// 1. Präsenz wird gehalten: Nach der letzten Bewegung gilt der Raum noch
///    [DisplaySettings.presenceHold] lang als besetzt. Solange jemand da ist,
///    wird nur gedimmt, nie ausgeschaltet.
/// 2. Aufwecken braucht mehrere Bewegungs-Frames kurz hintereinander, damit ein
///    einzelner Lichtwechsel (Fernseher, Auto vorm Fenster) nicht reicht.
/// 3. Nach jedem Helligkeitswechsel ignoriert die Kamera kurz alles, weil das
///    eigene Display-Licht das Kamerabild verändert und sonst sich selbst weckt.
/// 4. Nach dem Aufwachen bleibt das Display mindestens [DisplaySettings.minOnTime] an.
///    Gedimmt wird nur zurück auf hell geschaltet, wenn jemand nah ans Tablet kommt
///    ([DisplaySettings.nearMotionArea]), nicht bei Bewegung weiter hinten im Raum.
/// 5. Umgebungshelligkeit wird geglättet und nur bei spürbarer Änderung übernommen.
class DisplayController {
  DisplayController(this.settings, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    final now = _clock();
    _lastActivity = now;
    _lastPresence = now;
    _stateSince = now;
    _wokeAt = now;
  }

  DisplaySettings settings;
  final DateTime Function() _clock;

  DisplayState _state = DisplayState.active;
  late DateTime _lastActivity;
  late DateTime _lastPresence;
  late DateTime _stateSince;
  late DateTime _wokeAt;
  DateTime? _lastNear, _lastSeen;
  bool _sensorPresent = false;
  final List<DateTime> _motionFrames = [];

  double? _luxSmoothed;
  double _ambientTarget = 0.6;

  DisplayState get state => _state;

  /// Raum gilt als besetzt (Melder meldet Person oder Bewegung ist noch nicht lange her).
  bool get occupied => _sensorPresent || _clock().difference(_lastPresence) < settings.presenceHold;

  bool get isNight {
    final h = _clock().hour;
    final s = settings.nightStart, e = settings.nightEnd;
    return s > e ? (h >= s || h < e) : (h >= s && h < e);
  }

  /// Dunkles App-Design verwenden (nachts oder wenn es im Raum dunkel ist).
  bool get nightTheme => isNight || (_luxSmoothed != null && _luxSmoothed! < 5);

  /// Fensterhelligkeit 0..1, die die App setzen soll.
  double get brightness {
    if (_state == DisplayState.off) return 0;
    var target = _ambientTarget.clamp(settings.minBrightness, settings.maxBrightness);
    if (isNight) target = math.min(target, settings.nightMaxBrightness);
    if (_state == DisplayState.idle) {
      target = math.max(settings.minBrightness, target * settings.idleFactor);
    }
    return target;
  }

  // ---------- Eingänge ----------

  void onTouch() {
    _lastPresence = _lastNear = _lastSeen = _clock();
    _wake();
  }

  /// Gerade jemand direkt vor dem Tablet (berührt oder große Bewegung im Kamerabild).
  bool get someoneNear => _lastNear != null && _clock().difference(_lastNear!) < const Duration(seconds: 15);

  /// Das Tablet selbst hat kürzlich jemanden bemerkt (Kamera oder Berührung, ohne Präsenzmelder).
  bool get recentlySeen => _lastSeen != null && _clock().difference(_lastSeen!) < const Duration(seconds: 45);

  /// Ein Kamera-Frame hat sich deutlich vom vorherigen unterschieden.
  /// [area] = Anteil der geänderten Pixel (0..1). Wer direkt vor dem Tablet steht, füllt einen
  /// großen Teil des Bildes, wer hinten durch den Raum läuft, nur einen kleinen.
  void onCameraMotion({double area = 1}) {
    if (!settings.useCamera) return;
    final now = _clock();
    if (now.difference(_stateSince) < settings.cameraBlindTime) return;
    _motionFrames
      ..add(now)
      ..removeWhere((t) => now.difference(t) > settings.wakeWindow);
    if (_motionFrames.length < settings.motionFramesToWake) return;
    _lastPresence = now;
    _lastSeen = now;
    if (area >= settings.nearMotionArea) _lastNear = now;
    // Aus -> jede Bewegung weckt. Gedimmt/aktiv -> nur Annäherung macht (wieder) hell und
    // hält es hell, solange jemand davor steht. Kein Antippen nötig.
    if (_state == DisplayState.off || area >= settings.nearMotionArea) _wake();
  }

  /// Präsenzmelder aus Home Assistant (Zustand des Melders im Raum).
  void onPresenceSensor(bool present) {
    if (!settings.useSensor) return;
    _sensorPresent = present;
    _lastPresence = _clock(); // beim Wechsel auf "leer" startet die Haltezeit jetzt
    if (present && _state == DisplayState.off) _wake();
  }

  /// `{"type":"wake"}` vom Backend.
  void onWakeSignal() => onPresenceSensor(true);

  /// Messwert des Umgebungslichtsensors in Lux.
  void onAmbientLux(double lux) {
    final l = math.max(0.0, lux);
    _luxSmoothed = _luxSmoothed == null ? l : _luxSmoothed! * 0.8 + l * 0.2;
    final target = luxToBrightness(_luxSmoothed!);
    if ((target - _ambientTarget).abs() >= 0.05) _ambientTarget = target;
  }

  /// Ersatz, wenn das Tablet keinen Lichtsensor hat: mittlere Helligkeit des Kamerabilds (0..255).
  void onCameraLuma(double meanLuma) =>
      onAmbientLux(math.pow(10, (meanLuma.clamp(0, 255) / 255) * 3).toDouble() - 1);

  /// Einmal pro Sekunde aufrufen.
  void tick() {
    if (_state == DisplayState.off) return; // aus "off" kommt man nur über Eingänge
    final now = _clock();
    final idleFor = now.difference(_lastActivity);
    final DisplayState next;
    if (!occupied && idleFor >= settings.sleepAfter && now.difference(_wokeAt) >= settings.minOnTime) {
      next = DisplayState.off;
    } else if (idleFor >= settings.dimAfter) {
      next = DisplayState.idle;
    } else {
      next = DisplayState.active;
    }
    _setState(next);
  }

  // ---------- intern ----------

  /// Aufwachen zählt als Aktivität: Wer aufs Tablet zugeht, bekommt volle Helligkeit,
  /// gedimmt wird erst wieder nach [DisplaySettings.dimAfter].
  void _wake() {
    final now = _clock();
    if (_state == DisplayState.off) _wokeAt = now;
    _lastActivity = now;
    _setState(DisplayState.active);
  }

  void _setState(DisplayState s) {
    if (s == _state) return;
    _state = s;
    _stateSince = _clock();
    _motionFrames.clear();
  }
}

/// Logarithmische Kurve: 0 lx -> 0, ~10 lx -> 0.35, ~100 lx -> 0.67, ab 1000 lx -> 1.
double luxToBrightness(double lux) => (math.log(lux + 1) / math.ln10 / 3).clamp(0.0, 1.0);
