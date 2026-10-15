import 'dart:math' as math;
import 'dart:ui' show Color;

enum DeviceKind { light, climate, cover, media, scene, lock, toggle, sensor }

/// Klima-Modi wie im Prototyp: Name, Verb für den Status, Farbe.
class ClimateMode {
  const ClimateMode(this.label, this.verb, this.color);
  final String label;
  final String verb;
  final Color color;
}

const climateModes = {
  'cool': ClimateMode('Kühlen', 'Kühlt auf', Color(0xFF4AA3FF)),
  'heat': ClimateMode('Heizen', 'Heizt auf', Color(0xFFFF8A3D)),
  'auto': ClimateMode('Automatik', 'Automatik', Color(0xFF5FD17A)),
  'heat_cool': ClimateMode('Automatik', 'Automatik', Color(0xFF5FD17A)),
  'dry': ClimateMode('Entfeuchten', 'Entfeuchtet', Color(0xFF3CC8C8)),
  'fan_only': ClimateMode('Lüften', 'Lüftet', Color(0xFFB8C2D6)),
};

const fanLabels = {
  'auto': 'Auto', 'quiet': 'Leise', 'silent': 'Leise', 'low': 'Niedrig', 'medium': 'Mittel',
  'middle': 'Mittel', 'high': 'Hoch', 'turbo': 'Turbo', 'strong': 'Turbo', 'on': 'An', 'off': 'Aus',
};

String fanLabel(String f) => fanLabels[f.toLowerCase()] ?? (f.isEmpty ? f : f[0].toUpperCase() + f.substring(1));

/// Ein Gerät, so wie die Kacheln es brauchen. Wird aus einem Home-Assistant-Zustand gebaut.
class Device {
  Device({required this.id, required this.kind, required this.name});

  final String id; // entity_id
  final DeviceKind kind;
  String name;
  bool on = false;

  // Licht
  int bri = 100; // 0..100
  bool dimmable = true;
  bool hasColor = false;
  bool hasKelvin = false;
  String lightMode = 'white'; // color | white
  int kelvin = 3000;
  int minKelvin = 2200;
  int maxKelvin = 6500;
  double hue = 30; // 0..360
  double sat = 0.6; // 0..1

  // Klima
  double target = 22;
  double? current;
  double? humidity;
  String hvacMode = 'cool';
  List<String> hvacModes = const [];
  String? fanMode;
  List<String> fanModes = const [];
  double minTemp = 16;
  double maxTemp = 30;
  double tempStep = 0.5;
  String? swingMode;
  List<String> swingModes = const [];
  String? preset;
  List<String> presets = const [];

  // Rollo
  int position = 0;

  // Medien
  int volume = 30;
  String? title;
  String? artist;

  // Sensor
  String stateText = '';
  String? unit;
  String? deviceClass;

  /// Szene kurz als "ausgeführt" markieren.
  bool flash = false;

  /// Letzte lokale Bedienung; frische HA-Zustände werden kurz zurückgehalten, damit Regler nicht springen.
  DateTime touched = DateTime.fromMillisecondsSinceEpoch(0);

  bool get adjustable => switch (kind) {
        DeviceKind.light => dimmable,
        DeviceKind.climate || DeviceKind.cover || DeviceKind.media => true,
        _ => false,
      };

  bool get isOn => switch (kind) {
        DeviceKind.cover => position > 0,
        DeviceKind.scene => flash,
        _ => on,
      };

  bool get swing => swingMode != null && swingMode != 'off';
  bool get eco => preset == 'eco';
  bool get hasEco => presets.contains('eco');

  /// Wert, den eine Wischgeste über die Kachel verändert, normiert auf 0..1.
  double get level => switch (kind) {
        DeviceKind.light => on ? bri / 100 : 0,
        DeviceKind.climate => (target - minTemp) / (maxTemp - minTemp),
        DeviceKind.cover => position / 100,
        DeviceKind.media => volume / 100,
        _ => 0,
      };

  static DeviceKind? kindFor(String entityId) => switch (entityId.split('.').first) {
        'light' => DeviceKind.light,
        'climate' => DeviceKind.climate,
        'cover' => DeviceKind.cover,
        'media_player' => DeviceKind.media,
        'scene' => DeviceKind.scene,
        'lock' => DeviceKind.lock,
        'switch' || 'fan' || 'input_boolean' => DeviceKind.toggle,
        'sensor' || 'binary_sensor' => DeviceKind.sensor,
        _ => null,
      };

  static Device? fromHa(Map<String, dynamic> s) {
    final id = s['entity_id'] as String;
    final kind = kindFor(id);
    if (kind == null) return null;
    return Device(id: id, kind: kind, name: id)..applyHa(s);
  }

