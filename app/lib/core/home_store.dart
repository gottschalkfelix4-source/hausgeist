import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../display/display_controller.dart';
import '../voice/wake_word.dart';
import 'api.dart';
import 'demo.dart';
import 'device.dart';

/// Zustand des Raums: Geräte, Verbindung, Bedienung. Ohne [api] läuft alles lokal (Demo).
class HomeStore extends ChangeNotifier {
  HomeStore(this.api, {this.onWake, this.onDisplaySettings, this.onPresence});

  final Api? api;
  final VoidCallback? onWake;
  final void Function(DisplaySettings)? onDisplaySettings;
  final void Function(bool present)? onPresence;

  String room = '';
  String? presenceEntity;
  List<Device> devices = [];
  bool connected = false;
  String? error;

  /// Aktivierungswort für dieses Tablet (ändert sich, wenn es in der Verwaltung geändert wird).
  WakeConfig wake = WakeConfig.off;
  final _wakeResults = StreamController<Map<String, dynamic>>.broadcast();

  /// Neuere App-Version auf GitHub (`version`, `apk_url`), sonst null.
  Map<String, dynamic>? update;
  DateTime? _updateChecked;

  bool get demo => api == null;
  List<Device> get tiles => devices.where((d) => d.kind != DeviceKind.sensor).toList();

  bool _disposed = false;
  StreamSubscription<Map<String, dynamic>>? _events;
  final _deferred = <String, Map<String, dynamic>>{};
  final _deferTimers = <String, Timer>{};
  final _throttle = <String, _Pending>{};

  Future<void> start() async {
    if (demo) {
      room = 'Wohnzimmer';
      devices = demoDevices();
      connected = true;
      notifyListeners();
      return;
    }
    unawaited(_connectLoop());
  }

  Future<void> _connectLoop() async {
    while (!_disposed) {
      try {
        await _load();
        final done = Completer<void>();
        _events = api!.events().listen(_onEvent,
            onError: (_) => done.isCompleted ? null : done.complete(),
            onDone: () => done.isCompleted ? null : done.complete(),
            cancelOnError: true);
        connected = true;
        error = null;
        notifyListeners();
        unawaited(_checkUpdate());
        await done.future;
        // 4000: Server hat Raum/Einstellungen geändert -> sofort neu laden.
        if (api!.closeCode == 4000) continue;
        if (api!.closeCode == 4401) error = 'Token ungültig';
      } catch (e) {
        error = '$e';
      }
      connected = false;
      if (!_disposed) notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _load() async {
    final me = await api!.me();
    final r = (me['room'] as Map?)?.cast<String, dynamic>();
    room = r?['name'] as String? ?? 'Kein Raum zugewiesen';
    presenceEntity = r?['presence_entity'] as String?;
    final list = <Device>[];
    for (final s in (me['entities'] as List? ?? const [])) {
      final d = Device.fromHa((s as Map).cast<String, dynamic>());
      if (d != null) list.add(d);
    }
    list.sort((a, b) => a.kind.index.compareTo(b.kind.index));
    devices = list;
    final disp = me['display'];
    if (disp is Map) onDisplaySettings?.call(DisplaySettings.fromJson(disp.cast<String, dynamic>()));
    final w = me['wake'];
    wake = w is Map ? WakeConfig.fromJson(w.cast<String, dynamic>()) : WakeConfig.off;
  }

  /// Dieses Tablet hat das Aktivierungswort gehört. Der Server entscheidet, welches Tablet
  /// antwortet, wenn es mehrere gehört haben. Ohne Verbindung oder Antwort antwortet es selbst.
  Future<bool> mayAnswer({required double level, required bool presence, required bool near}) async {
    if (demo || !connected) return true;
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final result = _wakeResults.stream.firstWhere((m) => m['id'] == id);
    try {
      api!.send({'type': 'wake_heard', 'id': id, 'level': level, 'presence': presence, 'near': near});
      return (await result.timeout(const Duration(milliseconds: 1500)))['accept'] == true;
    } catch (_) {
      return true;
    }
  }

  /// Höchstens alle 12 Stunden nachsehen, ob es eine neuere App gibt.
  Future<void> _checkUpdate() async {
    final last = _updateChecked;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 12)) return;
    _updateChecked = DateTime.now();
    try {
      final latest = await api!.appUpdate();
      final version = latest['version'] as String?;
      final current = (await PackageInfo.fromPlatform()).version;
      final newer = version != null && latest['apk_url'] != null && isNewerVersion(version, current);
      update = newer ? latest : null;
      if (!_disposed) notifyListeners();
    } catch (_) {
      // Kein Internet am Server o. ä.: kein Hinweis, beim nächsten Mal wieder.
    }
  }

