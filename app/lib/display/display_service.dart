import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:light/light.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'display_controller.dart';
import 'motion_detector.dart';
import 'screen_control.dart';

/// Verbindet den [DisplayController] mit Android: Wakelock, Fensterhelligkeit,
/// Lichtsensor und Kamera. Die UI hört auf [state] und [nightTheme].
///
/// "Aus" heißt mit Freigabe als Geräteadministrator ([screenAdmin]): Bildschirm wirklich aus,
/// die Kamera schaut im Hintergrund weiter nach Bewegung und schaltet ihn wieder ein.
/// Ohne Freigabe: Helligkeit 0 und schwarzes Bild.
class DisplayService extends ChangeNotifier with WidgetsBindingObserver {
  DisplayService([DisplaySettings settings = const DisplaySettings()]) : ctrl = DisplayController(settings);

  final DisplayController ctrl;
  late final MotionDetector _motion = MotionDetector(onMotion: _onMotion, onLuma: _onLuma);

  Timer? _ticker;
  Timer? _ramp;
  StreamSubscription<int>? _lux;
  bool _hasLightSensor = false;
  double _current = -1; // zuletzt gesetzte Helligkeit
  DisplayState _lastState = DisplayState.active;
  bool _lastNight = false;
  final ScreenControl screen = ScreenControl();
  Timer? _offTimer;
  bool _offByUs = false; // Bildschirm ist gerade von uns ausgeschaltet
  bool _resumed = true;

  DisplayState get state => ctrl.state;
  bool get nightTheme => ctrl.nightTheme;

  /// Bildschirm ist wirklich aus (Mikrofon und Verbindung sollen trotzdem weiterlaufen).
  bool get screenOff => _offByUs;

  /// Schalter "Bildschirm ganz ausschalten" anzeigen (nur auf Android).
  bool get screenSupported => screen.supported;
  bool get screenAdmin => screen.admin;

  /// Freigabe zurücknehmen (vor dem Deinstallieren nötig).
  Future<void> disableScreenOff() async {
    await screen.removeAdmin();
    notifyListeners();
  }

  /// Freigabe neu abfragen, z. B. nach der Rückkehr aus dem Android-Dialog.
  Future<void> refreshScreen() async {
    final before = (screen.supported, screen.admin, screen.secure);
    if (await screen.refresh()) unawaited(screen.keepAlive());
    if ((screen.supported, screen.admin, screen.secure) != before) notifyListeners();
  }

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    screen
      ..onMotion = _onScreenMotion
      ..listen();
    await refreshScreen();
    await WakelockPlus.enable();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      ctrl.tick();
      _apply();
    });
    _ramp = Timer.periodic(const Duration(milliseconds: 100), (_) => _rampStep());
    _lux = Light().lightSensorStream.listen((v) {
      _hasLightSensor = true;
      ctrl.onAmbientLux(v.toDouble());
    }, onError: (_) {});
    if (ctrl.settings.useCamera) await _motion.start();
    _apply();
  }

  void updateSettings(DisplaySettings s) {
    ctrl.settings = s;
    if (s.useCamera) {
      unawaited(_motion.start());
    } else {
      unawaited(_motion.stop());
    }
    _apply();
  }

  void touch() {
    ctrl.onTouch();
    _apply();
  }

  void wake() {
    ctrl.onWakeSignal();
    _apply();
  }

  void presence(bool present) {
    ctrl.onPresenceSensor(present);
    _apply();
  }

  void _onMotion(double area) {
    ctrl.onCameraMotion(area: area);
    _apply();
  }

  /// Kamera hat bei ausgeschaltetem Bildschirm jemanden gesehen (Android schaltet schon ein).
  void _onScreenMotion() {
    ctrl.onActivity();
    _apply();
  }

  /// Sprachassistent ist aufgegangen.
  void activity() {
    ctrl.onActivity();
    _apply();
  }

  void _onLuma(double luma) {
    if (!_hasLightSensor) ctrl.onCameraLuma(luma);
  }

  void _apply() {
    if (ctrl.state != _lastState) {
      ctrl.state == DisplayState.off ? _scheduleOff() : _screenOn();
    }
    if (ctrl.state != _lastState || ctrl.nightTheme != _lastNight) {
      _lastState = ctrl.state;
      _lastNight = ctrl.nightTheme;
      notifyListeners();
    }
  }

  /// Erst langsam abdunkeln, dann wirklich ausschalten.
  void _scheduleOff() {
    _offTimer?.cancel();
    if (!screen.admin) return;
    _offTimer = Timer(const Duration(seconds: 3), () async {
      if (ctrl.state != DisplayState.off || _offByUs) return;
      // Die Kamera übergibt an die Bewegungserkennung von Android, die auch bei dunklem Bildschirm läuft.
      _offByUs = true;
      await _motion.stop();
      if (ctrl.state == DisplayState.off && await screen.off(watch: ctrl.settings.useCamera)) return;
      _offByUs = false;
      if (ctrl.settings.useCamera && _resumed) unawaited(_motion.start());
    });
  }

  void _screenOn() {
    _offTimer?.cancel();
    if (!_offByUs) return;
    _offByUs = false;
    unawaited(screen.on());
  }

  /// Helligkeit sanft nachführen: aufwachen schnell, dimmen langsam.
  void _rampStep() {
    final target = ctrl.brightness;
    if (_current < 0) {
      _set(target);
      return;
    }
    final diff = target - _current;
    if (diff.abs() < 0.005) return;
    final step = diff > 0 ? 0.25 : 0.04;
    _set(diff.abs() <= step ? target : _current + step * diff.sign);
  }

  void _set(double v) {
    _current = v;
    ScreenBrightness().setApplicationScreenBrightness(v.clamp(0.0, 1.0)).catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumed = true;
      WakelockPlus.enable();
      ctrl.onTouch();
      _apply();
      unawaited(refreshScreen());
      // Kurz warten, bis die Bewegungserkennung von Android die Kamera freigegeben hat.
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (_resumed && ctrl.settings.useCamera && !_offByUs) _motion.start();
      });
    } else if (state == AppLifecycleState.paused) {
      _resumed = false;
      _motion.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _ramp?.cancel();
    _offTimer?.cancel();
    _lux?.cancel();
    _motion.stop();
    ScreenBrightness().resetApplicationScreenBrightness().catchError((_) {});
    super.dispose();
  }
}