  void applyHa(Map<String, dynamic> s) {
    final st = '${s['state']}';
    final a = (s['attributes'] as Map?)?.cast<String, dynamic>() ?? const {};
    name = (a['friendly_name'] as String?) ?? name;
    stateText = st;
    switch (kind) {
      case DeviceKind.light:
        on = st == 'on';
        final modes = (a['supported_color_modes'] as List?)?.cast<String>() ?? const ['brightness'];
        hasColor = modes.any((m) => const {'hs', 'xy', 'rgb', 'rgbw', 'rgbww'}.contains(m));
        hasKelvin = modes.contains('color_temp');
        dimmable = !(modes.length == 1 && modes.first == 'onoff');
        if (a['brightness'] is num) bri = math.max(1, ((a['brightness'] as num) / 255 * 100).round());
        minKelvin = (a['min_color_temp_kelvin'] as num?)?.toInt() ?? minKelvin;
        maxKelvin = (a['max_color_temp_kelvin'] as num?)?.toInt() ?? maxKelvin;
        if (a['color_temp_kelvin'] is num) kelvin = (a['color_temp_kelvin'] as num).toInt();
        final hs = a['hs_color'] as List?;
        if (hs != null && hs.length == 2) {
          hue = (hs[0] as num).toDouble();
          sat = (hs[1] as num).toDouble() / 100;
        }
        final cm = a['color_mode'] as String?;
        if (cm != null) lightMode = cm == 'color_temp' ? 'white' : (hasColor && cm != 'brightness' && cm != 'onoff' ? 'color' : 'white');
      case DeviceKind.climate:
        on = st != 'off' && st != 'unavailable';
        hvacModes = ((a['hvac_modes'] as List?)?.cast<String>() ?? const []).where((m) => m != 'off').toList();
        if (on) {
          hvacMode = st;
        } else if (!hvacModes.contains(hvacMode) && hvacModes.isNotEmpty) {
          hvacMode = hvacModes.first;
        }
        minTemp = (a['min_temp'] as num?)?.toDouble() ?? minTemp;
        maxTemp = (a['max_temp'] as num?)?.toDouble() ?? maxTemp;
        tempStep = (a['target_temp_step'] as num?)?.toDouble() ?? tempStep;
        target = (a['temperature'] as num?)?.toDouble() ?? target;
        current = (a['current_temperature'] as num?)?.toDouble() ?? current;
        humidity = (a['current_humidity'] as num?)?.toDouble() ?? humidity;
        fanMode = a['fan_mode'] as String?;
        fanModes = (a['fan_modes'] as List?)?.cast<String>() ?? const [];
        swingMode = a['swing_mode'] as String?;
        swingModes = (a['swing_modes'] as List?)?.cast<String>() ?? const [];
        preset = a['preset_mode'] as String?;
        presets = (a['preset_modes'] as List?)?.cast<String>() ?? const [];
      case DeviceKind.cover:
        position = (a['current_position'] as num?)?.toInt() ?? (st == 'open' ? 100 : 0);
      case DeviceKind.media:
        on = st == 'playing';
        if (a['volume_level'] is num) volume = ((a['volume_level'] as num) * 100).round();
        title = a['media_title'] as String?;
        artist = a['media_artist'] as String?;
      case DeviceKind.lock:
        on = st == 'locked';
      case DeviceKind.toggle:
        on = st == 'on';
      case DeviceKind.scene:
        break;
      case DeviceKind.sensor:
        on = st == 'on';
        unit = a['unit_of_measurement'] as String?;
        deviceClass = a['device_class'] as String?;
    }
  }
}

// ---------- Farben ----------

Color hsvColor(double h, double s, [double v = 1]) {
  double f(int n) {
    final k = (n + h / 60) % 6;
    return v - v * s * math.max(0, math.min(math.min(k, 4 - k), 1));
  }

  return Color.fromARGB(255, (f(5) * 255).round(), (f(3) * 255).round(), (f(1) * 255).round());
}

Color kelvinColor(int k) {
  const p = [(2200, [255, 160, 80]), (4000, [255, 228, 196]), (6500, [220, 233, 255])];
  final lo = k <= 4000 ? p[0] : p[1], hi = k <= 4000 ? p[1] : p[2];
  final t = ((k - lo.$1) / (hi.$1 - lo.$1)).clamp(0.0, 1.0);
  int c(int i) => (lo.$2[i] + (hi.$2[i] - lo.$2[i]) * t).round();
  return Color.fromARGB(255, c(0), c(1), c(2));
}

Color lightColor(Device d) => d.lightMode == 'color' && d.hasColor ? hsvColor(d.hue, d.sat) : kelvinColor(d.kelvin);

Color accentOf(Device d) => switch (d.kind) {
      DeviceKind.light => lightColor(d),
      DeviceKind.climate => climateModes[d.hvacMode]?.color ?? const Color(0xFF5FD17A),
      DeviceKind.lock => const Color(0xFF34C759),
      _ => const Color(0xFFFFB340),
    };

// ---------- Texte ----------

String temp(double v) {
  final r = (v * 2).round() / 2;
  final s = r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toStringAsFixed(1).replaceAll('.', ',');
  return '$s °C';
}

String statusOf(Device d) {
  switch (d.kind) {
    case DeviceKind.light:
      if (!d.on) return 'Aus';
      final extra = !d.hasColor && !d.hasKelvin ? '' : (d.lightMode == 'color' ? ' · Farbe' : ' · ${d.kelvin} K');
      return d.dimmable ? '${d.bri} %$extra' : 'An';
    case DeviceKind.climate:
      if (!d.on) return 'Aus';
      final m = climateModes[d.hvacMode];
      final verb = m?.verb ?? d.hvacMode;
      return d.hvacMode == 'auto' || d.hvacMode == 'heat_cool' || d.hvacMode == 'fan_only' ? verb : '$verb ${temp(d.target)}';
    case DeviceKind.cover:
      return d.position == 0 ? 'Geschlossen' : d.position == 100 ? 'Offen' : '${d.position} % offen';
    case DeviceKind.media:
      return d.on ? 'Spielt${d.artist != null ? ' · ${d.artist}' : ''}' : 'Pausiert';
    case DeviceKind.scene:
      return d.flash ? 'Ausgeführt' : 'Szene';
    case DeviceKind.lock:
      return d.on ? 'Verriegelt' : 'Entriegelt';
    case DeviceKind.toggle:
      return d.on ? 'An' : 'Aus';
    case DeviceKind.sensor:
      return '${d.stateText}${d.unit != null ? ' ${d.unit}' : ''}';
  }
}