  void _onEvent(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'wake':
        onWake?.call();
      case 'wake_result':
        _wakeResults.add(m);
      case 'state':
        final s = (m['state'] as Map).cast<String, dynamic>();
        final id = s['entity_id'] as String;
        if (id == presenceEntity) onPresence?.call(const {'on', 'home', 'detected'}.contains(s['state']));
        _applyRemote(id, s);
    }
  }

  void _applyRemote(String id, Map<String, dynamic> s) {
    final d = devices.where((x) => x.id == id).firstOrNull;
    if (d == null) return;
    final since = DateTime.now().difference(d.touched);
    const hold = Duration(milliseconds: 1500);
    if (since < hold) {
      // Während jemand regelt, nicht mit älteren HA-Zuständen dazwischenfunken.
      _deferred[id] = s;
      _deferTimers[id]?.cancel();
      _deferTimers[id] = Timer(hold - since, () {
        final latest = _deferred.remove(id);
        if (latest != null) _applyRemote(id, latest);
      });
      return;
    }
    d.applyHa(s);
    notifyListeners();
  }

  // ---------- Bedienung ----------

  void toggle(Device d) {
    switch (d.kind) {
      case DeviceKind.light:
        d.on = !d.on;
        if (d.on && d.bri == 0) d.bri = 50;
        _send(d, d.on ? 'on' : 'off');
      case DeviceKind.climate:
        d.on = !d.on;
        d.on ? _send(d, 'set_mode', d.hvacMode) : _send(d, 'off');
      case DeviceKind.cover:
        d.position = d.position > 0 ? 0 : 100;
        _send(d, d.position > 0 ? 'open' : 'close');
      case DeviceKind.media:
        d.on = !d.on;
        _send(d, 'play_pause');
      case DeviceKind.lock:
        d.on = !d.on;
        _send(d, d.on ? 'lock' : 'unlock');
      case DeviceKind.scene:
        runScene(d);
        return;
      case DeviceKind.toggle:
        d.on = !d.on;
        _send(d, d.on ? 'on' : 'off');
      case DeviceKind.sensor:
        return;
    }
    notifyListeners();
  }

  /// Wischen über die Kachel / Regler: [v] normiert 0..1.
  void setLevel(Device d, double v) {
    v = v.clamp(0.0, 1.0);
    switch (d.kind) {
      case DeviceKind.light:
        d.bri = (v * 100).round();
        d.on = d.bri > 0;
        d.on ? _send(d, 'on', d.bri) : _send(d, 'off');
      case DeviceKind.climate:
        setTarget(d, d.minTemp + v * (d.maxTemp - d.minTemp));
        return;
      case DeviceKind.cover:
        d.position = (v * 100).round();
        _send(d, 'set_position', d.position);
      case DeviceKind.media:
        d.volume = (v * 100).round();
        _send(d, 'set_volume', d.volume / 100);
      default:
        return;
    }
    notifyListeners();
  }

  void setTarget(Device d, double t) {
    final step = d.tempStep <= 0 ? 0.5 : d.tempStep;
    d.target = ((t / step).round() * step).clamp(d.minTemp, d.maxTemp);
    if (!d.on) {
      d.on = true;
      _send(d, 'set_mode', d.hvacMode);
    }
    _send(d, 'set_temperature', d.target);
    notifyListeners();
  }

  void setClimateMode(Device d, String mode) {
    d
      ..hvacMode = mode
      ..on = true;
    _send(d, 'set_mode', mode);
    notifyListeners();
  }

  void setFan(Device d, String fan) {
    d.fanMode = fan;
    _send(d, 'set_fan_mode', fan);
    notifyListeners();
  }

  void setSwing(Device d, bool on) {
    final mode = on ? d.swingModes.firstWhere((m) => m != 'off', orElse: () => 'on') : 'off';
    d.swingMode = mode;
    _send(d, 'set_swing_mode', mode);
    notifyListeners();
  }

  void setEco(Device d, bool on) {
    final mode = on ? 'eco' : (d.presets.contains('none') ? 'none' : d.presets.firstWhere((p) => p != 'eco', orElse: () => 'none'));
    d.preset = mode;
    _send(d, 'set_preset', mode);
    notifyListeners();
  }

  void setColor(Device d, double hue, double sat) {
    d
      ..hue = hue
      ..sat = sat
      ..lightMode = 'color'
      ..on = true;
    if (d.bri == 0) d.bri = 50;
    _send(d, 'on', null, {'hs_color': [hue.roundToDouble(), (sat * 100).roundToDouble()]});
    notifyListeners();
  }

  void setKelvin(Device d, int k) {
    d
      ..kelvin = k
      ..lightMode = 'white'
      ..on = true;
    if (d.bri == 0) d.bri = 50;
    _send(d, 'on', null, {'color_temp_kelvin': k});
    notifyListeners();
  }

  /// Nur Anzeige umschalten (Farbe / Weißtöne), ohne Befehl.
  void setLightMode(Device d, String mode) {
    d.lightMode = mode;
    notifyListeners();
  }

  void media(Device d, String action) {
    if (action == 'play_pause') return toggle(d);
    _send(d, action);
  }

  void runScene(Device d) {
    _send(d, 'activate');
    if (demo) applyDemoScene(devices);
    d.flash = true;
    notifyListeners();
    Timer(const Duration(milliseconds: 1600), () {
      d.flash = false;
      if (!_disposed) notifyListeners();
    });
  }

  // ---------- Senden mit Drosselung (Regler schicken max. alle 250 ms) ----------

  void _send(Device d, String action, [Object? value, Map<String, dynamic>? data]) {
    d.touched = DateTime.now();
    if (api == null) return;
    final key = '${d.id}|$action|${data?.keys.join()}';
    final p = _throttle.putIfAbsent(key, _Pending.new);
    p.args = (action, value, data);
    if (p.timer == null) _flush(d.id, key, p);
  }

  void _flush(String id, String key, _Pending p) {
    final a = p.args;
    p.args = null;
    if (a == null) {
      _throttle.remove(key);
      return;
    }
    api!.command(id, a.$1, a.$2, a.$3).catchError((Object e) {
      error = '$e';
      notifyListeners();
    });
    p.timer = Timer(const Duration(milliseconds: 250), () {
      p.timer = null;
      _flush(id, key, p);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    _wakeResults.close();
    for (final t in _deferTimers.values) {
      t.cancel();
    }
    for (final p in _throttle.values) {
      p.timer?.cancel();
    }
    super.dispose();
  }
}

class _Pending {
  (String, Object?, Map<String, dynamic>?)? args;
  Timer? timer;
}
